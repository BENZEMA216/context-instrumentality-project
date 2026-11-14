// Actual worker/monitor regressions. All files and metadata results are synthetic.
private final class ProbeFailedMetadataQuery: NSMetadataQuery {
 override func start() -> Bool { false }
 override func stop() {}
}

extension Probe {
 static func verifyTypedProviderObservations(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  try await verifyPendingProviderReservation(root:root,manifest:manifest,audio:audio)
  try await verifyBadProviderHeadDoesNotStarveTail(root:root,manifest:manifest,audio:audio)
  try await verifyTypedNegativeRechecks(root:root,manifest:manifest,audio:audio)
  try await verifyTypedNegativeSurvivesLateTranscript(root:root,manifest:manifest,audio:audio)
  try await verifyTypedCacheMigration(root:root,manifest:manifest,audio:audio)
  try await verifyTypedIdentityFailures(root:root,manifest:manifest,audio:audio)
  try await verifyAutomaticCtimeRepair(root:root,manifest:manifest,audio:audio)
  try await verifyTypedMonitorDiagnostics(root:root)
 }

 static func providerCache(_ local:URL) throws -> [String:Any] {
  try JSONSerialization.jsonObject(with:Data(contentsOf:local.appendingPathComponent("ICloudDriveLibrary/provider-evidence.json"))) as! [String:Any]
 }

 // A23: a negative head must not hide 120 healthy files across cold rounds.
 // Source audio is removed after export, so rechecks cannot silently re-export.
 static func verifyBadProviderHeadDoesNotStarveTail(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  for fault in ["not_uploaded","missing_key","resource_error","not_ubiquitous","invalid_file","missing_file","identity_changed"] {
   let (repo,texts,access,_,sources,local,folder)=try await livenessFixture(root:root,
    name:"bad-provider-head-"+fault,count:40,manifest:manifest,audio:audio)
   try seedContinuationExports(repo:repo,local:local,folder:folder)
   let worker=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
   _ = try await worker.perform(.load,gate:ICloudDriveCancellation())
   access.typedStatus = .uploaded
   _ = try await worker.perform(.sync(sources,Set(sources.map(\.id)),maximumJobs:0),gate:ICloudDriveCancellation())
   for _ in 0..<5 { _ = try await worker.perform(.continueProviderStatus,gate:ICloudDriveCancellation()) }
   let cacheFile=local.appendingPathComponent("ICloudDriveLibrary/provider-evidence.json")
   var cache=try providerCache(local)
   let observations=cache["observations"] as! [String:[String:Any]]
   let paths=Set(observations.keys), head=paths.filter { $0.hasPrefix("audio/") }.sorted().first!
   try check(paths.count == 121,"\(fault): bad-head fixture begins with all 121 exported paths")
   cache["nextPath"]=head
   try JSONSerialization.data(withJSONObject:cache,options:[.sortedKeys]).write(to:cacheFile,options:.atomic)
   let grant=local.appendingPathComponent("ICloudDriveLibrary/state.json"), grantBytes=try Data(contentsOf:grant)
   for source in sources { try FileManager.default.removeItem(at:repo.audioURL(for:source)) }
   let target=folder.appendingPathComponent("RecordForAgent-"+(try SyncEvidenceArchive(root:local,stream:"icloud_drive").load()!.context.libraryID!.uuidString.lowercased())).appendingPathComponent(head)
   if fault == "missing_file" { try FileManager.default.removeItem(at:target) }
   else if fault == "identity_changed" { try check(chmod(target.path,0o640) == 0,"synthetic head ctime changes") }
   let statuses:[String:ICloudDriveProviderObservationStatus]=[
    "not_uploaded":.notUploaded,"missing_key":.missingKey,"resource_error":.resourceError,
    "not_ubiquitous":.notUbiquitous,"invalid_file":.invalidFile]
   access.duringMetadata={ url in
    access.typedStatus = url.path.hasSuffix("/"+head) ? (statuses[fault] ?? .uploaded) : .uploaded
   }
   var uploaded = -1, pending = -1
   var checked=Set<String>()
   for round in 0..<6 {
    let cold=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
    _ = try await cold.perform(.load,gate:ICloudDriveCancellation())
    access.metadataPaths=[]
    let state = try await cold.perform(round == 0 ? .refreshProviderStatus : .continueProviderStatus,
     gate:ICloudDriveCancellation())
    uploaded=state.uploadedFileCount; pending=state.pendingCloudFileCount
    try check(access.metadataPaths.count <= 32,"\(fault): cold round keeps the 32-provider-query limit")
    for path in access.metadataPaths { if let relative=paths.first(where:{ path.hasSuffix("/"+$0) }) { checked.insert(relative) } }
   }
   let final=try providerCache(local)["observations"] as! [String:[String:Any]]
   try check(uploaded == 120 && pending == 1,
    "\(fault): exactly the bad head remains unresolved; the healthy 120-file tail completes")
   try check(final[head]?["uploaded"] as? Bool != true && paths.subtracting([head]).allSatisfy { final[$0]?["uploaded"] as? Bool == true },
    "\(fault): the bad head never borrows an old positive or another file's result")
   try check(paths.subtracting([head]).isSubset(of:checked),"\(fault): every healthy path receives a new provider query")
   try check(try Data(contentsOf:grant) == grantBytes,"\(fault): rechecks preserve scope and export ledger with source audio absent")
   try check(access.starts == access.stops,"\(fault): security-scoped access is balanced")
  }
 }

 static func verifyPendingProviderReservation(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let (repo,texts,access,worker,sources,local,_)=try await livenessFixture(root:root,
    name:"pending-reservation",count:40,manifest:manifest,audio:audio)
  access.typedStatus = .uploaded
  _ = try await worker.perform(.sync(sources,Set(sources.map(\.id))),gate:ICloudDriveCancellation())
  for _ in 0..<5 { _ = try await worker.perform(.continueProviderStatus,gate:ICloudDriveCancellation()) }
  var cache=try providerCache(local)
  var observations=cache["observations"] as! [String:[String:Any]]
  try check(observations.count == 121,"pending quota fixture has a complete large metadata cache")
  let pending=Set(observations.keys.filter { $0.hasPrefix("audio/") }.sorted().suffix(24))
  for path in pending {
   observations[path]?["uploaded"]=false
   observations[path]?["status"]="not_uploaded"
   observations[path]?["failureCode"]="provider_pending"
   observations[path]?["observedAtMS"]=Int64(Date().timeIntervalSince1970 * 1000)-120_000
   observations[path]?.removeValue(forKey:"firstConfirmedAtMS")
   observations[path]?.removeValue(forKey:"latestConfirmedAtMS")
  }
  cache["observations"]=observations
  cache["nextPath"]=observations.keys.filter { $0.hasPrefix("commits/") }.sorted().first!
  cache.removeValue(forKey:"providerPriorityPaths")
  let file=local.appendingPathComponent("ICloudDriveLibrary/provider-evidence.json")
  try JSONSerialization.data(withJSONObject:cache,options:[.sortedKeys]).write(to:file,options:.atomic)
  for source in sources { try FileManager.default.removeItem(at:repo.audioURL(for:source)) }
  var remaining=pending
  for _ in 0..<3 {
   let cold=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
   _ = try await cold.perform(.load,gate:ICloudDriveCancellation())
   access.metadataPaths=[]
   _ = try await cold.perform(.continueProviderStatus,gate:ICloudDriveCancellation())
   let after=try providerCache(local)["observations"] as! [String:[String:Any]]
   let next=Set(remaining.filter { after[$0]?["uploaded"] as? Bool != true })
   try check(remaining.count-next.count >= min(8,remaining.count),
    "each bounded cold opportunity reserves eight pending rechecks ahead of historical positives")
   try check(access.metadataPaths.count <= 32,"pending reservation preserves the 32 metadata query cap")
   try check(access.metadataPaths.contains { $0.contains("/commits/") },
    "pending reservation retains historical kind coverage")
   remaining=next
  }
  try check(remaining.isEmpty,"24 stale pending observations clear within three cold opportunities without source audio")
 }

 static func verifyTypedNegativeRechecks(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let (repo,texts,access,worker,sources,local,_)=try await livenessFixture(root:root,
    name:"typed-negative",count:1,manifest:manifest,audio:audio)
  access.typedStatus = .uploaded
  let initial=try await worker.perform(.sync(sources,Set(sources.map(\.id))),gate:ICloudDriveCancellation())
  try check(initial.uploadedFileCount == 4,"typed fixture begins with positive provider observations")
  try check(initial.cloudConfirmedRecordingIDs == Set(sources.map(\.id)),
    "confirmed recording IDs are projected from provider evidence")
  let initialObservations=try providerCache(local)["observations"] as! [String:[String:Any]]
  let firstTimes=initialObservations.mapValues { $0["firstConfirmedAtMS"] as! Int64 }
  // The following provider checks must not reopen even the synthetic source.
  try FileManager.default.removeItem(at:repo.audioURL(for:sources[0]))
  for status:ICloudDriveProviderObservationStatus in [.notUploaded,.missingKey,.resourceError,.notUbiquitous,.invalidFile] {
   access.typedStatus = .uploaded
   _ = try await worker.perform(.refreshProviderStatus,gate:ICloudDriveCancellation())
   let positives=try providerCache(local)["observations"] as! [String:[String:Any]]
   try await Task.sleep(nanoseconds:2_000_000)
   access.typedStatus=status
   let state=try await worker.perform(.refreshProviderStatus,gate:ICloudDriveCancellation())
   try check(state.uploadedFileCount == 0 && state.pendingCloudFileCount == 4,
    "latest \(status.rawValue) replaces every older positive")
   try check(state.cloudConfirmedRecordingIDs.isEmpty && state.locallyWrittenRecordingIDs == Set(sources.map(\.id)),
    "negative provider metadata withdraws confirmation while retaining local export evidence")
   let cache=try providerCache(local)["observations"] as! [String:[String:Any]]
   try check(cache.values.allSatisfy { $0["status"] as? String == status.rawValue && $0["uploaded"] as? Bool == false },
    "typed \(status.rawValue) is persisted independently from legacy Bool")
   try check(cache.allSatisfy { path, observation in
    observation["firstConfirmedAtMS"] as? Int64 == firstTimes[path]
     && observation["latestConfirmedAtMS"] as? Int64 == positives[path]?["latestConfirmedAtMS"] as? Int64
   },"negative recheck preserves first and latest positive times for \(status.rawValue)")
   let counts=state.diagnosticObservation.counts
   let classified:Int
   switch status {
   case .notUploaded: classified=counts.providerReportedPendingFiles
   case .missingKey: classified=counts.providerMissingKeyFiles
   case .resourceError: classified=counts.providerResourceErrorFiles
   case .notUbiquitous: classified=counts.providerNotUbiquitousFiles
   case .invalidFile: classified=counts.providerInvalidFileFiles
   default: classified = -1
   }
   try check(classified == 4 && counts.retainedHistoricalPositiveFiles == 0
    && (status == .notUploaded || counts.providerReportedPendingFiles == 0),
    "diagnostics preserve the exact \(status.rawValue) cause without manufacturing explicit false")
  }
  let last=try providerCache(local)["observations"] as! [String:[String:Any]]
  let cold=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
  let loaded=try await cold.perform(.load,gate:ICloudDriveCancellation())
  try check(loaded.diagnosticObservation.firstProviderConfirmationAt == initial.diagnosticObservation.firstProviderConfirmationAt
    && loaded.diagnosticObservation.latestProviderConfirmationAt != nil,
    "first and latest positive confirmation facts survive restart behind a negative result")
  let restored=try providerCache(local)["observations"] as! [String:[String:Any]]
  try check((last as NSDictionary) == (restored as NSDictionary),"cold loading keeps exact typed observations and times")
 }

 static func verifyTypedCacheMigration(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let (repo,texts,access,worker,sources,local,_)=try await livenessFixture(root:root,
    name:"typed-migration",count:1,manifest:manifest,audio:audio)
  access.uploaded=true
  _ = try await worker.perform(.sync(sources,Set(sources.map(\.id))),gate:ICloudDriveCancellation())
  let path=local.appendingPathComponent("ICloudDriveLibrary/provider-evidence.json")
  var legacy=try providerCache(local)
  var observations=legacy["observations"] as! [String:[String:Any]]
  for key in observations.keys {
   observations[key]?["uploaded"]=false
   observations[key]?["failureCode"]="provider_pending"
   observations[key]?.removeValue(forKey:"status")
   observations[key]?.removeValue(forKey:"firstConfirmedAtMS")
   observations[key]?.removeValue(forKey:"latestConfirmedAtMS")
  }
  legacy["observations"]=observations
  try JSONSerialization.data(withJSONObject:legacy,options:[.sortedKeys]).write(to:path,options:.atomic)
  let cold=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
  let migrated=try await cold.perform(.load,gate:ICloudDriveCancellation())
  try check(migrated.diagnosticObservation.counts.providerLegacyUnknownFiles == 4
    && migrated.diagnosticObservation.counts.providerReportedPendingFiles == 0,
    "legacy false cache cannot invent an explicit provider false observation")
  try check(migrated.diagnosticObservation.firstProviderConfirmationAt == nil
    && migrated.diagnosticObservation.latestProviderConfirmationAt == nil,
    "legacy cache cannot invent first or latest confirmation times")
  for key in observations.keys {
   observations[key]?["uploaded"]=true
   observations[key]?["status"]="missing_key"
   observations[key]?["failureCode"]="missing_key"
  }
  legacy["observations"]=observations
  try JSONSerialization.data(withJSONObject:legacy,options:[.sortedKeys]).write(to:path,options:.atomic)
  let conflicting=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
  let checks=access.metadataChecks
  let state=try await conflicting.perform(.inspectProviderStatus,
    gate:ICloudDriveCancellation(takeProviderMetadataPermit:{ false }))
  try check(access.metadataChecks == checks && state.uploadedFileCount == 0
    && state.diagnosticObservation.counts.providerMissingKeyFiles == 4
    && state.diagnosticObservation.counts.retainedHistoricalPositiveFiles == 0,
    "typed negative defeats stale Bool positive after cold restart even with zero query permits")
  let evidence=try SyncEvidenceArchive(root:local,stream:"icloud_drive").load()!
  try check(evidence.rows.allSatisfy { $0.artifacts.allSatisfy { $0.state != "provider_uploaded" }
    && $0.commits.allSatisfy { !$0.providerUploaded } },
    "persisted sync projection cannot publish old positives over typed missing metadata")
 }

 static func verifyTypedNegativeSurvivesLateTranscript(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let (repo,texts,access,worker,sources,local,_)=try await livenessFixture(root:root,
    name:"typed-negative-late-text",count:1,manifest:manifest,audio:audio)
  let source=sources[0], ids=Set(sources.map(\.id))
  access.typedStatus = .uploaded
  _ = try await worker.perform(.sync(sources,ids),gate:ICloudDriveCancellation())
  access.typedStatus = .missingKey
  let negative=try await worker.perform(.refreshProviderStatus,gate:ICloudDriveCancellation())
  let original=try providerCache(local)["observations"] as! [String:[String:Any]]
  let unchangedPaths=original.keys.filter { $0.hasPrefix("audio/") || $0.hasPrefix("manifests/") }
  try check(negative.uploadedFileCount == 0 && unchangedPaths.count == 2
    && unchangedPaths.allSatisfy { original[$0]?["status"] as? String == "missing_key" },
    "late text fixture starts with typed negatives over previously confirmed audio and manifest")
  let transcript=SegmentTranscript(segmentID:source.id,audioSHA256:source.sha256,locale:"zh-CN",engine:"synthetic",
    createdAt:Date(timeIntervalSince1970:400),text:"延后合成文字",spans:[])
  try texts.save(transcript,for:source)
  try FileManager.default.removeItem(at:repo.audioURL(for:source))
  let checks=access.metadataChecks
  let exported=try await worker.perform(.sync(sources,ids,priorityTranscriptIDs:[source.id]),
    gate:ICloudDriveCancellation(takeProviderMetadataPermit:{ false }))
  let deferred=try providerCache(local), retained=deferred["observations"] as! [String:[String:Any]]
  let unchecked=Set(deferred["providerChangeUncheckedPaths"] as? [String] ?? [])
  try check(exported.savedTranscriptCount == 1 && exported.savedAudioCount == 1
    && exported.needsProviderContinuation && access.metadataChecks == checks,
    "late transcript exports with source absent and zero provider permits, leaving automatic metadata continuation")
  try check(unchangedPaths.allSatisfy { path in
    unchecked.contains(path) && retained[path]?["status"] as? String == "missing_key"
     && (retained[path]! as NSDictionary) == (original[path]! as NSDictionary)
   },"same-identity late export preserves exact negative observation and first/latest times while requeueing both artifacts")
  let pending=try SyncEvidenceArchive(root:local,stream:"icloud_drive").load()!
  try check(pending.rows.allSatisfy { $0.artifacts.allSatisfy { $0.state != "provider_uploaded" } },
    "late transcript does not promote older positives when provider checks have no permits")
  access.typedStatus = .uploaded
  try await Task.sleep(nanoseconds:2_000_000)
  let cold=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
  let resumed=try await cold.perform(.continueProviderStatus,gate:ICloudDriveCancellation())
  let confirmed=try providerCache(local)["observations"] as! [String:[String:Any]]
  try check(resumed.savedTranscriptCount == 1 && resumed.savedAudioCount == 1
    && access.metadataChecks > checks && access.metadataChecks-checks <= 32,
    "cold metadata-only continuation confirms the requeued files without another export or source read")
  try check(unchangedPaths.allSatisfy { path in
    confirmed[path]?["status"] as? String == "uploaded"
     && confirmed[path]?["firstConfirmedAtMS"] as? Int64 == original[path]?["firstConfirmedAtMS"] as? Int64
     && (confirmed[path]?["latestConfirmedAtMS"] as? Int64 ?? 0) > (original[path]?["latestConfirmedAtMS"] as? Int64 ?? 0)
   },"reconfirmed same-identity audio and manifest retain their first time and advance only latest confirmation")
 }

 static func verifyTypedIdentityFailures(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let (_,_,access,worker,sources,local,folder)=try await livenessFixture(root:root,
    name:"typed-identity",count:1,manifest:manifest,audio:audio)
  access.typedStatus = .uploaded
  _ = try await worker.perform(.sync(sources,Set(sources.map(\.id))),gate:ICloudDriveCancellation())
  let cache=try providerCache(local), libraryID=cache["libraryID"] as! String
  let observations=cache["observations"] as! [String:[String:Any]]
  let audioPath=observations.keys.first { $0.hasPrefix("audio/") }!
  let target=folder.appendingPathComponent("RecordForAgent-"+libraryID.lowercased()).appendingPathComponent(audioPath)
  try FileManager.default.setAttributes([.modificationDate:Date(timeIntervalSinceNow:1)],ofItemAtPath:target.path)
  let changed=try await worker.perform(.refreshProviderStatus,gate:ICloudDriveCancellation())
  try check(changed.uploadedFileCount == 3 && changed.diagnosticObservation.counts.identityMismatchFiles == 1,
    "provider true cannot override a changed export identity")
  let mismatch=try providerCache(local)["observations"] as! [String:[String:Any]]
  try check(mismatch[audioPath]?["status"] as? String == "identity_mismatch"
    && mismatch[audioPath]?["firstConfirmedAtMS"] as? Int64 == observations[audioPath]?["firstConfirmedAtMS"] as? Int64,
    "identity demotion preserves typed reason and original confirmation time")
  try FileManager.default.removeItem(at:target)
  let deleted=try await worker.perform(.refreshProviderStatus,gate:ICloudDriveCancellation())
  try check(deleted.uploadedFileCount == 3 && deleted.diagnosticObservation.counts.unavailableFiles == 1,
    "deleted target remains unavailable despite an older positive provider observation")
 }

 @MainActor static func verifyAutomaticCtimeRepair(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let (repo,texts,access,_,sources,local,folder)=try await livenessFixture(root:root,
    name:"automatic-ctime-repair",count:3,manifest:manifest,audio:audio)
  access.uploaded=true
  UIApplication.shared.applicationState = .active
  let query=ProbeMetadataQuery()
  let library=ICloudDriveLibrary(repository:repo,transcriptRepository:texts,folderAccess:access.access,
    providerMonitorFactory:{ changed in .init(changed:changed,makeQuery:{ query },startAccess:{ _ in true },stopAccess:{ _ in }) })
  defer { library.suspendForBackground() }
  try await continuationIdle(library)
  try check(library.uploadedFileCount == 10,"automatic repair starts with three fully confirmed sources")
  let cache=try providerCache(local), libraryID=cache["libraryID"] as! String
  let observations=cache["observations"] as! [String:[String:Any]]
  for path in observations.keys where path.hasPrefix("audio/") {
   let target=folder.appendingPathComponent("RecordForAgent-"+libraryID.lowercased()).appendingPathComponent(path)
   try FileManager.default.setAttributes([.posixPermissions:0o400],ofItemAtPath:target.path)
   try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:target.path)
  }
  for source in sources { try FileManager.default.removeItem(at:repo.audioURL(for:source)) }
  let grant=local.appendingPathComponent("ICloudDriveLibrary/state.json")
  let before=try Data(contentsOf:grant)
  library.checkCloudStatusReadOnly()
  try await continuationIdle(library)
  try check(library.diagnosticSnapshot().counts?.needsIdentityRevalidationSources == 3
    && library.uploadedFileCount == 7 && (try Data(contentsOf:grant)) == before,
    "read-only inspection reports ctime changes without validating audio or changing the export ledger")
  try check(try providerCache(local)["repairDiagnostics"] == nil,
    "read-only inspection cannot record or release a writer repair attempt")
  NotificationCenter.default.post(name:.NSMetadataQueryDidUpdate,object:query)
  try await continuationIdle(library)
  try check(library.uploadedFileCount == 10 && library.pendingCloudFileCount == 0
    && library.diagnosticSnapshot().counts?.needsIdentityRevalidationSources == 0,
    "one normal provider notification validates the existing exports in bounded slices without a manual sync")
  let repairedStats = try providerCache(local)["repairDiagnostics"] as! [String:Any]
  try check(repairedStats["attempted"] as? Int == 3 && repairedStats["completed"] as? Int == 3
    && repairedStats["deferred"] as? Int == 0 && repairedStats["conflicts"] as? Int == 0,
    "bounded diagnostics distinguish actual local repair commits from provider upload observations")
  let diagnosticRestart = ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
  _ = try await diagnosticRestart.perform(.load,gate:ICloudDriveCancellation())
  let restoredStats = try providerCache(local)["repairDiagnostics"] as! [String:Any]
  try check((repairedStats as NSDictionary) == (restoredStats as NSDictionary),
    "repair diagnostics survive cold load without replaying a writer or changing counters")
  try check(sources.allSatisfy { !FileManager.default.fileExists(atPath:repo.audioURL(for:$0).path) },
    "identity repair never restores or falls back to the missing source audio")
  let manifestPath=observations.keys.first { $0.hasPrefix("manifests/") }!
  let manifestTarget=folder.appendingPathComponent("RecordForAgent-"+libraryID.lowercased()).appendingPathComponent(manifestPath)
  try FileManager.default.setAttributes([.posixPermissions:0o400],ofItemAtPath:manifestTarget.path)
  try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:manifestTarget.path)
  NotificationCenter.default.post(name:.NSMetadataQueryDidUpdate,object:query)
  try await continuationIdle(library)
  try check(library.uploadedFileCount == 10 && library.pendingCloudFileCount == 0
    && library.diagnosticSnapshot().counts?.identityMismatchFiles == 0,
    "a later manifest-only ctime change resumes validation without another audio change or source fallback")
  var changedDuringObservation = false
  access.duringMetadata = { url in
   guard url == manifestTarget, !changedDuringObservation else { return }
   changedDuringObservation = true
   try! FileManager.default.setAttributes([.posixPermissions:0o400],ofItemAtPath:url.path)
   try! FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
  }
  library.checkCloudStatusReadOnly()
  try await continuationIdle(library)
  access.duringMetadata = nil
  let racing = try providerCache(local)["observations"] as! [String:[String:Any]]
  try check(changedDuringObservation && racing[manifestPath]?["status"] as? String == "file_changed_during_check"
    && racing[manifestPath]?["identityMismatchBits"] as? Int == 16,
    "manifest ctime change inside provider callback remains unconfirmed in read-only inspection")
  // Change again inside the sole normal notification, so the scheduler must
  // recover a racing observation rather than relying on another provider event.
  changedDuringObservation = false
  access.duringMetadata = { url in
   guard url == manifestTarget, !changedDuringObservation else { return }
   changedDuringObservation = true
   try! FileManager.default.setAttributes([.posixPermissions:0o400],ofItemAtPath:url.path)
   try! FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
  }
  NotificationCenter.default.post(name:.NSMetadataQueryDidUpdate,object:query)
  try await continuationIdle(library)
  access.duringMetadata = nil
  try check(changedDuringObservation && library.uploadedFileCount == 10 && library.pendingCloudFileCount == 0,
    "one normal notification repairs manifest ctime racing its metadata callback without a second event")
  let audioPath=observations.keys.first { $0.hasPrefix("audio/") }!
  let target=folder.appendingPathComponent("RecordForAgent-"+libraryID.lowercased()).appendingPathComponent(audioPath)
  var stamp=stat()
  try check(lstat(target.path,&stamp) == 0,"capture synthetic target identity before tamper")
  var corrupt=try Data(contentsOf:target); corrupt[0] ^= 0xff
  let handle=try FileHandle(forWritingTo:target)
  try handle.write(contentsOf:corrupt); try handle.close()
  var times=[stamp.st_atimespec,stamp.st_mtimespec]
  try check(utimensat(AT_FDCWD,target.path,&times,0) == 0,"restore exact synthetic mtime after tamper")
  NotificationCenter.default.post(name:.NSMetadataQueryDidUpdate,object:query)
  try await continuationIdle(library)
  try check(library.pendingCloudFileCount > 0
    && library.diagnosticSnapshot().counts?.needsIdentityRevalidationSources == 1
    && (try Data(contentsOf:target)) == corrupt,
    "same inode, length and restored mtime cannot pass digest validation or authorize overwriting changed bytes")
  let failedStats = try providerCache(local)["repairDiagnostics"] as! [String:Any]
  try check((failedStats["conflicts"] as? Int ?? 0) > 0
    && (failedStats["completed"] as? Int ?? 0) < (failedStats["attempted"] as? Int ?? 0),
    "failed content validation records a conflict rather than a successful local repair")
  let afterFailure=try Data(contentsOf:grant)
  NotificationCenter.default.post(name:.NSMetadataQueryDidUpdate,object:query)
  try await continuationIdle(library)
  try check((try Data(contentsOf:grant)) == afterFailure && (try Data(contentsOf:target)) == corrupt,
    "repeated provider notifications do not loop failed validation or rewrite its protected export")
 }

 @MainActor static func verifyTypedMonitorDiagnostics(root:URL) throws {
  let denied=ICloudDriveProviderMonitor(changed:{},makeQuery:{ ProbeMetadataQuery() },
    startAccess:{ _ in false },stopAccess:{ _ in })
  denied.observe(root)
  try check(denied.diagnosticSnapshot.startAttemptCount == 1 && denied.diagnosticSnapshot.startFailureCount == 1
    && denied.diagnosticSnapshot.startSuccessCount == 0,"monitor records denied scope start without inventing a query")
  let failure=ICloudDriveProviderMonitor(changed:{},makeQuery:{ ProbeFailedMetadataQuery() },
    startAccess:{ _ in true },stopAccess:{ _ in })
  failure.observe(root)
  try check(failure.diagnosticSnapshot.startAttemptCount == 1 && failure.diagnosticSnapshot.startFailureCount == 1,
    "monitor records query.start false")
  let query=ProbeMetadataQuery(), monitor=ICloudDriveProviderMonitor(changed:{},makeQuery:{ query },
    startAccess:{ _ in true },stopAccess:{ _ in })
  monitor.observe(root)
  NotificationCenter.default.post(name:.NSMetadataQueryDidFinishGathering,object:query)
  let first=monitor.diagnosticSnapshot.firstGatherAt
  NotificationCenter.default.post(name:.NSMetadataQueryDidUpdate,object:query)
  let snapshot=monitor.diagnosticSnapshot
  try check(snapshot.startAttemptCount == 1 && snapshot.startSuccessCount == 1 && snapshot.startFailureCount == 0
    && snapshot.notificationCount == 2 && first != nil && snapshot.firstGatherAt == first
    && snapshot.latestNotificationAt != nil,"monitor records first gather and latest signal independently of uploaded files")
  monitor.stop()
  NotificationCenter.default.post(name:.NSMetadataQueryDidUpdate,object:query)
  try check(monitor.diagnosticSnapshot == snapshot,"stopped monitor ignores later notifications and retains existing diagnostic facts")
 }
}
