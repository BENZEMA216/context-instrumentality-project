// D4 regressions use the real Phone scheduler and only synthetic local files.
// Provider notifications are wake signals; completion must not depend on a
// second notification, another user action, or reopening source audio.
extension Probe {
 @MainActor static func continuationIdle(_ library:ICloudDriveLibrary, timeout:TimeInterval = 120) async throws {
  let limit=ProcessInfo.processInfo.systemUptime+timeout
  var idleSince:TimeInterval?
  repeat {
   if !library.isBusy {
    if idleSince == nil { idleSince=ProcessInfo.processInfo.systemUptime }
    if ProcessInfo.processInfo.systemUptime-idleSince! > 0.08 { return }
   } else { idleSince=nil }
   guard ProcessInfo.processInfo.systemUptime < limit else {
    throw NSError(domain:"Provider continuation timeout",code:1,
      userInfo:[NSLocalizedDescriptionKey:"saved=\(library.savedAudioCount) uploaded=\(library.uploadedFileCount) pending=\(library.pendingCloudFileCount)"])
   }
   try await Task.sleep(nanoseconds:2_000_000)
  } while true
 }

 static func continuationCache(_ local:URL) throws -> [String:Any] {
  try JSONSerialization.jsonObject(with:Data(contentsOf:local.appendingPathComponent("ICloudDriveLibrary/provider-evidence.json"))) as! [String:Any]
 }

 // Set up a large *already exported* library through the real core writer.
 // Persist its validated ledger once: the regression targets confirmation
 // scheduling, not the independent per-export Phone ledger save cost.
 static func seedContinuationExports(repo:RecordingRepository,local:URL,folder:URL) throws {
  let file=local.appendingPathComponent("ICloudDriveLibrary/state.json")
  var state=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
  var ledgerObject=state["ledger"] as! [String:Any]
  let ledger=try TransportCodec.decode(ICloudDriveLibraryLedger.self,
   from:JSONSerialization.data(withJSONObject:ledgerObject))
  let writer=ICloudDriveExportWriter(root:folder,libraryID:ledger.libraryID)
  var jobs:[[String:Any]]=[], commits:[String]=[]
  for job in ledger.jobs {
   let receipt=try writer.export(job:job,audioURL:repo.audioURL(for:job.manifest))
   var item=try JSONSerialization.jsonObject(with:TransportCodec.encode(job)) as! [String:Any]
   item["exportedKeys"]=receipt.artifacts.map(\.key)
   item["exportedFiles"]=try JSONSerialization.jsonObject(with:TransportCodec.encode(receipt.localFileIdentities))
   jobs.append(item); commits.append(receipt.relativePath)
  }
  ledgerObject["jobs"]=jobs
  let exported=try TransportCodec.decode(ICloudDriveLibraryLedger.self,
   from:JSONSerialization.data(withJSONObject:ledgerObject))
  try exported.validate()
  state["ledger"]=try JSONSerialization.jsonObject(with:TransportCodec.encode(exported))
  state["committedReceiptPaths"]=commits
  try JSONSerialization.data(withJSONObject:state,options:[.sortedKeys]).write(to:file,options:.atomic)
 }

 @MainActor static func verifyAutomaticProviderContinuation(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  for count in [20,1000] {
   let (repo,texts,access,_,sources,local,folder)=try await livenessFixture(root:root,
    name:"automatic-provider-\(count)",count:count,manifest:manifest,audio:audio)
   if count == 1000 { try seedContinuationExports(repo:repo,local:local,folder:folder) }
   UIApplication.shared.applicationState = .active
   let query=ProbeMetadataQuery()
   let library=ICloudDriveLibrary(repository:repo,transcriptRepository:texts,folderAccess:access.access,
    providerMonitorFactory:{ changed in .init(changed:changed,makeQuery:{ query },startAccess:{ _ in true },stopAccess:{ _ in }) })
   try await continuationIdle(library)
   let expected=count*3+1
   try check(library.savedAudioCount == count && library.pendingCloudFileCount == expected && library.uploadedFileCount == 0,
    "\(count)-source fixture exports every synthetic artifact before its single notification")
   // This also makes an accidental discovery/export continuation fail loudly.
   for source in sources { try FileManager.default.removeItem(at:repo.audioURL(for:source)) }
   let grant=local.appendingPathComponent("ICloudDriveLibrary/state.json"), grantBytes=try Data(contentsOf:grant)
   let before=access.metadataChecks
   var roundStart=before, batches:[Int]=[], heartbeat=0, completedWithHeartbeat:[Int]=[]
   let observation=library.$isBusy.sink { busy in
    if busy {
     roundStart=access.metadataChecks
    }
    else if access.metadataChecks > roundStart {
     batches.append(access.metadataChecks-roundStart)
     completedWithHeartbeat.append(heartbeat)
     Task { @MainActor in heartbeat += 1 }
    }
   }
   access.uploaded=true
   NotificationCenter.default.post(name:.NSMetadataQueryDidUpdate,object:query)
   try await continuationIdle(library)
   observation.cancel()
   let paths=Set(access.metadataPaths.dropFirst(before)), cache=try continuationCache(local)
   try check(library.uploadedFileCount == expected && library.pendingCloudFileCount == 0
     && library.savedAudioCount == count && library.error == nil && paths.count == expected,
    "one metadata notification automatically confirms all \(expected) files without source audio or a second signal")
   try check(batches.count >= (expected+31)/32 && batches.allSatisfy { $0 > 0 && $0 <= 32 }
     && heartbeat >= batches.count
     && completedWithHeartbeat.enumerated().allSatisfy { $0.element >= $0.offset },
    "\(expected)-file continuation publishes bounded batches while the main actor keeps making progress")
   try check(cache["providerChangePending"] == nil && cache["providerChangeUncheckedPaths"] == nil
     && query.starts == 1 && query.stops == 0 && (try Data(contentsOf:grant)) == grantBytes,
    "automatic continuation drains its durable cohort without restarting the query or changing authorization")
   library.suspendForBackground()
  }
  try await verifyNotificationStormContinuation(root:root,manifest:manifest,audio:audio)
  try await verifyDiscoveryDuringProviderStorm(root:root,manifest:manifest,audio:audio)
  try await verifyBackgroundProviderContinuation(root:root,manifest:manifest,audio:audio)
  try await verifyBusyNotificationSurvivesBackground(root:root,manifest:manifest,audio:audio)
  try await verifyCancelledProviderContinuation(root:root,manifest:manifest,audio:audio)
  try await verifyProviderNewExportQuota(root:root,manifest:manifest,audio:audio)
  try await verifySlowProviderContinuation(root:root,manifest:manifest,audio:audio)
 }

 @MainActor static func verifyNotificationStormContinuation(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let (repo,texts,access,_,sources,local,_)=try await livenessFixture(root:root,
   name:"provider-notification-storm",count:60,manifest:manifest,audio:audio)
  UIApplication.shared.applicationState = .active
  let query=ProbeMetadataQuery()
  let library=ICloudDriveLibrary(repository:repo,transcriptRepository:texts,folderAccess:access.access,
   providerMonitorFactory:{ changed in .init(changed:changed,makeQuery:{ query },startAccess:{ _ in true },stopAccess:{ _ in }) })
  try await continuationIdle(library)
  for source in sources { try FileManager.default.removeItem(at:repo.audioURL(for:source)) }
  let before=access.metadataChecks, latch=ProbeMetadataLatch()
  var completedBatches=0, lastReported=before
  let events=library.$isBusy.sink { busy in
   if !busy && access.metadataChecks > lastReported {
    lastReported=access.metadataChecks
    completedBatches += 1
    if completedBatches <= 4 {
     for _ in 0..<5 { NotificationCenter.default.post(name:.NSMetadataQueryDidUpdate,object:query) }
    }
   }
  }
  access.uploaded=true; access.beforeMetadata={ latch.enterOnce() }
  NotificationCenter.default.post(name:.NSMetadataQueryDidUpdate,object:query)
  let limit=ProcessInfo.processInfo.systemUptime+5
  while !latch.hasEntered {
   guard ProcessInfo.processInfo.systemUptime < limit else { throw NSError(domain:"Storm latch timeout",code:1) }
   try await Task.sleep(nanoseconds:1_000_000)
  }
  // Many callbacks during one in-flight batch represent one dirty successor
  // generation. They must not each restart the current unchecked cohort.
  for _ in 0..<100 { NotificationCenter.default.post(name:.NSMetadataQueryDidUpdate,object:query) }
  await Task.yield()
  latch.release()
  try await continuationIdle(library)
  events.cancel()
  access.beforeMetadata=nil
  let paths=Array(access.metadataPaths.dropFirst(before))
  let unique=Set(paths), cache=try continuationCache(local)
  try check(library.uploadedFileCount == 181 && library.pendingCloudFileCount == 0 && unique.count == 181,
   "unchanged notification storms during and between batches cannot starve the 181-file tail")
  try check(paths.count <= 2*(181+6) && cache["providerChangePending"] == nil,
   "notification storm coalesces to at most one complete successor generation")
  library.suspendForBackground()
 }

 @MainActor static func verifyDiscoveryDuringProviderStorm(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let (repo,texts,access,_,sources,local,_)=try await livenessFixture(root:root,
   name:"provider-storm-discovery",count:40,manifest:manifest,audio:audio)
  UIApplication.shared.applicationState = .active
  let query=ProbeMetadataQuery()
  access.uploaded=true
  let library=ICloudDriveLibrary(repository:repo,transcriptRepository:texts,folderAccess:access.access,
   providerMonitorFactory:{ changed in .init(changed:changed,makeQuery:{ query },startAccess:{ _ in true },stopAccess:{ _ in }) })
  try await continuationIdle(library)
  try check(library.savedAudioCount == 40 && library.uploadedFileCount == 121,
   "discovery-storm fixture begins with an entirely confirmed historical cohort")
  for source in sources { try FileManager.default.removeItem(at:repo.audioURL(for:source)) }
  var stormActive=true, signals=0
  let before=access.metadataChecks
  // Every slow callback lets the MainActor deliver another signal before this
  // batch completes. A refresh-first scheduler would never consume discovery.
  access.beforeMetadata={
   Task { @MainActor in
    if stormActive {
     signals += 1
     NotificationCenter.default.post(name:.NSMetadataQueryDidUpdate,object:query)
    }
   }
   Thread.sleep(forTimeInterval:0.006)
  }
  defer { stormActive=false; access.beforeMetadata=nil; library.suspendForBackground() }
  NotificationCenter.default.post(name:.NSMetadataQueryDidUpdate,object:query)
  let limit=ProcessInfo.processInfo.systemUptime+12
  while access.metadataChecks < before+2 {
   guard ProcessInfo.processInfo.systemUptime < limit else { throw NSError(domain:"Discovery storm start timeout",code:1) }
   try await Task.sleep(nanoseconds:1_000_000)
  }
  let id=UUID(), fresh=SegmentManifest(id:id,sessionID:manifest.sessionID,sequence:1000,
   startedAt:manifest.startedAt.addingTimeInterval(1000),endedAt:manifest.endedAt.addingTimeInterval(1000),
   sampleRate:manifest.sampleRate,frameCount:manifest.frameCount,fileName:id.uuidString.lowercased()+".caf",
   byteCount:manifest.byteCount,sha256:manifest.sha256)
  _ = try repo.acceptIncomingFile(at:audio,manifest:fresh)
  let old=sources[0]
  try texts.save(SegmentTranscript(segmentID:old.id,audioSHA256:old.sha256,locale:"zh-CN",engine:"synthetic",
   createdAt:Date(timeIntervalSince1970:500),text:"持续通知期间的合成转写",spans:[]),for:old)
  library.discover(manifests:sources+[fresh],receivedIDs:Set((sources+[fresh]).map(\.id)))
  library.transcriptDidSave(for:old)
  while library.savedAudioCount != 41 || library.savedTranscriptCount != 1 {
   guard ProcessInfo.processInfo.systemUptime < limit else {
    throw NSError(domain:"Discovery starved by provider notifications",code:1,
     userInfo:[NSLocalizedDescriptionKey:"saved=\(library.savedAudioCount) text=\(library.savedTranscriptCount) signals=\(signals)"])
   }
   try await Task.sleep(nanoseconds:2_000_000)
  }
  try check(stormActive && signals >= 32 && library.error == nil,
   "new audio and an absent-source late transcript export while every metadata callback keeps notifying")
  let during=try SyncEvidenceArchive(root:local,stream:"icloud_drive").load()!
  try check(library.uploadedFileCount == 0 && during.context.counts["provider_change_replay_pending"] == 1
    && during.rows.allSatisfy { $0.artifacts.allSatisfy { $0.state != "provider_uploaded" }
      && $0.commits.allSatisfy { !$0.providerUploaded } },
   "discovery accepts the dirty successor generation before publishing and cannot revive older positives")
  stormActive=false; access.beforeMetadata=nil
  try await continuationIdle(library)
  let cache=try continuationCache(local)
  try check(library.savedAudioCount == 41 && library.savedTranscriptCount == 1
    && library.uploadedFileCount == 127 && library.pendingCloudFileCount == 0
    && cache["providerChangePending"] == nil && cache["providerChangeReplayPending"] == nil,
   "when the storm stops the scheduler confirms all new and historical files without another signal")
 }

 @MainActor static func verifyBackgroundProviderContinuation(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let (repo,texts,access,_,sources,local,_)=try await livenessFixture(root:root,
   name:"provider-background-cursor",count:40,manifest:manifest,audio:audio)
  UIApplication.shared.applicationState = .active
  let query=ProbeMetadataQuery()
  let library=ICloudDriveLibrary(repository:repo,transcriptRepository:texts,folderAccess:access.access,
   providerMonitorFactory:{ changed in .init(changed:changed,makeQuery:{ query },startAccess:{ _ in true },stopAccess:{ _ in }) })
  try await continuationIdle(library)
  for source in sources { try FileManager.default.removeItem(at:repo.audioURL(for:source)) }
  let before=access.metadataChecks, latch=ProbeMetadataLatch()
  access.uploaded=true
  access.beforeMetadata={ if access.metadataChecks-before == 7 { latch.enterOnce() } }
  NotificationCenter.default.post(name:.NSMetadataQueryDidUpdate,object:query)
  let limit=ProcessInfo.processInfo.systemUptime+5
  while !latch.hasEntered {
   guard ProcessInfo.processInfo.systemUptime < limit else { throw NSError(domain:"Background latch timeout",code:1) }
   try await Task.sleep(nanoseconds:1_000_000)
  }
  UIApplication.shared.applicationState = .background
  library.suspendForBackground()
  latch.release()
  // The old actor finishes persisting completed callbacks after cancellation.
  let persistenceLimit=ProcessInfo.processInfo.systemUptime+5
  while ((try continuationCache(local))["providerChangeUncheckedPaths"] as? [String])?.count != 114 {
   guard ProcessInfo.processInfo.systemUptime < persistenceLimit else { throw NSError(domain:"Background cursor persistence timeout",code:1) }
   try await Task.sleep(nanoseconds:2_000_000)
  }
  access.beforeMetadata=nil
  let suspended=try continuationCache(local), cursor=suspended["nextPath"] as! String
  let remaining=Set(suspended["providerChangeUncheckedPaths"] as! [String])
  let atBackground=access.metadataChecks
  NotificationCenter.default.post(name:.NSMetadataQueryDidUpdate,object:query)
  try await Task.sleep(nanoseconds:20_000_000)
  try check(remaining.count == 114 && access.metadataChecks == atBackground && !library.isBusy,
   "background cancels the eighth observation, preserves seven completions, and starts no ungranted work")
  UIApplication.shared.applicationState = .active
  let resumedAt=access.metadataChecks
  library.resume()
  try await continuationIdle(library)
  let resumed=Array(access.metadataPaths.dropFirst(resumedAt)).filter { !$0.hasSuffix("/library.json") }
  try check(resumed.first?.hasSuffix("/"+cursor) == true && library.uploadedFileCount == 121
    && library.pendingCloudFileCount == 0,
   "foreground resumption continues the interrupted durable cursor and automatically drains the tail")
  library.suspendForBackground()
 }

 @MainActor static func verifyCancelledProviderContinuation(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let (repo,texts,access,worker,sources,local,_)=try await livenessFixture(root:root,
   name:"provider-cold-cursor",count:40,manifest:manifest,audio:audio)
  _ = try await worker.perform(.sync(sources,Set(sources.map(\.id))),gate:ICloudDriveCancellation())
  for _ in 0..<8 where (try continuationCache(local))["providerChangePending"] as? Bool == true {
   _ = try await worker.perform(.continueProviderStatus,gate:ICloudDriveCancellation())
  }
  try check((try continuationCache(local))["providerChangePending"] as? Bool != true,
   "cancellation fixture finishes its initial false observation cohort")
  access.uploaded=true
  let before=access.metadataChecks, gate=ICloudDriveCancellation()
  access.beforeMetadata={ if access.metadataChecks-before == 5 { gate.cancel() } }
  do {
   _ = try await worker.perform(.refreshProviderStatus,gate:gate)
   throw NSError(domain:"Provider cancellation expected",code:1)
  } catch is CancellationError { }
  access.beforeMetadata=nil
  let cancelled=try continuationCache(local), cursor=cancelled["nextPath"] as! String
  let remaining=Set(cancelled["providerChangeUncheckedPaths"] as! [String])
  try check(remaining.count == 116,"cancelled callback remains unchecked while five completed observations survive restart")
  for source in sources { try FileManager.default.removeItem(at:repo.audioURL(for:source)) }
  let restartedAt=access.metadataChecks
  UIApplication.shared.applicationState = .active
  let library=ICloudDriveLibrary(repository:repo,transcriptRepository:texts,folderAccess:access.access,
   providerMonitorFactory:monitor)
  try await continuationIdle(library)
  let paths=Array(access.metadataPaths.dropFirst(restartedAt)).filter { !$0.hasSuffix("/library.json") }
  try check(paths.first?.hasSuffix("/"+cursor) == true && library.uploadedFileCount == 121
    && library.pendingCloudFileCount == 0 && (try continuationCache(local))["providerChangePending"] == nil,
   "a new coordinator restores the cancelled cursor and completes all 121 files without any new notification")
  library.suspendForBackground()
 }

 @MainActor static func verifyBusyNotificationSurvivesBackground(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let (repo,texts,access,_,_,local,_)=try await livenessFixture(root:root,
   name:"provider-notification-before-background",count:60,manifest:manifest,audio:audio)
  UIApplication.shared.applicationState = .active
  let query=ProbeMetadataQuery()
  let library=ICloudDriveLibrary(repository:repo,transcriptRepository:texts,folderAccess:access.access,
   providerMonitorFactory:{ changed in .init(changed:changed,makeQuery:{ query },startAccess:{ _ in true },stopAccess:{ _ in }) })
  try await continuationIdle(library)
  let before=access.metadataChecks, latch=ProbeMetadataLatch()
  access.uploaded=true
  access.beforeMetadata={ if access.metadataChecks-before == 32 { latch.enterOnce() } }
  NotificationCenter.default.post(name:.NSMetadataQueryDidUpdate,object:query)
  let limit=ProcessInfo.processInfo.systemUptime+5
  while !latch.hasEntered {
   guard ProcessInfo.processInfo.systemUptime < limit else { throw NSError(domain:"Busy notification latch timeout",code:1) }
   try await Task.sleep(nanoseconds:1_000_000)
  }
  try check(library.uploadedFileCount == 32,"busy-notification fixture publishes the first positive batch before blocking its successor")
  access.uploaded=false
  NotificationCenter.default.post(name:.NSMetadataQueryDidUpdate,object:query)
  // Let the MainActor receive the signal while the provider worker is blocked.
  try await Task.sleep(nanoseconds:2_000_000)
  UIApplication.shared.applicationState = .background
  library.suspendForBackground(); latch.release()
  access.beforeMetadata=nil
  UIApplication.shared.applicationState = .active
  library.resume()
  try await continuationIdle(library)
  let cache=try continuationCache(local)
  try check(library.uploadedFileCount == 0 && library.pendingCloudFileCount == 181
    && cache["providerChangePending"] == nil && cache["providerChangeReplayPending"] == nil,
   "a notification received while busy survives background cancellation and rechecks earlier positives without another signal")
  library.suspendForBackground()
 }

 static func verifyProviderNewExportQuota(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let (repo,_,access,worker,sources,local,_)=try await livenessFixture(root:root,
   name:"provider-fresh-quota",count:40,manifest:manifest,audio:audio)
  let ids=Set(sources.map(\.id))
  _ = try await worker.perform(.sync(sources,ids),gate:ICloudDriveCancellation())
  _ = try await worker.perform(.refreshProviderStatus,gate:ICloudDriveCancellation(takeProviderMetadataPermit:{ false }))
  var fresh:[SegmentManifest]=[]
  for sequence in 0..<6 {
   let id=UUID(uuidString:String(format:"ffffffff-0000-4000-8000-%012d",sequence))!
   let source=SegmentManifest(id:id,sessionID:manifest.sessionID,sequence:1000+sequence,
    startedAt:manifest.startedAt.addingTimeInterval(1000),endedAt:manifest.endedAt.addingTimeInterval(1000),
    sampleRate:manifest.sampleRate,frameCount:manifest.frameCount,fileName:id.uuidString.lowercased()+".caf",
    byteCount:manifest.byteCount,sha256:manifest.sha256)
   _ = try repo.acceptIncomingFile(at:audio,manifest:source); fresh.append(source)
  }
  let freshIDs=Set(fresh.map { $0.id.uuidString.lowercased() }), before=access.metadataChecks
  access.uploaded=true
  _ = try await worker.perform(.sync(sources+fresh,ids.union(fresh.map(\.id))),gate:ICloudDriveCancellation())
  let paths=Array(access.metadataPaths.dropFirst(before))
  let freshPaths=paths.filter { path in freshIDs.contains { path.contains("/"+$0+"/") } }
  let historicalPaths=paths.filter { path in !path.hasSuffix("/library.json") && !freshIDs.contains { path.contains("/"+$0+"/") } }
  try check(paths.count <= 32 && !freshPaths.isEmpty && freshPaths.count <= 8 && historicalPaths.count >= 23,
   "six newly exported sources receive a bounded priority quota while historical unchecked paths retain their quota")
  let remaining=Set((try continuationCache(local))["providerChangeUncheckedPaths"] as? [String] ?? [])
  let previouslyFresh=remaining.filter { path in freshIDs.contains { path.contains("/"+$0+"/") } }
  try check(!previouslyFresh.isEmpty,"continuous-arrival fixture retains some files from the first fresh cohort")
  var allSources=sources+fresh, checkedAfter:Set<String>=[]
  for round in 0..<8 {
   for sequence in 0..<3 {
    let id=UUID(), source=SegmentManifest(id:id,sessionID:manifest.sessionID,sequence:2000+round*3+sequence,
     startedAt:manifest.startedAt.addingTimeInterval(Double(2000+round*3+sequence)),
     endedAt:manifest.endedAt.addingTimeInterval(Double(2000+round*3+sequence)),
     sampleRate:manifest.sampleRate,frameCount:manifest.frameCount,fileName:id.uuidString.lowercased()+".caf",
     byteCount:manifest.byteCount,sha256:manifest.sha256)
    _ = try repo.acceptIncomingFile(at:audio,manifest:source); allSources.append(source)
   }
   let start=access.metadataChecks
   _ = try await worker.perform(.sync(allSources,Set(allSources.map(\.id))),gate:ICloudDriveCancellation())
   checkedAfter.formUnion(access.metadataPaths.dropFirst(start))
  }
  try check(previouslyFresh.allSatisfy { path in checkedAfter.contains { $0.hasSuffix("/"+path) } },
   "files left from an older fresh cohort join historical rotation despite new exports arriving before every batch")
 }

 @MainActor static func verifySlowProviderContinuation(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let (repo,texts,access,_,_,_,_)=try await livenessFixture(root:root,
   name:"provider-slow-marker",count:20,manifest:manifest,audio:audio)
  UIApplication.shared.applicationState = .active
  let query=ProbeMetadataQuery()
  let library=ICloudDriveLibrary(repository:repo,transcriptRepository:texts,folderAccess:access.access,
   providerMonitorFactory:{ changed in .init(changed:changed,makeQuery:{ query },startAccess:{ _ in true },stopAccess:{ _ in }) })
  try await continuationIdle(library)
  let before=access.metadataChecks
  var start=before, batches:[Int]=[]
  let observation=library.$isBusy.sink { busy in
   if busy { start=access.metadataChecks }
   else if access.metadataChecks > start { batches.append(access.metadataChecks-start) }
  }
  access.uploaded=true
  access.beforeMetadata={ if access.metadataChecks == before { Thread.sleep(forTimeInterval:1.05) } }
  NotificationCenter.default.post(name:.NSMetadataQueryDidUpdate,object:query)
  try await continuationIdle(library)
  access.beforeMetadata=nil; observation.cancel()
  let paths=Array(access.metadataPaths.dropFirst(before))
  try check(batches.first == 1 && batches.allSatisfy { $0 <= 32 }
    && paths.filter { $0.hasSuffix("/library.json") }.count == 1
    && library.uploadedFileCount == 61 && library.pendingCloudFileCount == 0,
   "a marker slower than one execution slice yields after one query and cannot starve the remaining 60 files")
  library.suspendForBackground()

  let (_,_,fairAccess,worker,sources,local,_)=try await livenessFixture(root:root,
   name:"provider-slow-priority",count:40,manifest:manifest,audio:audio)
  _ = try await worker.perform(.sync(sources,Set(sources.map(\.id))),
   gate:ICloudDriveCancellation(takeProviderMetadataPermit:{ false }))
  let markerStart=fairAccess.metadataChecks
  _ = try await worker.perform(.continueProviderStatus,
   gate:ICloudDriveCancellation(takeProviderMetadataPermit:{ fairAccess.metadataChecks == markerStart }))
  let priority=Set((try continuationCache(local))["providerPriorityPaths"] as? [String] ?? [])
  let remaining=Set((try continuationCache(local))["providerChangeUncheckedPaths"] as? [String] ?? [])
  try check(!priority.isEmpty && !remaining.subtracting(priority).isEmpty,
   "slow-slice fairness fixture contains both priority and historical paths")
  let firstStart=fairAccess.metadataChecks
  fairAccess.beforeMetadata={ Thread.sleep(forTimeInterval:1.05) }
  _ = try await worker.perform(.continueProviderStatus,gate:ICloudDriveCancellation())
  _ = try await worker.perform(.continueProviderStatus,gate:ICloudDriveCancellation())
  fairAccess.beforeMetadata=nil
  let checked=Array(fairAccess.metadataPaths.dropFirst(firstStart))
  try check(checked.count == 2
    && checked.contains { path in priority.contains { path.hasSuffix("/"+$0) } }
    && checked.contains { path in remaining.subtracting(priority).contains { path.hasSuffix("/"+$0) } },
   "consecutive one-query slices alternate priority and history so slow fresh metadata cannot starve old paths")
 }
}
