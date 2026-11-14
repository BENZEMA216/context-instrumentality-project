private final class ProbeAccess: @unchecked Sendable {
 var identity = String(repeating: "a", count:64)
 var persistentIdentity: String?
 var beforePersistentIdentity: (() -> Void)?
 var stale = false
 var starts = 0
 var stops = 0
 var uploaded = false
 var typedStatus: ICloudDriveProviderObservationStatus?
 var pendingMetadata = false
 var metadataChecks = 0
 var identityChecks = 0
 var beforeMetadata: (() -> Void)?
 var duringMetadata: ((URL) -> Void)?
 var metadataPaths: [String] = []
 var beforeValidate: (() throws -> Void)?
 var access: ICloudDriveFolderAccess {
  ICloudDriveFolderAccess(bookmark: { Data($0.path.utf8) },
    resolve: { [self] in (URL(fileURLWithPath:String(decoding:$0,as:UTF8.self)), stale) },
    start: { [self] _ in starts += 1; return true }, stop: { [self] _ in stops += 1 },
    validate: { [self] _ in try beforeValidate?() }, identity: { [self] _ in identityChecks += 1; return identity },
    uploaded: { [self] in metadataResult($0) == .uploaded }, observation: { [self] in metadataResult($0) },
    persistentIdentity: { [self] _ in beforePersistentIdentity?(); return persistentIdentity })
 }
 private func metadataResult(_ url: URL) -> ICloudDriveProviderObservationStatus {
  beforeMetadata?()
  duringMetadata?(url)
  metadataChecks += 1
  metadataPaths.append(url.path)
  if let typedStatus { return typedStatus }
  return uploaded && !(pendingMetadata && (url.lastPathComponent == "library.json" || url.path.contains("/commits/")))
   ? .uploaded : .notUploaded
 }
}
private final class ProbeMetadataLatch: @unchecked Sendable {
 private let lock = NSLock()
 private let releaseSignal = DispatchSemaphore(value:0)
 private var entered = false
 var hasEntered:Bool { lock.lock(); defer { lock.unlock() }; return entered }
 func enterOnce() {
  lock.lock()
  guard !entered else { lock.unlock(); return }
  entered = true
  lock.unlock()
  _ = releaseSignal.wait(timeout:.now()+5)
 }
 func release() { releaseSignal.signal() }
}
@main private struct Probe {
 static var assertions = 0
 static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
  assertions += 1
  if try !condition() { throw NSError(domain:"Probe",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
 }
 static func main() async throws {
  let fm = FileManager.default
  let root = fm.temporaryDirectory.appendingPathComponent("icloud-phone-probe-"+UUID().uuidString)
  try fm.createDirectory(at:root,withIntermediateDirectories:true)
  defer { try? fm.removeItem(at:root) }
  let local = root.appendingPathComponent("local"), folder = root.appendingPathComponent("synthetic-cloud")
  try fm.createDirectory(at:folder,withIntermediateDirectories:true)
  let repository = try RecordingRepository(root:local)
  let transcriptRepository = try TranscriptRepository(root:local)
  let id=UUID(), bytes=Data("synthetic-local-audio-only".utf8), audio=root.appendingPathComponent("source")
  try bytes.write(to:audio)
  let manifest=SegmentManifest(id:id,sessionID:UUID(),sequence:0,startedAt:Date(timeIntervalSince1970:100),
    endedAt:Date(timeIntervalSince1970:160),sampleRate:16000,frameCount:960000,
    fileName:id.uuidString.lowercased()+".caf",byteCount:Int64(bytes.count),sha256:ICloudDriveLibraryLedger.digest(bytes))
  if ProcessInfo.processInfo.environment["RFA_ICLOUD_FOREGROUND_SLICES_ONLY"] == "1" {
   try await verifyForegroundSyncSlices(root:root,manifest:manifest,audio:audio)
   print("PASS foreground sync slices production scheduler synthetic assertions=\(assertions), realCloudAccess=false, privateAudioAccess=false")
   return
  }
  if ProcessInfo.processInfo.environment["RFA_ICLOUD_LEGACY_EXPORT_ONLY"] == "1" {
   try await verifyInterruptedLegacyExportRecovery(root:root,manifest:manifest,audio:audio)
   print("PASS interrupted legacy export recovery production worker synthetic assertions=\(assertions), realCloudAccess=false, privateAudioAccess=false")
   return
  }
  if ProcessInfo.processInfo.environment["RFA_ICLOUD_SOURCE_ISOLATION_ONLY"] == "1" {
   try await verifySourceIsolationProviderContinuation(root:root,manifest:manifest,audio:audio)
   print("PASS source isolation provider continuation production scheduler synthetic assertions=\(assertions), realCloudAccess=false, privateAudioAccess=false")
   return
  }
  if ProcessInfo.processInfo.environment["RFA_ICLOUD_CONTINUATION_ONLY"] == "1" {
   try await verifyAutomaticProviderContinuation(root:root,manifest:manifest,audio:audio)
   print("PASS provider continuation production scheduler synthetic assertions=\(assertions), realCloudAccess=false, privateAudioAccess=false")
   return
  }
  if ProcessInfo.processInfo.environment["RFA_ICLOUD_TYPED_ONLY"] == "1" {
   try await verifyTypedProviderObservations(root:root,manifest:manifest,audio:audio)
   print("PASS typed provider observations production worker synthetic assertions=\(assertions), realCloudAccess=false, privateAudioAccess=false")
   return
  }
  if ProcessInfo.processInfo.environment["RFA_ICLOUD_RECOVERY_ONLY"] == "1" {
   try await verifyDirectoryRecovery(root:root,manifest:manifest,audio:audio)
   print("PASS directory recovery production worker synthetic assertions=\(assertions), realCloudAccess=false, privateAudioAccess=false")
   return
  }
  _ = try repository.acceptIncomingFile(at:audio,manifest:manifest)
  let fake=ProbeAccess(), gate=ICloudDriveCancellation()
  let worker=ICloudDriveLibraryWorker(repository:repository,transcriptRepository:transcriptRepository,folderAccess:fake.access)
  _ = try await worker.perform(.load,gate:gate)
  var state = try await worker.perform(.connect(folder),gate:gate)
  try check(state.connected && !state.enabled && state.scope == nil,"connect must not authorize")
  try check(try fm.contentsOfDirectory(atPath:folder.path).isEmpty,"connect must not write provider folder")
  state = try await worker.perform(.authorize(.existingAndFuture,[manifest],[id]),gate:gate)
  try check(state.enabled && state.authorizedCount == 1,"explicit authorization")
  try check(try fm.contentsOfDirectory(atPath:folder.path).isEmpty,"authorize stores local scope before export")
  state = try await worker.perform(.sync([manifest],[id]),gate:gate)
  try check(state.savedAudioCount == 1 && state.pendingCloudFileCount == 4 && state.uploadedFileCount == 0,"local export is not cloud uploaded (saved=\(state.savedAudioCount), pending=\(state.pendingCloudFileCount), error=\(state.error ?? "none"))")
  let libraries=try fm.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil)
  try check(libraries.count == 1,"one library marker")
  let parked=local.appendingPathComponent("parked-source")
  try fm.moveItem(at:repository.audioURL(for:manifest),to:parked)
  state = try await worker.perform(.sync([manifest],[id]),gate:gate)
  try check(state.savedAudioCount == 1 && state.error == nil,"repeat resume must not reopen unchanged source audio")
  // Later text can be committed without reopening the unchanged exported CAF.
  let text=SegmentTranscript(segmentID:id,audioSHA256:manifest.sha256,locale:"zh-CN",engine:"synthetic",
    createdAt:Date(timeIntervalSince1970:200),text:"合成转写",spans:[.init(start:0,end:1,text:"合成转写")])
  try transcriptRepository.save(text,for:manifest)
  state = try await worker.perform(.sync([manifest],[id]),gate:gate)
  try check(state.savedTranscriptCount == 1 && state.pendingCloudFileCount == 7,"late transcript reuses exported audio with source absent")
  fake.uploaded = true
  state = try await worker.perform(.sync([manifest],[id]),gate:gate)
  try check(state.uploadedFileCount == 7 && state.pendingCloudFileCount == 0,"uploaded count requires explicit provider evidence")
  fake.pendingMetadata = true
  state = try await worker.perform(.sync([manifest],[id]),gate:gate)
  try check(state.uploadedFileCount == 4 && state.pendingCloudFileCount == 3,"marker and every commit remain pending until provider confirms them")
  fake.pendingMetadata = false
  state = try await worker.perform(.disconnect,gate:gate)
  try check(!state.connected && !state.enabled && state.scope == .existingAndFuture,"disconnect preserves grant and stops writes")
  state = try await worker.perform(.sync([manifest],[id]),gate:gate)
  try check(state.savedAudioCount == 1 && !state.enabled,"disconnected sync is inert")
  fake.identity=String(repeating:"b",count:64)
  let originalGrantBytes=try Data(contentsOf:local.appendingPathComponent("ICloudDriveLibrary/state.json"))
  state = try await worker.perform(.connect(folder),gate:gate)
  try check(state.recoveryConfirmationRequired && !state.enabled,"changed identity with an exact marker remains an unconfirmed paused candidate")
  try check(try Data(contentsOf:local.appendingPathComponent("ICloudDriveLibrary/state.json")) == originalGrantBytes,
   "an initial directory reselection never adopts a changed identity")
  _ = try await worker.perform(.cancelDirectoryRecovery,gate:gate)
  fake.identity=String(repeating:"a",count:64)
  _ = try await worker.perform(.connect(folder),gate:gate)
  state = try await worker.perform(.setEnabled(true),gate:gate)
  try check(state.enabled && state.savedAudioCount == 1,"same folder reconnect preserves receipts")
  fake.stale = true
  state = try await worker.perform(.sync([manifest],[id]),gate:gate)
  try check(!state.enabled && state.error?.contains("过期") == true,"stale bookmark pauses without export")
  fake.stale = false
  _ = try await worker.perform(.setEnabled(true),gate:gate)
  // A stop intent survives even if the export actor/main ledger never receives
  // its pause command, as when a provider blocks and the app goes away.
  worker.stopImmediately(disconnecting:false)
  try await waitForStop(local:local,disconnected:false)
  let cold=ICloudDriveLibraryWorker(repository:repository,transcriptRepository:transcriptRepository,folderAccess:fake.access)
  let coldState = try await cold.perform(.load,gate:gate)
  try check(!coldState.enabled && coldState.connected,"independent pause fence survives cold launch")
  _ = try await worker.perform(.setEnabled(true),gate:gate)
  let cancellation=ICloudDriveCancellation(); cancellation.cancel()
  do { _ = try await worker.perform(.sync([manifest],[id]),gate:cancellation); throw NSError(domain:"Probe",code:3) }
  catch is CancellationError { try check(true,"cancel before processing") }
  try fm.removeItem(at:libraries[0].appendingPathComponent("library.json"))
  let beforeMissingMarker=try Data(contentsOf:local.appendingPathComponent("ICloudDriveLibrary/state.json"))
  state = try await worker.perform(.sync([manifest],[id]),gate:gate)
  try check(state.enabled && state.error != nil,"temporarily missing committed marker remains unresolved without silently disabling its original grant")
  try check(try Data(contentsOf:local.appendingPathComponent("ICloudDriveLibrary/state.json")) == beforeMissingMarker,
   "a temporarily missing marker preserves the original durable grant for the next real retry")
  try check(state.uploadedFileCount == 0,"failed metadata check withdraws old uploaded count")
  try check(!fm.fileExists(atPath:libraries[0].appendingPathComponent("library.json").path),"missing marker not recreated")
  try check(fake.starts == fake.stops,"security scopes balanced through success and failure")
  // Authorization cancelled before the first provider write can be resumed only
  // in the same original directory; no marker is guessed or adopted.
  let secondLocal=root.appendingPathComponent("local2"), secondFolder=root.appendingPathComponent("synthetic-cloud2")
  try fm.createDirectory(at:secondFolder,withIntermediateDirectories:true)
  let repo2=try RecordingRepository(root:secondLocal), texts2=try TranscriptRepository(root:secondLocal)
  _ = try repo2.acceptIncomingFile(at:audio,manifest:manifest)
  let fake2=ProbeAccess(), worker2=ICloudDriveLibraryWorker(repository:repo2,transcriptRepository:texts2,folderAccess:fake2.access)
  _ = try await worker2.perform(.connect(secondFolder),gate:gate)
  _ = try await worker2.perform(.authorize(.existingAndFuture,[manifest],[id]),gate:gate)
  _ = try await worker2.perform(.disconnect,gate:gate)
  _ = try await worker2.perform(.connect(secondFolder),gate:gate)
  _ = try await worker2.perform(.setEnabled(true),gate:gate)
  state=try await worker2.perform(.sync([manifest],[id]),gate:gate)
  try check(state.savedAudioCount == 1,"same identity recovers no-marker initial grant")
  worker2.stopImmediately(disconnecting:true)
  try await waitForStop(local:secondLocal,disconnected:true)
  let coldDisconnected=ICloudDriveLibraryWorker(repository:repo2,transcriptRepository:texts2,folderAccess:fake2.access)
  let disconnectedState=try await coldDisconnected.perform(.load,gate:gate)
  try check(!disconnectedState.connected && !disconnectedState.enabled,"independent disconnect fence survives cold launch")
  for object:Any in [Data([1,2,3]),"provider-id",NSNumber(value:123)] {
   try check(try ICloudDriveDirectoryIdentity.digest(object).count == 64,"strict resource identity digest")
  }
  do { _ = try ICloudDriveDirectoryIdentity.digest(["arbitrary":"description"]); throw NSError(domain:"Probe",code:4) }
  catch is ICloudDriveLibraryFailure { try check(true,"unsupported resource identity rejected") }
  try check(try ICloudDriveDirectoryIdentity.digest("123") != ICloudDriveDirectoryIdentity.digest(NSNumber(value:123)),"typed identity avoids string-number collision")
  // Production .system rejects a plain local folder instead of guessing from its path.
  do { try ICloudDriveFolderAccess.system.validate(root); throw NSError(domain:"Probe",code:5) }
  catch is ICloudDriveLibraryFailure { try check(true,"non-ubiquitous local folder rejected") }
  try await verifyForegroundSyncSlices(root:root,manifest:manifest,audio:audio)
  try await verifyMainLifecycle(root:root,manifest:manifest,audio:audio)
  try await verifyBackgroundExport(root:root,manifest:manifest,audio:audio)
  try await verifyCancelledLoadRecovery(root:root)
  try verifyConcurrentFence(root:root)
  try await verifyUnknownLegacyReceiptIndex(root:root,manifest:manifest,audio:audio)
  try await verifyInterruptedLegacyExportRecovery(root:root,manifest:manifest,audio:audio)
  try await verifySourceIsolationProviderContinuation(root:root,manifest:manifest,audio:audio)
  try await verifyDiscoveryCoalescing(root:root,manifest:manifest,audio:audio)
  try await verifyIncrementalCloudEvidence(root:root,manifest:manifest,audio:audio)
  try await verifyProviderLivenessAndCacheRetention(root:root,manifest:manifest,audio:audio)
  try await verifyAutomaticProviderContinuation(root:root,manifest:manifest,audio:audio)
  try await verifyTypedProviderObservations(root:root,manifest:manifest,audio:audio)
  try await verifyPausedReadOnlyProviderInspection(root:root,manifest:manifest,audio:audio)
  try await verifyDirectoryRecovery(root:root,manifest:manifest,audio:audio)
  print("PASS phone offline synthetic assertions=\(assertions), realCloudAccess=false, privateAudioAccess=false")
 }
 @MainActor static func verifyMainLifecycle(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let local=root.appendingPathComponent("main-local"), folder=root.appendingPathComponent("main-cloud")
  try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
  let repo=try RecordingRepository(root:local), texts=try TranscriptRepository(root:local)
  _ = try repo.acceptIncomingFile(at:audio,manifest:manifest)
  let access=ProbeAccess()
  let library=ICloudDriveLibrary(repository:repo,transcriptRepository:texts,folderAccess:access.access,providerMonitorFactory: Probe.monitor)
  try await settle(library)
  library.connect(to:folder)
  try await settle(library)
  try check(library.isConnected && !library.isEnabled,"main connect remains disabled")
  library.authorize(scope:.existingAndFuture,knownManifests:[manifest],receivedIDs:[manifest.id])
  try await settle(library)
  try check(library.savedAudioCount == 1,"main explicit authorize schedules foreground export")
  library.pause()
  library.suspendForBackground()
  try await settle(library)
  try check(!library.isEnabled && library.error == nil,"pause survives immediate background")
  let cold=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
  let state=try await cold.perform(.load,gate:ICloudDriveCancellation())
  try check(!state.enabled && state.connected,"main pause persisted before reporting completion")
  library.resume()
  try await settle(library)
  try check(!library.isEnabled,"foreground resume does not undo explicit pause")
  library.setEnabled(true)
  try await settle(library)
  try check(library.isEnabled,"explicit enable resumes same grant")
  library.disconnect()
  library.suspendForBackground()
  try await settle(library)
  let disconnected=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:access.access)
  let final=try await disconnected.perform(.load,gate:ICloudDriveCancellation())
  try check(!library.isConnected && !final.connected && !final.enabled,"disconnect persists despite immediate background")
  try check(access.starts == access.stops,"main lifecycle scopes balanced")
 }
 @MainActor static func verifyPausedReadOnlyProviderInspection(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  UIApplication.shared.applicationState = .active
  let fm=FileManager.default, local=root.appendingPathComponent("readonly-local"), folder=root.appendingPathComponent("readonly-cloud")
  try fm.createDirectory(at:folder,withIntermediateDirectories:true)
  let repo=try RecordingRepository(root:local), texts=try TranscriptRepository(root:local), fake=ProbeAccess()
  _ = try repo.acceptIncomingFile(at:audio,manifest:manifest)
  let library=ICloudDriveLibrary(repository:repo,transcriptRepository:texts,folderAccess:fake.access,providerMonitorFactory:Probe.monitor)
  try await settle(library)
  library.connect(to:folder); try await settle(library)
  library.authorize(scope:.existingAndFuture,knownManifests:[manifest],receivedIDs:[manifest.id]); try await settle(library)
  library.pause(); try await settle(library)
  let stateURL=local.appendingPathComponent("ICloudDriveLibrary/state.json"), fenceURL=local.appendingPathComponent("ICloudDriveLibrary/stop-intent.json")
  let beforeState=try Data(contentsOf:stateURL), beforeFence=try Data(contentsOf:fenceURL)
  let libraries=try fm.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil)
  let exported=libraries[0].appendingPathComponent("audio/"+manifest.id.uuidString.lowercased()+"/"+manifest.sha256+".caf")
  // No source bytes are available to export, and the old destination is missing.
  // A read-only provider check must still complete, leaving that gap pending.
  try fm.removeItem(at:repo.audioURL(for:manifest))
  try check(fm.fileExists(atPath:exported.path),"read-only fixture starts with the actual exported audio artifact")
  try fm.removeItem(at:exported)
  let additionalID=UUID()
  let additional=SegmentManifest(id:additionalID,sessionID:manifest.sessionID,sequence:manifest.sequence+1,
   startedAt:manifest.endedAt,endedAt:manifest.endedAt.addingTimeInterval(60),sampleRate:manifest.sampleRate,
   frameCount:manifest.frameCount,fileName:additionalID.uuidString.lowercased()+".caf",byteCount:manifest.byteCount,sha256:manifest.sha256)
  library.discover(manifests:[manifest,additional],receivedIDs:[manifest.id,additional.id])
  fake.uploaded=true
  let beforeChecks=fake.metadataChecks
  library.checkCloudStatusReadOnly(); try await settle(library)
  try check(library.error == nil && !library.isEnabled && library.activity.contains("只读检查完成"),"paused explicit inspection succeeds without enabling saving")
  try check(fake.metadataChecks > beforeChecks && fake.metadataChecks-beforeChecks <= 32,"paused inspection uses a bounded provider metadata opportunity")
  try check(library.authorizedCount == 1 && library.savedAudioCount == 1,"inspection cannot discover queued new sources or export audio")
  try check(try Data(contentsOf:stateURL) == beforeState && Data(contentsOf:fenceURL) == beforeFence,"read-only success preserves exact durable grant and pause bytes")
  try check(!fm.fileExists(atPath:repo.audioURL(for:manifest).path) && !fm.fileExists(atPath:exported.path),"inspection never recreates missing source or exported audio")
  let checksAfter=fake.metadataChecks
  await Task.yield()
  try check(!library.isBusy && fake.metadataChecks == checksAfter,"inspection completion does not schedule queued synchronization")
  fake.stale=true
  library.checkCloudStatusReadOnly(); try await settle(library)
  try check(library.error != nil && !library.isEnabled,"failed paused inspection reports the access error without enabling saving")
  try check(try Data(contentsOf:stateURL) == beforeState && Data(contentsOf:fenceURL) == beforeFence,"read-only failure preserves exact durable grant and pause bytes")
  fake.stale=false
  let worker=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:fake.access)
  _ = try await worker.perform(.setEnabled(true),gate:ICloudDriveCancellation())
  let enabledBytes=try Data(contentsOf:stateURL), enabledFence=try Data(contentsOf:fenceURL)
  fake.stale=true
  let failed=try await worker.perform(.inspectProviderStatus,gate:ICloudDriveCancellation())
  try check(failed.enabled && failed.error != nil,"read-only failure does not silently pause an enabled grant")
  try check(try Data(contentsOf:stateURL) == enabledBytes && Data(contentsOf:fenceURL) == enabledFence,"enabled inspection failure cannot rewrite grant or stop intent")
  try check(fake.starts == fake.stops,"explicit provider inspection balances security scopes on success and failure")
  let (largeRepo,_,largeAccess,largeWorker,sources,largeLocal,_)=try await livenessFixture(root:root,name:"readonly-rotation",count:20,manifest:manifest,audio:audio)
  let ids=Set(sources.map(\.id))
  _ = try await largeWorker.perform(.sync(sources,ids),gate:ICloudDriveCancellation())
  _ = try await largeWorker.perform(.setEnabled(false),gate:ICloudDriveCancellation())
  for source in sources { try fm.removeItem(at:largeRepo.audioURL(for:source)) }
  largeAccess.uploaded=true
  let largeState=try Data(contentsOf:largeLocal.appendingPathComponent("ICloudDriveLibrary/state.json"))
  let firstStart=largeAccess.metadataPaths.count
  let first=try await largeWorker.perform(.inspectProviderStatus,gate:ICloudDriveCancellation())
  let firstPaths=Set(largeAccess.metadataPaths.dropFirst(firstStart))
  let nextStart=largeAccess.metadataPaths.count
  let second=try await largeWorker.perform(.inspectProviderStatus,gate:ICloudDriveCancellation())
  let nextPaths=Set(largeAccess.metadataPaths.dropFirst(nextStart))
  try check(firstPaths.count == 32 && nextPaths.count == 32 && firstPaths != nextPaths,"paused explicit checks continue a fair bounded metadata cursor")
  try check(second.uploadedFileCount > first.uploadedFileCount && !second.enabled,"paused checks retain prior historical metadata observations without enabling saving")
  try check(try Data(contentsOf:largeLocal.appendingPathComponent("ICloudDriveLibrary/state.json")) == largeState,"repeated paused inspection never rewrites the original grant")
 }
 @MainActor static func verifyDiscoveryCoalescing(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let local=root.appendingPathComponent("coalesced-local"), folder=root.appendingPathComponent("coalesced-cloud")
  try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
  let repo=try RecordingRepository(root:local), texts=try TranscriptRepository(root:local), fake=ProbeAccess()
  _ = try repo.acceptIncomingFile(at:audio,manifest:manifest)
  let library=ICloudDriveLibrary(repository:repo,transcriptRepository:texts,folderAccess:fake.access,providerMonitorFactory: Probe.monitor)
  try await settle(library)
  library.connect(to:folder); try await settle(library)
  library.authorize(scope:.existingAndFuture,knownManifests:[manifest],receivedIDs:[manifest.id])
  try await settle(library)
  try check(library.savedAudioCount == 1 && fake.metadataChecks == 4,"first explicit authorization runs one cloud scan")
  let initial=fake.metadataChecks
  for _ in 0..<20 { library.discover(manifests:[manifest],receivedIDs:[manifest.id]) }
  try check(!library.isBusy && fake.metadataChecks == initial,"identical snapshots do not enqueue another sync")
  // Multiple foreground/manual opportunities arriving while a scan is busy
  // are the same opportunity, not a request for another whole scan.
  for _ in 0..<10 { library.resume() }
  try await settle(library)
  try check(fake.metadataChecks == initial+4,"busy resume opportunities coalesce into one scan")
  let secondID=UUID()
  let second=SegmentManifest(id:secondID,sessionID:manifest.sessionID,sequence:manifest.sequence+1,
    startedAt:manifest.endedAt,endedAt:manifest.endedAt.addingTimeInterval(60),sampleRate:manifest.sampleRate,
    frameCount:manifest.frameCount,fileName:secondID.uuidString.lowercased()+".caf",byteCount:manifest.byteCount,sha256:manifest.sha256)
  _ = try repo.acceptIncomingFile(at:audio,manifest:second)
  let latch=ProbeMetadataLatch(), before=fake.metadataChecks
  fake.beforeMetadata={ latch.enterOnce() }
  library.resume()
  let limit=ProcessInfo.processInfo.systemUptime+5
  while !latch.hasEntered {
   guard ProcessInfo.processInfo.systemUptime < limit else { throw NSError(domain:"metadata latch timeout",code:1) }
   try await Task.sleep(nanoseconds:1_000_000)
  }
  defer { latch.release() }
  // The provider is paused here, so these updates definitely arrive during an
  // in-flight scan. A changed snapshot is retained exactly once, not discarded.
  for _ in 0..<20 { library.discover(manifests:[second,manifest],receivedIDs:[manifest.id,second.id]) }
  library.discover(manifests:[manifest,second],receivedIDs:[manifest.id,second.id])
  library.resume()
  for _ in 0..<10 where !library.busyMessage.contains("上传状态") { await Task.yield() }
  try check(library.isBusy && library.busyMessage.contains("上传状态"),"cloud metadata work is labelled as checking rather than saving")
  latch.release()
  try await settle(library)
  fake.beforeMetadata=nil
  try check(library.savedAudioCount == 2 && fake.metadataChecks == before+4+4,"changed busy snapshot produces one follow-up for the new source and marker")
  let after=fake.metadataChecks
  library.discover(manifests:[second,manifest],receivedIDs:[second.id,manifest.id])
  library.discover(manifests:[manifest,second],receivedIDs:[manifest.id,second.id])
  try check(!library.isBusy && fake.metadataChecks == after,"manifest order and Set order do not manufacture changes")
  library.suspendForBackground(); library.resume(); library.resume()
  try await settle(library)
  try check(fake.metadataChecks == after+7,"foreground reload validates target then performs only one metadata scan")
  let text=SegmentTranscript(segmentID:manifest.id,audioSHA256:manifest.sha256,locale:"zh-CN",engine:"synthetic",
    createdAt:Date(timeIntervalSince1970:400),text:"增量文字",spans:[.init(start:0,end:1,text:"增量文字")])
  let textLatch=ProbeMetadataLatch(), beforeText=fake.metadataChecks
  fake.beforeMetadata={ textLatch.enterOnce() }
  library.resume()
  let textLimit=ProcessInfo.processInfo.systemUptime+5
  while !textLatch.hasEntered {
   guard ProcessInfo.processInfo.systemUptime < textLimit else { throw NSError(domain:"text metadata latch timeout",code:1) }
   try await Task.sleep(nanoseconds:1_000_000)
  }
  defer { textLatch.release() }
  try texts.save(text,for:manifest)
  library.transcriptDidSave(for:manifest)
  library.resume()
  textLatch.release()
  try await settle(library)
  fake.beforeMetadata=nil
  try check(library.savedTranscriptCount == 1 && fake.metadataChecks == beforeText+7+6,"busy transcript update checks its affected source and marker once without rescanning unrelated sources")
  let thirdID=UUID()
  let third=SegmentManifest(id:thirdID,sessionID:manifest.sessionID,sequence:manifest.sequence+2,
    startedAt:second.endedAt,endedAt:second.endedAt.addingTimeInterval(60),sampleRate:manifest.sampleRate,
    frameCount:manifest.frameCount,fileName:thirdID.uuidString.lowercased()+".caf",byteCount:manifest.byteCount,sha256:manifest.sha256)
  _ = try repo.acceptIncomingFile(at:audio,manifest:third)
  library.discover(manifests:[manifest,second,third],receivedIDs:[manifest.id,second.id])
  try await settle(library)
  try check(library.savedAudioCount == 2,"manifest without supplied receive proof is not exported")
  library.discover(manifests:[third,second,manifest],receivedIDs:[manifest.id,second.id,third.id])
  try await settle(library)
  try check(library.savedAudioCount == 3,"receive-ID-only change still admits the newly received source")
  try check(library.scope == .existingAndFuture && fake.starts == fake.stops,"deduplication preserves grant and balanced access")
 }
 static func waitForStop(local:URL,disconnected:Bool) async throws {
  // Simulate a subsequent process only after the independent tiny local write
  // has landed; arbitrary immediate process termination is not a durability claim.
  let path=local.appendingPathComponent("ICloudDriveLibrary/stop-intent.json")
  let limit=ProcessInfo.processInfo.systemUptime+2
  while true {
   if let bytes=try? Data(contentsOf:path),
      let object=(try? JSONSerialization.jsonObject(with:bytes)) as? [String:Any],
      object["stopped"] as? Bool == true, object["disconnected"] as? Bool == disconnected { return }
   guard ProcessInfo.processInfo.systemUptime < limit else { throw NSError(domain:"Stop persistence timeout",code:1) }
   try await Task.sleep(nanoseconds:10_000_000)
  }
 }
 @MainActor static func verifyCancelledLoadRecovery(root:URL) async throws {
  let local=root.appendingPathComponent("cancelled-load-local"), folder=root.appendingPathComponent("cancelled-load-cloud")
  try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
  let repo=try RecordingRepository(root:local), texts=try TranscriptRepository(root:local), fake=ProbeAccess()
  let worker=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:fake.access)
  _ = try await worker.perform(.connect(folder),gate:ICloudDriveCancellation())
  _ = try await worker.perform(.authorize(.futureOnly,[],[]),gate:ICloudDriveCancellation())
  let library=ICloudDriveLibrary(repository:repo,transcriptRepository:texts,folderAccess:fake.access,providerMonitorFactory: Probe.monitor)
  // The MainActor task cannot publish before this synchronous suspension.
  library.suspendForBackground()
  try check(!library.isConnected,"cancelled initial load has not published connection")
  library.resume()
  try await settle(library)
  try check(library.isConnected && library.isEnabled && library.scope == .futureOnly,"foreground reload recovers durable state after cancelled initial publish")
  library.pause(); library.suspendForBackground(); library.resume()
  try await settle(library)
  try check(library.isConnected && !library.isEnabled,"foreground reload waits for a durable explicit pause")
 }
 static func verifyUnknownLegacyReceiptIndex(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let local=root.appendingPathComponent("legacy-local"), folder=root.appendingPathComponent("legacy-cloud")
  try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
  let repo=try RecordingRepository(root:local), texts=try TranscriptRepository(root:local), fake=ProbeAccess()
  _ = try repo.acceptIncomingFile(at:audio,manifest:manifest)
  let gate=ICloudDriveCancellation(), worker=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:fake.access)
  _ = try await worker.perform(.connect(folder),gate:gate)
  _ = try await worker.perform(.authorize(.existingAndFuture,[manifest],[manifest.id]),gate:gate)
  _ = try await worker.perform(.sync([manifest],[manifest.id]),gate:gate)
  let file=local.appendingPathComponent("ICloudDriveLibrary/state.json")
  var object=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
  object.removeValue(forKey:"committedReceiptPaths")
  try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]).write(to:file,options:.atomic)
  let cold=ICloudDriveLibraryWorker(repository:repo,transcriptRepository:texts,folderAccess:fake.access)
  _ = try await cold.perform(.load,gate:gate)
  let text=SegmentTranscript(segmentID:manifest.id,audioSHA256:manifest.sha256,locale:"zh-CN",engine:"synthetic",
    createdAt:Date(timeIntervalSince1970:300),text:"晚到文字",spans:[.init(start:0,end:1,text:"晚到文字")])
  try texts.save(text,for:manifest)
  fake.uploaded=true
  let state=try await cold.perform(.sync([manifest],[manifest.id]),gate:gate)
  try check(state.savedTranscriptCount == 1 && state.pendingCloudFileCount > 0 && state.activity.contains("缺少提交报告索引"),"new transcript cannot erase unknown legacy commit index")
 }
 static func verifyConcurrentFence(root:URL) throws {
  let file=root.appendingPathComponent("concurrent-fence/stop-intent.json")
  let fence=ICloudDriveStopFence(file:file), group=DispatchGroup()
  for index in 0..<100 {
   group.enter()
   DispatchQueue.global(qos:.utility).async { fence.stop(disconnecting:index == 50); group.leave() }
  }
  group.wait()
  try fence.flush()
  let restored=try ICloudDriveStopFence(file:file).current()
  try check(restored.stopped && restored.disconnected,"concurrent pause snapshots cannot overwrite durable disconnect")
  let coldPause=ICloudDriveStopFence(file:file)
  coldPause.stop(disconnecting:false)
  try coldPause.flush()
  let afterColdPause=try ICloudDriveStopFence(file:file).current()
  try check(afterColdPause.disconnected,"pause before cold fence load cannot clear prior disconnect")
 }
 @MainActor static func settle(_ library:ICloudDriveLibrary) async throws {
  let limit=ProcessInfo.processInfo.systemUptime+5
  while library.isBusy {
   guard ProcessInfo.processInfo.systemUptime < limit else { throw NSError(domain:"Probe timeout",code:1) }
   try await Task.sleep(nanoseconds:10_000_000)
  }
 }

}
