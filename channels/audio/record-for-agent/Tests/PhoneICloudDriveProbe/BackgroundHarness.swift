// Synthetic production-coordinator coverage. No device or real provider access.
private final class ProbeCancellationFlag: @unchecked Sendable {
 private let lock=NSLock()
 private var cancelled=false
 private var checks=0
 var checkCount:Int { lock.lock(); defer { lock.unlock() }; return checks }
 func read() -> Bool { lock.lock(); defer { lock.unlock() }; checks += 1; return cancelled }
 func cancel() { lock.lock(); cancelled=true; lock.unlock() }
}
extension Probe {
 static func verifyIncrementalCloudEvidence(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let fm=FileManager.default, local=root.appendingPathComponent("evidence-local"), folder=root.appendingPathComponent("evidence-cloud")
  try fm.createDirectory(at:folder,withIntermediateDirectories:true)
  let repo=try RecordingRepository(root:local), texts=try TranscriptRepository(root:local), access=ProbeAccess()
  var sources:[SegmentManifest]=[]
  for sequence in 0..<20 {
   let id=UUID(), item=SegmentManifest(id:id,sessionID:manifest.sessionID,sequence:sequence,
    startedAt:manifest.startedAt,endedAt:manifest.endedAt,sampleRate:manifest.sampleRate,frameCount:manifest.frameCount,
    fileName:id.uuidString.lowercased()+".caf",byteCount:manifest.byteCount,sha256:manifest.sha256)
   _ = try repo.acceptIncomingFile(at:audio,manifest:item); sources.append(item)
  }
  let ids=Set(sources.map(\.id)), worker=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
  _ = try await worker.perform(.connect(folder),gate:ICloudDriveCancellation())
  _ = try await worker.perform(.authorize(.existingAndFuture,sources,ids),gate:ICloudDriveCancellation())
  var state=try await worker.perform(.sync(sources,ids),gate:ICloudDriveCancellation())
  let archive=SyncEvidenceArchive(root:local,stream:"icloud_drive")
  var evidence=try archive.load()!
  try check(access.metadataChecks == 32 && state.uploadedFileCount == 0 && state.pendingCloudFileCount == 61,
    "even foreground provider inspection is a bounded batch, separate from local export")
  try check(evidence.rows.count == 20 && evidence.rows.allSatisfy { $0.artifacts.allSatisfy { $0.state == "local_exported" } },
    "durable local export is logged per source and cannot become cloud proof")
  try check(evidence.context.counts["commit_file_count"] == 20 && evidence.context.counts["provider_uploaded_commit_count"] == 0,
    "commit files have separate provider accounting")
  try check(evidence.rows.allSatisfy { $0.commits.count == 1 && !$0.commits[0].providerUploaded },
    "each durable commit is associated with its exact source before provider confirmation")
  try check(access.metadataPaths.contains { $0.hasSuffix("/library.json") }
    && access.metadataPaths.contains { $0.contains("/commits/") },
    "first bounded metadata batch reaches marker and source commits despite audio backlog")
  try check(evidence.rows.allSatisfy { $0.artifacts.allSatisfy { $0.recordedAtMS != nil } },
    "actual local export callbacks retain their original commit times")
  // Remove every synthetic source CAF. Later provider observation must use
  // metadata only, with no source content fallback or renewed full validation.
  let parked=local.appendingPathComponent("parked")
  try fm.createDirectory(at:parked,withIntermediateDirectories:true)
  for source in sources { try fm.moveItem(at:repo.audioURL(for:source),to:parked.appendingPathComponent(source.fileName)) }
  access.uploaded=true
  let before=access.metadataChecks
  let markerChecks=access.metadataPaths.filter { $0.hasSuffix("/library.json") }.count
  state=try await worker.perform(.sync(sources,ids,maximumJobs:2),gate:ICloudDriveCancellation())
  evidence=try archive.load()!
  try check(access.metadataChecks-before == 29 && state.uploadedFileCount == 29,
    "background continues one provider batch without reopening missing source audio")
  try check(access.metadataPaths.filter { $0.hasSuffix("/library.json") }.count == markerChecks
    && evidence.context.counts["provider_uploaded_marker_count"] == 0,
    "continuing a cohort checks each path once and keeps the earlier negative marker observation unconfirmed")
  try check((evidence.context.counts["transcript_inspected_this_round"] ?? 100) <= 18,
    "background never scans every historical transcript before exporting")
  try check(evidence.context.discoveryComplete,"earlier full foreground discovery remains actual coverage during background continuation")
  let cold=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
  let coldBefore=access.metadataChecks
  state=try await cold.perform(.sync(sources,ids,maximumJobs:2),gate:ICloudDriveCancellation())
  try check(access.metadataChecks-coldBefore == 32 && state.uploadedFileCount > 29,
    "cold provider rotation advances beyond retained positives within one bounded batch")
  // New-export priority may have sampled non-contiguous paths before restart.
  // A complete ordinary rotation is still at most two 31-path+marker batches.
  if state.pendingCloudFileCount > 0 {
   state=try await cold.perform(.sync(sources,ids,maximumJobs:2),gate:ICloudDriveCancellation())
  }
  evidence=try archive.load()!
  try check(access.metadataChecks-coldBefore <= 64 && state.uploadedFileCount == 61 && state.pendingCloudFileCount == 0,
    "provider cursor survives restart and reaches every pending file within a complete bounded rotation")
  try check(evidence.rows.flatMap(\.artifacts).allSatisfy { $0.state == "provider_uploaded" && $0.observedAtMS != nil },
    "each cloud artifact needs its own positive timed provider observation")
  try check(evidence.context.counts["provider_uploaded_commit_count"] == 20 && evidence.context.counts["provider_uploaded_marker_count"] == 1,
    "all cloud artifacts do not stand in for commits or the marker")
  try check(evidence.rows.allSatisfy { $0.commits.count == 1 && $0.commits[0].providerUploaded && $0.commits[0].observedAtMS != nil },
    "positive commit evidence has per-source association and its own observation time")
  try check(evidence.context.discoveryComplete,"a completed bounded transcript discovery pass is retained")
  // A provider's later negative metadata withdraws those positive observations.
  access.pendingMetadata=true
  _ = try await cold.perform(.sync(sources,ids,maximumJobs:2),gate:ICloudDriveCancellation())
  evidence=try archive.load()!
  try check(evidence.context.discoveryComplete,
    "next rotating metadata pass does not erase previously completed source discovery")
  state=try await cold.perform(.sync(sources,ids,maximumJobs:2),gate:ICloudDriveCancellation())
  evidence=try archive.load()!
  try check(state.uploadedFileCount == 40 && state.pendingCloudFileCount == 21,
    "a rotating pass retracts old positive commit and marker metadata")
  try check(evidence.context.counts["provider_uploaded_commit_count"] == 0 && evidence.context.counts["provider_uploaded_artifact_count"] == 40,
    "artifact success cannot hide unconfirmed commits")
  access.pendingMetadata=false
  // Replacing an exported path changes its file identity. Provider=true alone
  // cannot validate those bytes or turn that source into confirmed cloud proof.
  let first=sources[0], libraryID=evidence.context.libraryID!
  let target=folder.appendingPathComponent("RecordForAgent-"+libraryID.uuidString.lowercased())
   .appendingPathComponent("audio/"+first.id.uuidString.lowercased()+"/"+first.sha256+".caf")
  try Data("synthetic replacement".utf8).write(to:target,options:.atomic)
  _ = try await cold.perform(.sync(sources,ids,maximumJobs:2),gate:ICloudDriveCancellation())
  _ = try await cold.perform(.sync(sources,ids,maximumJobs:2),gate:ICloudDriveCancellation())
  evidence=try archive.load()!
  try check(evidence.rows.first(where: { $0.segmentID == first.id })?.artifacts.first(where: { $0.kind == "audio" })?.state == "local_exported",
    "changed target identity withdraws confirmation without reading or hashing the file")
  try check((evidence.context.counts["provider_identity_mismatch_count"] ?? 0) > 0,
    "identity change is distinguishable from provider pending without relaxing evidence")
  // Diagnostic-state corruption is not a recording-grant failure. Restore an
  // unknown cache and make progress only from newly checked metadata.
  try Data("bad diagnostic cache".utf8).write(to:local.appendingPathComponent("ICloudDriveLibrary/provider-evidence.json"),options:.atomic)
  let recovered=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
  state=try await recovered.perform(.sync(sources,ids,maximumJobs:2),gate:ICloudDriveCancellation())
  try check(state.enabled && state.error == nil && state.uploadedFileCount <= 32,
    "bad diagnostic cache preserves grant and never reuses old cloud positives")
  access.identity=String(repeating:"b",count:64)
  state=try await recovered.perform(.sync(sources,ids,maximumJobs:2),gate:ICloudDriveCancellation())
  evidence=try archive.load()!
  try check(!state.enabled && state.uploadedFileCount == 0 && evidence.rows.flatMap(\.artifacts).allSatisfy { $0.state != "provider_uploaded" },
    "changed provider directory withdraws all positive evidence")
 }

 @MainActor static func verifyBackgroundExport(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let fm=FileManager.default
  let local=root.appendingPathComponent("background-local"), folder=root.appendingPathComponent("background-cloud")
  try fm.createDirectory(at:folder,withIntermediateDirectories:true)
  let repo=try RecordingRepository(root:local), texts=try TranscriptRepository(root:local), fake=ProbeAccess()
  let seed=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:fake.access)
  _ = try await seed.perform(.connect(folder),gate:ICloudDriveCancellation())
  _ = try await seed.perform(.authorize(.existingAndFuture,[],[]),gate:ICloudDriveCancellation())
  var sources:[SegmentManifest]=[]
  for sequence in 0..<8 {
   let id=UUID()
   let source=SegmentManifest(id:id,sessionID:manifest.sessionID,sequence:sequence,
    startedAt:manifest.startedAt.addingTimeInterval(Double(sequence)*60),
    endedAt:manifest.endedAt.addingTimeInterval(Double(sequence)*60),sampleRate:manifest.sampleRate,
    frameCount:manifest.frameCount,fileName:id.uuidString.lowercased()+".caf",byteCount:manifest.byteCount,sha256:manifest.sha256)
   _ = try repo.acceptIncomingFile(at:audio,manifest:source)
   sources.append(source)
  }
  UIApplication.shared.applicationState = .background
  defer { UIApplication.shared.applicationState = .active }
  let initialStarts=fake.starts
  let library=ICloudDriveLibrary(repository:repo,transcriptRepository:texts,folderAccess:fake.access,providerMonitorFactory: Probe.monitor)
  let coldDiagnostic=library.diagnosticSnapshot()
  try check(coldDiagnostic.availability == .notObserved && coldDiagnostic.status == .unknown,
    "cold background diagnostic reports unknown without triggering its deferred initial load")
  let diagnosticStarts=fake.starts, diagnosticIdentities=fake.identityChecks, diagnosticQueries=fake.metadataChecks
  for _ in 0..<100 { _ = try TransportCodec.encode(library.diagnosticSnapshot()) }
  try check(!library.isBusy && fake.starts == diagnosticStarts && fake.identityChecks == diagnosticIdentities
    && fake.metadataChecks == diagnosticQueries,
    "actual main-actor diagnostic accessor repeatedly copies memory with zero folder, provider or worker activity")
  library.discover(manifests:sources,receivedIDs:Set(sources.map(\.id)))
  for _ in 0..<10 { await Task.yield() }
  try check(!library.isBusy && fake.starts == initialStarts,"cold background launch without execution grant does not access provider")
  let first=await library.prepareBackgroundDelivery(isCancelled:{ false })
  try check(!first,"three small background batches retain unfinished backlog")
  try check(library.savedAudioCount == 6 && library.hasPendingExportWork,"one real lease continues at most three two-job batches")
  try check(fake.metadataChecks <= 32 && Set(fake.metadataPaths).count == 19 && library.uploadedFileCount == 0,
    "three export batches cover all six sources and marker within the shared 32-query budget without inventing confirmation")
  let second=await library.prepareBackgroundDelivery(isCancelled:{ false })
  try check(second,"next execution opportunity completes pending exports")
  try check(library.savedAudioCount == 8 && !library.hasPendingExportWork && library.pendingCloudFileCount > 0,
    "provider upload remains distinct and does not cause endless export wake requests")
  let pendingDiagnostic=library.diagnosticSnapshot()
  try check(pendingDiagnostic.status == .providerPending && pendingDiagnostic.counts?.needsIdentityRevalidationSources == 0,
    "ordinary pending metadata is not presented as an identity problem")
  let lateDiagnostic=library.diagnosticSnapshot(at:Date().addingTimeInterval(3601))
  try check(lateDiagnostic.availability == .stale && lateDiagnostic.status == .unknown
    && lateDiagnostic.observedAt == pendingDiagnostic.observedAt,
    "a late diagnostic export never refreshes the as-of time or claims stale status is current")
  let starts=fake.starts
  let expired=await library.prepareBackgroundDelivery(isCancelled:{ true })
  try check(!expired,"expired parent cannot obtain execution permission")
  try check(fake.starts == starts,"cancelled opportunity does not touch provider")
  library.pause(); try await settle(library)
  _ = await library.prepareBackgroundDelivery(isCancelled:{ false })
  try check(!library.isEnabled && library.savedAudioCount == 8,"background opportunities never override explicit pause")
  try check(fake.starts == fake.stops,"background export balances security-scoped access")

  // A provider can block in coordination. Parent expiry must return promptly,
  // and releasing the provider later must not commit another source.
  let blockedLocal=root.appendingPathComponent("background-blocked-local"), blockedFolder=root.appendingPathComponent("background-blocked-cloud")
  try fm.createDirectory(at:blockedFolder,withIntermediateDirectories:true)
  let blockedRepo=try RecordingRepository(root:blockedLocal), blockedTexts=try TranscriptRepository(root:blockedLocal), blockedAccess=ProbeAccess()
  _ = try blockedRepo.acceptIncomingFile(at:audio,manifest:manifest)
  let blockedSeed=ICloudDriveLibraryWorker(repository:blockedRepo,transcriptRepository:blockedTexts,folderAccess:blockedAccess.access)
  _ = try await blockedSeed.perform(.connect(blockedFolder),gate:ICloudDriveCancellation())
  _ = try await blockedSeed.perform(.authorize(.existingAndFuture,[manifest],[manifest.id]),gate:ICloudDriveCancellation())
  let blocked=ICloudDriveLibrary(repository:blockedRepo,transcriptRepository:blockedTexts,folderAccess:blockedAccess.access,providerMonitorFactory: Probe.monitor)
  blocked.discover(manifests:[manifest],receivedIDs:[manifest.id])
  let latch=ProbeMetadataLatch()
  blockedAccess.beforeValidate={ latch.enterOnce() }
  let identitiesBeforeBlock=blockedAccess.identityChecks
  // Wait for the controlled provider boundary before expiring the parent.
  // A 100 ms cold-start deadline can expire before the callback is reached on
  // a busy host, which tests scheduler speed instead of blocked cancellation.
  var parentExpired=false
  let delivery=Task { @MainActor in
   await blocked.prepareBackgroundDelivery(isCancelled:{ parentExpired },maximumDuration:5)
  }
  let entryDeadline=ProcessInfo.processInfo.systemUptime+5
  while !latch.hasEntered && ProcessInfo.processInfo.systemUptime < entryDeadline {
   try await Task.sleep(nanoseconds:1_000_000)
  }
  let start=ProcessInfo.processInfo.systemUptime
  parentExpired=true
  let result=await delivery.value
  try check(!result && ProcessInfo.processInfo.systemUptime-start < 1,"blocked provider cannot hold parent past finite execution wait")
  try check(latch.hasEntered,"cancellation exercised an actual blocked provider callback")
  latch.release(); blockedAccess.beforeValidate=nil
  let unwindDeadline=ProcessInfo.processInfo.systemUptime+2
  while blockedAccess.starts != blockedAccess.stops {
   guard ProcessInfo.processInfo.systemUptime < unwindDeadline else { throw NSError(domain:"provider unwind timeout",code:1) }
   try await Task.sleep(nanoseconds:1_000_000)
  }
  try check(blockedAccess.identityChecks == identitiesBeforeBlock,"late validation return must not start another provider identity or marker read")
  // Inspect committed state only after the cancelled provider callback unwinds.
  let inspection=ICloudDriveLibraryWorker(repository:blockedRepo,transcriptRepository:blockedTexts,folderAccess:blockedAccess.access)
  let state=try await inspection.perform(.load,gate:ICloudDriveCancellation())
  try check(state.savedAudioCount == 0 && (try fm.contentsOfDirectory(atPath:blockedFolder.path)).isEmpty,
    "late provider return after expiry cannot publish or commit export")
  let resumed=await blocked.prepareBackgroundDelivery(isCancelled:{ false })
  try check(resumed,"later granted opportunity recovers cancelled cold load automatically")
  try check(blocked.savedAudioCount == 1 && blocked.scope == .existingAndFuture,"retry preserves exact grant and source")
  try await verifyOverlappingBackgroundLeases(root:root,manifest:manifest,audio:audio)
  try await verifyProviderCursorSurvivesExpiry(root:root,manifest:manifest,audio:audio)
  try await verifyBoundedDiscoveryCoverage(root:root,manifest:manifest,audio:audio)
  try await verifyBackgroundLateTranscript(root:root,manifest:manifest,audio:audio)
  try await verifyUnreadableMetadataRecovery(root:root)
 }

 @MainActor static func verifyBackgroundLateTranscript(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let fm=FileManager.default, local=root.appendingPathComponent("late-text-local"), folder=root.appendingPathComponent("late-text-cloud")
  try fm.createDirectory(at:folder,withIntermediateDirectories:true)
  let repo=try RecordingRepository(root:local), texts=try TranscriptRepository(root:local), access=ProbeAccess()
  access.uploaded=true
  var sources:[SegmentManifest]=[]
  for sequence in 0..<20 {
   let id=UUID(), source=SegmentManifest(id:id,sessionID:manifest.sessionID,sequence:sequence,
    startedAt:manifest.startedAt,endedAt:manifest.endedAt,sampleRate:manifest.sampleRate,frameCount:manifest.frameCount,
    fileName:id.uuidString.lowercased()+".caf",byteCount:manifest.byteCount,sha256:manifest.sha256)
   _ = try repo.acceptIncomingFile(at:audio,manifest:source); sources.append(source)
  }
  let ids=Set(sources.map(\.id)), seed=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
  _ = try await seed.perform(.connect(folder),gate:ICloudDriveCancellation())
  _ = try await seed.perform(.authorize(.existingAndFuture,sources,ids),gate:ICloudDriveCancellation())
  for _ in 0..<3 { _ = try await seed.perform(.sync(sources,ids),gate:ICloudDriveCancellation()) }
  let target=sources.sorted { $0.id.uuidString < $1.id.uuidString }.last!
  let parked=local.appendingPathComponent("parked")
  try fm.createDirectory(at:parked,withIntermediateDirectories:true)
  for source in sources { try fm.moveItem(at:repo.audioURL(for:source),to:parked.appendingPathComponent(source.fileName)) }
  UIApplication.shared.applicationState = .background
  defer { UIApplication.shared.applicationState = .active }
  let library=ICloudDriveLibrary(repository:repo,transcriptRepository:texts,folderAccess:access.access,providerMonitorFactory: Probe.monitor)
  library.discover(manifests:sources,receivedIDs:ids)
  let startsBeforeNotification=access.starts
  let first=SegmentTranscript(segmentID:target.id,audioSHA256:target.sha256,locale:"zh-CN",engine:"synthetic",
    createdAt:Date(timeIntervalSince1970:400),text:"第一份增量文字",spans:[.init(start:0,end:1,text:"第一份增量文字")])
  try texts.save(first,for:target); library.transcriptDidSave(for:target)
  try check(!library.isBusy && access.starts == startsBeforeNotification,
    "late transcript stays pending without manufacturing background execution permission")
  let before=access.metadataChecks, latch=ProbeMetadataLatch()
  // Pause the first provider observation after the text's durable export.
  // A new text cohort has only marker + text JSON/text + commit to check.
  access.beforeMetadata={ latch.enterOnce() }
  let opportunity=Task { @MainActor in await library.prepareBackgroundDelivery(isCancelled:{ false },systemGranted:true) }
  let deadline=ProcessInfo.processInfo.systemUptime+5
  while !latch.hasEntered {
   guard ProcessInfo.processInfo.systemUptime < deadline else { throw NSError(domain:"late transcript latch timeout",code:1) }
   try await Task.sleep(nanoseconds:1_000_000)
  }
  defer { latch.release() }
  let archive=SyncEvidenceArchive(root:local,stream:"icloud_drive")
  // The first notification is outside the next 16 historical IDs. Inspect the
  // durable local state before allowing provider observation to finish.
  let during=try archive.load()!
  let firstDigest=ICloudDriveLibraryLedger.digest(try TransportCodec.encode(first))
  let firstExport=folder.appendingPathComponent("RecordForAgent-"+during.context.libraryID!.uuidString.lowercased())
   .appendingPathComponent("transcripts/"+target.id.uuidString.lowercased()+"/"+firstDigest+".json")
  try check(fm.fileExists(atPath:firstExport.path),
    "notified source outside the historical cursor is inspected and exported in the first granted batch")
  let second=SegmentTranscript(segmentID:target.id,audioSHA256:target.sha256,locale:"zh-CN",engine:"synthetic",
    createdAt:Date(timeIntervalSince1970:401),text:"第二份增量文字",spans:[.init(start:0,end:1,text:"第二份增量文字")])
  try texts.save(second,for:target); library.transcriptDidSave(for:target)
  latch.release()
  let completed=await opportunity.value
  access.beforeMetadata=nil
  let after=try archive.load()!, secondDigest=ICloudDriveLibraryLedger.digest(try TransportCodec.encode(second))
  try check(completed && library.savedTranscriptCount == 1 && !library.hasPendingExportWork,
    "same-source notification arriving during a scan survives the older completion and drains within the lease")
  try check(after.rows.first(where:{ $0.segmentID == target.id })?.artifacts.contains(where:{ $0.kind == "transcriptJSON" && $0.sha256 == secondDigest }) == true,
    "the latest notified transcript version is durably exported rather than merely clearing a dirty flag")
  try check(access.metadataChecks-before <= 32 && (after.context.counts["transcript_inspected_this_round"] ?? 100) <= 18,
    "targeted transcript continuation shares the original finite provider and metadata budgets")
  try check(!fm.fileExists(atPath:repo.audioURL(for:target).path),
    "late transcript export reuses the existing exact target identity without reopening missing source audio")
 }

 static func verifyBoundedDiscoveryCoverage(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let local=root.appendingPathComponent("discovery-local"), folder=root.appendingPathComponent("discovery-cloud")
  try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
  let repo=try RecordingRepository(root:local), texts=try TranscriptRepository(root:local), access=ProbeAccess()
  var sources:[SegmentManifest]=[]
  for sequence in 0..<40 {
   let id=UUID(), item=SegmentManifest(id:id,sessionID:manifest.sessionID,sequence:sequence,
    startedAt:manifest.startedAt,endedAt:manifest.endedAt,sampleRate:manifest.sampleRate,frameCount:manifest.frameCount,
    fileName:id.uuidString.lowercased()+".caf",byteCount:manifest.byteCount,sha256:manifest.sha256)
   _ = try repo.acceptIncomingFile(at:audio,manifest:item); sources.append(item)
  }
  let ids=Set(sources.map(\.id)), worker=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
  _ = try await worker.perform(.connect(folder),gate:ICloudDriveCancellation())
  _ = try await worker.perform(.authorize(.existingAndFuture,sources,ids),gate:ICloudDriveCancellation())
  _ = try await worker.perform(.sync(sources,ids,maximumJobs:2),gate:ICloudDriveCancellation())
  let archive=SyncEvidenceArchive(root:local,stream:"icloud_drive")
  var evidence=try archive.load()!
  try check(!evidence.context.discoveryComplete && (evidence.context.counts["transcript_inspected_this_round"] ?? 100) <= 18,
    "first bounded discovery cannot claim unvisited historical sources")
  for _ in 0..<3 { _ = try await worker.perform(.sync(sources,ids,maximumJobs:2),gate:ICloudDriveCancellation()) }
  evidence=try archive.load()!
  try check(evidence.context.discoveryComplete,"fair bounded discovery eventually covers every authorized source")
  let cold=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
  _ = try await cold.perform(.sync(sources,ids,maximumJobs:2),gate:ICloudDriveCancellation())
  evidence=try archive.load()!
  try check(evidence.context.discoveryComplete,"completed discovery survives cold restart and continued fair rescans")
 }

 static func verifyProviderCursorSurvivesExpiry(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let local=root.appendingPathComponent("provider-expiry-local"), folder=root.appendingPathComponent("provider-expiry-cloud")
  try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
  let repo=try RecordingRepository(root:local), texts=try TranscriptRepository(root:local), access=ProbeAccess()
  var sources:[SegmentManifest]=[]
  for sequence in 0..<20 {
   let id=UUID(), item=SegmentManifest(id:id,sessionID:manifest.sessionID,sequence:sequence,
    startedAt:manifest.startedAt,endedAt:manifest.endedAt,sampleRate:manifest.sampleRate,frameCount:manifest.frameCount,
    fileName:id.uuidString.lowercased()+".caf",byteCount:manifest.byteCount,sha256:manifest.sha256)
   _ = try repo.acceptIncomingFile(at:audio,manifest:item); sources.append(item)
  }
  let ids=Set(sources.map(\.id)), worker=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
  _ = try await worker.perform(.connect(folder),gate:ICloudDriveCancellation())
  _ = try await worker.perform(.authorize(.existingAndFuture,sources,ids),gate:ICloudDriveCancellation())
  let gate=ICloudDriveCancellation()
  access.beforeMetadata={ if access.metadataChecks == 4 { gate.cancel() } }
  do {
   _ = try await worker.perform(.sync(sources,ids),gate:gate)
   throw NSError(domain:"expiry did not cancel",code:1)
  } catch is CancellationError { }
  access.beforeMetadata=nil
  let file=local.appendingPathComponent("ICloudDriveLibrary/provider-evidence.json")
  let before=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
  let observations=before["observations"] as! [String:Any], next=before["nextPath"] as! String
  try check(observations.count == 4 && !observations.keys.contains(next),
    "completed provider observations and next cursor persist when next callback expires")
  access.metadataPaths.removeAll(); access.uploaded=true
  let cold=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
  _ = try await cold.perform(.sync(sources,ids,maximumJobs:2),gate:ICloudDriveCancellation())
  try check(access.metadataPaths.first?.hasSuffix(next) == true
    && access.metadataPaths.allSatisfy { path in !observations.keys.contains { path.hasSuffix("/"+$0) } },
    "cold worker resumes its historical cursor without rechecking completed marker or artifact observations")
 }

 @MainActor static func verifyOverlappingBackgroundLeases(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let local=root.appendingPathComponent("overlapping-local"), folder=root.appendingPathComponent("overlapping-cloud")
  try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
  let repo=try RecordingRepository(root:local), texts=try TranscriptRepository(root:local), access=ProbeAccess()
  _ = try repo.acceptIncomingFile(at:audio,manifest:manifest)
  let seed=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
  _ = try await seed.perform(.connect(folder),gate:ICloudDriveCancellation())
  _ = try await seed.perform(.authorize(.existingAndFuture,[manifest],[manifest.id]),gate:ICloudDriveCancellation())
  let library=ICloudDriveLibrary(repository:repo,transcriptRepository:texts,folderAccess:access.access,providerMonitorFactory: Probe.monitor)
  library.discover(manifests:[manifest],receivedIDs:[manifest.id])
  let latch=ProbeMetadataLatch(), system=ProbeCancellationFlag()
  access.beforeValidate={ latch.enterOnce() }
  let uiTask=Task { @MainActor in await library.prepareBackgroundDelivery(isCancelled:{ false }) }
  let deadline=ProcessInfo.processInfo.systemUptime+2
  while !latch.hasEntered {
   guard ProcessInfo.processInfo.systemUptime < deadline else { throw NSError(domain:"overlap provider timeout",code:1) }
   try await Task.sleep(nanoseconds:1_000_000)
  }
  let systemTask=Task { @MainActor in
   await library.prepareBackgroundDelivery(isCancelled:{ system.read() },systemGranted:true)
  }
  // The second cancellation check is inside the wait after registering the
  // system lease, rather than its pre-registration guard.
  while system.checkCount < 2 {
   guard ProcessInfo.processInfo.systemUptime < deadline else { throw NSError(domain:"overlap lease timeout",code:1) }
   try await Task.sleep(nanoseconds:1_000_000)
  }
  system.cancel(); library.expireBackgroundWork()
  latch.release()
  let systemResult=await systemTask.value, uiResult=await uiTask.value
  try check(!systemResult,"expired system waiter cannot claim another lease's completion")
  try check(uiResult && library.savedAudioCount == 1,"expiring system lease preserves independent live UIKit opportunity")
  try check(access.starts == access.stops && access.metadataChecks == 4,"overlapping leases balance access and retain bounded background metadata")
 }

 static func verifyUnreadableMetadataRecovery(root:URL) async throws {
  let fm=FileManager.default, local=root.appendingPathComponent("unreadable-local"), folder=root.appendingPathComponent("unreadable-cloud")
  try fm.createDirectory(at:folder,withIntermediateDirectories:true)
  let repo=try RecordingRepository(root:local), texts=try TranscriptRepository(root:local), access=ProbeAccess()
  let seed=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
  _ = try await seed.perform(.connect(folder),gate:ICloudDriveCancellation())
  _ = try await seed.perform(.authorize(.futureOnly,[],[]),gate:ICloudDriveCancellation())
  _ = try await seed.perform(.setEnabled(false),gate:ICloudDriveCancellation())
  for name in ["state.json","stop-intent.json"] {
   let file=local.appendingPathComponent("ICloudDriveLibrary/"+name), original=try Data(contentsOf:file)
   let cold=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
   try fm.setAttributes([.posixPermissions:0o000],ofItemAtPath:file.path)
   defer { try? fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path) }
   do {
    _ = try await cold.perform(.load,gate:ICloudDriveCancellation())
    throw NSError(domain:"unreadable metadata unexpectedly loaded",code:1)
   } catch {
    try check((error as? ICloudDriveLibraryFailure) == .unavailableState,
      "inaccessible metadata maps precisely to unavailable state rather than an empty grant: "+name)
    let diagnostic=try recoveryJSON(Data(contentsOf:local.appendingPathComponent("ICloudDriveLibrary/directory-recovery.json")))
    if name == "stop-intent.json" {
     try check(diagnostic["stage"] as? String == "load_stop_fence"
       && diagnostic["code"] as? String == "local_state_io_unavailable"
       && diagnostic["posixErrno"] as? Int == Int(EACCES),
       "mapped stop-fence failure preserves its exact EACCES evidence")
    } else {
     try check(diagnostic["stage"] as? String == "load_state"
       && diagnostic["code"] as? String == "local_state_unavailable",
       "state restoration failure is identified separately from directory or provider errors")
    }
   }
   try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
   try check(try Data(contentsOf:file) == original,"failed read leaves original metadata bytes intact")
   let restored=try await cold.perform(.load,gate:ICloudDriveCancellation())
   try check(restored.connected && !restored.enabled && restored.scope == .futureOnly,
     "same worker reloads recovered metadata and retains exact paused grant")
   try check(try Data(contentsOf:file) == original,"successful retry does not rewrite an unchanged grant")
  }
  try check(access.starts == access.stops,"readable-state recovery balances provider access")
 }
}
