// REC-39/Build 89: a foreground export backlog must not withhold current
// provider observations and published progress until the final source finishes.
extension Probe {
 @MainActor static func verifyForegroundSyncSlices(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let (repo,texts,access,_,sources,local,_)=try await livenessFixture(root:root,
   name:"foreground-sync-slices",count:8,manifest:manifest,audio:audio)
  let stateURL=local.appendingPathComponent("ICloudDriveLibrary/state.json")
  let latch=ProbeMetadataLatch()
  access.uploaded=true
  access.beforeValidate={
   let state=try JSONSerialization.jsonObject(with:Data(contentsOf:stateURL)) as! [String:Any]
   let ledger=try TransportCodec.decode(ICloudDriveLibraryLedger.self,
    from:JSONSerialization.data(withJSONObject:state["ledger"]!))
   if ledger.exportedAudioCount == 2 { latch.enterOnce() }
  }
  UIApplication.shared.applicationState = .active
  let library=ICloudDriveLibrary(repository:repo,transcriptRepository:texts,folderAccess:access.access,
   providerMonitorFactory:monitor)
  defer { latch.release(); access.beforeValidate=nil; library.suspendForBackground() }
  let limit=ProcessInfo.processInfo.systemUptime+12
  while !latch.hasEntered {
   guard ProcessInfo.processInfo.systemUptime < limit else { throw NSError(domain:"Foreground slice latch timeout",code:1) }
   try await Task.sleep(nanoseconds:1_000_000)
  }
  let during=try SyncEvidenceArchive(root:local,stream:"icloud_drive").load()!
  try check(library.savedAudioCount == 2 && library.uploadedFileCount == 7
    && library.authorizedCount == 8 && library.isBusy,
   "two local exports and their seven provider confirmations publish while the remaining foreground exports are blocked")
  try check(during.context.counts["local_exported_artifact_count"] == 4
    && during.context.counts["provider_uploaded_file_count"] == 7
    && during.context.counts["pending_export_artifact_count"] == 12
    && during.context.counts["bg_round"] == 0,
   "sync evidence publishes the same bounded foreground progress before backlog completion")
  let audioRows=during.rows.flatMap(\.artifacts).filter { $0.kind == "audio" }
  try check(audioRows.filter { $0.state == "provider_uploaded" }.count == 2
    && audioRows.filter { $0.state == "pending" }.count == 6,
   "per-source evidence distinguishes confirmed local exports from sources not yet exported")
  try check(audioRows.filter { $0.state == "provider_uploaded" }.allSatisfy {
    $0.localExportedAtMS != nil && $0.providerCheckedAtMS != nil
      && $0.providerResult == .uploaded && $0.providerGate == .current
   } && audioRows.filter { $0.state == "pending" }.allSatisfy {
    $0.localExportedAtMS == nil && $0.providerCheckedAtMS == nil
      && $0.providerResult == nil && $0.providerGate == .awaitingLocalExport
   }, "diagnostics preserve exact local export and last check times with typed current versus not-local state")
  // A user stop between slices must win before another coordinated write.
  library.pause(); latch.release(); access.beforeValidate=nil
  try await continuationIdle(library)
  try await waitForStop(local:local,disconnected:false)
  let paused=try JSONSerialization.jsonObject(with:Data(contentsOf:stateURL)) as! [String:Any]
  let pausedLedger=try TransportCodec.decode(ICloudDriveLibraryLedger.self,
   from:JSONSerialization.data(withJSONObject:paused["ledger"]!))
  try check(pausedLedger.exportedAudioCount == 2 && !library.isEnabled,
   "pause between foreground slices prevents the third export without losing authorization or user files")
  library.setEnabled(true)
  try await continuationIdle(library)
  try check(library.savedAudioCount == 8 && library.uploadedFileCount == 25
    && library.pendingCloudFileCount == 0 && library.error == nil,
   "resuming drains every remaining foreground slice without another discovery or provider notification saved=\(library.savedAudioCount) uploaded=\(library.uploadedFileCount) pending=\(library.pendingCloudFileCount) error=\(library.error ?? "nil")")
  try check(sources.allSatisfy { FileManager.default.fileExists(atPath:repo.audioURL(for:$0).path) }
    && access.starts == access.stops && library.scope == .existingAndFuture,
   "foreground slicing retains every source, balanced security scope and the exact authorization")
  try await verifyForegroundSliceFailureQuiescence(root:root,manifest:manifest,audio:audio)
 }

 @MainActor static func verifyForegroundSliceFailureQuiescence(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let (repo,texts,access,_,sources,local,folder)=try await livenessFixture(root:root,
   name:"foreground-slice-conflict",count:24,manifest:manifest,audio:audio)
  let state=try JSONSerialization.jsonObject(with:Data(contentsOf:local.appendingPathComponent("ICloudDriveLibrary/state.json"))) as! [String:Any]
  let ledger=try TransportCodec.decode(ICloudDriveLibraryLedger.self,
   from:JSONSerialization.data(withJSONObject:state["ledger"]!))
  let writer=ICloudDriveExportWriter(root:folder,libraryID:ledger.libraryID)
  _ = try writer.validateMarker(createIfMissing:true)
  let bad=sources[0], target=writer.libraryURL
   .appendingPathComponent("audio/"+bad.id.uuidString.lowercased()+"/"+bad.sha256+".caf")
  try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
  try Data("synthetic conflicting user file".utf8).write(to:target)
  // Corrupt metadata in the first transcript cohort must retain its warning
  // after subsequent slices inspect the remaining sources.
  try Data("{}".utf8).write(to:local.appendingPathComponent("transcripts/"+bad.id.uuidString.lowercased()+".json"),options:.atomic)
  UIApplication.shared.applicationState = .active
  let library=ICloudDriveLibrary(repository:repo,transcriptRepository:texts,folderAccess:access.access,
   providerMonitorFactory:monitor)
  defer { library.suspendForBackground() }
  try await continuationIdle(library)
  let checks=access.metadataChecks
  try await Task.sleep(nanoseconds:40_000_000)
  try check(library.savedAudioCount == 23 && !library.isBusy && access.metadataChecks == checks,
   "a permanent source conflict does not spin automatic sync slices or starve the 23 healthy peers saved=\(library.savedAudioCount) busy=\(library.isBusy) error=\(library.error ?? "nil")")
  let evidence=try SyncEvidenceArchive(root:local,stream:"icloud_drive").load()!
  try check(evidence.context.counts["transcript_issue_count"] == 1 && library.error?.contains("转写") == true,
   "later transcript slices preserve the prior corrupt source warning")
  try check(library.diagnosticSnapshot().counts?.sourceDiscoveryCovered == 24
    && (try Data(contentsOf:target)) == Data("synthetic conflicting user file".utf8),
   "bounded transcript coverage completes and preserves the conflicting user file")
 }
}
