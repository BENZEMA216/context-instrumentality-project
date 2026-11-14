// Actual production Worker, Core marker reader and synthetic local files only.
extension Probe {
 static func recoveryTrace(_ value:String) {
  FileHandle.standardOutput.write(Data((value+"\n").utf8))
 }
 struct DirectoryRecoveryFixture {
  let repository: RecordingRepository
  let transcripts: TranscriptRepository
  let access: ProbeAccess
  let worker: ICloudDriveLibraryWorker
  let sources: [SegmentManifest]
  let local: URL
  let folder: URL
  let marker: URL
  let originalState: Data
  let originalMarker: Data
  var stateURL: URL { local.appendingPathComponent("ICloudDriveLibrary/state.json") }
  var diagnosticURL: URL { local.appendingPathComponent("ICloudDriveLibrary/directory-recovery.json") }
 }

 static func recoveryFixture(root:URL,name:String,manifest:SegmentManifest,audio:URL) async throws -> DirectoryRecoveryFixture {
  let (repo,texts,access,worker,sources,local,folder)=try await livenessFixture(
   root:root,name:"directory-recovery-"+name,count:1,manifest:manifest,audio:audio)
  let state=try await worker.perform(.sync(sources,Set(sources.map(\.id))),gate:ICloudDriveCancellation())
  try check(state.savedAudioCount == 1,"recovery fixture uses a real synthetic export receipt")
  _ = try await worker.perform(.setEnabled(false),gate:ICloudDriveCancellation())
  let library=try FileManager.default.contentsOfDirectory(at:folder,includingPropertiesForKeys:nil)
   .first { $0.lastPathComponent.hasPrefix("RecordForAgent-") }!
  let marker=library.appendingPathComponent("library.json")
  // Recovery may inspect the small marker, never either source or exported audio.
  for source in sources {
   try FileManager.default.removeItem(at:repo.audioURL(for:source))
   let target=library.appendingPathComponent("audio/"+source.id.uuidString.lowercased()+"/"+source.sha256+".caf")
   try FileManager.default.removeItem(at:target)
  }
  return .init(repository:repo,transcripts:texts,access:access,worker:worker,sources:sources,
   local:local,folder:folder,marker:marker,
   originalState:try Data(contentsOf:local.appendingPathComponent("ICloudDriveLibrary/state.json")),
   originalMarker:try Data(contentsOf:marker))
 }

 static func recoveryJSON(_ bytes:Data) throws -> [String:Any] {
  guard let object=try JSONSerialization.jsonObject(with:bytes) as? [String:Any] else {
   throw NSError(domain:"Probe",code:90,userInfo:[NSLocalizedDescriptionKey:"recovery JSON object required"])
  }
  return object
 }

 static func recoveryGrant(_ bytes:Data) throws -> ICloudDriveLibraryLedger {
  let state=try recoveryJSON(bytes)
  // Persisted sets can legitimately serialize in a different array order.
  // Compare every typed ledger field rather than JSON Set iteration order.
  let ledger=try JSONSerialization.data(withJSONObject:state["ledger"]!,options:[.sortedKeys])
  return try TransportCodec.decode(ICloudDriveLibraryLedger.self,from:ledger)
 }

 static func checkRecoveryFilesUnchanged(_ fixture:DirectoryRecoveryFixture) throws {
  try check(try Data(contentsOf:fixture.stateURL) == fixture.originalState,
   "an unconfirmed directory choice preserves exact persisted grant/bookmark/identity bytes")
  try check(try Data(contentsOf:fixture.marker) == fixture.originalMarker,
   "recovery cannot recreate or rewrite the existing library marker")
  for source in fixture.sources {
   try check(!FileManager.default.fileExists(atPath:fixture.repository.audioURL(for:source).path),
    "recovery does not restore or require missing synthetic source audio")
  }
 }

 static func verifyDirectoryRecovery(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let gate=ICloudDriveCancellation()
  try await verifyPersistentDirectoryIdentity(root:root,manifest:manifest,audio:audio)
  // A stale access bookmark does not erase the grant. Selecting the exact same
  // provider identity obtains a fresh bookmark but never enables synchronization.
  do {
   recoveryTrace("BEGIN recovery/same-folder-stale-bookmark")
   let f=try await recoveryFixture(root:root,name:"same-folder",manifest:manifest,audio:audio)
   f.access.stale=true
   let cold=ICloudDriveLibraryWorker(repository:f.repository,transcriptRepository:f.transcripts,folderAccess:f.access.access)
   let stale=try await cold.perform(.load,gate:gate)
   try check(!stale.enabled && stale.error != nil,"stale bookmark fails closed before explicit reselection")
   f.access.stale=false
   let selected=try await cold.perform(.connect(f.folder),gate:gate)
   try check(selected.connected && !selected.enabled && !selected.recoveryConfirmationRequired
    && selected.scope == .existingAndFuture && selected.savedAudioCount == 1,
    "same original provider identity can reconnect a stale bookmark with scope and receipts retained, still paused")
   try check(try recoveryGrant(Data(contentsOf:f.stateURL)) == recoveryGrant(f.originalState),
    "same-directory reselection never reauthorizes the ledger")
   try check(try Data(contentsOf:f.marker) == f.originalMarker,"same-directory reconnection leaves marker bytes intact")
   try check(f.access.starts == f.access.stops,"same-directory security scopes are balanced")
   recoveryTrace("PASS recovery/same-folder-stale-bookmark")
  }
  // A new provider identifier is a candidate, not authority. Neither passive
  // startup nor a first folder selection may silently bind the old grant to it.
  do {
   recoveryTrace("BEGIN recovery/passive-candidate-cancel-confirm")
   let f=try await recoveryFixture(root:root,name:"explicit-confirmation",manifest:manifest,audio:audio)
   f.access.identity=String(repeating:"b",count:64)
   let cold=ICloudDriveLibraryWorker(repository:f.repository,transcriptRepository:f.transcripts,folderAccess:f.access.access)
   let passive=try await cold.perform(.load,gate:gate)
   try check(!passive.enabled && passive.recoveryConfirmationRequired && passive.error != nil,
    "a valid existing bookmark with matching marker offers confirmation directly, never silently adopts a changed identity")
   try checkRecoveryFilesUnchanged(f)
   let pending=try await cold.perform(.connect(f.folder),gate:gate)
   try check(pending.recoveryConfirmationRequired && !pending.enabled && pending.scope == .existingAndFuture,
    "explicit reselection with a valid original marker requires a separate recovery confirmation")
   try checkRecoveryFilesUnchanged(f)
   let cancelled=try await cold.perform(.cancelDirectoryRecovery,gate:gate)
   try check(!cancelled.recoveryConfirmationRequired && !cancelled.enabled,
    "cancelling a pending recovery dismisses the candidate and remains paused")
   try checkRecoveryFilesUnchanged(f)
   _ = try await cold.perform(.connect(f.folder),gate:gate)
   let confirmed=try await cold.perform(.confirmDirectoryRecovery,gate:gate)
   let after=try Data(contentsOf:f.stateURL), object=try recoveryJSON(after)
   try check(!confirmed.recoveryConfirmationRequired && confirmed.connected && !confirmed.enabled
    && confirmed.savedAudioCount == 1 && confirmed.scope == .existingAndFuture,
    "only the second explicit action commits a fresh directory binding, still paused")
   try check(object["folderIdentity"] as? String == f.access.identity
    && (try recoveryGrant(after)) == recoveryGrant(f.originalState),
    "confirmed recovery changes only the access binding, never libraryID, authorization date, baseline or source ledger")
   try check(try Data(contentsOf:f.marker) == f.originalMarker,"confirmed recovery never rewrites marker bytes")
   try check(f.access.starts == f.access.stops,"candidate, cancellation and confirmation balance security scopes")
   recoveryTrace("PASS recovery/passive-candidate-cancel-confirm")
  }
  try await verifyCopiedMarkerRequiresConfirmation(root:root,manifest:manifest,audio:audio)
  recoveryTrace("PASS recovery/copied-marker-needs-confirmation")
  try await verifyRecoveryTOCTOU(root:root,manifest:manifest,audio:audio)
  recoveryTrace("PASS recovery/candidate-identity-marker-toctou-and-disconnect")
  try await verifyRecoveryMarkerFailures(root:root,manifest:manifest,audio:audio)
  try await verifyRecoveryTransientIO(root:root,manifest:manifest,audio:audio)
  recoveryTrace("PASS recovery/transient-marker-io-retry")
  try await verifyRecoveryPersistenceFailure(root:root,manifest:manifest,audio:audio)
  recoveryTrace("PASS recovery/atomic-write-denied-keeps-pause")
  try await verifyEnabledRecoveryCandidate(root:root,manifest:manifest,audio:audio)
  recoveryTrace("PASS recovery/enabled-grant-effectively-paused-candidate")
  try await verifyPersistedGrantTOCTOU(root:root,manifest:manifest,audio:audio)
  recoveryTrace("PASS recovery/durable-grant-before-and-during-confirm-toctou")
  try await verifyUnsafeRecoveryMarkers(root:root,manifest:manifest,audio:audio)
 }

 static func verifyPersistentDirectoryIdentity(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let gate=ICloudDriveCancellation(), stable=String(repeating:"d",count:64)
  let volume="E70A9656-98F5-4CD0-90C4-AF61B9796CD4"
  let digest=ICloudDriveDirectoryIdentity.persistentDigest(documentIdentifier:42,volumeUUID:volume)
  try check(digest?.count == 64 && digest == ICloudDriveDirectoryIdentity.persistentDigest(documentIdentifier:42,volumeUUID:volume.lowercased()),
   "persistent identity has canonical UUID and document representation")
  try check(digest != ICloudDriveDirectoryIdentity.persistentDigest(documentIdentifier:43,volumeUUID:volume)
   && digest != ICloudDriveDirectoryIdentity.persistentDigest(documentIdentifier:42,volumeUUID:UUID().uuidString),
   "copies and different volumes cannot share a persistent directory binding")
  try check(ICloudDriveDirectoryIdentity.persistentDigest(documentIdentifier:0,volumeUUID:volume) == nil
   && ICloudDriveDirectoryIdentity.persistentDigest(documentIdentifier:42,volumeUUID:nil) == nil
   && ICloudDriveDirectoryIdentity.persistentDigest(documentIdentifier:42,volumeUUID:"not-a-uuid") == nil,
   "unsupported persistent evidence remains unknown instead of inventing a path identity")
  for enabled in [false,true] {
   let f=try await recoveryFixture(root:root,name:"persistent-legacy-\(enabled)",manifest:manifest,audio:audio)
   if enabled { _ = try await f.worker.perform(.setEnabled(true),gate:gate) }
   let before=try Data(contentsOf:f.stateURL)
   f.access.persistentIdentity=stable
   let cold=ICloudDriveLibraryWorker(repository:f.repository,transcriptRepository:f.transcripts,folderAccess:f.access.access)
   let enrolled=try await cold.perform(.load,gate:gate)
   try check(enrolled.enabled == enabled && enrolled.error == nil && !enrolled.recoveryConfirmationRequired,
    "verified legacy identity enrolls stable evidence preserving explicit enabled/paused setting")
   let saved=try Data(contentsOf:f.stateURL)
   try check(try recoveryJSON(saved)["persistentFolderIdentityV1"] as? String == stable
    && recoveryGrant(saved) == recoveryGrant(before),"legacy migration preserves every ledger and scope field")
   f.access.identity=String(repeating:"b",count:64)
   let restarted=ICloudDriveLibraryWorker(repository:f.repository,transcriptRepository:f.transcripts,folderAccess:f.access.access)
   let restored=try await restarted.perform(.load,gate:gate)
   try check(restored.enabled == enabled && restored.error == nil && !restored.recoveryConfirmationRequired,
    "persistent identity survives a changed temporary resource ID across process restart")
   try check(try Data(contentsOf:f.stateURL) == saved && Data(contentsOf:f.marker) == f.originalMarker,
    "normal persistent restore does not rewrite original grant or marker")
   // A different stable identity still requires confirmation. Missing provider
   // evidence defers the round, never falls back or revokes the saved setting.
   for current:String? in [String(repeating:"e",count:64),nil] {
    f.access.persistentIdentity=current
    let rejected=ICloudDriveLibraryWorker(repository:f.repository,transcriptRepository:f.transcripts,folderAccess:f.access.access)
    let pending=try await rejected.perform(.load,gate:gate)
    if current == nil {
     try check(pending.enabled == enabled && !pending.recoveryConfirmationRequired && pending.error != nil,
      "missing stable identity defers access without disabling continuous saving or asking to adopt a folder")
    } else {
     try check(!pending.enabled && pending.recoveryConfirmationRequired,"mismatched stable identity never silently falls back to temporary ID")
    }
    try check(try Data(contentsOf:f.stateURL) == saved,"unconfirmed persistent mismatch keeps exact original grant")
    _ = try await rejected.perform(.cancelDirectoryRecovery,gate:gate)
   }
   f.access.persistentIdentity=stable
   let available=ICloudDriveLibraryWorker(repository:f.repository,transcriptRepository:f.transcripts,folderAccess:f.access.access)
   let resumed=try await available.perform(.load,gate:gate)
   try check(resumed.enabled == enabled && resumed.error == nil && !resumed.recoveryConfirmationRequired,
    "provider metadata recovery restores readiness without reselection or reauthorizing continuous saving")
   try check(try Data(contentsOf:f.stateURL) == saved && Data(contentsOf:f.marker) == f.originalMarker,
    "temporary metadata failure and recovery leave original grant and library marker unchanged")
  }
  // Old state whose temporary identity already changed cannot enroll a new
  // stable identity until explicit confirmation through the existing bookmark.
  let f=try await recoveryFixture(root:root,name:"persistent-confirm-migration",manifest:manifest,audio:audio)
  f.access.identity=String(repeating:"b",count:64);f.access.persistentIdentity=stable
  let cold=ICloudDriveLibraryWorker(repository:f.repository,transcriptRepository:f.transcripts,folderAccess:f.access.access)
  let pending=try await cold.perform(.load,gate:gate)
  try check(pending.recoveryConfirmationRequired && !pending.enabled,"old mismatch offers one confirmation with no folder picker")
  try checkRecoveryFilesUnchanged(f)
  let confirmed=try await cold.perform(.confirmDirectoryRecovery,gate:gate)
  try check(!confirmed.enabled && !confirmed.recoveryConfirmationRequired,"one confirmation restores access while staying paused")
  let saved=try Data(contentsOf:f.stateURL)
  try check(try recoveryJSON(saved)["persistentFolderIdentityV1"] as? String == stable
   && recoveryGrant(saved) == recoveryGrant(f.originalState),"confirmed migration keeps all original authorization and receipts")
  f.access.identity=String(repeating:"c",count:64)
  let again=ICloudDriveLibraryWorker(repository:f.repository,transcriptRepository:f.transcripts,folderAccess:f.access.access)
  let restored=try await again.perform(.load,gate:gate)
  try check(restored.error == nil && !restored.enabled && !restored.recoveryConfirmationRequired,"confirmed stable migration does not prompt on next temporary ID change")
  f.access.persistentIdentity=String(repeating:"e",count:64)
  _ = try await again.perform(.load,gate:gate)
  f.access.persistentIdentity=String(repeating:"f",count:64)
  do {
   _ = try await again.perform(.confirmDirectoryRecovery,gate:gate)
   throw NSError(domain:"Probe",code:97,userInfo:[NSLocalizedDescriptionKey:"stable identity changed before confirmation accepted"])
  } catch let error as NSError where error.domain == "Probe" { throw error }
  catch { try check(true,"persistent identity change during confirmation is rejected") }
  try check(try Data(contentsOf:f.stateURL) == saved,"failed confirmation does not commit replacement identity")
  f.access.persistentIdentity=stable
  let disconnecting=ICloudDriveLibraryWorker(repository:f.repository,transcriptRepository:f.transcripts,folderAccess:f.access.access)
  _ = try await disconnecting.perform(.load,gate:gate)
  let disconnected=try await disconnecting.perform(.disconnect,gate:gate)
  try check(!disconnected.connected && !disconnected.enabled,"persistent authorization can be explicitly disconnected")
  let afterDisconnect=try Data(contentsOf:f.stateURL)
  let disconnectedWorker=ICloudDriveLibraryWorker(repository:f.repository,transcriptRepository:f.transcripts,folderAccess:f.access.access)
  let disconnectedCold=try await disconnectedWorker.perform(.load,gate:gate)
  try check(!disconnectedCold.connected && !disconnectedCold.enabled && disconnectedCold.error == nil
   && disconnectedCold.scope == .existingAndFuture && disconnectedCold.savedAudioCount == 1,
   "cold restart accepts retained persistent identity as disconnected authorization history")
  try check(try Data(contentsOf:f.stateURL) == afterDisconnect,"disconnected cold load preserves exact grant history")
  let reconnected=try await disconnectedWorker.perform(.connect(f.folder),gate:gate)
  try check(reconnected.connected && !reconnected.enabled && !reconnected.recoveryConfirmationRequired
   && reconnected.scope == .existingAndFuture && reconnected.savedAudioCount == 1,
   "explicit reconnection of original persistent directory keeps scope and receipts, still paused")
  let racing=try await recoveryFixture(root:root,name:"persistent-enroll-grant-race",manifest:manifest,audio:audio)
  racing.access.persistentIdentity=stable
  var reads=0, concurrentBytes:Data?
  racing.access.beforePersistentIdentity = {
   reads += 1
   if reads == 3 {
    var disk=try! recoveryJSON(Data(contentsOf:racing.stateURL))
    var connection=disk["connection"] as! [String:Any]
    connection["folderName"]="Changed by another metadata writer"
    disk["connection"]=connection
    concurrentBytes=try! JSONSerialization.data(withJSONObject:disk,options:[.sortedKeys])
    try! concurrentBytes!.write(to:racing.stateURL,options:.atomic)
   }
  }
  let racingWorker=ICloudDriveLibraryWorker(repository:racing.repository,transcriptRepository:racing.transcripts,folderAccess:racing.access.access)
  let raced=try await racingWorker.perform(.load,gate:gate)
  try check(concurrentBytes != nil && raced.error != nil && !raced.enabled,"migration rejects a grant changed during provider inspection")
  try check(try Data(contentsOf:racing.stateURL) == concurrentBytes,"migration never overwrites the concurrently updated grant")
  recoveryTrace("PASS recovery/persistent-identity-migration-and-restart")
 }

 static func verifyCopiedMarkerRequiresConfirmation(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let f=try await recoveryFixture(root:root,name:"copied-marker",manifest:manifest,audio:audio)
  let alternate=root.appendingPathComponent("directory-recovery-alternate"), copy=alternate.appendingPathComponent(f.marker.deletingLastPathComponent().lastPathComponent)
  try FileManager.default.createDirectory(at:copy,withIntermediateDirectories:true)
  let copiedMarker=copy.appendingPathComponent("library.json")
  try f.originalMarker.write(to:copiedMarker)
  f.access.identity=String(repeating:"c",count:64)
  let pending=try await f.worker.perform(.connect(alternate),gate:ICloudDriveCancellation())
  try check(pending.recoveryConfirmationRequired && !pending.enabled,
   "even an exact copied marker in a different directory cannot silently inherit the original grant")
  try checkRecoveryFilesUnchanged(f)
  _ = try await f.worker.perform(.cancelDirectoryRecovery,gate:ICloudDriveCancellation())
  try checkRecoveryFilesUnchanged(f)
  try check(try Data(contentsOf:copiedMarker) == f.originalMarker
   && FileManager.default.subpathsOfDirectory(atPath:alternate.path).sorted() == [copy.lastPathComponent,copy.lastPathComponent+"/library.json"].sorted(),
   "selection and cancellation cannot export into or modify the alternate folder")
 }

 static func verifyRecoveryTOCTOU(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  for mutation in ["identity","marker"] {
   let f=try await recoveryFixture(root:root,name:"toctou-"+mutation,manifest:manifest,audio:audio)
   f.access.identity=String(repeating:"b",count:64)
   _ = try await f.worker.perform(.connect(f.folder),gate:ICloudDriveCancellation())
   if mutation == "identity" { f.access.identity=String(repeating:"c",count:64) }
   else { try Data("{invalid-marker".utf8).write(to:f.marker) }
   do {
    _ = try await f.worker.perform(.confirmDirectoryRecovery,gate:ICloudDriveCancellation())
    throw NSError(domain:"Probe",code:91,userInfo:[NSLocalizedDescriptionKey:"TOCTOU accepted"])
   } catch let error as NSError where error.domain == "Probe" { throw error }
   catch { try check(true,"a changed candidate "+mutation+" is rejected during explicit confirmation") }
   try check(try Data(contentsOf:f.stateURL) == f.originalState,
    "candidate TOCTOU preserves the original persisted access and ledger")
   let diagnostic=try recoveryJSON(Data(contentsOf:f.diagnosticURL))
   try check(diagnostic["confirmationRequired"] as? Bool == false,
    "a consumed failed confirmation does not leave a stale pending prompt in its writable report")
   if mutation == "marker" {
    try check(try Data(contentsOf:f.marker) == Data("{invalid-marker".utf8),"failed recovery does not repair a corrupt marker")
   } else { try check(try Data(contentsOf:f.marker) == f.originalMarker,"identity TOCTOU leaves marker unchanged") }
   try check(f.access.starts == f.access.stops,"TOCTOU failure balances security scopes")
  }
  let f=try await recoveryFixture(root:root,name:"candidate-invalidation",manifest:manifest,audio:audio)
  f.access.identity=String(repeating:"b",count:64)
  _ = try await f.worker.perform(.connect(f.folder),gate:ICloudDriveCancellation())
  let disconnected=try await f.worker.perform(.disconnect,gate:ICloudDriveCancellation())
  let afterDisconnect=try Data(contentsOf:f.stateURL)
  try check(!disconnected.connected && !disconnected.enabled,"explicit disconnect supersedes a pending recovery")
  do {
   let state=try await f.worker.perform(.confirmDirectoryRecovery,gate:ICloudDriveCancellation())
   try check(!state.connected && !state.enabled && !state.recoveryConfirmationRequired,
    "a stale confirmation cannot restore a subsequently disconnected grant")
  } catch let error as NSError where error.domain == "Probe" { throw error }
  catch { try check(true,"a stale recovery confirmation is rejected after disconnect") }
  try check(try Data(contentsOf:f.stateURL) == afterDisconnect,
   "confirmation cannot overwrite a newer explicit stop or connection state")
 }

 static func verifyRecoveryMarkerFailures(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let f=try await recoveryFixture(root:root,name:"marker-failures",manifest:manifest,audio:audio)
  let fm=FileManager.default, library=f.marker.deletingLastPathComponent(), parked=root.appendingPathComponent("recovery-marker-parked")
  f.access.identity=String(repeating:"b",count:64)
  var codes=Set<String>()
  for mutation in ["missing-library","missing-marker","wrong-library","decode"] {
   recoveryTrace("BEGIN recovery/marker-"+mutation)
   switch mutation {
   case "missing-library": try fm.moveItem(at:library,to:parked)
   case "missing-marker": try fm.removeItem(at:f.marker)
   case "wrong-library": try TransportCodec.encode(ICloudDriveLibraryMarker(libraryID:UUID())).write(to:f.marker)
   default: try Data("{invalid-marker".utf8).write(to:f.marker)
   }
   do {
    _ = try await f.worker.perform(.connect(f.folder),gate:ICloudDriveCancellation())
    throw NSError(domain:"Probe",code:92,userInfo:[NSLocalizedDescriptionKey:"bad marker accepted"])
   } catch let error as NSError where error.domain == "Probe" { throw error }
   catch { try check(true,"invalid marker condition "+mutation+" fails closed") }
   let diagnostic=try recoveryJSON(Data(contentsOf:f.diagnosticURL))
   try check(diagnostic["audioRead"] as? Bool == false && diagnostic["markerWritten"] as? Bool == false,
    "failed recovery explicitly records metadata-only scope")
   if let code=diagnostic["code"] as? String { codes.insert(code) }
   try check(try Data(contentsOf:f.stateURL) == f.originalState,
    "marker failure "+mutation+" preserves exact original grant and bookmark bytes")
   if mutation == "missing-library" {
    try check(!fm.fileExists(atPath:library.path),"missing library is not recreated")
    try fm.moveItem(at:parked,to:library)
   } else {
    if mutation == "missing-marker" { try check(!fm.fileExists(atPath:f.marker.path),"missing marker is not recreated") }
    try f.originalMarker.write(to:f.marker)
   }
   recoveryTrace("PASS recovery/marker-"+mutation)
  }
  try check(codes.count == 4,"missing library, missing marker, wrong library and decode failures remain distinct")
  try check(f.access.starts == f.access.stops,"marker failures balance security scopes")
 }

 static func verifyRecoveryTransientIO(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let f=try await recoveryFixture(root:root,name:"transient-io",manifest:manifest,audio:audio)
  f.access.identity=String(repeating:"b",count:64)
  var injected=true
  var custom=f.access.access
  custom.inspectMarker={ folder,libraryID in
   if injected { throw NSError(domain:NSPOSIXErrorDomain,code:Int(EAGAIN)) }
   _ = try ICloudDriveExportWriter(root:folder,libraryID:libraryID).inspectExistingMarker()
  }
  let worker=ICloudDriveLibraryWorker(repository:f.repository,transcriptRepository:f.transcripts,folderAccess:custom)
  do {
   _ = try await worker.perform(.connect(f.folder),gate:ICloudDriveCancellation())
   throw NSError(domain:"Probe",code:93,userInfo:[NSLocalizedDescriptionKey:"transient read unexpectedly accepted"])
  } catch let error as NSError where error.domain == "Probe" { throw error }
  catch { try check(true,"temporary marker IO fails without inventing a folder mismatch") }
  let diagnostic=try recoveryJSON(Data(contentsOf:f.diagnosticURL))
  try check(diagnostic["posixErrno"] as? Int == Int(EAGAIN),"temporary marker IO retains its typed errno")
  try checkRecoveryFilesUnchanged(f)
  injected=false
  let pending=try await worker.perform(.connect(f.folder),gate:ICloudDriveCancellation())
  try check(pending.recoveryConfirmationRequired && !pending.enabled,
   "a real new explicit opportunity retries transient marker IO without permanently corrupting authorization")
  try checkRecoveryFilesUnchanged(f)
  _ = try await worker.perform(.cancelDirectoryRecovery,gate:ICloudDriveCancellation())
 }

 static func verifyRecoveryPersistenceFailure(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let f=try await recoveryFixture(root:root,name:"write-failure",manifest:manifest,audio:audio)
  f.access.identity=String(repeating:"b",count:64)
  _ = try await f.worker.perform(.connect(f.folder),gate:ICloudDriveCancellation())
  let stateDirectory=f.stateURL.deletingLastPathComponent()
  // Keep the exact state readable for both candidate-binding checks, while
  // denying the real atomic writer's temporary-file creation in its directory.
  try check(getuid() != 0,"the native write-denial fixture must run without root privileges")
  try check(chmod(stateDirectory.path,0o500) == 0,"synthetic state directory is read/search-only")
  defer { _ = chmod(stateDirectory.path,0o700) }
  do {
   _ = try await f.worker.perform(.confirmDirectoryRecovery,gate:ICloudDriveCancellation())
   throw NSError(domain:"Probe",code:94,userInfo:[NSLocalizedDescriptionKey:"failed persistence accepted"])
  } catch let error as NSError where error.domain == "Probe" { throw error }
  catch let failure as ICloudDriveLibraryFailure {
   recoveryTrace("OBSERVED recovery/write-denial-error="+String(describing:failure))
   try check(failure == .directoryUnavailable || failure == .unavailableState,
    "write denial fails as unavailable metadata rather than a candidate-binding rejection")
  }
  let fence=try recoveryJSON(Data(contentsOf:f.local.appendingPathComponent("ICloudDriveLibrary/stop-intent.json")))
  try check(fence["stopped"] as? Bool == true,"failed recovery cannot clear the durable pause fence")
  try check(try Data(contentsOf:f.stateURL) == f.originalState && Data(contentsOf:f.marker) == f.originalMarker,
   "failed persistence preserves the old saved grant and marker bytes")
  try check(chmod(stateDirectory.path,0o700) == 0,"synthetic write permissions restored after denial")
  do {
   _ = try await f.worker.perform(.load,gate:ICloudDriveCancellation())
   throw NSError(domain:"Probe",code:98,userInfo:[NSLocalizedDescriptionKey:"native persistence failure was not reached"])
  } catch let failure as ICloudDriveLibraryFailure {
   try check(failure == .unavailableState,"the production persist failure marked its worker unavailable until a cold reload")
  }
  let cold=ICloudDriveLibraryWorker(repository:f.repository,transcriptRepository:f.transcripts,folderAccess:f.access.access)
  let state=try await cold.perform(.load,gate:ICloudDriveCancellation())
  try check(!state.enabled && state.scope == .existingAndFuture,"cold restart after write failure cannot silently enable the old grant")
 }

 static func verifyEnabledRecoveryCandidate(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let f=try await recoveryFixture(root:root,name:"enabled-candidate",manifest:manifest,audio:audio)
  _ = try await f.worker.perform(.setEnabled(true),gate:ICloudDriveCancellation())
  let enabledBytes=try Data(contentsOf:f.stateURL)
  f.access.identity=String(repeating:"b",count:64)
  let pending=try await f.worker.perform(.connect(f.folder),gate:ICloudDriveCancellation())
  try check(pending.recoveryConfirmationRequired && !pending.enabled,
   "a candidate has an effectively paused projection even if the retained grant was enabled")
  try check(try Data(contentsOf:f.stateURL) == enabledBytes,"candidate selection cannot silently alter an enabled durable grant")
  let metadataChecks=f.access.metadataChecks, identityChecks=f.access.identityChecks
  _ = try await f.worker.perform(.sync(f.sources,Set(f.sources.map(\.id))),gate:ICloudDriveCancellation())
  _ = try await f.worker.perform(.refreshProviderStatus,gate:ICloudDriveCancellation())
  try check(f.access.metadataChecks == metadataChecks && f.access.identityChecks == identityChecks,
   "pending confirmation prevents both passive export and provider refresh from using either directory")
  let cancelled=try await f.worker.perform(.cancelDirectoryRecovery,gate:ICloudDriveCancellation())
  try check(cancelled.enabled && !cancelled.recoveryConfirmationRequired,
   "cancelling restores the prior enabled projection rather than silently changing the original grant")
  try check(try Data(contentsOf:f.stateURL) == enabledBytes,"candidate cancellation preserves the original enabled grant bytes")
 }

 static func verifyPersistedGrantTOCTOU(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let f=try await recoveryFixture(root:root,name:"persisted-grant-toctou",manifest:manifest,audio:audio)
  f.access.identity=String(repeating:"b",count:64)
  _ = try await f.worker.perform(.connect(f.folder),gate:ICloudDriveCancellation())
  let independent=ICloudDriveLibraryWorker(repository:f.repository,transcriptRepository:f.transcripts,folderAccess:f.access.access)
  _ = try await independent.perform(.disconnect,gate:ICloudDriveCancellation())
  let stoppedBytes=try Data(contentsOf:f.stateURL)
  do {
   _ = try await f.worker.perform(.confirmDirectoryRecovery,gate:ICloudDriveCancellation())
   throw NSError(domain:"Probe",code:95,userInfo:[NSLocalizedDescriptionKey:"a newer durable grant was overwritten"])
  } catch let error as NSError where error.domain == "Probe" { throw error }
  catch { try check(true,"confirmation rejects a grant replaced by an independent worker") }
  try check(try Data(contentsOf:f.stateURL) == stoppedBytes,"a pending candidate cannot overwrite a newer saved disconnect")
  try check(try Data(contentsOf:f.marker) == f.originalMarker,"persisted grant TOCTOU cannot rewrite the marker")

  let mid=try await recoveryFixture(root:root,name:"mid-confirm-grant-toctou",manifest:manifest,audio:audio)
  mid.access.identity=String(repeating:"b",count:64)
  var replacement=try recoveryJSON(mid.originalState)
  replacement.removeValue(forKey:"connection")
  let replacementBytes=try JSONSerialization.data(withJSONObject:replacement,options:[.sortedKeys])
  var mutateDuringConfirmation=false, mutationCount=0
  var custom=mid.access.access
  custom.inspectMarker={ folder,libraryID in
   try ICloudDriveExportWriter(root:folder,libraryID:libraryID).inspectExistingMarker()
   if mutateDuringConfirmation {
    try replacementBytes.write(to:mid.stateURL,options:.atomic)
    mutationCount += 1
   }
  }
  let candidateWorker=ICloudDriveLibraryWorker(repository:mid.repository,transcriptRepository:mid.transcripts,folderAccess:custom)
  _ = try await candidateWorker.perform(.connect(mid.folder),gate:ICloudDriveCancellation())
  mutateDuringConfirmation=true
  do {
   _ = try await candidateWorker.perform(.confirmDirectoryRecovery,gate:ICloudDriveCancellation())
   throw NSError(domain:"Probe",code:97,userInfo:[NSLocalizedDescriptionKey:"a mid-confirm grant change was overwritten"])
  } catch let error as NSError where error.domain == "Probe" { throw error }
  catch { try check(true,"confirmation rechecks the durable grant after the provider marker read") }
  try check(mutationCount == 1,"the synthetic grant replacement occurred inside the actual confirm marker read")
  try check(try Data(contentsOf:mid.stateURL) == replacementBytes,
   "a provider callback cannot make confirmation overwrite a newer saved binding")
  try check(try Data(contentsOf:mid.marker) == mid.originalMarker,"mid-confirm grant replacement leaves marker intact")
 }

 static func verifyUnsafeRecoveryMarkers(root:URL,manifest:SegmentManifest,audio:URL) async throws {
  let f=try await recoveryFixture(root:root,name:"unsafe-markers",manifest:manifest,audio:audio)
  let fm=FileManager.default, outside=root.appendingPathComponent("synthetic-marker-outside.json")
  try f.originalMarker.write(to:outside)
  f.access.identity=String(repeating:"b",count:64)
  for mutation in ["symlink","hardlink","fifo","oversize"] {
   recoveryTrace("BEGIN recovery/marker-"+mutation)
   try fm.removeItem(at:f.marker)
   switch mutation {
   case "symlink": try fm.createSymbolicLink(at:f.marker,withDestinationURL:outside)
   case "hardlink": try fm.linkItem(at:outside,to:f.marker)
   case "fifo": try check(mkfifo(f.marker.path,0o600) == 0,"synthetic marker FIFO created")
   default: try Data(repeating:0x20,count:4_097).write(to:f.marker)
   }
   let began=Date()
   do {
    _ = try await f.worker.perform(.connect(f.folder),gate:ICloudDriveCancellation())
    throw NSError(domain:"Probe",code:96,userInfo:[NSLocalizedDescriptionKey:"unsafe marker accepted"])
   } catch let error as NSError where error.domain == "Probe" { throw error }
   catch { try check(true,"unsafe marker "+mutation+" fails closed") }
   try check(Date().timeIntervalSince(began) < 2,"bounded marker inspection does not block on "+mutation)
   try check(try Data(contentsOf:f.stateURL) == f.originalState,"unsafe marker never changes the original grant")
   try fm.removeItem(at:f.marker);try f.originalMarker.write(to:f.marker)
   recoveryTrace("PASS recovery/marker-"+mutation)
  }
  try check(try Data(contentsOf:outside) == f.originalMarker,"recovery never writes a marker link target")
 }
}
