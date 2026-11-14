// Production actor tests; every file and provider callback is synthetic/local.
extension Probe {
 static func livenessFixture(root:URL,name:String,count:Int,manifest:SegmentManifest,audio:URL) async throws
  -> (RecordingRepository,TranscriptRepository,ProbeAccess,ICloudDriveLibraryWorker,[SegmentManifest],URL,URL) {
  let local=root.appendingPathComponent(name+"-local"), folder=root.appendingPathComponent(name+"-cloud")
  try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
  let repo=try RecordingRepository(root:local), texts=try TranscriptRepository(root:local), access=ProbeAccess()
  var sources:[SegmentManifest]=[]
  for sequence in 0..<count {
   let id=UUID(), source=SegmentManifest(id:id,sessionID:manifest.sessionID,sequence:sequence,
    startedAt:manifest.startedAt,endedAt:manifest.endedAt,sampleRate:manifest.sampleRate,frameCount:manifest.frameCount,
    fileName:id.uuidString.lowercased()+".caf",byteCount:manifest.byteCount,sha256:manifest.sha256)
   _ = try repo.acceptIncomingFile(at:audio,manifest:source); sources.append(source)
  }
  sources.sort { $0.id.uuidString < $1.id.uuidString }
  let worker=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
  _ = try await worker.perform(.connect(folder),gate:ICloudDriveCancellation())
  _ = try await worker.perform(.authorize(.existingAndFuture,sources,Set(sources.map(\.id))),gate:ICloudDriveCancellation())
  return (repo,texts,access,worker,sources,local,folder)
 }

 static func verifyProviderLivenessAndCacheRetention(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  try check(ICloudDriveUploadStatus.isConfirmed(regular:true,symbolicLink:false,ubiquitous:true,uploaded:true),
    "provider upload confirmation does not require local download residency")
  try check(!ICloudDriveUploadStatus.isConfirmed(regular:true,symbolicLink:false,ubiquitous:true,uploaded:nil)
    && !ICloudDriveUploadStatus.isConfirmed(regular:true,symbolicLink:true,ubiquitous:true,uploaded:true),
    "unknown upload status and symlinks remain unconfirmed")
  try await verifyProviderEventRouting(root:root,manifest:manifest,audio:audio)
  try verifyProviderMonitor(root:root)
  try await verifyMetadataOnlyRefresh(root:root,manifest:manifest,audio:audio)
  try await verifyRepairExportFairness(root:root,manifest:manifest,audio:audio)
  try await verifyNewExportBeforeRepair(root:root,manifest:manifest,audio:audio)
  try await verifyLocalCtimeRepair(root:root,manifest:manifest,audio:audio)
  try await verifyLocalCtimeRepair(root:root,manifest:manifest,audio:audio,deviceDrift:true)
  try await verifyTransientProviderFailurePreservesHistory(root:root,manifest:manifest,audio:audio)
  try await verifyExportBeforeProviderMetadata(root:root,manifest:manifest,audio:audio)
  try await verifyShortLeaseNewSourceAndHistoricalFairness(root:root,manifest:manifest,audio:audio)
  try await verifyColdSourceMetadataFences(root:root,manifest:manifest,audio:audio)
  try await verifyRepairSourceMetadataFence(root:root,manifest:manifest,audio:audio)
  try await verifyBadPendingTranscriptDoesNotBlockAudio(root:root,manifest:manifest,audio:audio)
  try await verifyPriorityTranscriptFairness(root:root,manifest:manifest,audio:audio)
  try await verifyIdentityRevalidationDoesNotBlockOtherSources(root:root,manifest:manifest,audio:audio)
  try await verifyUnchangedLateTextRetainsTimedAudioObservation(root:root,manifest:manifest,audio:audio)
  try verifyCommitLibraryIdentity(root:root,manifest:manifest,audio:audio)
  try await verifyPureConflictRotation(root:root,manifest:manifest,audio:audio)
  try await verifyPureConflictRotationAfterExpiryAndRestart(root:root,manifest:manifest,audio:audio)
  try await verifyProviderUncheckedTail(root:root,manifest:manifest,audio:audio)
  try await verifyProviderChangeBeyondBatch(root:root,manifest:manifest,audio:audio)
  try await verifyProviderChangeLocalStampDemotion(root:root,manifest:manifest,audio:audio)
 }

 static func verifyColdSourceMetadataFences(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  for fault in ["manifest_changed","receipt_missing","receipt_changed"] {
   let (repo,texts,access,_,sources,local,folder)=try await livenessFixture(root:root,
    name:"cold-source-fence-"+fault,count:2,manifest:manifest,audio:audio)
   let bad=sources[0], healthy=sources[1], name=bad.id.uuidString.lowercased()+".json"
   let manifestFile=local.appendingPathComponent("manifests").appendingPathComponent(name)
   let receiptFile=local.appendingPathComponent("receipts").appendingPathComponent(name)
   let originalManifest=try Data(contentsOf:manifestFile), originalReceipt=try Data(contentsOf:receiptFile)
   if fault == "manifest_changed" {
    let changed=SegmentManifest(id:bad.id,sessionID:bad.sessionID,sequence:bad.sequence+100,
     startedAt:bad.startedAt,endedAt:bad.endedAt,sampleRate:bad.sampleRate,frameCount:bad.frameCount,
     fileName:bad.fileName,byteCount:bad.byteCount,sha256:bad.sha256)
    try TransportCodec.encode(changed).write(to:manifestFile,options:.atomic)
   } else if fault == "receipt_missing" { try FileManager.default.removeItem(at:receiptFile) }
   else {
    try TransportCodec.encode(SegmentReceipt(segmentID:bad.id,sha256:String(repeating:"f",count:64),
     byteCount:bad.byteCount)).write(to:receiptFile,options:.atomic)
   }
   let cold=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
   let state=try await cold.perform(.sync(nil,nil,maximumJobs:2),gate:ICloudDriveCancellation())
   let archive=SyncEvidenceArchive(root:local,stream:"icloud_drive"), blocked=try archive.load()!
   let library=folder.appendingPathComponent("RecordForAgent-"+blocked.context.libraryID!.uuidString.lowercased())
   let rejectedAudio=library.appendingPathComponent("audio/"+bad.id.uuidString.lowercased()+"/"+bad.sha256+".caf")
   try check(state.enabled && state.savedAudioCount == 1 && state.authorizedCount == 2
    && blocked.context.counts["source_metadata_issue_count"] == 1
    && blocked.rows.first { $0.segmentID == bad.id }!.artifacts.allSatisfy { $0.state == "pending" }
    && blocked.rows.first { $0.segmentID == healthy.id }!.artifacts.contains { $0.kind == "audio" && $0.state == "local_exported" },
    "cold metadata-only fence isolates "+fault+" while a healthy peer exports in the same two-job lease")
   try check(!FileManager.default.fileExists(atPath:rejectedAudio.path),
    "rejected current source metadata reaches no provider audio write for "+fault)
   try originalManifest.write(to:manifestFile,options:.atomic)
   try originalReceipt.write(to:receiptFile,options:.atomic)
   let resumed=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
   let recovered=try await resumed.perform(.sync(nil,nil,maximumJobs:2),gate:ICloudDriveCancellation())
   let after=try archive.load()!
   try check(recovered.enabled && recovered.scope == .existingAndFuture && recovered.savedAudioCount == 2
    && recovered.authorizedCount == 2 && after.context.counts["source_metadata_issue_count"] == 0,
    "matching current source metadata resumes the same durable per-source quarantine after cold restart for "+fault)
   try check(access.starts == access.stops,"source metadata refusal balances security-scoped access for "+fault)
  }
 }

 static func verifyRepairSourceMetadataFence(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let (repo,texts,access,worker,sources,local,folder)=try await livenessFixture(root:root,
   name:"repair-source-fence",count:2,manifest:manifest,audio:audio)
  let old=sources[0], ids=Set(sources.map(\.id)); access.uploaded=true
  _ = try await worker.perform(.sync(sources,ids,maximumJobs:1),gate:ICloudDriveCancellation())
  let archive=SyncEvidenceArchive(root:local,stream:"icloud_drive"), initial=try archive.load()!
  let target=folder.appendingPathComponent("RecordForAgent-"+initial.context.libraryID!.uuidString.lowercased())
   .appendingPathComponent("audio/"+old.id.uuidString.lowercased()+"/"+old.sha256+".caf")
  try check(chmod(target.path,0o640) == 0,"source fence fixture creates an identity-repair candidate")
  _ = try await worker.perform(.sync(sources,ids,maximumJobs:0),gate:ICloudDriveCancellation())
  let receipt=local.appendingPathComponent("receipts/"+old.id.uuidString.lowercased()+".json")
  let original=try Data(contentsOf:receipt)
  try FileManager.default.removeItem(at:receipt)
  try FileManager.default.removeItem(at:repo.audioURL(for:old))
  let cold=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
  let state=try await cold.perform(.sync(nil,nil,maximumJobs:2),gate:ICloudDriveCancellation())
  let held=try archive.load()!
  try check(state.enabled && state.savedAudioCount == 2 && held.context.counts["needs_identity_revalidation_count"] == 1
   && held.context.counts["source_metadata_issue_count"] == 1,
   "repair cannot revalidate a source with withdrawn receipt while an independent pending source still exports")
  try original.write(to:receipt,options:.atomic)
  let resumed=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
  _ = try await resumed.perform(.sync(nil,nil,maximumJobs:2),gate:ICloudDriveCancellation())
  let repaired=try archive.load()!
  try check(repaired.context.counts["needs_identity_revalidation_count"] == 0
   && repaired.context.counts["source_metadata_issue_count"] == 0
   && !FileManager.default.fileExists(atPath:repo.audioURL(for:old).path),
   "restoring matching metadata permits exact target repair without requiring the absent source audio")
 }

 static func verifyBadPendingTranscriptDoesNotBlockAudio(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let (repo,texts,access,worker,sources,local,_)=try await livenessFixture(root:root,
   name:"bad-pending-transcript",count:2,manifest:manifest,audio:audio)
  let bad=sources[0], ids=Set(sources.map(\.id))
  try texts.save(SegmentTranscript(segmentID:bad.id,audioSHA256:bad.sha256,locale:"zh-CN",engine:"synthetic",
   createdAt:Date(),text:"合成转写",spans:[]),for:bad)
  _ = try await worker.perform(.sync(sources,ids,maximumJobs:0),gate:ICloudDriveCancellation())
  try Data("{}".utf8).write(to:local.appendingPathComponent("transcripts/"+bad.id.uuidString.lowercased()+".json"),options:.atomic)
  let cold=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
  let state=try await cold.perform(.sync(nil,nil,maximumJobs:2),gate:ICloudDriveCancellation())
  let evidence=try SyncEvidenceArchive(root:local,stream:"icloud_drive").load()!
  try check(state.enabled && state.savedAudioCount == 2 && state.savedTranscriptCount == 0
   && evidence.context.counts["transcript_issue_count"] == 1 && evidence.context.counts["progressed_items"] == 2
   && evidence.context.counts["transcript_inspected_this_round"] == 2,
   "a failed pre-export transcript inspection remains an isolated issue while both source audios export")
  try check(evidence.rows.first { $0.segmentID == bad.id }!.artifacts.contains { $0.kind == "transcriptJSON" && $0.state == "pending" },
   "bad transcript bytes never create an exported text receipt")
 }

 static func verifyLocalCtimeRepair(root:URL,manifest:SegmentManifest,audio:URL,deviceDrift:Bool = false) async throws {
  let (repo,_,access,worker,sources,local,folder)=try await livenessFixture(root:root,name:deviceDrift ? "device-repair" : "ctime-repair",count:1,manifest:manifest,audio:audio)
  let source=sources[0], ids=Set(sources.map(\.id)); access.uploaded=true
  _ = try await worker.perform(.sync(sources,ids),gate:ICloudDriveCancellation())
  let archive=SyncEvidenceArchive(root:local,stream:"icloud_drive"), initial=try archive.load()!
  let library=folder.appendingPathComponent("RecordForAgent-"+initial.context.libraryID!.uuidString.lowercased())
  let target=library.appendingPathComponent("audio/"+source.id.uuidString.lowercased()+"/"+source.sha256+".caf")
  let commit=try FileManager.default.subpathsOfDirectory(atPath:library.path).filter { $0.hasPrefix("commits/") && $0.hasSuffix(".json") }.first!
  let committed=try Data(contentsOf:library.appendingPathComponent(commit))
  try check(chmod(target.path,0o640) == 0,"readable synthetic target gets ctime-only change")
  var active=worker
  if deviceDrift {
   let stateURL=local.appendingPathComponent("ICloudDriveLibrary/state.json")
   var state=try JSONSerialization.jsonObject(with:Data(contentsOf:stateURL)) as! [String:Any]
   var ledger=state["ledger"] as! [String:Any]
   var jobs=ledger["jobs"] as! [[String:Any]]
   var identities=jobs[0]["exportedFiles"] as! [String:[String:Any]]
   for key in Array(identities.keys) {
    let device=(identities[key]!["device"] as! NSNumber).uint64Value
    identities[key]!["device"]=device ^ 4
   }
   jobs[0]["exportedFiles"]=identities; ledger["jobs"]=jobs; state["ledger"]=ledger
   try JSONSerialization.data(withJSONObject:state).write(to:stateURL,options:.atomic)
   active=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:try TranscriptRepository(root:local),folderAccess:access.access)
  }
  // No source fallback: repair must use the already-local exported target only.
  try FileManager.default.removeItem(at:repo.audioURL(for:source))
  _ = try await active.perform(.sync(sources,ids),gate:ICloudDriveCancellation())
  let quarantined=try archive.load()!
  try check(quarantined.rows[0].artifacts.first { $0.kind == "audio" }?.state == "local_exported",
    "metadata observation alone never promotes changed-ctime audio")
  let queriesBeforeRepair=access.metadataChecks
  let repaired=try await active.perform(.sync(sources,ids,maximumJobs:2),gate:ICloudDriveCancellation())
  let rebound=try archive.load()!
  try check(repaired.error == nil && rebound.context.counts["needs_identity_revalidation_count"] == 0
    && rebound.rows[0].artifacts.first { $0.kind == "audio" }?.state == "provider_uploaded"
    && access.metadataChecks > queriesBeforeRepair,
    "targeted identity repair is confirmed only by a later real metadata callback in the remaining round budget")
  _ = try await active.perform(.sync(sources,ids,maximumJobs:2),gate:ICloudDriveCancellation())
  let after=try archive.load()!
  try check(after.rows[0].artifacts.first { $0.kind == "audio" }?.state == "provider_uploaded",
    "subsequent matched provider observation retains the repaired audio confirmation")
  try check(try Data(contentsOf:library.appendingPathComponent(commit)) == committed,
    "local identity repair preserves immutable cloud commit bytes")
  try check(!FileManager.default.fileExists(atPath:repo.audioURL(for:source).path),
    "repair never restores or requires source recording")
 }

 static func verifyTransientProviderFailurePreservesHistory(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let (repo,texts,access,worker,sources,local,_)=try await livenessFixture(root:root,name:"transient-history",count:20,manifest:manifest,audio:audio)
  let ids=Set(sources.map(\.id)); access.uploaded=true
  for _ in 0..<3 { _ = try await worker.perform(.sync(sources,ids),gate:ICloudDriveCancellation()) }
  let archive=SyncEvidenceArchive(root:local,stream:"icloud_drive"), cache=local.appendingPathComponent("ICloudDriveLibrary/provider-evidence.json")
  let before=try Data(contentsOf:cache), initial=try archive.load()!
  try check(initial.context.counts["provider_uploaded_file_count"] == 61,"fixture has genuine timed synthetic observations for all files")
  access.beforeValidate={ throw NSError(domain:"synthetic transient coordination",code:35) }
  let failed=try await worker.perform(.sync(sources,ids,maximumJobs:2),gate:ICloudDriveCancellation())
  let during=try archive.load()!
  try check(failed.enabled && failed.error != nil && failed.uploadedFileCount == 0,
    "transient target failure keeps grant but cannot publish current uploaded readiness")
  let failedDiagnostic=ICloudDriveDiagnosticSnapshot(observation:failed.diagnosticObservation,
    connected:failed.connected,enabled:failed.enabled)
  try check(failedDiagnostic.availability == .unavailable && failedDiagnostic.status == .unavailable
    && failedDiagnostic.counts?.providerConfirmedFiles == 0
    && failedDiagnostic.counts?.retainedHistoricalPositiveFiles == 61,
    "shareable typed diagnostics distinguish a transient failure from retained historical provider facts")
  try check(try Data(contentsOf:cache) == before,"transient failure preserves exact historical provider cache and fair cursor")
  try check(during.rows.flatMap(\.artifacts).allSatisfy { $0.state != "provider_uploaded" }
    && during.context.counts["provider_target_available"] == 0
    && during.context.counts["retained_historical_provider_positive_count"] == 61,
    "retained historical observations are distinct from unavailable current target readiness")
  access.beforeValidate=nil
  let cold=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
  let resumed=try await cold.perform(.sync(sources,ids,maximumJobs:2),gate:ICloudDriveCancellation())
  try check(resumed.enabled && resumed.error == nil && resumed.uploadedFileCount == 61,
    "cold retry revalidates the same target and resumes preserved metadata without reexport")
  let resumedEvidence=try archive.load()!
  try check(resumedEvidence.rows.map(\.segmentID) == initial.rows.map(\.segmentID)
    && resumedEvidence.rows.allSatisfy { row in initial.rows.contains { $0.segmentID == row.segmentID && $0.sha256 == row.sha256 } },
    "retry retains source identities rather than replacing authorization")
  access.identity=String(repeating:"b",count:64)
  let revoked=try await cold.perform(.sync(sources,ids,maximumJobs:2),gate:ICloudDriveCancellation())
  let revokedEvidence=try archive.load()!
  let cleared=try JSONSerialization.jsonObject(with:Data(contentsOf:cache)) as! [String:Any]
  try check(!revoked.enabled && revoked.scope == .existingAndFuture && revoked.authorizedCount == 20,
    "real provider directory change revokes access without widening or rewriting source scope")
  let revokedDiagnostic=ICloudDriveDiagnosticSnapshot(observation:revoked.diagnosticObservation,
    connected:revoked.connected,enabled:revoked.enabled)
  try check(revokedDiagnostic.availability == .unavailable && revokedDiagnostic.cacheResetReason == .folderChanged
    && revokedDiagnostic.counts?.retainedHistoricalPositiveFiles == 0,
    "revocation diagnostic has a safe typed reason rather than a successful or paused upload claim")
  try check((cleared["observations"] as! [String:Any]).isEmpty && cleared["nextPath"] == nil
    && revokedEvidence.context.counts["retained_historical_provider_positive_count"] == 0,
    "real binding change clears cached confirmations and cursor instead of preserving them as current")
  try check((revokedEvidence.context.counts["provider_cache_reset_reason"] ?? 0) > 0
    && (revokedEvidence.context.counts["provider_cache_reset_count"] ?? 0) > 0,
    "binding withdrawal has a fixed safe diagnostic cause and count")
 }

 static func verifyExportBeforeProviderMetadata(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let (_,texts,access,worker,sources,local,_)=try await livenessFixture(root:root,name:"reserved-provider",count:20,manifest:manifest,audio:audio)
  let ids=Set(sources.map(\.id)); access.uploaded=true
  for _ in 0..<3 { _ = try await worker.perform(.sync(sources,ids),gate:ICloudDriveCancellation()) }
  for source in sources.prefix(16) {
   let text=SegmentTranscript(segmentID:source.id,audioSHA256:source.sha256,locale:"zh-CN",engine:"synthetic",
    createdAt:Date(timeIntervalSince1970:400),text:"新文字",spans:[])
   try texts.save(text,for:source)
  }
  let before=access.metadataChecks, gate=ICloudDriveCancellation()
  access.beforeMetadata={ if access.metadataChecks-before == 3 { gate.cancel() } }
  do {
   _ = try await worker.perform(.sync(sources,ids,maximumJobs:2,priorityTranscriptIDs:Set(sources.prefix(16).map(\.id))),gate:gate)
   throw NSError(domain:"reserved slice should expire",code:1)
  } catch is CancellationError { }
  access.beforeMetadata=nil
  let evidence=try SyncEvidenceArchive(root:local,stream:"icloud_drive").load()!
  try check(access.metadataChecks-before == 4 && evidence.context.counts["metadata_checked_this_round"] == 3,
    "remaining opportunity commits completed provider observations before metadata expiry")
  try check(evidence.rows.filter { $0.artifacts.contains { $0.kind == "transcriptJSON" && $0.state != "pending" } }.count == 2
    && evidence.context.counts["progressed_items"] == 2 && evidence.context.counts["first_progress_phase"] == 1,
    "bounded late text exports commit before a provider callback consumes the remaining lease")
  try check((evidence.context.counts["provider_phase_expiry_count"] ?? 0) > 0
    && evidence.context.counts["provider_last_expired_phase"] == 5 && evidence.context.counts["bg_round"] == 1
    && (evidence.context.counts["round_finished_at_ms"] ?? 0) >= (evidence.context.counts["round_started_at_ms"] ?? 1),
    "cancelled provider stage retains the exact completed round and its durable export progress")
 }

 // A real monotonic deadline bounds each synthetic round; cancelling the
 // first metadata callback models a provider using the rest of a short lease.
 // Four cold workers also prove that fair class/cursor state is durable.
 static func verifyShortLeaseNewSourceAndHistoricalFairness(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let (repo,texts,access,worker,historical,local,_)=try await livenessFixture(root:root,
    name:"short-lease-703",count:703,manifest:manifest,audio:audio)
  var sources=historical
  func addNew(_ sequence:Int) throws -> SegmentManifest {
   let id=UUID(), started=Date().addingTimeInterval(Double(sequence)), source=SegmentManifest(id:id,
    sessionID:manifest.sessionID,sequence:sequence,startedAt:started,endedAt:started.addingTimeInterval(60),
    sampleRate:manifest.sampleRate,frameCount:manifest.frameCount,fileName:id.uuidString.lowercased()+".caf",
    byteCount:manifest.byteCount,sha256:manifest.sha256)
   _ = try repo.acceptIncomingFile(at:audio,manifest:source); sources.append(source)
   return source
  }
  _ = try addNew(1000)
  let newest=try addNew(1001), archive=SyncEvidenceArchive(root:local,stream:"icloud_drive")
  func shortRound(_ current:ICloudDriveLibraryWorker) async throws -> SyncEvidenceArchive.Snapshot {
   let started=ProcessInfo.processInfo.systemUptime, deadline=started+15
   let gate=ICloudDriveCancellation(providerAllowed:{ ProcessInfo.processInfo.systemUptime < deadline })
   access.beforeMetadata={ gate.cancel() }
   do {
    _ = try await current.perform(.sync(sources,Set(sources.map(\.id)),maximumJobs:1),gate:gate)
    throw NSError(domain:"synthetic provider should exhaust remaining lease",code:1)
   } catch is CancellationError { }
   access.beforeMetadata=nil
   let evidence=try archive.load()!
   try check(ProcessInfo.processInfo.systemUptime-started <= 15
     && evidence.context.counts["progressed_items"] == 1 && evidence.context.counts["first_progress_phase"] == 1,
     "a <=15s lease with 703 historical sources commits one source before cancelled provider metadata")
   try check(evidence.context.counts["metadata_checked_this_round"] == 0
     && evidence.rows.flatMap(\.artifacts).allSatisfy { $0.state != "provider_uploaded" },
     "export progress remains local-only when the first provider reply is cancelled")
   return evidence
  }
  func exported(_ evidence:SyncEvidenceArchive.Snapshot) -> Set<UUID> {
   Set(evidence.rows.filter { $0.artifacts.contains { $0.kind == "audio" && $0.state == "local_exported" } }.map(\.segmentID))
  }
  let first=try await shortRound(worker)
  try check(exported(first) == [newest.id],"the newest post-authorization source leads 703 historical pending sources")
  _ = try addNew(1002)
  let cold=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
  let second=try await shortRound(cold), firstHistorical=exported(second).subtracting([newest.id])
  try check(firstHistorical.count == 1 && firstHistorical.isSubset(of:Set(historical.map(\.id))),
    "durable historical turn progresses even when another new source arrives before a cold restart")
  let latest=try addNew(1003)
  let coldAgain=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
  let third=try await shortRound(coldAgain)
  try check(exported(third).subtracting(exported(second)) == [latest.id],
    "the next recent turn selects the newest source rather than the earlier recent backlog")
  _ = try addNew(1004)
  let finalWorker=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
  let fourth=try await shortRound(finalWorker), nextHistorical=exported(fourth).subtracting(exported(third))
  try check(nextHistorical.count == 1 && nextHistorical.isSubset(of:Set(historical.map(\.id)))
    && nextHistorical.isDisjoint(with:firstHistorical),
    "the historical cursor advances to another source despite sustained recent arrivals and cancellation")
  try check(access.starts == access.stops,"short cancelled rounds balance all security-scoped access")
 }

 static func verifyPriorityTranscriptFairness(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let (_,_,_,worker,sources,local,_)=try await livenessFixture(root:root,name:"priority-fairness",count:40,manifest:manifest,audio:audio)
  let ids=Set(sources.map(\.id)), priority=Set(sources.prefix(16).map(\.id))
  for _ in 0..<3 {
   _ = try await worker.perform(.sync(sources,ids,maximumJobs:2,priorityTranscriptIDs:priority),gate:ICloudDriveCancellation())
  }
  let evidence=try SyncEvidenceArchive(root:local,stream:"icloud_drive").load()!
  try check((evidence.context.counts["source_discovery_covered_count"] ?? 0) >= 28,
    "continuous sixteen targeted notices cannot consume the fair general discovery quota")
  try check((evidence.context.counts["transcript_inspected_this_round"] ?? 100) <= 18
    && (evidence.context.counts["metadata_checked_this_round"] ?? 100) <= 32,
    "fairness does not expand existing transcript or provider query bounds")
  try check(!evidence.context.discoveryComplete,"partial fair coverage never stands in for every source")
 }

 static func verifyIdentityRevalidationDoesNotBlockOtherSources(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let (repo,texts,access,worker,sources,local,folder)=try await livenessFixture(root:root,name:"identity-revalidation",count:2,manifest:manifest,audio:audio)
  let ids=Set(sources.map(\.id)); access.uploaded=true
  _ = try await worker.perform(.sync(sources,ids),gate:ICloudDriveCancellation())
  let archive=SyncEvidenceArchive(root:local,stream:"icloud_drive"), original=try archive.load()!
  let first=sources[0], target=folder.appendingPathComponent("RecordForAgent-"+original.context.libraryID!.uuidString.lowercased())
   .appendingPathComponent("audio/"+first.id.uuidString.lowercased()+"/"+first.sha256+".caf")
  // Permission metadata changes ctime only. The observation/export path must
  // not open or hash this unreadable synthetic target to make it look current.
  try check(chmod(target.path,0) == 0,"synthetic ctime update succeeds")
  defer { _ = chmod(target.path,0o600) }
  let parked=local.appendingPathComponent("parked")
  try FileManager.default.createDirectory(at:parked,withIntermediateDirectories:true)
  for source in sources {
   try FileManager.default.moveItem(at:repo.audioURL(for:source),to:parked.appendingPathComponent(source.fileName))
   try texts.save(SegmentTranscript(segmentID:source.id,audioSHA256:source.sha256,locale:"zh-CN",engine:"synthetic",
    createdAt:Date(timeIntervalSince1970:401),text:"稍后到达的文字",spans:[]),for:source)
  }
  let state=try await worker.perform(.sync(sources,ids),gate:ICloudDriveCancellation())
  let evidence=try archive.load()!
  let failed=evidence.rows.first { $0.segmentID == first.id }!
  let other=evidence.rows.first { $0.segmentID == sources[1].id }!
  try check(state.enabled && state.error == nil && state.savedTranscriptCount == 1,
    "one explicit audio identity proof gap does not pause or block an unrelated late transcript")
  let starts=access.starts, identityChecks=access.identityChecks, queries=access.metadataChecks
  let diagnostic=ICloudDriveDiagnosticSnapshot(observation:state.diagnosticObservation,
    connected:state.connected,enabled:state.enabled)
  let diagnosticBytes=try TransportCodec.encode(diagnostic)
  try check(diagnostic.availability == .cached && diagnostic.status == .needsIdentityRevalidation
    && diagnostic.counts?.needsIdentityRevalidationSources == 1,
    "identity gap is exposed separately from ordinary provider pending without changing export acceptance")
  try check(diagnosticBytes.count < 4096 && !String(decoding:diagnosticBytes,as:UTF8.self).contains(first.id.uuidString.lowercased())
    && !String(decoding:diagnosticBytes,as:UTF8.self).contains(folder.path)
    && access.starts == starts && access.identityChecks == identityChecks && access.metadataChecks == queries,
    "encoding typed actor state uses no worker/provider operations and exposes no source ID or folder")
  try check(failed.artifacts.first { $0.kind == "audio" }?.state == "local_exported"
    && failed.artifacts.filter { $0.kind == "transcriptJSON" || $0.kind == "transcriptText" }.allSatisfy { $0.state == "pending" },
    "changed ctime is never silently rebound, reexported or promoted to provider_uploaded")
  try check(other.artifacts.filter { $0.kind == "transcriptJSON" || $0.kind == "transcriptText" }.allSatisfy { $0.state != "pending" }
    && evidence.context.counts["needs_identity_revalidation_count"] == 1
    && evidence.context.counts["identity_ctime_only_changed_count"] == 1,
    "diagnostics distinguish a specific identity proof gap from ordinary provider pending")
  _ = try await worker.perform(.sync(sources,ids,maximumJobs:2),gate:ICloudDriveCancellation())
  try check(!FileManager.default.fileExists(atPath:repo.audioURL(for:first).path),
    "subsequent bounded continuation has no source-audio fallback")
 }

 static func verifyUnchangedLateTextRetainsTimedAudioObservation(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let (_,texts,access,worker,sources,local,_)=try await livenessFixture(root:root,name:"retained-audio-observation",count:1,manifest:manifest,audio:audio)
  let source=sources[0], ids:Set<UUID>=[source.id]; access.uploaded=true
  _ = try await worker.perform(.sync(sources,ids),gate:ICloudDriveCancellation())
  let archive=SyncEvidenceArchive(root:local,stream:"icloud_drive"), before=try archive.load()!
  let oldAudio=before.rows[0].artifacts.first { $0.kind == "audio" }!
  try texts.save(SegmentTranscript(segmentID:source.id,audioSHA256:source.sha256,locale:"zh-CN",engine:"synthetic",
   createdAt:Date(timeIntervalSince1970:402),text:"仅新增文字",spans:[]),for:source)
  let gate=ICloudDriveCancellation(), queries=access.metadataChecks
  do {
   _ = try await worker.perform(.sync(sources,ids),gate:gate,phase:{ phase in
    if case .checkingCloud = phase { gate.cancel() }
   })
   throw NSError(domain:"post export gate should expire",code:1)
  } catch is CancellationError { }
  let after=try archive.load()!, retained=after.rows[0].artifacts.first { $0.kind == "audio" }!
  try check(access.metadataChecks == queries && retained.state == "provider_uploaded"
    && retained.observedAtMS == oldAudio.observedAtMS && retained.recordedAtMS == oldAudio.recordedAtMS,
    "unchanged exact audio identity retains its original as-of observation without pretending a new provider check")
  try check(after.rows[0].artifacts.filter { $0.kind == "transcriptJSON" || $0.kind == "transcriptText" }.allSatisfy { $0.state == "local_exported" },
    "new text is still only locally exported until its own provider metadata is observed")
 }
}

// Regressions from the Linear follow-up review run the production validator and
// worker. The generated files, receipts and provider replies are all synthetic.
extension Probe {
 static func verifyCommitLibraryIdentity(root:URL,manifest:SegmentManifest,audio:URL) throws {
  var ledger=ICloudDriveLibraryLedger()
  try ledger.authorize(.existingAndFuture,knownIDs:[])
  try ledger.discover(manifests:[manifest],receivedIDs:[manifest.id])
  let folder=root.appendingPathComponent("commit-library-proof")
  try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
  let writer=ICloudDriveExportWriter(root:folder,libraryID:ledger.libraryID)
  let receipt=try writer.export(job:ledger.jobs[0],audioURL:audio)
  let valid=try TransportCodec.encode(receipt)
  try check(ICloudDriveLibraryLedger.provesCommit(valid,relativePath:receipt.relativePath,job:ledger.jobs[0]),
    "unmodified same-library commit is valid")
  var object=try JSONSerialization.jsonObject(with:valid) as! [String:Any]
  object["libraryID"]=UUID().uuidString.lowercased()
  let changed=try JSONSerialization.data(withJSONObject:object)
  let foreign=try TransportCodec.decode(ICloudDriveExportReceipt.self,from:changed)
  try check(foreign.segmentID == receipt.segmentID && foreign.artifacts == receipt.artifacts
    && foreign.exportDigest == receipt.exportDigest && foreign.relativePath == receipt.relativePath,
    "library-only mutation retains the exact source, artifacts, export digest and commit path")
  try check(!ICloudDriveLibraryLedger.provesCommit(changed,relativePath:receipt.relativePath,job:ledger.jobs[0]),
    "commit proof rejects a changed library even when every source and artifact field matches")
 }

 static func conflictFixture(root:URL,name:String,count:Int,manifest:SegmentManifest,audio:URL) async throws
  -> (RecordingRepository,TranscriptRepository,ProbeAccess,ICloudDriveLibraryWorker,[SegmentManifest],URL,URL) {
  let fixture=try await livenessFixture(root:root,name:name,count:count,manifest:manifest,audio:audio)
  let (_,_,_,worker,sources,local,folder)=fixture
  let initial=try SyncEvidenceArchive(root:local,stream:"icloud_drive").load()!
  let writer=ICloudDriveExportWriter(root:folder,libraryID:initial.context.libraryID!)
  _ = try writer.validateMarker(createIfMissing:true)
  for source in sources {
   let target=writer.libraryURL.appendingPathComponent("audio/"+source.id.uuidString.lowercased()+"/"+source.sha256+".caf")
   try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
   try Data("synthetic conflicting bytes".utf8).write(to:target)
  }
  _ = try await worker.perform(.sync(sources,Set(sources.map(\.id))),gate:ICloudDriveCancellation())
  let cache=local.appendingPathComponent("ICloudDriveLibrary/provider-evidence.json")
  let blocked=try JSONSerialization.jsonObject(with:Data(contentsOf:cache)) as! [String:Any]
  try check((blocked["exportConflictIDs"] as? [String])?.count == count,
    "fixture records more pure conflicts than one repair batch")
  let last=sources.last!
  try FileManager.default.removeItem(at:writer.libraryURL.appendingPathComponent(
    "audio/"+last.id.uuidString.lowercased()+"/"+last.sha256+".caf"))
  return fixture
 }

 static func verifyPureConflictRotation(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let (_,_,_,worker,sources,local,_)=try await conflictFixture(root:root,name:"pure-conflict-rotation",count:3,manifest:manifest,audio:audio)
  let ids=Set(sources.map(\.id))
  for _ in 0..<10 {
   _ = try await worker.perform(.sync(sources,ids,maximumJobs:2),gate:ICloudDriveCancellation())
  }
  let evidence=try SyncEvidenceArchive(root:local,stream:"icloud_drive").load()!
  let third=evidence.rows.first { $0.segmentID == sources[2].id }!
  let others=evidence.rows.filter { $0.segmentID != sources[2].id }
  try check(third.artifacts.first { $0.kind == "audio" }?.state == "local_exported",
    "third pure conflict is retried and exported after its obstruction is removed")
  try check(others.allSatisfy { $0.artifacts.first { $0.kind == "audio" }?.state == "pending" },
    "permanent neighboring conflicts remain quarantined instead of being overwritten")
  let cache=try JSONSerialization.jsonObject(with:Data(contentsOf:local.appendingPathComponent("ICloudDriveLibrary/provider-evidence.json"))) as! [String:Any]
  try check((cache["exportConflictIDs"] as? [String])?.count == 2 && cache["repairNextID"] != nil,
    "pure conflict rotation persists its cursor and removes only the resolved conflict")
 }

 static func verifyPureConflictRotationAfterExpiryAndRestart(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let (repo,texts,access,_,sources,local,_)=try await conflictFixture(root:root,name:"pure-conflict-expiry",count:5,manifest:manifest,audio:audio)
  let ids=Set(sources.map(\.id)), cache=local.appendingPathComponent("ICloudDriveLibrary/provider-evidence.json")
  // Expire after the selected repair's durable cursor, before its file work.
  // A cold process must pick the next candidate rather than retrying that head.
  for index in 0..<2 {
   let cold=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
   let gate=ICloudDriveCancellation()
   do {
    _ = try await cold.perform(.sync(sources,ids,maximumJobs:1),gate:gate,phase:{ phase in
     if case .saving = phase { gate.cancel() }
    })
    throw NSError(domain:"repair opportunity should expire",code:1)
   } catch is CancellationError { }
   let persisted=try JSONSerialization.jsonObject(with:Data(contentsOf:cache)) as! [String:Any]
   try check((persisted["repairNextID"] as? String)?.lowercased() == sources[index+1].id.uuidString.lowercased(),
    "expired pure-conflict lease durably yields its slot before a cold restart")
  }
  for _ in 0..<3 {
   let cold=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
   _ = try await cold.perform(.sync(sources,ids,maximumJobs:1),gate:ICloudDriveCancellation())
  }
  let evidence=try SyncEvidenceArchive(root:local,stream:"icloud_drive").load()!
  try check(evidence.rows.first { $0.segmentID == sources[4].id }?.artifacts.first { $0.kind == "audio" }?.state == "local_exported",
    "cold one-job rounds reach the fifth repair despite two expired leases and four permanent conflicts")
  try check(evidence.rows.filter { $0.artifacts.first { $0.kind == "audio" }?.state != "pending" }.count == 1,
    "expiry and restart never overwrite conflicting destinations or invent other exports")
 }

 static func verifyProviderUncheckedTail(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let (repo,texts,access,worker,sources,local,folder)=try await livenessFixture(root:root,
    name:"provider-unchecked-tail",count:20,manifest:manifest,audio:audio)
  let ids=Set(sources.map(\.id)); access.uploaded=true
  for _ in 0..<3 { _ = try await worker.perform(.sync(sources,ids),gate:ICloudDriveCancellation()) }
  let archive=SyncEvidenceArchive(root:local,stream:"icloud_drive")
  try check(try archive.load()!.context.counts["provider_uploaded_file_count"] == 61,
    "unchecked-tail fixture starts with 61 confirmed synthetic files")
  for source in sources { try FileManager.default.removeItem(at:repo.audioURL(for:source)) }
  let cache=local.appendingPathComponent("ICloudDriveLibrary/provider-evidence.json")
  let grant=local.appendingPathComponent("ICloudDriveLibrary/state.json"), grantBytes=try Data(contentsOf:grant)
  let historical=try JSONSerialization.jsonObject(with:Data(contentsOf:cache)) as! [String:Any]
  let oldObservations=historical["observations"] as! [String:NSDictionary]
  let allPaths=Set(oldObservations.keys)
  let before=access.metadataChecks
  let first=try await worker.perform(.refreshProviderStatus,gate:ICloudDriveCancellation())
  try check(access.metadataChecks-before == 32 && first.uploadedFileCount == 32 && first.pendingCloudFileCount == 29,
    "unchecked tail must remain pending after 32 queries: uploaded=\(first.uploadedFileCount), pending=\(first.pendingCloudFileCount)")
  let firstCache=try JSONSerialization.jsonObject(with:Data(contentsOf:cache)) as! [String:Any]
  let unchecked=Set(firstCache["providerChangeUncheckedPaths"] as! [String])
  let observations=firstCache["observations"] as! [String:NSDictionary]
  let cursor=firstCache["nextPath"] as! String
  try check(firstCache["providerChangePending"] as? Bool == true && unchecked.count == 29
    && unchecked.allSatisfy { observations[$0] == oldObservations[$0] },
    "unchecked historical observations retain their timestamps behind a durable 29-file fence")
  let report=try archive.load()!, checked=allPaths.subtracting(unchecked)
  try check(report.context.counts["provider_uploaded_file_count"] == 32
    && report.context.counts["pending_provider_file_count"] == 29
    && report.context.counts["provider_change_unchecked_file_count"] == 29,
    "report counts agree with state and never count the unchecked tail as complete")
  for row in report.rows {
   for artifact in row.artifacts {
    let path=(artifact.kind == "audio" ? "audio/" : "manifests/") + row.segmentID.uuidString.lowercased()
      + "/" + artifact.sha256 + (artifact.kind == "audio" ? ".caf" : ".json")
    try check((artifact.state == "provider_uploaded") == checked.contains(path)
      && (artifact.observedAtMS != nil) == checked.contains(path),
      "each artifact receipt excludes its own unchecked historical observation")
   }
   for commit in row.commits {
    let path="commits/"+row.segmentID.uuidString.lowercased()+"/"+commit.exportDigest+".json"
    try check(commit.providerUploaded == checked.contains(path)
      && (commit.observedAtMS != nil) == checked.contains(path),
      "each source commit receipt excludes its own unchecked historical observation")
   }
  }
  let noPermitBefore=access.metadataChecks
  let noPermit=try await worker.perform(.inspectProviderStatus,
    gate:ICloudDriveCancellation(takeProviderMetadataPermit:{ false }))
  let noPermitCache=try JSONSerialization.jsonObject(with:Data(contentsOf:cache)) as! NSDictionary
  try check(noPermit.uploadedFileCount == 32 && noPermit.pendingCloudFileCount == 29
    && access.metadataChecks == noPermitBefore && noPermitCache["providerChangePending"] as? Bool == true
    && Set(noPermitCache["providerChangeUncheckedPaths"] as! [String]) == unchecked
    && noPermitCache["observations"] as? NSDictionary == firstCache["observations"] as? NSDictionary
    && noPermitCache["nextPath"] as? String == cursor,
    "a zero-permit continuation preserves exact pending coverage, observations and cursor")
  let cold=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
  let loaded=try await cold.perform(.load,gate:ICloudDriveCancellation())
  try check(loaded.uploadedFileCount == 0 && (try archive.load()!.context.counts["provider_uploaded_file_count"] ?? 0) <= 32,
    "cold load cannot resurrect unchecked historical confirmations")
  let nextBefore=access.metadataChecks
  let complete=try await cold.perform(.sync(sources,ids,maximumJobs:0),gate:ICloudDriveCancellation())
  let nextPaths=Array(access.metadataPaths.dropFirst(nextBefore))
  let completeCache=try JSONSerialization.jsonObject(with:Data(contentsOf:cache)) as! NSDictionary
  try check(nextPaths.count <= 32 && nextPaths.filter { !$0.hasSuffix("/library.json") }.first?.hasSuffix("/"+cursor) == true
    && unchecked.allSatisfy { path in nextPaths.contains { $0.hasSuffix("/"+path) } },
    "cold zero-export continuation checks every remaining path from the durable cursor within 32 permits")
  try check(complete.uploadedFileCount == 61 && complete.pendingCloudFileCount == 0
    && completeCache["providerChangePending"] == nil && completeCache["providerChangeUncheckedPaths"] == nil,
    "only full provider coverage clears the pending-change fence")

  // Expiry inside the fourth callback must not count that callback or skip it
  // on restart. The first three completed observations remain useful.
  let cancelledGate=ICloudDriveCancellation(), cancelBefore=access.metadataChecks
  access.beforeMetadata={ if access.metadataChecks-cancelBefore == 3 { cancelledGate.cancel() } }
  do {
   _ = try await cold.perform(.refreshProviderStatus,gate:cancelledGate)
   throw NSError(domain:"provider-tail callback should expire",code:1)
  } catch is CancellationError { }
  access.beforeMetadata=nil
  let cancelled=try JSONSerialization.jsonObject(with:Data(contentsOf:cache)) as! [String:Any]
  let remaining=Set(cancelled["providerChangeUncheckedPaths"] as! [String])
  let cancelledCursor=cancelled["nextPath"] as! String
  try check(remaining.count == 58 && cancelled["providerChangePending"] as? Bool == true
    && (try archive.load()!.context.counts["provider_uploaded_file_count"]) == 3,
    "expiry persists only completed observations and leaves the interrupted path unchecked")
  let restarted=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
  let retryBefore=access.metadataChecks
  let retry=try await restarted.perform(.inspectProviderStatus,gate:ICloudDriveCancellation())
  try check(access.metadataChecks-retryBefore == 32 && retry.uploadedFileCount == 35
    && retry.pendingCloudFileCount == 26
    && access.metadataPaths[retryBefore].hasSuffix("/"+cancelledCursor),
    "read-only cold continuation resumes the interrupted path without losing completed coverage")
  _ = try await restarted.perform(.inspectProviderStatus,gate:ICloudDriveCancellation())

  // Schema-1 caches from P-54 have the bool but no per-path coverage. They must
  // conservatively resume a full pass, including if the next round gets no IO.
  var legacy=try JSONSerialization.jsonObject(with:Data(contentsOf:cache)) as! [String:Any]
  legacy["providerChangePending"]=true; legacy.removeValue(forKey:"providerChangeUncheckedPaths")
  try JSONSerialization.data(withJSONObject:legacy).write(to:cache,options:.atomic)
  let legacyWorker=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
  let legacyResult=try await legacyWorker.perform(.inspectProviderStatus,
    gate:ICloudDriveCancellation(takeProviderMetadataPermit:{ false }))
  let legacyCache=try JSONSerialization.jsonObject(with:Data(contentsOf:cache)) as! [String:Any]
  try check(legacyResult.uploadedFileCount == 0 && legacyResult.pendingCloudFileCount == 61
    && Set(legacyCache["providerChangeUncheckedPaths"] as! [String]) == allPaths,
    "legacy pending fence without coverage treats every expected path as unchecked")
  legacy["providerChangeUncheckedPaths"]=["outside-authorized-library.json"]
  try JSONSerialization.data(withJSONObject:legacy).write(to:cache,options:.atomic)
  let invalidWorker=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
  let invalid=try await invalidWorker.perform(.inspectProviderStatus,
    gate:ICloudDriveCancellation(takeProviderMetadataPermit:{ false }))
  try check(invalid.uploadedFileCount == 0 && invalid.pendingCloudFileCount == 61
    && (try archive.load()!.context.counts["provider_cache_reset_reason"]) == 2,
    "coverage outside the expected paths invalidates the cache without inventing confirmation")
  try check(try Data(contentsOf:grant) == grantBytes,
    "status refresh and zero-export recovery preserve the exact authorization and export ledger")
  try check(try FileManager.default.contentsOfDirectory(atPath:folder.path).count == 1
    && access.starts == access.stops,"tail recovery creates no extra library and balances security scopes")
 }

 static func verifyProviderChangeBeyondBatch(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let (repo,texts,access,worker,sources,local,_)=try await livenessFixture(root:root,name:"provider-change-large",count:20,manifest:manifest,audio:audio)
  let ids=Set(sources.map(\.id)); access.uploaded=true
  for _ in 0..<3 { _ = try await worker.perform(.sync(sources,ids),gate:ICloudDriveCancellation()) }
  let archive=SyncEvidenceArchive(root:local,stream:"icloud_drive"), initial=try archive.load()!
  try check(initial.context.counts["provider_uploaded_file_count"] == 61,
    "large provider fixture has more positive artifact and commit observations than the 32-query budget")
  // Metadata notifications and follow-up observations have no audio fallback.
  for source in sources { try FileManager.default.removeItem(at:repo.audioURL(for:source)) }
  let cache=local.appendingPathComponent("ICloudDriveLibrary/provider-evidence.json")
  for _ in 0..<4 {
   let before=access.metadataChecks
   var unchanged=try await worker.perform(.refreshProviderStatus,gate:ICloudDriveCancellation())
   try check(access.metadataChecks-before == 32 && unchanged.uploadedFileCount == 32
     && unchanged.pendingCloudFileCount == 29,
     "a fresh provider generation conservatively invalidates prior status and starts one bounded batch")
   let continuationBefore=access.metadataChecks
   unchanged=try await worker.perform(.continueProviderStatus,gate:ICloudDriveCancellation())
   try check(access.metadataChecks-continuationBefore <= 32 && unchanged.uploadedFileCount == 61
     && unchanged.pendingCloudFileCount == 0,
     "the next provider batch completes the current generation without requiring another signal")
  }
  let unchangedCache=try JSONSerialization.jsonObject(with:Data(contentsOf:cache)) as! NSDictionary
  let noPermitBefore=access.metadataChecks
  let noPermit=try await worker.perform(.refreshProviderStatus,
    gate:ICloudDriveCancellation(takeProviderMetadataPermit:{ false }))
  let noPermitCache=try JSONSerialization.jsonObject(with:Data(contentsOf:cache)) as! NSDictionary
  try check(noPermit.uploadedFileCount == 0 && noPermit.pendingCloudFileCount == 61 && access.metadataChecks == noPermitBefore
    && unchangedCache["observations"] as? NSDictionary == noPermitCache["observations"] as? NSDictionary
    && unchangedCache["nextPath"] as? String == noPermitCache["nextPath"] as? String
    && noPermitCache["providerChangePending"] as? Bool == true,
    "lstat-only notification retains history and cursor but requires provider confirmation for every path")
  access.uploaded=false
  let before=access.metadataChecks
  let changed=try await worker.perform(.continueProviderStatus,gate:ICloudDriveCancellation())
  let firstNegative=try archive.load()!
  try check(access.metadataChecks-before == 32 && changed.uploadedFileCount == 0 && changed.pendingCloudFileCount == 61
    && firstNegative.context.counts["provider_uploaded_file_count"] == 0
    && firstNegative.context.counts["provider_change_unchecked_file_count"] == 29,
    "negative provider replies and the unchecked tail both remain unconfirmed after the first batch")
  let secondBefore=access.metadataChecks
  let second=try await worker.perform(.inspectProviderStatus,gate:ICloudDriveCancellation())
  let withdrawn=try archive.load()!
  try check(access.metadataChecks-secondBefore <= 32 && second.uploadedFileCount == 0
    && withdrawn.context.counts["provider_uploaded_file_count"] == 0
    && withdrawn.rows.flatMap(\.artifacts).allSatisfy { $0.state != "provider_uploaded" },
    "fair continuation withdraws every negative provider observation beyond the first batch")
  let persisted=try JSONSerialization.jsonObject(with:Data(contentsOf:cache)) as! [String:Any]
  try check(persisted["providerChangePending"] == nil && persisted["providerChangeUncheckedPaths"] == nil,
    "negative responses still complete coverage, without claiming that any file uploaded")
  guard let cursor=persisted["nextPath"] as? String else { throw NSError(domain:"provider cursor missing",code:1) }
  access.uploaded=true
  let pathsBefore=access.metadataPaths.count
  let cold=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
  let restored=try await cold.perform(.sync(sources,ids,maximumJobs:0),gate:ICloudDriveCancellation())
  let firstPaths=Array(access.metadataPaths.dropFirst(pathsBefore))
  try check(firstPaths.count == 32 && firstPaths.filter { !$0.hasSuffix("/library.json") }.first?.hasSuffix("/"+cursor) == true,
    "cold metadata continuation resumes the persisted cursor within the same 32-query bound")
  try check(restored.savedAudioCount == 20 && restored.uploadedFileCount == 32,
    "zero-export round restores only the files it actually observes with all source audio absent")
  let nextBefore=access.metadataChecks
  let completed=try await cold.perform(.sync(sources,ids,maximumJobs:0),gate:ICloudDriveCancellation())
  try check(access.metadataChecks-nextBefore == 32 && completed.uploadedFileCount == 61,
    "later fair metadata round reaches every withdrawn file instead of starving the tail")
 }

 static func verifyProviderChangeLocalStampDemotion(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let (repo,texts,access,worker,sources,local,folder)=try await livenessFixture(root:root,
    name:"provider-change-local-stamps",count:20,manifest:manifest,audio:audio)
  let ids=Set(sources.map(\.id)); access.uploaded=true
  for _ in 0..<3 { _ = try await worker.perform(.sync(sources,ids),gate:ICloudDriveCancellation()) }
  let archive=SyncEvidenceArchive(root:local,stream:"icloud_drive"), initial=try archive.load()!
  let library=folder.appendingPathComponent("RecordForAgent-"+initial.context.libraryID!.uuidString.lowercased())
  let cache=local.appendingPathComponent("ICloudDriveLibrary/provider-evidence.json")
  for source in sources { try FileManager.default.removeItem(at:repo.audioURL(for:source)) }
  let initialCache=try JSONSerialization.jsonObject(with:Data(contentsOf:cache)) as! [String:Any]
  let originalObservations=initialCache["observations"] as! [String:NSDictionary]
  let positive=Set(originalObservations.compactMap { $0.value["uploaded"] as? Bool == true ? $0.key : nil })
  try check(positive.count == 61,"local stamp fixture confirms every synthetic file before mutation")
  for (index,mutation) in ["delete","move","inode","size"].enumerated() {
   let source=sources[index]
   let path="audio/"+source.id.uuidString.lowercased()+"/"+source.sha256+".caf"
   let target=library.appendingPathComponent(path)
   var before=stat()
   try check(lstat(target.path,&before) == 0,"mutation starts with a regular synthetic exported file")
   switch mutation {
   case "delete": try FileManager.default.removeItem(at:target)
   case "move": try FileManager.default.moveItem(at:target,to:root.appendingPathComponent("moved-synthetic-export"))
   case "inode":
    let replacement=root.appendingPathComponent("synthetic-inode-replacement")
    try Data(repeating:0,count:Int(manifest.byteCount)).write(to:replacement)
    try check(rename(replacement.path,target.path) == 0,"synthetic replacement changes inode at the confirmed path")
    var after=stat()
    try check(lstat(target.path,&after) == 0 && before.st_ino != after.st_ino && before.st_size == after.st_size,
      "inode replacement preserves file size so size-only checks cannot pass")
   default:
    try check(truncate(target.path,before.st_size+1) == 0,"synthetic size mutation requires no audio read")
    var after=stat()
    try check(lstat(target.path,&after) == 0 && before.st_ino == after.st_ino && before.st_size != after.st_size,
      "size mutation preserves inode so inode-only checks cannot pass")
   }
   let metadataBefore=access.metadataChecks
   let changed=try await worker.perform(.refreshProviderStatus,
     gate:ICloudDriveCancellation(takeProviderMetadataPermit:{ false }))
   let persisted=try JSONSerialization.jsonObject(with:Data(contentsOf:cache)) as! [String:Any]
   let observations=persisted["observations"] as! [String:NSDictionary]
   let actualPositive=Set(observations.compactMap { $0.value["uploaded"] as? Bool == true ? $0.key : nil })
   try check(changed.uploadedFileCount == 0 && changed.pendingCloudFileCount == 61 && actualPositive == positive
     && access.metadataChecks == metadataBefore,
     "\(mutation) fences every old positive without unbounded local scans when no provider permits are available")
   try check(positive.allSatisfy { observations[$0] == originalObservations[$0] },
     "\(mutation) preserves historical observations and timestamps until each path receives its bounded check")
   let evidence=try archive.load()!
   try check(evidence.rows.first { $0.segmentID == source.id }?.artifacts.first { $0.kind == "audio" }?.state != "provider_uploaded"
     && evidence.context.counts["provider_uploaded_file_count"] == 0
     && evidence.context.counts["retained_historical_provider_positive_count"] == positive.count,
     "\(mutation) excludes the unchecked changed artifact from current per-source evidence and total")
  }
  let cold=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
  let restored=try await cold.perform(.refreshProviderStatus,
    gate:ICloudDriveCancellation(takeProviderMetadataPermit:{ false }))
  try check(restored.uploadedFileCount == 0 && restored.pendingCloudFileCount == 61,
    "cold notification cannot promote unchanged historical confirmations without provider permits")
  let cancelledSource=sources[4]
  try FileManager.default.removeItem(at:library.appendingPathComponent(
    "audio/"+cancelledSource.id.uuidString.lowercased()+"/"+cancelledSource.sha256+".caf"))
  let beforeCancellation=try JSONSerialization.jsonObject(with:Data(contentsOf:cache)) as! NSDictionary
  let cancelledGate=ICloudDriveCancellation()
  do {
   _ = try await cold.perform(.refreshProviderStatus,gate:cancelledGate,phase:{ phase in
    if case .checkingCloud = phase { cancelledGate.cancel() }
   })
   throw NSError(domain:"provider change should cancel before local stamp validation",code:1)
  } catch is CancellationError { }
  let cancelledEvidence=try archive.load()!
  try check(cancelledEvidence.context.counts["provider_uploaded_file_count"] == 0
    && cancelledEvidence.rows.flatMap(\.artifacts).allSatisfy { $0.state != "provider_uploaded" },
    "cancellation before local stamp validation cannot publish unchecked paths as currently uploaded")
  let afterCancelledCache=try JSONSerialization.jsonObject(with:Data(contentsOf:cache)) as! NSDictionary
  try check(afterCancelledCache["observations"] as? NSDictionary == beforeCancellation["observations"] as? NSDictionary
    && afterCancelledCache["nextPath"] as? String == beforeCancellation["nextPath"] as? String
    && afterCancelledCache["providerChangePending"] as? Bool == true,
    "cancelled notification preserves observations and cursor while durably marking their required local revalidation")
  let coldAfterCancellation=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
  let loadedAfterCancellation=try await coldAfterCancellation.perform(.load,gate:ICloudDriveCancellation())
  let loadedEvidence=try archive.load()!
  try check(loadedAfterCancellation.uploadedFileCount == 0
    && loadedEvidence.context.counts["provider_uploaded_file_count"] == 0,
    "cold load cannot republish historical confirmations before a cancelled notification's local validation resumes")
  let afterCancellation=try await coldAfterCancellation.perform(.sync(sources,ids,maximumJobs:0),
    gate:ICloudDriveCancellation(takeProviderMetadataPermit:{ false }))
  let recoveredCache=try JSONSerialization.jsonObject(with:Data(contentsOf:cache)) as! NSDictionary
  try check(afterCancellation.uploadedFileCount == 0 && afterCancellation.pendingCloudFileCount == 61
    && recoveredCache["providerChangePending"] as? Bool == true
    && (try archive.load()!.context.counts["retained_historical_provider_positive_count"]) == 61,
    "cold zero-permit synchronization keeps historical observations fenced until bounded metadata checks resume")

  let failedSource=sources[5]
  try FileManager.default.removeItem(at:library.appendingPathComponent(
    "audio/"+failedSource.id.uuidString.lowercased()+"/"+failedSource.sha256+".caf"))
  access.beforeValidate={ throw NSError(domain:"synthetic provider change validation failure",code:35) }
  let failed=try await coldAfterCancellation.perform(.refreshProviderStatus,gate:ICloudDriveCancellation())
  let failedCache=try JSONSerialization.jsonObject(with:Data(contentsOf:cache)) as! NSDictionary
  try check(failed.uploadedFileCount == 0 && failed.error != nil
    && failedCache["providerChangePending"] as? Bool == true,
    "a transient target validation failure retains the durable notification fence")
  access.beforeValidate=nil
  let coldAfterFailure=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
  _ = try await coldAfterFailure.perform(.load,gate:ICloudDriveCancellation())
  let resumed=try await coldAfterFailure.perform(.sync(sources,ids,maximumJobs:0),
    gate:ICloudDriveCancellation(takeProviderMetadataPermit:{ false }))
  let resumedCache=try JSONSerialization.jsonObject(with:Data(contentsOf:cache)) as! NSDictionary
  try check(resumed.error == nil && resumed.uploadedFileCount == 0 && resumed.pendingCloudFileCount == 61
    && resumedCache["providerChangePending"] as? Bool == true
    && (try archive.load()!.context.counts["retained_historical_provider_positive_count"]) == 61,
    "target recovery preserves the unchecked fence without turning old positives into current confirmation")
  var complete=resumed
  for _ in 0..<8 {
   complete=try await coldAfterFailure.perform(.continueProviderStatus,gate:ICloudDriveCancellation())
   let current=try continuationCache(local)
   if current["providerChangePending"] as? Bool != true && current["providerChangeReplayPending"] as? Bool != true { break }
  }
  let final=try archive.load()!
  try check(complete.uploadedFileCount == 55 && complete.pendingCloudFileCount == 6
    && final.context.counts["provider_file_unavailable_count"] == 4
    && final.context.counts["provider_identity_mismatch_count"] == 2,
    "bounded continuation replaces all six changed-file positives with unavailable or identity-mismatch observations")
  try check(access.starts == access.stops,"local stamp revalidation keeps security-scoped access balanced")
 }
}

// A one-job lease and cold restart reproduce starvation more strictly than the
// production two-job budget. No real recordings or provider are accessed.
extension Probe {
 static func verifyNewExportBeforeRepair(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let (repo,texts,access,worker,historical,local,folder)=try await livenessFixture(root:root,
    name:"new-before-repair",count:3,manifest:manifest,audio:audio)
  let oldIDs=Set(historical.map(\.id)); access.uploaded=true
  _ = try await worker.perform(.sync(historical,oldIDs,maximumJobs:1),gate:ICloudDriveCancellation())
  let archive=SyncEvidenceArchive(root:local,stream:"icloud_drive"), initial=try archive.load()!
  let old=initial.rows.first { $0.artifacts.contains { $0.kind == "audio" && $0.state == "provider_uploaded" } }!
  let oldSource=historical.first { $0.id == old.segmentID }!
  let target=folder.appendingPathComponent("RecordForAgent-"+initial.context.libraryID!.uuidString.lowercased())
   .appendingPathComponent("audio/"+old.segmentID.uuidString.lowercased()+"/"+old.sha256+".caf")
  try check(chmod(target.path,0o640) == 0,"new-source priority fixture marks one old source for identity repair")
  _ = try await worker.perform(.sync(historical,oldIDs,maximumJobs:0),gate:ICloudDriveCancellation())
  try FileManager.default.removeItem(at:repo.audioURL(for:oldSource))
  let id=UUID(), started=Date().addingTimeInterval(1), fresh=SegmentManifest(id:id,
    sessionID:manifest.sessionID,sequence:999,startedAt:started,endedAt:started.addingTimeInterval(60),
    sampleRate:manifest.sampleRate,frameCount:manifest.frameCount,fileName:id.uuidString.lowercased()+".caf",
    byteCount:manifest.byteCount,sha256:manifest.sha256)
  _ = try repo.acceptIncomingFile(at:audio,manifest:fresh)
  let all=historical+[fresh], ids=Set(all.map(\.id))
  let cold=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
  let first=try await cold.perform(.sync(all,ids,maximumJobs:1),gate:ICloudDriveCancellation())
  let afterNew=try archive.load()!
  try check(first.savedAudioCount == 2 && afterNew.context.counts["needs_identity_revalidation_count"] == 1
    && afterNew.rows.first { $0.segmentID == fresh.id }?.artifacts.first { $0.kind == "audio" }?.state == "provider_uploaded",
    "a recent source exports before the inherited historical repair turn in a one-job cold lease")
  let repairWorker=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
  let second=try await repairWorker.perform(.sync(all,ids,maximumJobs:1),gate:ICloudDriveCancellation())
  let afterRepair=try archive.load()!
  try check(second.savedAudioCount == 2 && afterRepair.context.counts["needs_identity_revalidation_count"] == 0,
    "the next cold one-job lease retains the repair turn instead of starving it behind pending exports")
 }

 static func verifyRepairExportFairness(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let (repo,texts,access,worker,sources,local,folder)=try await livenessFixture(root:root,name:"repair-fairness",count:8,manifest:manifest,audio:audio)
  let ids=Set(sources.map(\.id)); access.uploaded=true
  let first=try await worker.perform(.sync(sources,ids,maximumJobs:1),gate:ICloudDriveCancellation())
  try check(first.savedAudioCount == 1,"one-job lease bounds fresh export work")
  let archive=SyncEvidenceArchive(root:local,stream:"icloud_drive"), initial=try archive.load()!
  let row=initial.rows.first { $0.artifacts.contains { $0.kind == "audio" && $0.state == "provider_uploaded" } }!
  let source=sources.first { $0.id == row.segmentID }!
  let library=folder.appendingPathComponent("RecordForAgent-"+initial.context.libraryID!.uuidString.lowercased())
  let target=library.appendingPathComponent("audio/"+source.id.uuidString.lowercased()+"/"+source.sha256+".caf")
  try check(chmod(target.path,0o640) == 0,"fairness fixture changes only target ctime")
  _ = try await worker.perform(.sync(sources,ids,maximumJobs:0),gate:ICloudDriveCancellation())
  let gap=try archive.load()!
  try check(gap.context.counts["needs_identity_revalidation_count"] == 1,"metadata-only round records proof gap without exporting")
  // A repair cannot fall back to rereading/re-exporting this source.
  try FileManager.default.removeItem(at:repo.audioURL(for:source))
  let cold=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
  let repaired=try await cold.perform(.sync(sources,ids,maximumJobs:1),gate:ICloudDriveCancellation())
  let repairedEvidence=try archive.load()!
  try check(repaired.error == nil && repaired.savedAudioCount == 1
    && repairedEvidence.context.counts["needs_identity_revalidation_count"] == 0,
    "durable category cursor repairs target before seven waiting fresh exports after restart")
  let coldAgain=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
  let exported=try await coldAgain.perform(.sync(sources,ids,maximumJobs:1),gate:ICloudDriveCancellation())
  try check(exported.error == nil && exported.savedAudioCount == 2,
    "next one-job lease admits fresh export instead of monopolizing repair category")
 }
}

private final class ProbeMetadataQuery: NSMetadataQuery {
 var starts = 0, stops = 0
 override func start() -> Bool { starts += 1; return true }
 override func stop() { stops += 1 }
}
private final class ProbeMonitorCounts: @unchecked Sendable { var changes = 0; var starts = 0; var stops = 0 }
extension Probe {
 static func monitor(_ changed: @escaping @Sendable () -> Void) -> ICloudDriveProviderMonitor {
  .init(changed:changed,makeQuery:{ ProbeMetadataQuery() },startAccess:{ _ in true },stopAccess:{ _ in })
 }
 static func verifyProviderMonitor(root:URL) throws {
  let q=ProbeMetadataQuery(), counts=ProbeMonitorCounts()
  let monitor=ICloudDriveProviderMonitor(changed:{ counts.changes += 1 },makeQuery:{ q },
    startAccess:{ _ in counts.starts += 1; return true },stopAccess:{ _ in counts.stops += 1 })
  monitor.observe(root)
  try check(q.searchScopes.count == 1 && (q.searchScopes.first as? URL) == root,
    "metadata subscription searches only the authorized folder")
  monitor.observe(root)
  try check(q.starts == 1 && counts.starts == 1,"publishing unchanged state does not restart metadata gathering")
  NotificationCenter.default.post(name:.NSMetadataQueryDidUpdate,object:q)
  try check(counts.changes == 1,"provider metadata update emits a signal without reading query results")
  monitor.stop()
  NotificationCenter.default.post(name:.NSMetadataQueryDidUpdate,object:q)
  try check(counts.changes == 1 && counts.stops == 1 && q.stops == 1,
    "stop balances security scope and suppresses later notifications")
 }
 static func verifyMetadataOnlyRefresh(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let (repo,_,access,worker,sources,_,_)=try await livenessFixture(root:root,name:"metadata-event",count:3,manifest:manifest,audio:audio)
  let ids=Set(sources.map(\.id))
  _ = try await worker.perform(.sync(sources,ids,maximumJobs:1),gate:ICloudDriveCancellation())
  for source in sources { try FileManager.default.removeItem(at:repo.audioURL(for:source)) }
  access.uploaded=true; let before=access.metadataChecks
  let state=try await worker.perform(.refreshProviderStatus,gate:ICloudDriveCancellation())
  try check(state.error == nil && state.savedAudioCount == 1 && state.uploadedFileCount > 0,
    "notification path confirms metadata with all source audio absent and leaves pending exports untouched")
  try check(access.metadataChecks-before <= 32,"notification metadata query work retains the bounded provider quota")
  _ = try await worker.perform(.setEnabled(false),gate:ICloudDriveCancellation())
  let pausedChecks=access.metadataChecks
  _ = try await worker.perform(.refreshProviderStatus,gate:ICloudDriveCancellation())
  try check(access.metadataChecks == pausedChecks,"paused grant rejects notification-triggered provider access")
 }
}

extension Probe {
 @MainActor static func verifyProviderEventRouting(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let (repo,texts,access,_,sources,_,_)=try await livenessFixture(root:root,name:"event-routing",count:1,manifest:manifest,audio:audio)
  UIApplication.shared.applicationState = .active
  let q=ProbeMetadataQuery()
  let library=ICloudDriveLibrary(repository:repo,transcriptRepository:texts,folderAccess:access.access,
    providerMonitorFactory:{ changed in .init(changed:changed,makeQuery:{ q },startAccess:{ _ in true },stopAccess:{ _ in }) })
  try await settle(library)
  try check(library.savedAudioCount == 1 && library.uploadedFileCount == 0 && q.starts == 1,
    "enabled coordinator subscribes after independent target validation")
  let id=UUID(), extra=SegmentManifest(id:id,sessionID:manifest.sessionID,sequence:77,
    startedAt:manifest.startedAt,endedAt:manifest.endedAt,sampleRate:manifest.sampleRate,frameCount:manifest.frameCount,
    fileName:id.uuidString.lowercased()+".caf",byteCount:manifest.byteCount,sha256:manifest.sha256)
  _ = try repo.acceptIncomingFile(at:audio,manifest:extra)
  try FileManager.default.removeItem(at:repo.audioURL(for:sources[0]))
  access.uploaded=true
  NotificationCenter.default.post(name:.NSMetadataQueryDidUpdate,object:q)
  let limit=ProcessInfo.processInfo.systemUptime+5
  while library.uploadedFileCount == 0 || library.isBusy {
   guard ProcessInfo.processInfo.systemUptime < limit else { throw NSError(domain:"Metadata event timeout",code:1) }
   try await Task.sleep(nanoseconds:10_000_000)
  }
  try check(library.savedAudioCount == 1 && library.authorizedCount == 1 && library.error == nil,
    "actual event callback only refreshes metadata and cannot discover or export the new source")
  library.suspendForBackground()
  let checks=access.metadataChecks
  NotificationCenter.default.post(name:.NSMetadataQueryDidUpdate,object:q)
  try await Task.sleep(nanoseconds:20_000_000)
  try check(q.stops == 1 && access.metadataChecks == checks,
    "background transition stops subscription without granting execution or querying provider")
 }
}
