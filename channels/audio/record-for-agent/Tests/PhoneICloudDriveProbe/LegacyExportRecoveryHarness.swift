// Regression for a durable export interrupted before provider-cache cleanup.
// Only synthetic repository data and provider metadata are used.
extension Probe {
 static func verifyInterruptedLegacyExportRecovery(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  for legacyIndex in [true,false] {
   for lateText in [false,true] {
    let label="interrupted-export-\(legacyIndex ? "legacy" : "indexed")-\(lateText ? "text" : "audio")"
    let (repo,texts,access,worker,originalSources,local,folder)=try await livenessFixture(root:root,
     name:label,count:20,manifest:manifest,audio:audio)
    var sources=originalSources
    access.uploaded=true
    var initial=try await worker.perform(.sync(sources,Set(sources.map(\.id))),gate:ICloudDriveCancellation())
    while initial.needsProviderContinuation {
     initial=try await worker.perform(.continueProviderStatus,gate:ICloudDriveCancellation())
    }
    try check(initial.uploadedFileCount == 61,"\(label) begins with historical confirmation times")
    let stateFile=local.appendingPathComponent("ICloudDriveLibrary/state.json")
    let cacheFile=local.appendingPathComponent("ICloudDriveLibrary/provider-evidence.json")
    var persisted=try JSONSerialization.jsonObject(with:Data(contentsOf:stateFile)) as! [String:Any]
    var cache=try continuationCache(local)
    if legacyIndex {
     // Model a valid legacy cache. Its index and cached paths never contained
     // commit receipts; do not begin with an already-invalid migrated fixture.
     persisted.removeValue(forKey:"committedReceiptPaths")
     cache["observations"]=(cache["observations"] as! [String:Any]).filter { !$0.key.hasPrefix("commits/") }
     cache["localExportedAtMS"]=(cache["localExportedAtMS"] as! [String:Any]).filter { !$0.key.hasPrefix("commits/") }
     if (cache["nextPath"] as? String)?.hasPrefix("commits/") == true { cache.removeValue(forKey:"nextPath") }
    }
    cache["repairNextID"]=sources.last!.id.uuidString
    cache["preferRepairNext"]=true
    try JSONSerialization.data(withJSONObject:persisted,options:[.sortedKeys]).write(to:stateFile,options:.atomic)
    try JSONSerialization.data(withJSONObject:cache,options:[.sortedKeys]).write(to:cacheFile,options:.atomic)
    let exporting=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
    let loaded=try await exporting.perform(.load,gate:ICloudDriveCancellation())
    try check(loaded.diagnosticObservation.cacheResetReason != .invalid,
     "\(label) legacy fixture loads without resetting valid history")
    _ = try await exporting.perform(.refreshProviderStatus,gate:ICloudDriveCancellation())
    let before=try continuationCache(local)
    let beforeUnchecked=Set(before["providerChangeUncheckedPaths"] as! [String])
    let beforeObservations=before["observations"] as! [String:[String:Any]]
    try check(!beforeUnchecked.isEmpty && before["nextPath"] as? String != nil,
     "\(label) has an in-flight cohort and a durable cursor before new export")
    // Metadata continuation cannot depend on reopening the old audio sources.
    for source in sources { try FileManager.default.removeItem(at:repo.audioURL(for:source)) }
    if lateText {
     let source=sources[0]
     try texts.save(SegmentTranscript(segmentID:source.id,audioSHA256:source.sha256,locale:"zh-CN",engine:"synthetic",
      createdAt:Date(timeIntervalSince1970:800),text:"中断恢复合成转写",spans:[]),for:source)
    } else {
     let id=UUID(), fresh=SegmentManifest(id:id,sessionID:manifest.sessionID,sequence:1000,
      startedAt:manifest.startedAt.addingTimeInterval(1000),endedAt:manifest.endedAt.addingTimeInterval(1000),
      sampleRate:manifest.sampleRate,frameCount:manifest.frameCount,fileName:id.uuidString.lowercased()+".caf",
      byteCount:manifest.byteCount,sha256:manifest.sha256)
     _ = try repo.acceptIncomingFile(at:audio,manifest:fresh)
     sources.append(fresh)
    }
    let checks=access.metadataChecks, gate=ICloudDriveCancellation()
    do {
     _ = try await exporting.perform(.sync(sources,Set(sources.map(\.id))),gate:gate,phase:{ phase in
      // This real phase callback follows noteLocalExport's durable cache save
      // and precedes refreshCloudStatus's filtering. No timing race is needed.
      if case .checkingCloud = phase { gate.cancel() }
     })
     throw NSError(domain:"Interrupted export failed to cancel",code:1)
    } catch is CancellationError {}
    let interruptedState=try JSONSerialization.jsonObject(with:Data(contentsOf:stateFile)) as! [String:Any]
    let ledger=try TransportCodec.decode(ICloudDriveLibraryLedger.self,
     from:JSONSerialization.data(withJSONObject:interruptedState["ledger"]!))
    let indexedCommits=Set(interruptedState["committedReceiptPaths"] as? [String] ?? [])
    var expected=indexedCommits
    for job in ledger.jobs {
     expected.formUnion(job.artifacts.filter { job.exportedKeys.contains($0.key) }.map(\.relativePath))
    }
    expected.insert("library.json")
    let interrupted=try continuationCache(local), interruptedBytes=try Data(contentsOf:cacheFile)
    let unchecked=Set(interrupted["providerChangeUncheckedPaths"] as! [String])
    let priority=Set(interrupted["providerPriorityPaths"] as? [String] ?? [])
    let times=interrupted["localExportedAtMS"] as! [String:Any]
    try check(ledger.exportedAudioCount == (lateText ? 20 : 21)
      && ledger.exportedTranscriptCount == (lateText ? 1 : 0) && access.metadataChecks == checks,
     "\(label) interruption occurs after durable export and before metadata cleanup")
    try check(Set(times.keys).isSubset(of:expected) && unchecked.isSubset(of:expected) && priority.isSubset(of:expected),
     "\(label) every persisted export time and scheduled path belongs to the durable ledger")
    try check((interruptedState["committedReceiptPaths"] == nil) == legacyIndex
      && (legacyIndex ? !times.keys.contains { $0.hasPrefix("commits/") }
       : indexedCommits.isSubset(of:Set(times.keys)) && priority.contains { $0.hasPrefix("commits/") }),
     "\(label) preserves unknown legacy index while still prioritizing indexed new commits")
    try check(beforeUnchecked.isSubset(of:unchecked) && interrupted["nextPath"] as? String == before["nextPath"] as? String
      && interrupted["repairNextID"] as? String == before["repairNextID"] as? String
      && (interrupted["observations"] as! NSDictionary) == (beforeObservations as NSDictionary),
     "\(label) export interruption retains old cohort, cursor, repair rotation and timed observations")
    let cold=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
    var restored=try await cold.perform(.load,gate:ICloudDriveCancellation())
    try check(restored.enabled && restored.scope == .existingAndFuture && restored.needsProviderContinuation
      && restored.diagnosticObservation.cacheResetReason == loaded.diagnosticObservation.cacheResetReason
      && restored.diagnosticObservation.firstProviderConfirmationAt == loaded.diagnosticObservation.firstProviderConfirmationAt
      && access.metadataChecks == checks && (try Data(contentsOf:cacheFile)) == interruptedBytes,
     "\(label) cold launch restores exact recovery state without cache reset or provider queries")
    var batches=0
    while restored.needsProviderContinuation {
     let start=access.metadataChecks
     restored=try await cold.perform(.continueProviderStatus,gate:ICloudDriveCancellation())
     batches += 1
     try check(access.metadataChecks-start <= 32 && batches < 10,
      "\(label) resumed continuation remains bounded and terminates")
    }
    let libraryPrefix=folder.appendingPathComponent("RecordForAgent-"+ledger.libraryID.uuidString.lowercased()).path+"/"
    let paths=Set(access.metadataPaths.dropFirst(checks).map { String($0.dropFirst(libraryPrefix.count)) })
    try check(restored.uploadedFileCount == expected.count && restored.pendingCloudFileCount == (legacyIndex ? 1 : 0)
      && paths == unchecked && restored.diagnosticObservation.counts.cacheResetCount == loaded.diagnosticObservation.counts.cacheResetCount,
     "\(label) resumes only the retained tail, while unknown commits never become fully confirmed")
    try check(access.starts == access.stops,"\(label) balances scope access across cancellation and cold recovery")
   }
  }
 }
}
