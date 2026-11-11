// Source-local failures must not close the healthy metadata confirmation
// pipeline. These cases drive the production coordinator, using only synthetic
// temporary files and injected provider observations.
extension Probe {
 @MainActor static func verifySourceIsolationProviderContinuation(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  for fault in ["corrupt_transcript", "changed_source_manifest", "changed_source_receipt"] {
   let (repo,texts,access,worker,sources,local,_)=try await livenessFixture(root:root,
    name:"source-warning-continuation-"+fault,count:21,manifest:manifest,audio:audio)
   let bad=sources[0]
   let receiptFile=local.appendingPathComponent("receipts/"+bad.id.uuidString.lowercased()+".json")
   let originalReceipt=try Data(contentsOf:receiptFile)
   if fault == "corrupt_transcript" {
    try texts.save(SegmentTranscript(segmentID:bad.id,audioSHA256:bad.sha256,locale:"zh-CN",engine:"synthetic",
     createdAt:Date(timeIntervalSince1970:500),text:"synthetic pending text",spans:[]),for:bad)
    _ = try await worker.perform(.sync(sources,Set(sources.map(\.id)),maximumJobs:0),gate:ICloudDriveCancellation())
    try Data("{}".utf8).write(to:local.appendingPathComponent("transcripts/"+bad.id.uuidString.lowercased()+".json"),options:.atomic)
   } else if fault == "changed_source_manifest" {
    let changed=SegmentManifest(id:bad.id,sessionID:bad.sessionID,sequence:bad.sequence+100,
     startedAt:bad.startedAt,endedAt:bad.endedAt,sampleRate:bad.sampleRate,frameCount:bad.frameCount,
     fileName:bad.fileName,byteCount:bad.byteCount,sha256:bad.sha256)
    try TransportCodec.encode(changed).write(to:local.appendingPathComponent("manifests/"+bad.id.uuidString.lowercased()+".json"),options:.atomic)
   } else {
    try TransportCodec.encode(SegmentReceipt(segmentID:bad.id,sha256:String(repeating:"f",count:64),
     byteCount:bad.byteCount)).write(to:receiptFile,options:.atomic)
   }
   // Queue the already-delivered source snapshot before the coordinator gets
   // execution time. Exact per-source metadata still fences the actual export.
   UIApplication.shared.applicationState = .background
   let query=ProbeMetadataQuery()
   let library=ICloudDriveLibrary(repository:repo,transcriptRepository:texts,folderAccess:access.access,
    providerMonitorFactory:{ changed in .init(changed:changed,makeQuery:{ query },startAccess:{ _ in true },stopAccess:{ _ in }) })
   if fault == "corrupt_transcript" {
    library.discover(manifests:sources,receivedIDs:Set(sources.map(\.id)))
    library.transcriptDidSave(for:bad)
   }
   // The changed-manifest case deliberately supplies no source snapshot:
   // actual cold load -> sync(nil,nil) must isolate its freshly read replacement.
   var firstBatchError:Error?, removedSourceAudio=false, initialBatches:[Int]=[], previous=access.metadataChecks
   let firstPass=library.$isBusy.sink { busy in
    guard !busy, access.metadataChecks > previous else { return }
    initialBatches.append(access.metadataChecks-previous); previous=access.metadataChecks
    // Foreground exports now publish between two-source slices. Remove
    // synthetic sources only after their local writes, then require all later
    // provider-only continuation to work without reopening them.
    if !removedSourceAudio && library.savedAudioCount == (fault == "corrupt_transcript" ? 21 : 20) {
     removedSourceAudio=true
     do { for source in sources { try FileManager.default.removeItem(at:repo.audioURL(for:source)) } }
     catch { firstBatchError=error }
    }
   }
   UIApplication.shared.applicationState = .active
   library.resume()
   try await continuationIdle(library)
   firstPass.cancel()
   if let firstBatchError { throw firstBatchError }
   let expected=fault == "corrupt_transcript" ? 64 : 61
   let warning=library.error, initial=try SyncEvidenceArchive(root:local,stream:"icloud_drive").load()!
   let issueKey=fault == "corrupt_transcript" ? "transcript_issue_count" : "source_metadata_issue_count"
   try check(library.isEnabled && warning != nil && !library.hasBlockingError && removedSourceAudio
     && library.savedAudioCount == (fault == "corrupt_transcript" ? 21 : 20)
     && library.uploadedFileCount == 0 && library.pendingCloudFileCount == expected
     && initialBatches.count >= 2 && initialBatches.allSatisfy { $0 <= 32 }
     && initial.context.counts[issueKey] == 1 && initial.context.failureCode == nil,
    "\(fault) remains a visible isolated warning while the real scheduler drains its initial >32-file cohort")
   try check(!initial.context.discoveryComplete && initial.context.counts["source_discovery_pass_count"] == 1
     && initial.context.counts["transcript_inspected_this_round"] == 0
     && query.starts == 1 && query.stops == 0,
    "isolated source warnings preserve the monitor and use metadata-only continuation without retrying corrupt discovery")
   let grant=local.appendingPathComponent("ICloudDriveLibrary/state.json"), grantBytes=try Data(contentsOf:grant)
   let before=access.metadataChecks
   var last=before, batches:[Int]=[], warningsPreserved=true
   let observation=library.$isBusy.sink { busy in
    guard !busy, access.metadataChecks > last else { return }
    batches.append(access.metadataChecks-last); last=access.metadataChecks
    warningsPreserved = warningsPreserved && library.error == warning
   }
   access.uploaded=true
   NotificationCenter.default.post(name:.NSMetadataQueryDidUpdate,object:query)
   try await continuationIdle(library)
   observation.cancel()
   let evidence=try SyncEvidenceArchive(root:local,stream:"icloud_drive").load()!, cache=try continuationCache(local)
   let badRow=evidence.rows.first { $0.segmentID == bad.id }!
   try check(library.uploadedFileCount == expected && library.pendingCloudFileCount == 0
     && Set(access.metadataPaths.dropFirst(before)).count == expected && batches.count >= 2
     && batches.allSatisfy { $0 > 0 && $0 <= 32 } && warningsPreserved && library.error == warning
     && !library.hasBlockingError,
    "one notification confirms every healthy \(fault) path automatically, retaining the warning after each bounded batch")
   try check(evidence.context.failureCode == nil && evidence.context.counts[issueKey] == 1
     && evidence.context.counts["provider_uploaded_file_count"] == expected
     && evidence.context.counts["source_discovery_pass_count"] == 1
     && evidence.context.counts["transcript_inspected_this_round"] == 0
     && cache["providerChangePending"] == nil && query.starts == 1 && query.stops == 0
     && (try Data(contentsOf:grant)) == grantBytes,
    "healthy confirmations survive evidence publication without changing the grant or erasing source findings")
   let rejectedText=badRow.artifacts.filter { $0.kind == "transcriptJSON" || $0.kind == "transcriptText" }
   try check(fault == "corrupt_transcript"
     ? rejectedText.count == 2 && rejectedText.allSatisfy { $0.state == "pending" }
     : badRow.artifacts.allSatisfy { $0.state == "pending" },
    "isolating \(fault) never promotes its rejected artifacts to provider uploaded")
   let cold=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
   let restored=try await cold.perform(.load,gate:ICloudDriveCancellation())
   try check(restored.sourceWarning == warning && restored.blockingError == nil && restored.enabled,
    "a cold load restores the durable \(fault) warning without reopening absent audio or creating a provider failure")
   if fault != "corrupt_transcript" {
    try TransportCodec.encode(bad).write(to:local.appendingPathComponent("manifests/"+bad.id.uuidString.lowercased()+".json"),options:.atomic)
    try originalReceipt.write(to:receiptFile,options:.atomic)
    try FileManager.default.copyItem(at:audio,to:repo.audioURL(for:bad))
    library.resume()
    try await continuationIdle(library)
    let recovered=try SyncEvidenceArchive(root:local,stream:"icloud_drive").load()!
    try check(library.error == nil && !library.hasBlockingError && library.isEnabled
      && library.savedAudioCount == 21 && library.uploadedFileCount == 64 && library.pendingCloudFileCount == 0
      && recovered.context.counts["source_metadata_issue_count"] == 0
      && recovered.context.libraryID == initial.context.libraryID && query.starts == 1 && query.stops == 0,
     "restoring the exact \(fault) binding clears only its warning and resumes that original source grant")
   }
   library.suspendForBackground()
  }
  try await verifySourceWarningContinuationSafety(root:root,manifest:manifest,audio:audio)
  try await verifySourceDiscoveryInputGuards(root:root,manifest:manifest,audio:audio)
 }

 static func verifySourceDiscoveryInputGuards(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  for fault in ["duplicate_id", "invalid_replacement"] {
   let (_,_,access,worker,sources,local,_)=try await livenessFixture(root:root,
    name:"source-discovery-guard-"+fault,count:1,manifest:manifest,audio:audio)
   let source=sources[0], grant=local.appendingPathComponent("ICloudDriveLibrary/state.json")
   let original=try Data(contentsOf:grant)
   let replacement=SegmentManifest(id:source.id,sessionID:source.sessionID,sequence:source.sequence,
    startedAt:source.startedAt,endedAt:source.endedAt,sampleRate:source.sampleRate,frameCount:source.frameCount,
    fileName:source.fileName,byteCount:131*1_024*1_024,sha256:source.sha256)
   let state=try await worker.perform(.sync(fault == "duplicate_id" ? [source,source] : [replacement],[source.id]),
    gate:ICloudDriveCancellation())
   try check(state.blockingError != nil && state.sourceWarning == nil && state.savedAudioCount == 0
     && state.providerObservationURL == nil && !state.needsProviderContinuation && access.metadataChecks == 0
     && (try Data(contentsOf:grant)) == original,
    "\(fault) retains strict discovery rejection without provider work, a source-warning downgrade, or a grant rewrite")
  }
 }

 @MainActor static func verifySourceWarningContinuationSafety(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  for fault in ["directory_unavailable", "identity_changed", "pause", "disconnect"] {
   let (repo,texts,access,_,sources,local,folder)=try await livenessFixture(root:root,
    name:"source-warning-safety-"+fault,count:21,manifest:manifest,audio:audio)
   try seedContinuationExports(repo:repo,local:local,folder:folder)
   try Data("{}".utf8).write(to:local.appendingPathComponent("transcripts/"+sources[0].id.uuidString.lowercased()+".json"),options:.atomic)
   for source in sources { try FileManager.default.removeItem(at:repo.audioURL(for:source)) }
   UIApplication.shared.applicationState = .active
   let query=ProbeMetadataQuery()
   var providerChanged:(@Sendable () -> Void)?
   let library=ICloudDriveLibrary(repository:repo,transcriptRepository:texts,folderAccess:access.access,
    providerMonitorFactory:{ changed in
     providerChanged=changed
     return .init(changed:changed,makeQuery:{ query },startAccess:{ _ in true },stopAccess:{ _ in })
    })
   try await continuationIdle(library)
   try check(library.error != nil && !library.hasBlockingError && library.isEnabled && query.stops == 0,
    "\(fault) fixture begins with a nonblocking corrupt transcript warning")
   let before=access.metadataChecks
   var injected=false
   let observation=library.$isBusy.sink { busy in
    guard !busy, !injected, access.metadataChecks > before else { return }
    injected=true
    if fault == "directory_unavailable" { access.beforeValidate={ throw ICloudDriveLibraryFailure.directoryUnavailable } }
    else if fault == "identity_changed" { access.identity=String(repeating:"b",count:64) }
    else {
     Task { @MainActor in
      if fault == "pause" { library.pause() } else { library.disconnect() }
     }
    }
   }
   access.uploaded=true
   NotificationCenter.default.post(name:.NSMetadataQueryDidUpdate,object:query)
   try await continuationIdle(library)
   observation.cancel()
   let stoppedAt=access.metadataChecks, evidence=try SyncEvidenceArchive(root:local,stream:"icloud_drive").load()!
   try await Task.sleep(nanoseconds:30_000_000)
   try check(injected && stoppedAt-before == 32 && access.metadataChecks == stoppedAt && !library.isBusy
     && library.uploadedFileCount == 0 && query.stops > 0
     && evidence.rows.allSatisfy { $0.artifacts.allSatisfy { $0.state != "provider_uploaded" }
       && $0.commits.allSatisfy { !$0.providerUploaded } },
    "\(fault) blocks the remaining metadata tail and current positive publication despite a source warning")
   try check(fault == "directory_unavailable"
     ? library.isEnabled && evidence.context.failureCode == "provider_unavailable"
     : !library.isEnabled,
    "\(fault) retains its original provider/auth stop semantics")
   if fault == "directory_unavailable" || fault == "identity_changed" {
    try check(library.hasBlockingError,"\(fault) remains a blocking error rather than a source warning")
   }
   if fault == "disconnect" { try check(!library.isConnected,"disconnect still revokes the active folder connection") }
   if fault == "directory_unavailable" {
    access.beforeValidate=nil; access.uploaded=false
    // Simulate a callback already queued before stop() removed its observer.
    // It must retain invalidation without itself starting blocked provider IO.
    providerChanged?()
    try await Task.sleep(nanoseconds:30_000_000)
    try check(library.hasBlockingError && !library.isBusy && access.metadataChecks == stoppedAt,
     "a late provider callback preserves the current failure without automatically reentering blocked work")
    library.resume()
    try await continuationIdle(library)
    let cache=try continuationCache(local)
    try check(!library.hasBlockingError && library.error != nil && library.isEnabled
      && library.uploadedFileCount == 0 && library.pendingCloudFileCount == 64
      && cache["providerChangePending"] == nil && cache["providerChangeReplayPending"] == nil,
     "the next authorized retry consumes the retained callback and cannot revive the earlier 32 positive observations")
   }
   library.suspendForBackground()
  }
 }
}
