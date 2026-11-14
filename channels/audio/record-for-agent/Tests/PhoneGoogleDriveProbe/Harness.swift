import Foundation
import RecordingCore

private struct PipelineState: Codable { let schemaVersion: Int; let records: [GoogleDriveBackgroundUploads.Record] }
private final class RetryClock: @unchecked Sendable {
    private let lock = NSLock(); private var value = Date(), followsWallClock = false
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return followsWallClock ? Date() : value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value.addTimeInterval(seconds); lock.unlock() }
    func followWallClock() { lock.lock(); followsWallClock = true; lock.unlock() }
}
private struct ProbeFailure: Error { let message: String }
private func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
    guard value() else { throw ProbeFailure(message: message) }
}
private final class Gate: @unchecked Sendable {
    private let lock = NSLock(); private var closed = false
    func close() { lock.lock(); closed = true; lock.unlock() }
    func check() throws { lock.lock(); defer { lock.unlock() }; if closed { throw CancellationError() } }
}
private final class TaskCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelTask: (@Sendable () -> Void)?
    func install(_ task: Task<Void, Error>) { lock.lock(); cancelTask = { task.cancel() }; lock.unlock() }
    func cancel() { lock.lock(); let action = cancelTask; lock.unlock(); action?() }
}
private final class BudgetGate: @unchecked Sendable {
    private let lock = NSLock()
    private var budget: GoogleDriveExecutionBudget
    private var now: TimeInterval = 0
    init(isForeground: Bool, systemGranted: Bool = false, now: TimeInterval = 0, maximumDeadline: TimeInterval? = nil) {
        self.now = now
        budget = GoogleDriveExecutionBudget(isForeground: isForeground, systemGranted: systemGranted,
            now: now, maximumDeadline: maximumDeadline)
    }
    var time: TimeInterval { lock.lock(); defer { lock.unlock() }; return now }
    var deadline: TimeInterval { lock.lock(); defer { lock.unlock() }; return budget.deadline }
    func advance(_ seconds: TimeInterval) { lock.lock(); now += seconds; lock.unlock() }
    func enterBackground() { lock.lock(); budget.enterBackground(at: now); lock.unlock() }
    func expire() { lock.lock(); budget.expire(); lock.unlock() }
    func check() throws { lock.lock(); defer { lock.unlock() }; try budget.check(at: now) }
    func requestTimeout() throws -> TimeInterval { lock.lock(); defer { lock.unlock() }; return try budget.requestTimeout(at: now) }
}
private struct Reply { let code: Int; var headers: [String: String] = [:]; var data = Data() }
private final class MockProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: ((URLRequest) throws -> Reply)?
    static func install(_ handler: @escaping (URLRequest) throws -> Reply) { lock.lock(); self.handler = handler; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handler; Self.lock.unlock()
        do {
            guard let handler else { throw ProbeFailure(message: "No synthetic route") }
            let reply = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.code, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
@MainActor private final class Tokens: GoogleDriveTokenProvider {
    var values: [String]
    init(_ values: [String] = ["synthetic-access"]) { self.values = values }
    func accessToken(for accountID: String) async throws -> String {
        if values.count > 1 { return values.removeFirst() }; return values[0]
    }
}
/// Holds the actual client's token await; it never accesses native credentials.
@MainActor private final class PhaseTokens: GoogleDriveTokenProvider {
    let targetCall: Int, hold: Bool, rotate: Bool
    private(set) var calls = 0
    private(set) var entered = false
    private var waiting: CheckedContinuation<String, Error>?
    init(targetCall: Int, hold: Bool, rotate: Bool = true) {
        self.targetCall = targetCall; self.hold = hold; self.rotate = rotate
    }
    func accessToken(for accountID: String) async throws -> String {
        calls += 1
        if hold && calls == targetCall {
            entered = true
            return try await withCheckedThrowingContinuation { waiting = $0 }
        }
        return rotate && calls >= targetCall ? "synthetic-rotated-access" : "synthetic-first-access"
    }
    func release(_ error: URLError.Code? = nil) {
        guard let waiting else { return }; self.waiting = nil
        if let error { waiting.resume(throwing: URLError(error)) }
        else { waiting.resume(returning: "synthetic-rotated-access") }
    }
}
/// Blocks only the synthetic URLProtocol reply, with a hard escape on test failure.
private final class AccountReplyHold: @unchecked Sendable {
    private let lock = NSLock(), released = DispatchSemaphore(value: 0)
    private var didEnter = false, error: URLError.Code?
    var entered: Bool { lock.lock(); defer { lock.unlock() }; return didEnter }
    func reply() throws -> Reply {
        lock.lock(); didEnter = true; lock.unlock()
        guard released.wait(timeout: .now() + 5) == .success else {
            throw ProbeFailure(message: "Held account reply was not released")
        }
        lock.lock(); let error = error; lock.unlock()
        if let error { throw URLError(error) }
        return try about()
    }
    func release(_ error: URLError.Code? = nil) {
        lock.lock(); self.error = error; lock.unlock(); released.signal()
    }
}
@MainActor private func awaitPhaseHold(_ ready: () -> Bool) async throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    while !ready() {
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            throw ProbeFailure(message: "Client did not reach the held diagnostic boundary")
        }
        await Task.yield()
    }
}
private func syntheticCredential() -> GoogleDriveCredential {
    .init(clientID: "synthetic-client.apps.googleusercontent.com", accessToken: "synthetic-old-access",
        refreshToken: "synthetic-refresh", expiresAt: Date(timeIntervalSince1970: 0), accountID: "owner-123")
}
/// Encoded synthetic Keychain record: recreating the reader cannot drop the
/// revocation-only purpose. No native Keychain service is touched by this probe.
@MainActor private final class RevocationStore {
    var bytes: Data? = try! JSONEncoder().encode(syntheticCredential())
    var revision = 0
    var failPersist = false, failRemove = false
    var removes = 0
    var current: GoogleDriveCredential? { bytes.flatMap { try? JSONDecoder().decode(GoogleDriveCredential.self, from: $0) } }
    func replace(_ credential: GoogleDriveCredential) throws {
        bytes = try JSONEncoder().encode(credential); revision += 1
    }
    func revoke(http: GoogleDriveHTTP) async throws -> Bool {
        let observed = revision
        return try await GoogleDriveCredentialRevocation.revoke(current: current, http: http, persist: { value in
            if self.failPersist { throw GoogleDriveError.credentials }
            self.bytes = try JSONEncoder().encode(value)
        }, remove: {
            if self.failRemove { throw GoogleDriveError.credentials }
            self.bytes = nil; self.removes += 1
        }, check: {
            guard self.revision == observed else { throw CancellationError() }
        })
    }
}
@MainActor private final class ExchangeTokens: GoogleDriveTokenProvider {
    let transport: GoogleDriveHTTP
    init(transport: GoogleDriveHTTP) { self.transport = transport }
    func accessToken(for accountID: String) async throws -> String {
        try await accessToken(for: accountID, timeout: nil)
    }
    func accessToken(for accountID: String, timeout: TimeInterval?) async throws -> String {
        let previous = syntheticCredential()
        let next = try await GoogleDriveOAuthExchange.exchange(http: transport, clientID: previous.clientID,
            values: ["client_id": previous.clientID, "refresh_token": previous.refreshToken, "grant_type": "refresh_token"], previous: previous, timeout: timeout)
        return next.accessToken
    }
}
/// Uses the exact production credential-owned refresh/commit boundary with an
/// in-memory store, never Keychain. Each client keeps its own upload lease.
@MainActor private final class SharedExchangeTokens: GoogleDriveTokenProvider {
    let transport: GoogleDriveHTTP
    let refresh = GoogleDriveCredentialRefresh()
    var credential = syntheticCredential()
    var revision = 0
    private(set) var commits = 0
    init(transport: GoogleDriveHTTP) { self.transport = transport }
    func accessToken(for accountID: String) async throws -> String { try await accessToken(for: accountID, timeout: nil) }
    func accessToken(for accountID: String, timeout: TimeInterval?) async throws -> String {
        let observed = revision
        return try await refresh.accessToken(current: credential, accountID: accountID, http: transport, timeout: timeout,
            isCurrent: { self.revision == observed }, commit: { self.credential = $0; self.commits += 1 })
    }
    func invalidate() { revision += 1; refresh.invalidate() }
}
private final class RecoveryTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var diagnostics: [GoogleDriveTransportDiagnostic] = []
    private var completions: [GoogleDriveRequestCompletion] = []
    func append(_ value: GoogleDriveTransportDiagnostic) { lock.lock(); diagnostics.append(value); lock.unlock() }
    func finish(_ value: GoogleDriveRequestCompletion) { lock.lock(); completions.append(value); lock.unlock() }
    var attempts: [GoogleDriveTransportDiagnostic] { lock.lock(); defer { lock.unlock() }; return diagnostics }
    var finished: [GoogleDriveRequestCompletion] { lock.lock(); defer { lock.unlock() }; return completions }
}
private final class Trace: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    func append(_ value: URLRequest) { lock.lock(); requests.append(value); lock.unlock() }
    func count(_ predicate: (URLRequest) -> Bool) -> Int { lock.lock(); defer { lock.unlock() }; return requests.filter(predicate).count }
}
private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
private func about(_ owner: String = "owner-123") throws -> Reply { .init(code: 200, data: try json(["user": ["permissionId": owner, "displayName": "Synthetic account"]])) }
private func http() -> GoogleDriveHTTP {
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockProtocol.self]
    return GoogleDriveHTTP(configuration: config)
}
private func fixture(_ bytes: Data, root: URL) throws -> (GoogleDriveLibraryLedger, SegmentManifest, GoogleDriveArtifact, URL) {
    let id = UUID(), now = Date(timeIntervalSince1970: 1_700_000_000)
    let manifest = SegmentManifest(id: id, sessionID: UUID(), sequence: 1, startedAt: now, endedAt: now.addingTimeInterval(30),
        sampleRate: 16_000, frameCount: 480_000, fileName: id.uuidString.lowercased() + ".caf", byteCount: Int64(bytes.count), sha256: GoogleDriveLibraryLedger.digest(bytes))
    var ledger = GoogleDriveLibraryLedger(); try ledger.bind(accountID: "owner-123", label: "Synthetic account")
    try ledger.authorize(.existingAndFuture, knownIDs: [], at: now)
    try ledger.discover(manifests: [manifest], receivedIDs: [id]); try ledger.allocateFolder("folder-123")
    let artifact = ledger.jobs[0].artifacts[0]; try ledger.allocateFile(segmentID: id, key: artifact.key, fileID: "audio-123")
    let url = root.appendingPathComponent(UUID().uuidString + ".caf"); try bytes.write(to: url)
    return (ledger, manifest, ledger.jobs[0].artifacts[0], url)
}
private func remote(_ ledger: GoogleDriveLibraryLedger, _ manifest: SegmentManifest, _ artifact: GoogleDriveArtifact) throws -> Data {
    try json(["id": "audio-123", "size": String(artifact.byteCount), "sha256Checksum": artifact.sha256, "parents": ["folder-123"],
        "ownedByMe": true, "shared": false, "trashed": false,
        "permissions": [["id": "owner-123", "type": "user", "role": "owner"]],
        "appProperties": ["rfaSchema": "1", "rfaLibraryID": ledger.libraryID.uuidString.lowercased(), "rfaSegmentID": manifest.id.uuidString.lowercased(),
            "rfaKind": "audio", "rfaContentSHA256": artifact.sha256, "rfaAudioSHA256": manifest.sha256]])
}
/// A successful HTTP request is never the assertion boundary for an audio case.
/// Check the exact source/artifact receipt that production exports as remote_verified.
private func requireAudioReceipt(_ ledger: GoogleDriveLibraryLedger, _ manifest: SegmentManifest,
                                 _ artifact: GoogleDriveArtifact) throws {
    guard let saved = ledger.jobs.first(where: { $0.id == manifest.id })?.artifacts.first(where: { $0.key == artifact.key }) else {
        throw ProbeFailure(message: "Exact source/artifact disappeared before remote_verified")
    }
    try require(saved.kind == .audio && saved.fileID == artifact.fileID && saved.sha256 == artifact.sha256
        && saved.byteCount == artifact.byteCount && saved.verifiedAt != nil && saved.uploadURL == nil
        && saved.verifiedUploadCorrelation == GoogleDriveUploadCorrelation(segmentID: manifest.id, kind: .audio, manifestSHA256: manifest.sha256)
        && ledger.savedAudioCount == 1 && ledger.jobs.flatMap(\.artifacts).filter { $0.verifiedAt != nil }.count == 1,
        "Recovery lacked one exact remote_verified audio receipt or credited another source/artifact")
}
private func folder(_ ledger: GoogleDriveLibraryLedger) throws -> Data {
    try json(["id": "folder-123", "mimeType": "application/vnd.google-apps.folder", "ownedByMe": true,
        "shared": false, "trashed": false, "permissions": [["id": "owner-123", "type": "user", "role": "owner"]],
        "appProperties": ["rfaSchema": "1", "rfaLibraryID": ledger.libraryID.uuidString.lowercased()]])
}
private func orderedManifests(_ count: Int) -> [SegmentManifest] {
    (0..<count).map { index in
        let id = UUID(), start = Date(timeIntervalSince1970: 1_700_000_000 + Double(count - index) * 60)
        return SegmentManifest(id: id, sessionID: UUID(), sequence: index + 1, startedAt: start,
            endedAt: start.addingTimeInterval(30), sampleRate: 16_000, frameCount: 480_000,
            fileName: id.uuidString.lowercased() + ".caf", byteCount: 8,
            sha256: GoogleDriveLibraryLedger.digest(Data(repeating: 1, count: 8)))
    }
}
private func priorityLedger(_ manifests: [SegmentManifest], scope: GoogleDriveRecordingScope = .existingAndFuture,
                            baseline: Set<UUID> = [], authorizedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) throws -> GoogleDriveLibraryLedger {
    var ledger = GoogleDriveLibraryLedger()
    try ledger.bind(accountID: "owner-123", label: "Synthetic account")
    try ledger.authorize(scope, knownIDs: baseline, at: authorizedAt)
    try ledger.discover(manifests: manifests, receivedIDs: Set(manifests.map(\.id)))
    try ledger.allocateFolder("folder-123")
    return ledger
}
private func addPriorityTranscript(_ manifest: SegmentManifest, to ledger: inout GoogleDriveLibraryLedger) throws {
    try ledger.discoverTranscript(SegmentTranscript(segmentID: manifest.id, audioSHA256: manifest.sha256,
        locale: "zh-CN", engine: "synthetic-priority", createdAt: manifest.endedAt,
        text: "合成排序回归文字", spans: []), for: manifest)
}
private func acceptSyntheticReceipt(_ selected: GoogleDriveSyncProgress.UploadChoice,
                                    in ledger: inout GoogleDriveLibraryLedger,
                                    checksum: String? = nil) throws -> GoogleDriveArtifact.Kind {
    let job = ledger.jobs.first { $0.id == selected.segmentID }!
    var artifact = job.artifacts.first { $0.key == selected.artifactKey }!
    if artifact.fileID == nil {
        try ledger.allocateFile(segmentID: job.id, key: artifact.key, fileID: "synthetic-" + UUID().uuidString.lowercased())
        artifact = ledger.jobs.first { $0.id == job.id }!.artifacts.first { $0.key == selected.artifactKey }!
    }
    let file = GoogleDriveRemoteFile(id: artifact.fileID!, size: String(artifact.byteCount), sha256Checksum: checksum ?? artifact.sha256,
        parents: [ledger.folderID!], ownedByMe: true, shared: false, trashed: false,
        appProperties: ["rfaSchema": "1", "rfaLibraryID": ledger.libraryID.uuidString.lowercased(),
            "rfaSegmentID": job.id.uuidString.lowercased(), "rfaKind": artifact.kind.rawValue,
            "rfaAudioSHA256": job.manifest.sha256, "rfaContentSHA256": artifact.sha256],
        permissions: [.init(id: "owner-123", type: "user", role: "owner")])
    try ledger.recordVerified(segmentID: job.id, key: artifact.key, file: file, in: "owner-123")
    return artifact.kind
}


@MainActor private final class NativeUploads: GoogleDriveUploadTransport {
    var identifier = ""
    var active: [GoogleDriveUploadTaskInfo] = []
    var requests: [URLRequest] = []
    var bodies: [Data] = []
    var resumed: [Int] = []
    var cancelled = Set<Int>()
    var onResume: ((Int) throws -> Void)?
    var resumeFailure: Error?
    var createFailure = false
    var invalidationCount = 0
    var holdInvalidation = false
    var invalidationWaiting: CheckedContinuation<Void, Never>?
    var autoCancelCompletion = true
    var cancelledEvents: [GoogleDriveUploadTaskInfo] = []
    var holdEnumeration = false
    var enumeration: CheckedContinuation<[GoogleDriveUploadTaskInfo], Never>?
    var enumerationSnapshot: [GoogleDriveUploadTaskInfo] = []
    var complete: (@Sendable (GoogleDriveUploadCompletion) -> Void)?
    var finished: (@Sendable (BackgroundSessionEvent) -> Void)?
    var factory: GoogleDriveBackgroundUploads.Factory {
        { identifier, complete, finished in
            self.identifier = identifier; self.complete = complete; self.finished = finished
            return self
        }
    }
    func tasks() async -> [GoogleDriveUploadTaskInfo] {
        let snapshot = active
        if holdEnumeration {
            enumerationSnapshot = snapshot
            return await withCheckedContinuation { enumeration = $0 }
        }
        return snapshot
    }
    func releaseEnumeration() { enumeration?.resume(returning: enumerationSnapshot); enumeration = nil }
    func create(_ request: URLRequest, file: URL, nonce: String) throws -> Int {
        if createFailure { throw ProbeFailure(message: "Synthetic native registration failure") }
        let id = requests.count + 1
        requests.append(request); bodies.append(try Data(contentsOf: file))
        active.append(.init(id: id, nonce: nonce, url: request.url?.absoluteString, method: request.httpMethod,
                            contentRange: request.value(forHTTPHeaderField: "Content-Range"), isSuspended: true))
        return id
    }
    func resume(_ taskID: Int) {
        do { try onResume?(taskID) } catch { resumeFailure = error }
        resumed.append(taskID)
        active = active.map { $0.id == taskID ? .init(id: $0.id, nonce: $0.nonce, url: $0.url,
            method: $0.method, contentRange: $0.contentRange, isSuspended: false) : $0 }
    }
    func cancel(_ taskIDs: Set<Int>) async {
        cancelled.formUnion(taskIDs)
        let removed = active.filter { taskIDs.contains($0.id) }
        active.removeAll { taskIDs.contains($0.id) }
        for task in removed {
            if autoCancelCompletion { complete?(.init(task: task, responseURL: nil, status: nil, transportFailed: true)) }
            else { cancelledEvents.append(task) }
        }
    }
    func invalidateAndCancel() async {
        invalidationCount += 1
        await cancel(Set(active.map(\.id)))
        if holdInvalidation { await withCheckedContinuation { invalidationWaiting = $0 } }
    }
    func releaseInvalidation() { invalidationWaiting?.resume(); invalidationWaiting = nil }
    func emit(_ task: GoogleDriveUploadTaskInfo, code: Int = 200, responseURL: String? = nil, failed: Bool = false) {
        active.removeAll { $0.id == task.id }
        complete?(.init(task: task, responseURL: responseURL ?? task.url, status: code, transportFailed: failed))
    }
}
@MainActor private func settleUploads() async {
    for _ in 0..<20 { await Task.yield() }
    try? await Task.sleep(nanoseconds: 2_000_000)
}
private func backgroundFixture(root: URL, bytes: Data = Data((0..<128).map { UInt8($0) })) throws
    -> (GoogleDriveLibraryLedger, SegmentManifest, GoogleDriveArtifact, URL, GoogleDriveUploadContext) {
    var (ledger, manifest, artifact, file) = try fixture(bytes, root: root)
    try ledger.recordSession(segmentID: manifest.id, key: artifact.key,
                             url: "https://www.googleapis.com/upload/drive/v3/files?upload_id=synthetic-native")
    artifact = ledger.jobs[0].artifacts[0]
    return (ledger, manifest, artifact, file, try GoogleDriveUploadContext(ledger: ledger, manifest: manifest, artifact: artifact))
}
private func backgroundRequest(_ context: GoogleDriveUploadContext, offset: Int64 = 0) -> URLRequest {
    var request = URLRequest(url: URL(string: context.artifact.uploadURL!)!)
    request.httpMethod = "PUT"; request.setValue("Bearer synthetic-private-token", forHTTPHeaderField: "Authorization")
    request.setValue(String(context.artifact.byteCount - offset), forHTTPHeaderField: "Content-Length")
    request.setValue("bytes \(offset)-\(context.artifact.byteCount - 1)/\(context.artifact.byteCount)", forHTTPHeaderField: "Content-Range")
    return request
}

/// A synthetic environment around the actual production loop/client/coordinator.
/// It supplies only immutable generated files, token stubs and URLProtocol data.
private func audioRemote(_ context: GoogleDriveUploadContext) throws -> Data {
    try TransportCodec.encode(GoogleDriveRemoteFile(id: context.artifact.fileID!,
        size: String(context.artifact.byteCount), sha256Checksum: context.artifact.sha256,
        parents: [context.folderID], ownedByMe: true, shared: false, trashed: false,
        appProperties: ["rfaSchema": "1", "rfaLibraryID": context.libraryID.uuidString.lowercased(),
            "rfaSegmentID": context.manifest.id.uuidString.lowercased(), "rfaKind": "audio",
            "rfaAudioSHA256": context.manifest.sha256, "rfaContentSHA256": context.artifact.sha256],
        permissions: [.init(id: context.accountID, type: "user", role: "owner")]))
}

private func requireAudioReceipts(_ ledger: GoogleDriveLibraryLedger,
                                  _ expected: [GoogleDriveUploadContext]) throws {
    try require(ledger.savedAudioCount == expected.count
        && ledger.jobs.flatMap(\.artifacts).filter { $0.verifiedAt != nil }.count == expected.count,
        "HTTP/native completion or an unrelated artifact received audio receipt credit")
    for context in expected {
        let artifact = ledger.jobs.first { $0.id == context.manifest.id }?.artifacts.first { $0.key == context.artifact.key }
        try require(artifact?.kind == .audio && artifact?.fileID == context.artifact.fileID
            && artifact?.sha256 == context.artifact.sha256 && artifact?.byteCount == context.artifact.byteCount
            && artifact?.verifiedAt != nil && artifact?.uploadURL == nil
            && artifact?.verifiedUploadCorrelation == GoogleDriveUploadCorrelation(segmentID: context.manifest.id,
                kind: .audio, manifestSHA256: context.manifest.sha256),
            "Strict receipt was not bound to this exact source audio and stable remote file")
    }
}

@MainActor private final class PipelineProbe {
    var ledger: GoogleDriveLibraryLedger
    var progress = GoogleDriveSyncProgress()
    let native = NativeUploads()
    let clock = RetryClock()
    let directory: URL
    var files: [String: URL] = [:]
    var remotelyCompleted = Set<String>()
    var coordinator: GoogleDriveBackgroundUploads!
    var selectedKinds: [GoogleDriveArtifact.Kind] = []
    init(root: URL, count: Int = 6, transcripts: Bool = false, audioBytes: Int = 8,
         authorizedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) throws {
        let audio = Data(repeating: 1, count: audioBytes), hash = GoogleDriveLibraryLedger.digest(audio)
        let manifests = orderedManifests(count).map { m in
            SegmentManifest(id: m.id, sessionID: m.sessionID, sequence: m.sequence, startedAt: m.startedAt,
                endedAt: m.endedAt, sampleRate: m.sampleRate, frameCount: m.frameCount,
                fileName: m.fileName, byteCount: Int64(audioBytes), sha256: hash)
        }
        ledger = try priorityLedger(manifests, authorizedAt: authorizedAt)
        directory = root.appendingPathComponent(UUID().uuidString)
        for manifest in manifests {
            if transcripts { try addPriorityTranscript(manifest, to: &ledger) }
            let transcript = SegmentTranscript(segmentID: manifest.id, audioSHA256: manifest.sha256,
                locale: "zh-CN", engine: "synthetic-priority", createdAt: manifest.endedAt,
                text: "合成排序回归文字", spans: [])
            for artifact in ledger.jobs.first(where: { $0.id == manifest.id })!.artifacts {
                let bytes: Data
                switch artifact.kind {
                case .audio: bytes = audio
                case .manifest: bytes = try TransportCodec.encode(GoogleDriveLibraryLedger.exportManifest(manifest))
                case .transcriptJSON: bytes = try TransportCodec.encode(transcript)
                case .transcriptText: bytes = GoogleDriveLibraryLedger.readableTranscript(transcript, manifest: manifest)
                }
                let file = root.appendingPathComponent(UUID().uuidString)
                try bytes.write(to: file)
                files[manifest.id.uuidString.lowercased() + "/" + artifact.key] = file
                let id = "pipeline-" + UUID().uuidString.lowercased()
                try ledger.allocateFile(segmentID: manifest.id, key: artifact.key, fileID: id)
                try ledger.recordSession(segmentID: manifest.id, key: artifact.key,
                    url: "https://www.googleapis.com/upload/drive/v3/files?upload_id=" + id)
            }
        }
        // This fixture starts after metadata and derived-record discovery; a
        // bare finishSlice must not erase a still-unaccepted source snapshot.
        let snapshot = progress.snapshot
        progress.acceptSnapshot(manifests, previousIDs: Set(manifests.map(\.id)), request: snapshot)
        for manifest in progress.remaining { try progress.finishRecord(manifest.id, issue: nil) }
        progress.finishSlice(observedRevision: snapshot.revision)
        coordinator = try GoogleDriveBackgroundUploads(directory: directory, libraryID: ledger.libraryID,
            changed: {}, finishedEvents: { _ in }, now: { [clock] in clock.now() }, factory: native.factory)
    }
    /// Isolate audio acceptance from manifest/transcript scheduling. Native
    /// creation/completion still cannot credit a receipt in the real ledger.
    func stageAudioTasks() async throws -> [GoogleDriveUploadContext] {
        var contexts: [GoogleDriveUploadContext] = []
        for job in ledger.jobs {
            let artifact = job.artifacts.first { $0.kind == .audio }!
            let context = try GoogleDriveUploadContext(ledger: ledger, manifest: job.manifest, artifact: artifact)
            try await coordinator.start(request: backgroundRequest(context),
                file: files[job.id.uuidString.lowercased() + "/" + artifact.key]!, offset: 0,
                context: context, isAuthorized: { context.isAuthorized(in: self.ledger) }, check: {})
            contexts.append(context)
        }
        return contexts
    }
    func changeSourceMetadata(_ id: UUID) throws {
        var object = try JSONSerialization.jsonObject(with: TransportCodec.encode(ledger)) as! [String:Any]
        var jobs = object["jobs"] as! [[String:Any]]
        let index = jobs.firstIndex { UUID(uuidString: ($0["manifest"] as! [String:Any])["id"] as! String) == id }!
        var manifest = jobs[index]["manifest"] as! [String:Any]; manifest["sequence"] = (manifest["sequence"] as! Int) + 100
        jobs[index]["manifest"] = manifest
        let revised = try TransportCodec.decode(SegmentManifest.self, from: json(manifest))
        let bytes = try TransportCodec.encode(GoogleDriveLibraryLedger.exportManifest(revised))
        var artifacts = jobs[index]["artifacts"] as! [[String:Any]]
        for i in artifacts.indices where artifacts[i]["kind"] as? String == "manifest" {
            artifacts[i]["sha256"] = GoogleDriveLibraryLedger.digest(bytes); artifacts[i]["byteCount"] = bytes.count
        }
        jobs[index]["artifacts"] = artifacts; object["jobs"] = jobs
        ledger = try TransportCodec.decode(GoogleDriveLibraryLedger.self, from: json(object)); try ledger.validate()
        let artifact = ledger.jobs[index].artifacts.first { $0.kind == .manifest }!
        let file = directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try bytes.write(to: file); files[id.uuidString.lowercased()+"/"+artifact.key] = file
    }
    func installProtocol() {
        MockProtocol.install { [self] request in
            if request.url!.path == "/drive/v3/about" { return try about() }
            if request.url!.path == "/drive/v3/files/folder-123" { return .init(code: 200, data: try folder(ledger)) }
            if request.httpMethod == "GET" {
                let id = request.url!.lastPathComponent
                guard remotelyCompleted.contains(id),
                      let job = ledger.jobs.first(where: { $0.artifacts.contains { $0.fileID == id } }),
                      let artifact = job.artifacts.first(where: { $0.fileID == id }) else { return .init(code: 404) }
                let remote = GoogleDriveRemoteFile(id: id, size: String(artifact.byteCount), sha256Checksum: artifact.sha256,
                    parents: [ledger.folderID!], ownedByMe: true, shared: false, trashed: false,
                    appProperties: ["rfaSchema":"1", "rfaLibraryID": ledger.libraryID.uuidString.lowercased(),
                        "rfaSegmentID":job.id.uuidString.lowercased(), "rfaKind":artifact.kind.rawValue,
                        "rfaAudioSHA256":job.manifest.sha256, "rfaContentSHA256":artifact.sha256],
                    permissions: [.init(id:"owner-123",type:"user",role:"owner")])
                return .init(code: 200, data: try TransportCodec.encode(remote))
            }
            try require(request.httpMethod == "PUT" && request.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes */") == true,
                "Pipeline emitted unexpected ephemeral byte upload")
            return .init(code: 308)
        }
    }
    func perform(_ selected: GoogleDriveSyncProgress.UploadChoice) async throws {
        let job = ledger.jobs.first { $0.id == selected.segmentID }!
        let artifact = job.artifacts.first { $0.key == selected.artifactKey }!
        let file = files[job.id.uuidString.lowercased() + "/" + artifact.key]!
        selectedKinds.append(artifact.kind)
        let client = GoogleDriveClient(http: http(), oauth: Tokens(), accountID: "owner-123", check: {})
        let remote = try await client.upload(file: file, artifact: artifact, manifest: job.manifest,
            folderID: ledger.folderID!, libraryID: ledger.libraryID, backgroundHandoff: { request, source, offset in
                if self.coordinator.completedRecord(for: job.id, artifactKey: artifact.key) != nil {
                    try self.coordinator.deferUnverifiedRetry(for: job.id, artifactKey: artifact.key)
                }
                let current = self.ledger.jobs.first { $0.id == job.id }!.artifacts.first { $0.key == artifact.key }!
                let context = try GoogleDriveUploadContext(ledger: self.ledger, manifest: job.manifest, artifact: current)
                try await self.coordinator.start(request: request, file: source, offset: offset, context: context,
                    isAuthorized: { context.isAuthorized(in: self.ledger) }, check: {})
            }, saveSession: { url in try self.ledger.recordSession(segmentID: job.id, key: artifact.key, url: url) })
        let completed = coordinator.completedRecord(for: job.id, artifactKey: artifact.key)
        try ledger.recordVerified(segmentID: job.id, key: artifact.key, file: remote, in: "owner-123")
        try coordinator.cancelUnauthorized(in:ledger)
        if let completed {
            try require(coordinator.records.contains { $0.nonce == completed.nonce && !$0.cancelled },
                "Successful ledger receipt removed its native correlation before exact retirement")
        }
        if let completed { try coordinator.discardCompleted(nonce: completed.nonce) }
        try coordinator.clearItemRetry(for: job.id, artifactKey: artifact.key)
        try progress.didVerify(selected, in: ledger.jobs)
    }
    @discardableResult
    func readBackOne(check: @escaping () throws -> Void = {}, timeout: (() throws -> TimeInterval)? = nil,
                     validateSource: (GoogleDrivePreflightPin) throws -> Bool = { _ in true }) async throws -> Bool {
        try await coordinator.runCompletedReadback(ledger: { self.ledger }, progress: { self.progress }, check: check) { selected in
            let pin = try GoogleDrivePreflightPin(ledger: self.ledger, selected: selected)
            guard try validateSource(pin) else { throw GoogleDriveLibraryError.changedManifest }
            let client = GoogleDriveClient(http: http(), oauth: Tokens(), accountID: "owner-123", check: check, requestTimeout: timeout)
            try await client.validateAccount()
            try await client.verifyFolder(id: self.ledger.folderID!, libraryID: self.ledger.libraryID)
            let readBack = try await client.readBackCompletedUpload(artifact: pin.artifact, manifest: pin.manifest)
            if case .sessionExpired = readBack {
                try self.ledger.recordSession(segmentID: selected.segmentID, key: selected.artifactKey, url: nil)
            }
            guard case .remote(let remote) = readBack else {
                try self.coordinator.deferUnverifiedRetry(for: selected.segmentID, artifactKey: selected.artifactKey)
                return
            }
            try check()
            guard try validateSource(pin), try pin.reconciled(in: self.ledger) != nil else { throw GoogleDriveLibraryError.changedManifest }
            let prior = self.coordinator.completedRecord(for: selected.segmentID, artifactKey: selected.artifactKey)!
            try self.ledger.recordVerified(segmentID: selected.segmentID, key: selected.artifactKey, file: remote, in: "owner-123")
            try self.coordinator.discardCompleted(nonce: prior.nonce)
            try self.coordinator.clearItemRetry(for: selected.segmentID, artifactKey: selected.artifactKey)
            try self.progress.didVerify(selected, in: self.ledger.jobs)
        }
    }
    @discardableResult
    func recheckLegacyOne(validateSource: (GoogleDrivePreflightPin) throws -> Bool = { _ in true }) async throws -> Bool {
        try await coordinator.runLegacyQuarantineReadback(ledger: { self.ledger }, check: {}) { selected in
            let pin = try GoogleDrivePreflightPin(ledger: self.ledger, selected: selected)
            guard try validateSource(pin) else { throw GoogleDriveLibraryError.changedManifest }
            let client = GoogleDriveClient(http: http(), oauth: Tokens(), accountID: pin.accountID, check: {})
            try await client.validateAccount()
            try await client.verifyFolder(id: pin.folderID, libraryID: pin.libraryID)
            let remote: GoogleDriveRemoteFile?
            if let id = pin.artifact.fileID { remote = try await client.metadata(id) } else { remote = nil }
            guard try validateSource(pin), try pin.reconciled(in: self.ledger) != nil else { throw GoogleDriveLibraryError.changedManifest }
            if let remote {
                try self.ledger.recordVerified(segmentID: selected.segmentID, key: selected.artifactKey, file: remote, in: pin.accountID)
                try self.progress.didVerify(selected, in: self.ledger.jobs)
            } else if !self.coordinator.permitsMissingRemoteRequeue(for: selected.segmentID, artifactKey: selected.artifactKey, in: self.ledger) {
                throw GoogleDriveLibraryError.metadataIncomplete
            }
            try self.coordinator.clearItemRetry(for: selected.segmentID, artifactKey: selected.artifactKey)
        }
    }
    func makeLegacyQuarantine() async throws {
        try await coordinator.runAvailable(ledger: { self.ledger }, progress: { self.progress }, check: {},
            perform: { _ in throw GoogleDriveLibraryError.invalidRemoteFile })
        let state = directory.appendingPathComponent("pipeline.json")
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: state)) as! [String:Any]
        var retries = object["retries"] as! [[String:Any]]
        for i in retries.indices { retries[i].removeValue(forKey: "failureReason") }
        object["retries"] = retries
        try json(object).write(to: state)
        coordinator = try GoogleDriveBackgroundUploads(directory: directory, libraryID: ledger.libraryID,
            changed: {}, finishedEvents: { _ in }, now: { [clock] in clock.now() }, factory: native.factory)
    }
    @discardableResult func fill(check: () throws -> Void = {}) async throws -> Int {
        try await coordinator.runAvailable(ledger: { self.ledger }, progress: { self.progress }, check: check,
            perform: { try await self.perform($0) })
    }
    func finish(_ task: GoogleDriveUploadTaskInfo, code: Int = 200, failed: Bool = false) {
        if code == 200 && !failed, let record = coordinator.records.first(where: { $0.matches(task) }) {
            remotelyCompleted.insert(record.context.artifact.fileID!)
        }
        native.emit(task, code: code, failed: failed)
    }
}

private final class PreflightRouteWorld: @unchecked Sendable {
    let gate: BudgetGate
    var delay: Double
    var fault = "none"
    var trace: [String] = []
    var remoteByID: [String: Data] = [:]
    var nextID = 1
    var folderData: Data
    var accountCalls = 0
    var statusCounts: [String:Int] = [:]
    init(gate: BudgetGate, delay: Double, folderData: Data) { self.gate=gate;self.delay=delay;self.folderData=folderData }
    func route(_ r: URLRequest) throws -> Reply {
        let path=r.url!.path,method=r.httpMethod ?? "GET"
        let phase: String
        if path=="/drive/v3/about" { phase="account" }
        else if path=="/drive/v3/files/generateIds" { phase="allocate_id" }
        else if path=="/drive/v3/files/folder-123" { phase="folder" }
        else if path=="/upload/drive/v3/files" {phase=method=="POST" ? "session_create" : "session_query"}
        else if path.hasPrefix("/drive/v3/files/") {phase="file_lookup"}
        else {throw ProbeFailure(message:"Unexpected synthetic route")}
        trace.append(phase)
        let remaining=try gate.requestTimeout()
        try require(r.timeoutInterval <= remaining+0.001,"Request timeout exceeds finite lease")
        if delay >= remaining {gate.advance(remaining);throw URLError(.timedOut)}
        gate.advance(delay)
        if phase=="account" {
            accountCalls+=1
            if fault=="account_401" {return .init(code:401)}
            return try about(fault=="wrong_account" ? "other-owner" : "owner-123")
        }
        if phase=="folder" {return .init(code:200,data:folderData)}
        if phase=="allocate_id" {defer{nextID+=1};return .init(code:200,data:try json(["ids":["generated-\(nextID)"]]))}
        if phase=="file_lookup" {
            let id=String(path.dropFirst("/drive/v3/files/".count))
            if let data=remoteByID[id] {return .init(code:200,data:data)}
            return .init(code:404)
        }
        if phase=="session_create" {return .init(code:200,headers:["Location":"https://www.googleapis.com/upload/drive/v3/files?upload_id=synthetic-session"])}
        return .init(code:308)
    }
}
@MainActor private final class PreflightExperiment {
    let root:URL
    var ledger:GoogleDriveLibraryLedger
    var progress=GoogleDriveSyncProgress()
    let native=NativeUploads()
    var coordinator:GoogleDriveBackgroundUploads!
    var files:[String:URL]=[:]
    var bytes:[String:Data]=[:]
    var rounds:[[String:Any]]=[]
    var usePin = true
    var pinStore: GoogleDrivePreflightPinStore!
    var denyHandoff=false
    var token=Tokens()
    var chosen:[GoogleDriveSyncProgress.UploadChoice]=[]
    init(root:URL,allocated:Bool=false,withTranscript:Bool=false) throws {
        self.root=root;try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let manifests=orderedManifests(1)
        ledger=try priorityLedger(manifests)
        if withTranscript {try addPriorityTranscript(manifests[0],to:&ledger)}
        try stageAll()
        if allocated {
            let selection=progress.nextUpload(in:ledger.jobs)!
            try ledger.allocateFile(segmentID:selection.segmentID,key:selection.artifactKey,fileID:"initial-file-123")
        }
        pinStore = try GoogleDrivePreflightPinStore(directory: root.appendingPathComponent("pin-control"))
        coordinator=try GoogleDriveBackgroundUploads(directory:root.appendingPathComponent("background"),libraryID:ledger.libraryID,
            changed:{},finishedEvents:{_ in},factory:native.factory)
    }
    func stageAll() throws {
        for job in ledger.jobs {
            for a in job.artifacts {
                let key=job.id.uuidString+"/"+a.key
                if files[key] != nil {continue}
                let data:Data
                switch a.kind {
                case .audio:data=Data(repeating:1,count:Int(a.byteCount))
                case .manifest:data=try TransportCodec.encode(GoogleDriveLibraryLedger.exportManifest(job.manifest))
                case .transcriptJSON:
                    data=try TransportCodec.encode(SegmentTranscript(segmentID:job.id,audioSHA256:job.manifest.sha256,locale:"zh-CN",engine:"synthetic-priority",createdAt:job.manifest.endedAt,text:"合成排序回归文字",spans:[]))
                case .transcriptText:
                    let t=SegmentTranscript(segmentID:job.id,audioSHA256:job.manifest.sha256,locale:"zh-CN",engine:"synthetic-priority",createdAt:job.manifest.endedAt,text:"合成排序回归文字",spans:[])
                    data=GoogleDriveLibraryLedger.readableTranscript(t,manifest:job.manifest)
                }
                try require(GoogleDriveLibraryLedger.digest(data)==a.sha256,"Synthetic fixture digest mismatch")
                let url=root.appendingPathComponent(UUID().uuidString.lowercased()+".synthetic")
                try data.write(to:url);files[key]=url;bytes[key]=data
            }
        }
    }
    func addNewTranscript(_ n:Int) throws {
        let id=UUID(),start=Date(timeIntervalSince1970:1_700_000_100+Double(n)*60)
        let m=SegmentManifest(id:id,sessionID:UUID(),sequence:n+2,startedAt:start,endedAt:start.addingTimeInterval(30),sampleRate:16_000,frameCount:480_000,fileName:id.uuidString.lowercased()+".caf",byteCount:8,sha256:GoogleDriveLibraryLedger.digest(Data(repeating:1,count:8)))
        try ledger.discover(manifests:ledger.jobs.map(\.manifest)+[m],receivedIDs:Set(ledger.jobs.map(\.id)).union([id]))
        try addPriorityTranscript(m,to:&ledger);try stageAll()
        progress.requestDiscovery(prioritizing:m.id)
    }
    func remoteData(for selected:GoogleDriveSyncProgress.UploadChoice,fault:String="none") throws -> Data {
        let job=ledger.jobs.first{$0.id==selected.segmentID}!,a=job.artifacts.first{$0.key==selected.artifactKey}!
        return try json(["id":a.fileID!,"size":String(a.byteCount),"sha256Checksum":fault=="wrong_hash" ? String(repeating:"f",count:64) : a.sha256,"parents":[fault=="wrong_parent" ? "foreign-folder" : "folder-123"],"ownedByMe":true,"shared":fault=="shared_file","trashed":false,"permissions":[["id":"owner-123","type":"user","role":"owner"]],"appProperties":["rfaSchema":"1","rfaLibraryID":ledger.libraryID.uuidString.lowercased(),"rfaSegmentID":job.id.uuidString.lowercased(),"rfaKind":a.kind.rawValue,"rfaContentSHA256":a.sha256,"rfaAudioSHA256":job.manifest.sha256]])
    }
    func persistRoundTrip() throws {
        ledger=try TransportCodec.decode(GoogleDriveLibraryLedger.self,from:TransportCodec.encode(ledger));try ledger.validate()
        pinStore = try GoogleDrivePreflightPinStore(directory: root.appendingPathComponent("pin-control"))
    }
    func run(dedup:Bool,delay:Double=4,fault:String="none",readback:Bool=false,localSeconds:Double=0) async throws -> [String:Any] {
        if usePin { try pinStore.reconcileSources(in: ledger, manifests: ledger.jobs.map(\.manifest), receivedIDs: Set(ledger.jobs.map(\.id))) }
        let peek = try coordinator.nextUpload(in:ledger,progress:progress,allowPipelineFill:!readback,preflight:usePin ? pinStore.pin : nil)
        let completed = peek.map { coordinator.completedRecord(for:$0.segmentID,artifactKey:$0.artifactKey) != nil } ?? false
        let deferred = usePin && pinStore.canDeferDiscovery(selected:peek,completedReadback:completed)
        let gate=BudgetGate(isForeground:false);gate.advance(deferred ? 0 : localSeconds)
        var folderObject=try JSONSerialization.jsonObject(with:folder(ledger)) as! [String:Any]
        if fault=="shared_folder" {folderObject["shared"]=true}
        if fault=="wrong_owner" {folderObject["permissions"]=[["id":"other-owner","type":"user","role":"owner"]]}
        if fault=="wrong_library" {folderObject["appProperties"]=["rfaSchema":"1","rfaLibraryID":UUID().uuidString.lowercased()]}
        if fault=="wrong_schema" {folderObject["appProperties"]=["rfaSchema":"2","rfaLibraryID":ledger.libraryID.uuidString.lowercased()]}
        let world=PreflightRouteWorld(gate:gate,delay:delay,folderData:try json(folderObject));world.fault=fault;world.nextID=rounds.count*100+1
        if readback,let selected=chosen.last {
            let a=ledger.jobs.first{$0.id==selected.segmentID}!.artifacts.first{$0.key==selected.artifactKey}!
            world.remoteByID[a.fileID!]=try remoteData(for:selected,fault:fault)
        }
        MockProtocol.install {try world.route($0)}
        let before=native.resumed.count
        let client=GoogleDriveClient(http:http(),oauth:token,accountID:"owner-123",check:{try gate.check()},requestTimeout:gate.requestTimeout)
        var result="none"
        do {
            try gate.check()
            try await client.validateAccount()
            if !dedup {try await client.ensureFolder(id:"folder-123",libraryID:ledger.libraryID)}
            guard let selected=try coordinator.nextUpload(in:ledger,progress:progress,allowPipelineFill:!readback,preflight:usePin ? pinStore.pin : nil) else {throw ProbeFailure(message:"No synthetic work selected")}
            chosen.append(selected)
            let job=ledger.jobs.first{$0.id==selected.segmentID}!
            var a=job.artifacts.first{$0.key==selected.artifactKey}!
            if usePin, coordinator.completedRecord(for:job.id,artifactKey:a.key)==nil { try pinStore.capture(ledger:ledger,selected:selected) }
            if a.fileID==nil {
                let id=try await client.generateID();try gate.check()
                try ledger.allocateFile(segmentID:job.id,key:a.key,fileID:id)
                if usePin { try pinStore.reconcile(in:ledger) }
                a=ledger.jobs.first{$0.id==job.id}!.artifacts.first{$0.key==selected.artifactKey}!
            }
            let local=files[job.id.uuidString+"/"+a.key]!
            let fingerprint=try RecordingRepository.fingerprint(of:local,while:{(try? gate.check()) != nil})
            guard fingerprint.sha256==a.sha256,fingerprint.byteCount==a.byteCount else {throw GoogleDriveLibraryError.changedManifest}
            if dedup {try await client.ensureFolder(id:"folder-123",libraryID:ledger.libraryID)}
            else {try await client.verifyFolder(id:"folder-123",libraryID:ledger.libraryID)}
            let expected=a
            let remote=try await client.upload(file:local,artifact:a,manifest:job.manifest,folderID:"folder-123",libraryID:ledger.libraryID,backgroundHandoff:{request,file,offset in
                try gate.check()
                if self.denyHandoff {try self.ledger.setEnabled(false)}
                guard let current=self.ledger.jobs.first(where:{$0.id==job.id})?.artifacts.first(where:{$0.key==expected.key}) else {throw GoogleDriveLibraryError.notAuthorized}
                let context=try GoogleDriveUploadContext(ledger:self.ledger,manifest:job.manifest,artifact:current)
                try await self.coordinator.start(request:request,file:file,offset:offset,context:context,isAuthorized:{context.isAuthorized(in:self.ledger)},check:{try gate.check()})
                if self.usePin { try self.pinStore.clear(matching:job.id,key:expected.key) }
            },saveSession:{url in
                try gate.check();try self.ledger.recordSession(segmentID:job.id,key:expected.key,url:url)
                if self.usePin { try self.pinStore.reconcile(in:self.ledger) }
            })
            try gate.check()
            try ledger.recordVerified(segmentID:job.id,key:expected.key,file:remote,in:"owner-123")
            if let r=coordinator.completedRecord(for:job.id,artifactKey:expected.key) {try coordinator.discardCompleted(nonce:r.nonce)}
            try progress.didVerify(selected,in:ledger.jobs)
            result="verified"
        } catch is GoogleDriveUploadHandoff {result="handoff"}
        catch is CancellationError {result="cancelled"}
        catch GoogleDriveLibraryError.changedAccount {result="changed_account"}
        catch GoogleDriveLibraryError.changedManifest {result="changed_manifest"}
        catch GoogleDriveLibraryError.invalidRemoteFile {result="invalid_remote"}
        catch GoogleDriveLibraryError.invalidRemoteFolder {result="invalid_remote_folder"}
        catch GoogleDriveLibraryError.notAuthorized {result="not_authorized"}
        catch GoogleDriveLibraryError.invalidState {result="invalid_state"}
        catch GoogleDriveError.needsSignIn {result="needs_sign_in"}
        catch {result="unexpected_error";throw ProbeFailure(message:"Unexpected safe error type "+String(reflecting:type(of:error)))}
        let row:[String:Any]=["outcome":result,"discoveryDeferred":deferred,"elapsedVirtualSeconds":gate.time,"requestPhases":world.trace,"requests":world.trace.count,"nativeRegistered":native.resumed.count-before,"verifiedReceiptCount":ledger.jobs.flatMap(\.artifacts).filter{$0.verifiedAt != nil}.count,"allocatedPendingCount":ledger.jobs.flatMap(\.artifacts).filter{$0.verifiedAt==nil && $0.fileID != nil}.count,"sessionSavedCount":ledger.jobs.flatMap(\.artifacts).filter{$0.uploadURL != nil}.count,"finiteBudgetSeconds":19]
        rounds.append(row);return row
    }
    func finishNative() async {
        for task in Array(native.active) {native.emit(task,code:200)}
        await settleUploads()
    }
}

/// One pending audio artifact; all bytes and metadata are synthetic. Establish
/// the failure and both D5 cooldowns through the actual production operations,
/// then age only their persisted timestamps to avoid a real 60-second test wait.
@MainActor private func itemCooldownFixture(root: URL, sharedRemaining: TimeInterval,
                                            itemRemaining: TimeInterval) async throws
    -> (PipelineProbe, GoogleDriveScheduleAdmissionProbe, Date) {
    let fixture = try PipelineProbe(root: root, count: 1)
    fixture.installProtocol()
    let job = fixture.ledger.jobs[0]
    for artifact in job.artifacts where artifact.kind != .audio {
        fixture.remotelyCompleted.insert(artifact.fileID!)
        try await fixture.perform(.init(segmentID: job.id, artifactKey: artifact.key, isPrioritySmall: false))
    }
    try require(fixture.ledger.jobs.flatMap(\.artifacts).filter { $0.verifiedAt == nil }.count == 1,
        "Item recovery fixture must have no healthy peer able to hide its lost wake")
    _ = try await fixture.coordinator.runAvailable(ledger: { fixture.ledger }, progress: { fixture.progress },
        check: {}, maximumOperations: 1) { _ in throw URLError(.cannotConnectToHost) }
    let pipeline = fixture.directory.appendingPathComponent("pipeline.json")
    var object = try JSONSerialization.jsonObject(with: Data(contentsOf: pipeline)) as! [String: Any]
    var retries = object["retries"] as! [[String: Any]]
    retries[0]["failures"] = 10
    retries[0]["retryAfter"] = Int64(Date(timeIntervalSinceNow: 3_600).timeIntervalSince1970 * 1_000)
    object["retries"] = retries; try json(object).write(to: pipeline)
    fixture.coordinator = try GoogleDriveBackgroundUploads(directory: fixture.directory, libraryID: fixture.ledger.libraryID,
        changed: {}, finishedEvents: { _ in }, now: { fixture.clock.now() }, factory: fixture.native.factory)
    let probe = GoogleDriveScheduleAdmissionProbe(ledger: fixture.ledger, progress: fixture.progress,
        background: fixture.coordinator, http: http(), oauth: Tokens())
    probe.networkPath = .nonCellular
    MockProtocol.install { _ in throw URLError(.cannotConnectToHost) }
    try await probe.recoverNetworkAtOpportunity(token: 0, lease: .init())
    try require(probe.ledger.retryAfter == nil && probe.ledger.recoveryProbeAt != nil
        && fixture.coordinator.itemRetries.count == 1 && fixture.coordinator.itemRetries[0].recoveryProbeAt != nil
        && fixture.coordinator.itemRetries[0].retryFailureKind == .recoverableNetwork
        && fixture.coordinator.itemRetries[0].retryAfter.timeIntervalSinceNow > 3_590,
        "Actual failed item D5 did not retain the hour retry and both cooldowns")
    let anchor = Date()
    let sharedDate = anchor.addingTimeInterval(sharedRemaining - 60)
    let itemDate = anchor.addingTimeInterval(itemRemaining - 60)
    var ledgerJSON = try JSONSerialization.jsonObject(with: TransportCodec.encode(probe.ledger)) as! [String: Any]
    ledgerJSON["recoveryProbeAt"] = Int64(sharedDate.timeIntervalSince1970 * 1_000)
    probe.ledger = try TransportCodec.decode(GoogleDriveLibraryLedger.self, from: json(ledgerJSON))
    object = try JSONSerialization.jsonObject(with: Data(contentsOf: pipeline)) as! [String: Any]
    retries = object["retries"] as! [[String: Any]]
    retries[0]["recoveryProbeAt"] = Int64(itemDate.timeIntervalSince1970 * 1_000)
    object["retries"] = retries; try json(object).write(to: pipeline)
    fixture.clock.followWallClock()
    fixture.coordinator = try GoogleDriveBackgroundUploads(directory: fixture.directory, libraryID: fixture.ledger.libraryID,
        changed: {}, finishedEvents: { _ in }, now: { fixture.clock.now() }, factory: fixture.native.factory)
    probe.backgroundUploads = fixture.coordinator
    fixture.ledger = probe.ledger
    fixture.installProtocol()
    probe.executesScheduledRounds = true
    probe.advance = { [weak probe] in
        guard let probe else { throw CancellationError() }
        fixture.ledger = probe.ledger; fixture.progress = probe.progress
        _ = try await fixture.fill(check: { try probe.checkWork(0) })
        probe.ledger = fixture.ledger; probe.progress = fixture.progress
    }
    return (fixture, probe, anchor.addingTimeInterval(max(sharedRemaining, itemRemaining)))
}

@MainActor private func reviseSyntheticItemRetry(_ fixture: PipelineProbe, _ probe: GoogleDriveScheduleAdmissionProbe,
                                                 update: (inout [String: Any]) -> Void) throws {
    let pipeline = fixture.directory.appendingPathComponent("pipeline.json")
    var object = try JSONSerialization.jsonObject(with: Data(contentsOf: pipeline)) as! [String: Any]
    var retries = object["retries"] as! [[String: Any]]
    try require(retries.count == 1, "Expected only one synthetic item retry")
    update(&retries[0]); object["retries"] = retries
    try json(object).write(to: pipeline)
    fixture.coordinator = try GoogleDriveBackgroundUploads(directory: fixture.directory, libraryID: fixture.ledger.libraryID,
        changed: {}, finishedEvents: { _ in }, now: { fixture.clock.now() }, factory: fixture.native.factory)
    probe.backgroundUploads = fixture.coordinator
}

@main @MainActor private struct Probe {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var cases = 0, failures: [String] = []
        var preparationEvidence: [String: Any] = [:]
        var accountPhaseEvidence: [[String: Any]] = []
        var completionEvidence: [String: Any] = [:]
        var workerDiagnosticAssertions = 0
        let caseFilter = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : ""
        func test(_ name: String, _ operation: () async throws -> Void) async {
            guard caseFilter.isEmpty || name.contains(caseFilter) else { return }
            cases += 1
            do { try await operation() } catch { failures.append(name + ": " + String(describing: error)) }
        }
        await test("REC-38 cold foreground waits for first path and credential pause gates remain closed") {
            let fixture = try PipelineProbe(root: root, count: 1)
            let probe = GoogleDriveScheduleAdmissionProbe(ledger: fixture.ledger, progress: fixture.progress,
                background: fixture.coordinator, http: http(), oauth: Tokens())
            probe.didBecomeActive()
            try require(probe.foregroundRecoveryAwaitingPath && !probe.networkRecoveryRequested && probe.resumeRequests == 1,
                "Unknown cold path lost foreground event or issued an early probe")
            probe.networkPathDidChange(.nonCellular, restored: false)
            try require(probe.networkRecoveryRequested && !probe.foregroundRecoveryAwaitingPath && probe.scheduleRequests == 1,
                "First available snapshot did not consume the genuine foreground opportunity")
            probe.networkRecoveryRequested = false
            probe.networkPathDidChange(.nonCellular, restored: false)
            probe.resume()
            try require(!probe.networkRecoveryRequested && probe.scheduleRequests == 1, "Ordinary resume invented recovery")
            probe.oauth.hasCredential = false
            probe.networkPathDidChange(.nonCellular, restored: true)
            try require(!probe.networkRecoveryRequested && probe.scheduleRequests == 1, "Missing credential permitted recovery")
            probe.oauth.hasCredential = true
            try probe.ledger.setEnabled(false)
            probe.didBecomeActive()
            try require(!probe.networkRecoveryRequested && probe.scheduleRequests == 1, "Paused foreground permitted recovery")
            probe.ledger.revoke()
            probe.networkPathDidChange(.nonCellular, restored: true)
            try require(!probe.networkRecoveryRequested && probe.scheduleRequests == 1, "Revoked grant permitted recovery")
        }
        await test("REC-38 hour network backoff gets one actual account recovery and keeps cooldown") {
            let fixture = try PipelineProbe(root: root, count: 1)
            var ledger = fixture.ledger
            let start = Date()
            for _ in 0..<10 { ledger.recordFailure(at: start, kind: .recoverableNetwork) }
            let original = ledger
            let probe = GoogleDriveScheduleAdmissionProbe(ledger: ledger, progress: fixture.progress,
                background: fixture.coordinator, http: http(), oauth: Tokens())
            let trace = Trace()
            MockProtocol.install { request in
                trace.append(request)
                try require(request.httpMethod == "GET" && request.url?.path == "/drive/v3/about", "Recovery mutated remote data")
                return try about()
            }
            try await probe.recoverNetworkAtOpportunity(token: 0, lease: .init())
            try require(trace.count { _ in true } == 1 && probe.ledger.retryAfter == nil && probe.ledger.failureCount == 0,
                "Recovered path remained behind hour backoff")
            try require(probe.ledger.jobs == original.jobs && probe.ledger.authorizedAt == original.authorizedAt,
                "Account recovery changed an item or grant")
            probe.ledger.recordFailure(at: start, kind: .recoverableNetwork)
            try await probe.recoverNetworkAtOpportunity(token: 0, lease: .init())
            try require(trace.count { _ in true } == 1 && probe.ledger.retryAfter != nil, "Flapping bypassed cooldown")
        }
        await test("REC-39 recovery signal inside cooldown reaches native without old hour wait") {
            let fixture = try PipelineProbe(root: root, count: 1)
            var ledger = fixture.ledger
            for _ in 0..<10 { ledger.recordFailure(kind: .recoverableNetwork) }
            try require(ledger.reserveNetworkRecovery(at: Date(timeIntervalSinceNow: -59.8)), "Cooldown fixture failed")
            let original = ledger
            let probe = GoogleDriveScheduleAdmissionProbe(ledger: ledger, progress: fixture.progress,
                background: fixture.coordinator, http: http(), oauth: Tokens())
            probe.networkPath = .nonCellular
            fixture.installProtocol()
            let started = ProcessInfo.processInfo.systemUptime
            probe.checkAfterNetworkRecovery()
            try require(probe.networkRecoveryRetryAt != nil && probe.scheduleRequests == 0,
                "Early recovery signal bypassed cooldown")
            try require(PhoneBackgroundSync.shared.requested.last == probe.networkRecoveryRetryAt,
                "Recovery retained an old BG request instead of requesting its safe cooldown date")
            for _ in 0..<20 { probe.checkAfterNetworkRecovery() }
            try require(probe.scheduleRequests == 0, "Repeated signals spun the worker")
            for _ in 0..<100 where probe.scheduleRequests == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
            try require(probe.scheduleRequests == 1 && probe.networkRecoveryRequested && probe.networkRecoveryRetryAt == nil,
                "Cooldown signal was lost behind the hour backoff")
            try await probe.recoverNetworkAtOpportunity(token: 0, lease: .init())
            try require(probe.ledger.retryAfter == nil, "Successful account recovery did not clear its own backoff")
            fixture.ledger = probe.ledger
            _ = try await fixture.fill()
            try require(!fixture.native.resumed.isEmpty && ProcessInfo.processInfo.systemUptime - started < 3,
                "Recovered synthetic queue did not promptly reach first native registration")
            try require(probe.ledger.authorizedAt == original.authorizedAt && probe.ledger.jobs == original.jobs,
                "Recovery changed authorization, IDs or sessions")
            try require(fixture.ledger.savedAudioCount == 0, "Native registration fabricated a strict receipt")
        }
        await test("REC-39 queued recovery rechecks a new 429 before requesting Google") {
            let fixture = try PipelineProbe(root: root, count: 1)
            var ledger = fixture.ledger
            for _ in 0..<10 { ledger.recordFailure(kind: .recoverableNetwork) }
            try require(ledger.reserveNetworkRecovery(at: Date(timeIntervalSinceNow: -59.8)), "Cooldown fixture failed")
            let probe = GoogleDriveScheduleAdmissionProbe(ledger: ledger, progress: fixture.progress,
                background: fixture.coordinator, http: http(), oauth: Tokens())
            probe.networkPath = .nonCellular
            probe.checkAfterNetworkRecovery()
            probe.ledger.recordFailure(kind: .other)
            let throttled = probe.ledger
            let trace = Trace()
            MockProtocol.install { request in trace.append(request); throw ProbeFailure(message: "429 issued network request") }
            for _ in 0..<100 where probe.scheduleRequests == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
            try await probe.recoverNetworkAtOpportunity(token: 0, lease: .init())
            try require(probe.ledger == throttled && trace.count { _ in true } == 0,
                "Queued network signal shortened the newer server backoff")
        }
        for sharedIsLater in [false, true] {
            await test("REC-39 item cooldown signal automatically reaches native sharedLater=\(sharedIsLater)") {
                let (fixture, probe, due) = try await itemCooldownFixture(root: root,
                    sharedRemaining: sharedIsLater ? 0.5 : 0.15, itemRemaining: sharedIsLater ? 0.15 : 0.5)
                let original = probe.ledger
                let previousState = UIApplication.shared.applicationState
                UIApplication.shared.applicationState = .active
                defer { UIApplication.shared.applicationState = previousState }
                let started = ProcessInfo.processInfo.systemUptime
                try require(probe.canCheckNetworkRecoveryFromProduction(),
                    "Network recovery action disappeared while the sole item remained in cooldown")
                probe.checkAfterNetworkRecovery()
                try require(probe.networkRecoveryRetryAt != nil && probe.scheduleRequests == 0,
                    "Sole deferred item's cooldown hid its recovery signal; no continuation was retained")
                try require(abs(probe.networkRecoveryRetryAt!.timeIntervalSince(due)) < 0.003,
                    "Recovery must wait for max(shared cooldown, item cooldown), not either earlier date")
                for _ in 0..<20 { probe.checkAfterNetworkRecovery() }
                try require(probe.scheduleRequests == 0 && fixture.native.resumed.isEmpty,
                    "Repeated signals bypassed an item/shared cooldown")
                // No manual recovery, ordinary resume or fill occurs after the
                // signal: the actual timer calls the actual scheduled round.
                for _ in 0..<300 where fixture.native.resumed.isEmpty {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                await probe.work?.value
                try require(!fixture.native.resumed.isEmpty && ProcessInfo.processInfo.systemUptime - started < 4,
                    "Retained item signal failed to reach native without another external event")
                try require(probe.ledger.authorizedAt == original.authorizedAt
                    && probe.ledger.recordingScope == original.recordingScope
                    && probe.ledger.jobs == original.jobs && probe.ledger.savedAudioCount == 0,
                    "Timer recovery changed authorization/session IDs or invented a cloud receipt")
                try require(probe.scheduleRequests <= 2, "Item cooldown continuation spun the scheduler")
            }
        }
        await test("REC-39 item cooldown queued round rechecks a later item deadline") {
            let (fixture, probe, _) = try await itemCooldownFixture(root: root, sharedRemaining: -0.2, itemRemaining: -0.2)
            let previousState = UIApplication.shared.applicationState
            UIApplication.shared.applicationState = .active
            defer { UIApplication.shared.applicationState = previousState }
            probe.checkAfterNetworkRecovery()
            try require(probe.work != nil, "Eligible signal failed to queue the production round")
            // The scheduled Task has not entered yet. Another durable attempt
            // moves this item's cooldown before it reaches D5 admission.
            let extended = Date(timeIntervalSinceNow: -59.5)
            try reviseSyntheticItemRetry(fixture, probe) { $0["recoveryProbeAt"] = Int64(extended.timeIntervalSince1970 * 1_000) }
            await probe.work?.value
            try require(fixture.native.resumed.isEmpty && probe.networkRecoveryRetryAt != nil,
                "Queued round consumed the signal after the item's cooldown changed")
            for _ in 0..<300 where fixture.native.resumed.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
            await probe.work?.value
            try require(fixture.native.resumed.count == 1 && probe.scheduleRequests <= 2,
                "Later item cooldown was not automatically continued exactly once")
        }
        for changedState in ["pause", "revoke", "credential", "item429"] {
            await test("REC-39 item cooldown timer rechecks current \(changedState)") {
                let (fixture, probe, _) = try await itemCooldownFixture(root: root, sharedRemaining: 0.2, itemRemaining: 0.3)
                let previousState = UIApplication.shared.applicationState
                UIApplication.shared.applicationState = .active
                defer { UIApplication.shared.applicationState = previousState }
                probe.checkAfterNetworkRecovery()
                try require(probe.networkRecoveryRetryAt != nil, "Expected a retained item recovery before state changed")
                switch changedState {
                case "pause": try probe.ledger.setEnabled(false)
                case "revoke": probe.ledger.revoke()
                case "credential": probe.oauth.hasCredential = false
                default: try reviseSyntheticItemRetry(fixture, probe) { $0["retryFailureKind"] = "other" }
                }
                let guarded = probe.ledger
                let trace = Trace()
                MockProtocol.install { request in trace.append(request); throw ProbeFailure(message: "Stale recovery sent after permission/failure changed") }
                try require(!probe.canCheckNetworkRecoveryFromProduction(), "UI offered recovery without current permission/network failure")
                for _ in 0..<100 where probe.networkRecoveryRetryAt != nil { try await Task.sleep(nanoseconds: 10_000_000) }
                await probe.work?.value
                try require(trace.count { _ in true } == 0 && fixture.native.resumed.isEmpty && probe.ledger == guarded,
                    "Timer bypassed the current pause/revoke/credential/429 state")
            }
        }
        await test("REC-38 HTTP throttling and paused library never issue opportunity requests") {
            for stopped in [false, true] {
                let fixture = try PipelineProbe(root: root, count: 1)
                var ledger = fixture.ledger
                ledger.recordFailure(kind: stopped ? .recoverableNetwork : .other)
                if stopped { try ledger.setEnabled(false) }
                let probe = GoogleDriveScheduleAdmissionProbe(ledger: ledger, progress: fixture.progress,
                    background: fixture.coordinator, http: http(), oauth: Tokens())
                let trace = Trace()
                MockProtocol.install { request in trace.append(request); throw ProbeFailure(message: "Unexpected request") }
                try await probe.recoverNetworkAtOpportunity(token: 0, lease: .init())
                try require(trace.count { _ in true } == 0 && probe.ledger == ledger,
                    "HTTP retry or pause was bypassed")
            }
        }
        await test("REC-38 item network recovery clears only matching transport retry and retains 429") {
            let fixture = try PipelineProbe(root: root, count: 2)
            var choices: [GoogleDriveSyncProgress.UploadChoice] = []
            _ = try await fixture.coordinator.runAvailable(ledger: { fixture.ledger }, progress: { fixture.progress },
                check: {}, maximumOperations: 2) { selected in
                choices.append(selected)
                if choices.count == 1 { throw URLError(.notConnectedToInternet) }
                throw GoogleDriveError.http(429)
            }
            try require(choices.count == 2 && fixture.coordinator.itemRetries.count == 2, "Retry fixture failed")
            fixture.coordinator = try GoogleDriveBackgroundUploads(directory: fixture.directory, libraryID: fixture.ledger.libraryID,
                changed: {}, finishedEvents: { _ in }, now: { fixture.clock.now() }, factory: fixture.native.factory)
            let originalJobs = fixture.ledger.jobs
            let retryStatus = fixture.coordinator.retryPresentation(in: fixture.ledger)
            try require(retryStatus.networkFailure && retryStatus.lastFailureAt.map { abs($0.timeIntervalSince(fixture.clock.now())) < 0.001 } == true,
                "Item network failure lost its typed state or failure time")
            let probe = GoogleDriveScheduleAdmissionProbe(ledger: fixture.ledger, progress: fixture.progress,
                background: fixture.coordinator, http: http(), oauth: Tokens())
            let trace = Trace()
            MockProtocol.install { request in
                trace.append(request)
                try require(request.httpMethod == "GET", "Recovery attempted upload/session mutation")
                if request.url?.path == "/drive/v3/about" { return try about() }
                if request.url?.lastPathComponent == "folder-123" { return .init(code: 200, data: try folder(probe.ledger)) }
                return .init(code: 404)
            }
            try await probe.recoverNetworkAtOpportunity(token: 0, lease: .init())
            try require(trace.count { _ in true } == 3 && fixture.coordinator.itemRetries.count == 1,
                "Item did not receive bounded read-only recovery")
            let retained = fixture.coordinator.itemRetries[0]
            try require(retained.segmentID == choices[1].segmentID && retained.artifactKey == choices[1].artifactKey
                && retained.retryFailureKind == .other && probe.ledger.jobs == originalJobs,
                "Recovery cleared 429, changed a session or invented a receipt")
            try await probe.recoverNetworkAtOpportunity(token: 0, lease: .init())
            try require(!fixture.coordinator.retryPresentation(in: probe.ledger).networkFailure,
                "Retained HTTP 429 was mislabeled as network connection failure")
            try require(trace.count { _ in true } == 3, "429 became another opportunity probe")
        }
        await test("REC-38 failed item recovery persists cooldown across restart and does not walk peers") {
            let fixture = try PipelineProbe(root: root, count: 2)
            _ = try await fixture.coordinator.runAvailable(ledger: { fixture.ledger }, progress: { fixture.progress },
                check: {}, maximumOperations: 2) { _ in throw URLError(.secureConnectionFailed) }
            let probe = GoogleDriveScheduleAdmissionProbe(ledger: fixture.ledger, progress: fixture.progress,
                background: fixture.coordinator, http: http(), oauth: Tokens())
            let trace = Trace()
            MockProtocol.install { request in trace.append(request); return .init(code: 429) }
            try await probe.recoverNetworkAtOpportunity(token: 0, lease: .init())
            try require(trace.count { _ in true } == 1, "First recovery did not hit server throttle")
            probe.ledger = try TransportCodec.decode(GoogleDriveLibraryLedger.self, from: TransportCodec.encode(probe.ledger))
            probe.backgroundUploads = try GoogleDriveBackgroundUploads(directory: fixture.directory, libraryID: fixture.ledger.libraryID,
                changed: {}, finishedEvents: { _ in }, now: { fixture.clock.now() }, factory: fixture.native.factory)
            try await probe.recoverNetworkAtOpportunity(token: 0, lease: .init())
            try require(trace.count { _ in true } == 1 && probe.backgroundUploads?.itemRetries.count == 2,
                "Restart or peer selection bypassed shared recovery cooldown")
        }
        await test("credential revocation timeout retains a cold retry token but never upload access") {
            let store = RevocationStore(), transport = http(), trace = Trace()
            MockProtocol.install { request in
                trace.append(request)
                try require(request.url?.path == "/revoke", "Revocation sent an unrelated request")
                if trace.count({ _ in true }) == 1 { throw URLError(.timedOut) }
                return .init(code: 200)
            }
            do { _ = try await store.revoke(http: transport); throw ProbeFailure(message: "Timeout unexpectedly confirmed") }
            catch let error as URLError { try require(error.code == .timedOut, "Wrong natural failure") }
            let retained = try JSONDecoder().decode(GoogleDriveCredential.self, from: store.bytes!)
            try require(retained.revocationOnly == true && !retained.permitsAccessToken, "Cold record remained an upload credential")
            let refresh = GoogleDriveCredentialRefresh()
            do {
                _ = try await refresh.accessToken(current: retained, accountID: "owner-123", http: transport,
                    timeout: 10, isCurrent: { true }, commit: { _ in throw ProbeFailure(message: "Revoked token refreshed") })
                throw ProbeFailure(message: "Revocation-only token returned upload access")
            } catch GoogleDriveError.needsSignIn { }
            try require(trace.count({ _ in true }) == 1, "Denied upload still made a network request")
            let confirmed = try await store.revoke(http: transport)
            try require(confirmed && trace.count({ _ in true }) == 2 && store.bytes == nil && store.removes == 1,
                "Explicit retry did not issue the second POST and clear only after confirmation")
        }
        await test("credential revocation HTTP rejection retains exact retry purpose") {
            let store = RevocationStore(), transport = http(), trace = Trace()
            MockProtocol.install { request in trace.append(request); return .init(code: 503) }
            let confirmed = try await store.revoke(http: transport)
            try require(!confirmed && store.current?.revocationOnly == true && store.removes == 0,
                "Non-200 response discarded the only retry token")
            try require(trace.count({ _ in true }) == 1, "Revoke POST was automatically replayed")
        }
        await test("credential revocation stale entry cannot overwrite a new login before request") {
            let transport = http(), trace = Trace()
            var writes = 0, removes = 0
            MockProtocol.install { request in trace.append(request); return .init(code: 200) }
            do {
                _ = try await GoogleDriveCredentialRevocation.revoke(current: syntheticCredential(), http: transport,
                    persist: { _ in writes += 1 }, remove: { removes += 1 }, check: { throw CancellationError() })
                throw ProbeFailure(message: "Stale credential revision was accepted")
            } catch is CancellationError { }
            try require(writes == 0 && removes == 0 && trace.count({ _ in true }) == 0,
                "Old revoke touched the new credential before checking revision")
        }
        await test("credential revocation storage failures cannot send or destroy retry evidence") {
            let store = RevocationStore(), transport = http(), trace = Trace()
            MockProtocol.install { request in trace.append(request); return .init(code: 200) }
            store.failPersist = true
            do { _ = try await store.revoke(http: transport); throw ProbeFailure(message: "Missing durable stop purpose accepted") }
            catch GoogleDriveError.credentials { }
            try require(trace.count({ _ in true }) == 0, "POST started before durable purpose persisted")
            store.failPersist = false; store.failRemove = true
            do { _ = try await store.revoke(http: transport); throw ProbeFailure(message: "Deletion failure reported confirmation") }
            catch GoogleDriveError.credentials { }
            try require(store.current?.revocationOnly == true && store.removes == 0,
                "Failed cleanup lost the protected retry record")
        }
        await test("credential revocation late success cannot delete a newly committed login") {
            let store = RevocationStore(), transport = http(), hold = AccountReplyHold()
            MockProtocol.install { _ in _ = try hold.reply(); return .init(code: 200) }
            let old = Task { @MainActor in try await store.revoke(http: transport) }
            try await awaitPhaseHold { hold.entered }
            var replacement = syntheticCredential(); replacement.accountID = "new-synthetic-account"
            try store.replace(replacement)
            hold.release()
            do { _ = try await old.value; throw ProbeFailure(message: "Old revoke accepted new credential revision") }
            catch is CancellationError { }
            try require(store.current?.accountID == "new-synthetic-account" && store.current?.permitsAccessToken == true && store.removes == 0,
                "Old revoke response deleted or fenced a newer login")
        }
        await test("credential revocation absent legacy token never fakes remote confirmation") {
            let store = RevocationStore(), transport = http(), trace = Trace(); store.bytes = nil
            MockProtocol.install { request in trace.append(request); return .init(code: 200) }
            let confirmed = try await store.revoke(http: transport)
            try require(!confirmed && trace.count({ _ in true }) == 0 && store.removes == 0,
                "Missing token invented a remote confirmation or request")
        }
        await test("credential revocation original v1 record remains active until explicit stop") {
            let original = try JSONEncoder().encode(syntheticCredential())
            var object = try JSONSerialization.jsonObject(with: original) as! [String: Any]
            object.removeValue(forKey: "revocationOnly")
            let legacy = try JSONDecoder().decode(GoogleDriveCredential.self, from: JSONSerialization.data(withJSONObject: object))
            try require(legacy.revocationOnly == nil && legacy.permitsAccessToken,
                "Original Keychain schema could not reconnect or continue its existing grant")
            var pending = legacy; pending.revocationOnly = true
            let cold = try JSONDecoder().decode(GoogleDriveCredential.self, from: JSONEncoder().encode(pending))
            try require(!cold.permitsAccessToken, "Cold restart forgot the revocation fence")
        }
        await test("REC-39 cold credential requirement clears only after committed same-account reconnect") {
            for failsCommit in [false, true] {
                var ledger = GoogleDriveLibraryLedger()
                try ledger.bind(accountID: "owner-123", label: "Original")
                try ledger.authorize(.futureOnly, knownIDs: [UUID()])
                try ledger.allocateFolder("folder-123")
                ledger.recordCredentialRequired(at: Date(timeIntervalSince1970: 1_800_000_000))
                try ledger.setEnabled(false)
                ledger = try TransportCodec.decode(GoogleDriveLibraryLedger.self, from: TransportCodec.encode(ledger))
                let original = ledger
                let probe = GoogleDriveIdentityTransactionProbe(ledger: ledger, http: http())
                probe.oauth.failCommit = failsCommit
                MockProtocol.install { _ in try about() }
                probe.connect(); await probe.work?.value
                try require((probe.ledger.credentialRequiredAt != nil) == failsCommit,
                    "Cold credential requirement was cleared before credential commit or retained after success")
                try require(!probe.ledger.enabled && probe.schedules == 0,
                    "Credential repair automatically restarted recording uploads")
                try require(probe.ledger.recordingScope == original.recordingScope
                    && probe.ledger.authorizedAt == original.authorizedAt && probe.ledger.folderID == original.folderID
                    && probe.ledger.baselineIDs == original.baselineIDs && probe.ledger.jobs == original.jobs,
                    "Credential repair changed the original grant or queue")
            }
        }
        await test("credential revocation fresh same account connection stays paused until explicit continue") {
            var ledger = GoogleDriveLibraryLedger()
            try ledger.bind(accountID: "owner-123", label: "Original")
            try ledger.authorize(.futureOnly, knownIDs: [UUID()])
            try ledger.allocateFolder("folder-123"); ledger.revoke()
            let original = ledger
            let probe = GoogleDriveIdentityTransactionProbe(ledger: ledger, http: http())
            MockProtocol.install { _ in try about() }
            probe.connect(); await probe.work?.value
            try require(probe.oauth.commits == 1 && !probe.ledger.revokedLocally && !probe.ledger.remoteRevocationConfirmed,
                "Fresh committed login did not supersede only the local pending revoke")
            try require(!probe.ledger.enabled && probe.schedules == 0,
                "Reconnection silently enabled recording uploads")
            try require(probe.ledger.libraryID == original.libraryID && probe.ledger.folderID == original.folderID
                && probe.ledger.recordingScope == original.recordingScope && probe.ledger.authorizedAt == original.authorizedAt
                && probe.ledger.baselineIDs == original.baselineIDs && probe.ledger.jobs == original.jobs,
                "Reconnection changed the original library or recording grant")
            probe.continueSync()
            try require(probe.ledger.enabled && probe.schedules == 1, "Explicit continue failed after fresh reauthorization")
        }
        await test("credential revocation failed credential commit leaves pending grant fenced") {
            var ledger = GoogleDriveLibraryLedger()
            try ledger.bind(accountID: "owner-123", label: "Original")
            try ledger.authorize(.existingAndFuture, knownIDs: []); ledger.revoke()
            let probe = GoogleDriveIdentityTransactionProbe(ledger: ledger, http: http()); probe.oauth.failCommit = true
            MockProtocol.install { _ in try about() }
            probe.connect(); await probe.work?.value
            try require(probe.ledger.revokedLocally && !probe.ledger.enabled && probe.oauth.commits == 0,
                "Failed Keychain commit cleared the pending revoke")
            probe.continueSync()
            try require(!probe.ledger.enabled && probe.schedules == 0, "Failed login resumed old recording grant")
            try require(probe.writes.count == 2 && probe.writes.allSatisfy { $0.revokedLocally && !$0.enabled },
                "Account fence was not persisted before credential commit")
        }
        await test("credential revocation failed post credential ledger write cannot resume old active token") {
            var ledger = GoogleDriveLibraryLedger()
            try ledger.bind(accountID: "owner-123", label: "Original")
            try ledger.authorize(.existingAndFuture, knownIDs: []); ledger.revoke()
            let probe = GoogleDriveIdentityTransactionProbe(ledger: ledger, http: http()); probe.failWriteNumber = 3
            MockProtocol.install { _ in try about() }
            probe.connect(); await probe.work?.value
            try require(probe.isConnected && probe.oauth.commits == 1 && probe.ledger.revokedLocally && !probe.ledger.enabled,
                "Post-credential persistence failure did not retain paused pending state")
            probe.continueSync()
            try require(!probe.ledger.enabled && probe.schedules == 0,
                "Continue cleared revoke based on a locally active Keychain credential alone")
        }
        await test("credential revocation different account cannot commit or replace original identity") {
            var ledger = GoogleDriveLibraryLedger()
            try ledger.bind(accountID: "owner-123", label: "Original")
            try ledger.authorize(.existingAndFuture, knownIDs: []); ledger.revoke()
            let original = ledger
            let probe = GoogleDriveIdentityTransactionProbe(ledger: ledger, http: http())
            MockProtocol.install { _ in try about("different-synthetic-owner") }
            probe.connect(); await probe.work?.value
            try require(probe.oauth.commits == 0 && probe.ledger == original && !probe.ledger.enabled,
                "Different account crossed the immutable account fence")
        }
        await test("credential revocation unscoped failed reconnect cannot authorize using stale active credential") {
            var ledger = GoogleDriveLibraryLedger()
            try ledger.bind(accountID: "owner-123", label: "Original"); ledger.revoke()
            let probe = GoogleDriveIdentityTransactionProbe(ledger: ledger, http: http()); probe.failWriteNumber = 3
            MockProtocol.install { _ in try about() }
            probe.connect(); await probe.work?.value
            try require(probe.isConnected && probe.ledger.revokedLocally && probe.ledger.recordingScope == nil,
                "Unscoped failure fixture did not retain the pending grant")
            let pending = probe.ledger
            probe.enable(.existingAndFuture)
            try require(probe.ledger == pending && probe.repository.reads == 0 && probe.schedules == 0,
                "First scope admission bypassed failed reauthorization and cleared revoke")
        }
        await test("credential refresh survives cancelled waiter coalesces and persists once") {
            let refresh = GoogleDriveCredentialRefresh()
            var requests = 0, commits = 0
            var release: CheckedContinuation<GoogleDriveCredential, Never>?
            let first = Task { @MainActor in
                try await refresh.value {
                    requests += 1
                    let value = await withCheckedContinuation { release = $0 }
                    try Task.checkCancellation()
                    commits += 1
                    return value
                }
            }
            try await awaitPhaseHold { release != nil }
            let second = Task { @MainActor in
                try await refresh.value { requests += 1; return syntheticCredential() }
            }
            // Let the second waiter join the same exchange before completing it.
            for _ in 0..<10 { await Task.yield() }
            first.cancel()
            release!.resume(returning: syntheticCredential())
            _ = try await second.value
            do { _ = try await first.value; throw ProbeFailure(message: "Cancelled upload waiter accepted token") }
            catch is CancellationError { }
            try require(requests == 1 && commits == 1, "Refresh replayed POST or discarded successful credential")
            // A revoked or replaced credential cancels the exchange itself.
            var resumed: CheckedContinuation<GoogleDriveCredential, Never>?
            let stale = Task { @MainActor in
                try await refresh.value {
                    let value = await withCheckedContinuation { resumed = $0 }
                    try Task.checkCancellation()
                    commits += 1
                    return value
                }
            }
            try await awaitPhaseHold { resumed != nil }
            refresh.invalidate()
            resumed!.resume(returning: syntheticCredential())
            do { _ = try await stale.value; throw ProbeFailure(message: "Revoked refresh survived invalidation") }
            catch is CancellationError { }
            try require(commits == 1, "Revoked refresh committed credentials")
        }
        await test("production shared token refresh retries natural timeout once despite one cancelled waiter") {
            let transport = http(), requests = Trace(), recovery = RecoveryTrace(), hold = AccountReplyHold()
            transport.setTransportDiagnosticHandler { recovery.append($0) }
            transport.setRequestCompletionHandler { recovery.finish($0) }
            MockProtocol.install { request in
                requests.append(request)
                if request.url!.host == "oauth2.googleapis.com" {
                    if requests.count({ $0.url!.host == "oauth2.googleapis.com" }) == 1 { _ = try hold.reply() }
                    return .init(code: 200, data: try json(["access_token":"synthetic-shared-access", "expires_in":3600, "token_type":"Bearer"]))
                }
                return try about()
            }
            let tokens = SharedExchangeTokens(transport: transport)
            let cancelled = Task { @MainActor in try await tokens.accessToken(for: "owner-123", timeout: 20) }
            try await awaitPhaseHold { hold.entered }
            let live = Task { @MainActor in
                let client = GoogleDriveClient(http: transport, oauth: tokens, accountID: "owner-123", check: {})
                try await client.validateAccount()
            }
            for _ in 0..<10 { await Task.yield() }
            cancelled.cancel(); hold.release(.timedOut)
            try await live.value
            do { _ = try await cancelled.value; throw ProbeFailure(message: "Cancelled waiter consumed shared token") }
            catch is CancellationError { }
            try require(tokens.commits == 1 && requests.count { $0.url!.host == "oauth2.googleapis.com" } == 2
                && requests.count { $0.url!.path == "/drive/v3/about" } == 1,
                "Shared natural-timeout recovery duplicated refresh/commit or resumed a cancelled upload")
            let attempts = recovery.attempts.filter { $0.endpoint == .oauthToken }
            let finished = recovery.finished.filter { value in attempts.first?.requestID == value.requestID }
            try require(attempts.count == 2 && attempts[0].phase == .apiRequest && attempts[1].phase == .apiRecovery
                && attempts[0].requestID != nil && attempts[0].requestID == attempts[1].requestID
                && attempts.allSatisfy { $0.origin == .natural }
                && attempts[0].errors.contains { $0.domain == NSURLErrorDomain && $0.code == -1001 }
                && attempts[1].httpStatus == 200 && attempts[1].errors.isEmpty
                && finished.count == 1 && finished[0].outcome == .recovered && finished[0].attemptCount == 2,
                "Refresh timeout, recovery and commit were not bound to one natural request")
            _ = try await tokens.accessToken(for: "owner-123", timeout: 1)
            try require(tokens.commits == 1 && requests.count { $0.url!.host == "oauth2.googleapis.com" } == 2,
                "Cached successful credential started another refresh")
        }
        for expire in [false, true] {
            await test("production shared refresh preserves credential while shortened waiter budget expires=\(expire)") {
                let transport = http(), trace = Trace(), hold = AccountReplyHold(), budget = BudgetGate(isForeground: true)
                MockProtocol.install { request in
                    trace.append(request)
                    if request.url!.host == "oauth2.googleapis.com" {
                        if trace.count({ $0.url!.host == "oauth2.googleapis.com" }) == 1 { _ = try hold.reply() }
                        return .init(code:200,data:try json(["access_token":"synthetic-shortened-access", "expires_in":3600, "token_type":"Bearer"]))
                    }
                    try require(request.timeoutInterval <= 9, "Account request escaped the shortened upload lease")
                    return try about()
                }
                let tokens = SharedExchangeTokens(transport: transport)
                let first = Task { @MainActor in
                    let client = GoogleDriveClient(http:transport,oauth:tokens,accountID:"owner-123",check:budget.check,
                        requestTimeout:budget.requestTimeout)
                    try await client.validateAccount()
                }
                try await awaitPhaseHold { hold.entered }
                budget.advance(10); budget.enterBackground(); budget.advance(expire ? 19 : 10)
                hold.release(.timedOut)
                if expire {
                    do { try await first.value; throw ProbeFailure(message:"Expired waiter started account request") }
                    catch is CancellationError { }
                    try require(trace.count { $0.url!.path == "/drive/v3/about" } == 0,
                        "Credential-owned refresh lent execution time to the expired upload")
                } else { try await first.value }
                try require(tokens.commits == 1 && trace.count { $0.url!.host == "oauth2.googleapis.com" } == 2,
                    "Shortened/cancelled waiter discarded safe refresh progress or renewed the refresh budget")
                let next = GoogleDriveClient(http:transport,oauth:tokens,accountID:"owner-123",check:{},requestTimeout:{ 2 })
                try await next.validateAccount()
                try require(trace.count { $0.url!.host == "oauth2.googleapis.com" } == 2,
                    "The next execution opportunity replayed a completed credential refresh")
            }
        }
        for fault in ["missing", "id", "shared", "library", "schema"] {
            await test("folder \(fault) readback failure never quarantines artifacts and repair resumes") {
                let probe = try PipelineProbe(root:root,count:2); probe.installProtocol(); try await probe.fill()
                for task in Array(probe.native.active) { probe.finish(task) }; await settleUploads()
                let prior = probe.coordinator.records.count
                MockProtocol.install { request in
                    if request.url!.path == "/drive/v3/about" { return try about() }
                    try require(request.url!.path == "/drive/v3/files/folder-123", "Folder refusal reached an artifact or mutation")
                    if fault == "missing" { return .init(code:404) }
                    var object = try JSONSerialization.jsonObject(with:folder(probe.ledger)) as! [String:Any]
                    if fault == "shared" { object["shared"] = true }
                    else if fault == "id" { object["id"] = "foreign-folder" }
                    else { var props = object["appProperties"] as! [String:String]; props[fault == "library" ? "rfaLibraryID" : "rfaSchema"] = "foreign"; object["appProperties"] = props }
                    return .init(code:200,data:try json(object))
                }
                do { try await probe.readBackOne(); throw ProbeFailure(message:"Invalid folder was accepted") }
                catch GoogleDriveLibraryError.invalidRemoteFolder { }
                try require(probe.coordinator.itemRetries.isEmpty && probe.coordinator.records.count == prior
                    && probe.ledger.enabled && probe.ledger.savedAudioCount == 0,
                    "Folder-level refusal poisoned healthy artifact retries, grant or pending native evidence")
                probe.installProtocol(); try await probe.readBackOne()
                try require(probe.ledger.jobs.flatMap(\.artifacts).filter { $0.verifiedAt != nil }.count == 1
                    && probe.coordinator.itemRetries.isEmpty,
                    "Restored private folder could not resume its original completed upload")
            }
        }
        await test("folder validation in ordinary pipeline preserves healthy queue and missing ensureFolder creates only its bound folder") {
            let probe = try PipelineProbe(root:root,count:2)
            MockProtocol.install { request in
                if request.url!.path == "/drive/v3/about" { return try about() }
                var object = try JSONSerialization.jsonObject(with:folder(probe.ledger)) as! [String:Any]
                object["shared"] = true
                return .init(code:200,data:try json(object))
            }
            do {
                try await probe.coordinator.runAvailable(ledger:{probe.ledger},progress:{probe.progress},check:{}) { _ in
                    let client = GoogleDriveClient(http:http(),oauth:Tokens(),accountID:"owner-123",check:{})
                    try await client.validateAccount(); try await client.ensureFolder(id:"folder-123",libraryID:probe.ledger.libraryID)
                }
                throw ProbeFailure(message:"Shared folder admitted ordinary upload")
            } catch GoogleDriveLibraryError.invalidRemoteFolder { }
            let afterFolderFailure = try probe.coordinator.nextUpload(in:probe.ledger,progress:probe.progress)
            try require(probe.coordinator.itemRetries.isEmpty && afterFolderFailure != nil,
                "An ordinary folder error terminally quarantined its selected artifact")
            var created = false, posts = 0
            MockProtocol.install { request in
                if request.url!.path == "/drive/v3/about" { return try about() }
                if request.httpMethod == "POST" {
                    try require(request.url!.path == "/drive/v3/files", "Missing folder created an unexpected resource")
                    created = true; posts += 1; return .init(code:200)
                }
                return created ? .init(code:200,data:try folder(probe.ledger)) : .init(code:404)
            }
            let client = GoogleDriveClient(http:http(),oauth:Tokens(),accountID:"owner-123",check:{})
            try await client.ensureFolder(id:"folder-123",libraryID:probe.ledger.libraryID)
            try require(posts == 1 && probe.ledger.savedAudioCount == 0, "Missing-folder creation fabricated an artifact receipt")
        }
        await test("legacy ambiguous terminal missing remote requeues only after restored folder and current source checks") {
            let probe = try PipelineProbe(root:root,count:2); try await probe.makeLegacyQuarantine()
            let before = probe.coordinator.itemRetries.count
            try require(before == 4, "Legacy fixture failed to quarantine every selected artifact")
            probe.installProtocol()
            var validations = 0
            try await probe.recheckLegacyOne { _ in validations += 1; return true }
            try require(validations == 2 && probe.coordinator.itemRetries.count == before-1
                && probe.ledger.savedAudioCount == 0 && probe.native.requests.isEmpty,
                "Legacy migration skipped source checks, invented a receipt or transmitted content")
            try await probe.fill()
            try require(probe.native.requests.count == 1 && probe.coordinator.itemRetries.count == before-1,
                "Healthy not-yet-uploaded legacy item remained permanently quarantined after folder repair")
        }
        await test("production schedule admission runs legacy terminal repair without discovery or body capacity") {
            let probe = try PipelineProbe(root:root,count:1); try await probe.makeLegacyQuarantine()
            let admission = GoogleDriveScheduleAdmissionProbe(ledger:probe.ledger,progress:probe.progress,background:probe.coordinator,http:http(),oauth:Tokens())
            let blocked = try probe.coordinator.nextUpload(in:probe.ledger,progress:probe.progress,allowPipelineFill:true)
            let allowed = try admission.scheduledWorkAdmission()
            try require(!probe.progress.needsDiscovery && blocked == nil && allowed == .ready,
                "Actual schedule still waits for upload selection before legacy metadata repair")
            probe.installProtocol(); try await admission.recheckLegacyQuarantine(token:0,lease:GoogleDriveExecutionLease())
            try require(admission.sourceChecks == 2 && probe.coordinator.itemRetries.count == 1 && probe.native.requests.isEmpty,
                "Actual schedule admission→legacy readback path opened a body or failed to recover a healthy old terminal")
            // Retained completed bodies can consume the full 64MiB budget even
            // though no native upload or ordinary readback is currently eligible.
            let full = try PipelineProbe(root:root,count:8,audioBytes:8*1_024*1_024)
            for job in full.ledger.jobs {
                let artifact = job.artifacts.first { $0.kind == .audio }!
                let context = try GoogleDriveUploadContext(ledger:full.ledger,manifest:job.manifest,artifact:artifact)
                try await full.coordinator.start(request:backgroundRequest(context),file:full.files[job.id.uuidString.lowercased()+"/"+artifact.key]!,offset:0,
                    context:context,isAuthorized:{context.isAuthorized(in:full.ledger)},check:{})
            }
            for task in full.native.active { full.finish(task,code:500) }; await settleUploads()
            try await full.coordinator.runAvailable(ledger:{full.ledger},progress:{full.progress},check:{}) { _ in throw GoogleDriveError.http(503) }
            let state = full.directory.appendingPathComponent("pipeline.json")
            var object = try JSONSerialization.jsonObject(with:Data(contentsOf:state)) as! [String:Any]
            var retries = object["retries"] as! [[String:Any]]
            for i in retries.indices { retries[i]["terminal"] = true; retries[i].removeValue(forKey:"failureReason") }
            object["retries"] = retries; try json(object).write(to:state)
            full.coordinator = try GoogleDriveBackgroundUploads(directory:full.directory,libraryID:full.ledger.libraryID,
                changed:{},finishedEvents:{_ in},now:{[clock=full.clock] in clock.now()},factory:full.native.factory)
            let fullAdmission = GoogleDriveScheduleAdmissionProbe(ledger:full.ledger,progress:full.progress,background:full.coordinator,http:http(),oauth:Tokens())
            let fullAllowed = try fullAdmission.scheduledWorkAdmission()
            try require(!full.coordinator.canProcess && !full.coordinator.canReserve(bytes:1)
                && full.coordinator.readyReadbackCount == 0 && fullAllowed == .ready,
                "Actual schedule body-capacity gate concealed due metadata-only legacy repair")
            full.installProtocol(); let bodies = full.native.requests.count
            try await fullAdmission.recheckLegacyQuarantine(token:0,lease:GoogleDriveExecutionLease())
            try require(fullAdmission.sourceChecks == 2 && full.coordinator.itemRetries.count == 7 && full.native.requests.count == bodies
                && !full.coordinator.canReserve(bytes:1), "Legacy admission bypassed native body capacity")
            full.ledger.revoke()
            let revoked = full.coordinator.hasDueLegacyMetadataWork(in:full.ledger)
            try require(!revoked, "Schedule migration admitted work under a revoked grant")
        }
        await test("legacy ambiguous terminal readback verifies exact healthy remote and pins genuinely bad artifact") {
            let probe = try PipelineProbe(root:root,count:1); try await probe.makeLegacyQuarantine()
            let candidate = probe.coordinator.itemRetries[0]
            let job = probe.ledger.jobs.first { $0.id == candidate.segmentID }!
            let artifact = job.artifacts.first { $0.key == candidate.artifactKey }!
            probe.remotelyCompleted.insert(artifact.fileID!); probe.installProtocol()
            try await probe.recheckLegacyOne()
            try require(probe.ledger.jobs[0].artifacts.first { $0.key == artifact.key }!.verifiedAt != nil
                && probe.coordinator.itemRetries.count == 1 && probe.native.requests.isEmpty,
                "Exact remote metadata did not safely retire the old ambiguous quarantine")
            MockProtocol.install { request in
                if request.url!.path == "/drive/v3/about" { return try about() }
                if request.url!.path == "/drive/v3/files/folder-123" { return .init(code:200,data:try folder(probe.ledger)) }
                return .init(code:200,data:try json(["id":request.url!.lastPathComponent,"size":"1","sha256Checksum":String(repeating:"f",count:64)]))
            }
            try await probe.recheckLegacyOne()
            try require(probe.coordinator.itemRetries.count == 1 && probe.coordinator.itemRetries[0].failureReason == .remoteConflict,
                "Known-invalid remote artifact was released back into uploads")
            probe.clock.advance(7_200)
            let checked = try await probe.recheckLegacyOne()
            let afterBadArtifact = try probe.coordinator.nextUpload(in:probe.ledger,progress:probe.progress)
            try require(!checked && afterBadArtifact == nil,
                "A known bad artifact was periodically reopened by the legacy migration")
        }
        await test("legacy quarantine migration is bounded cold-durable and cannot bypass folder or revoked source") {
            let probe = try PipelineProbe(root:root,count:1); try await probe.makeLegacyQuarantine()
            var requests = 0
            MockProtocol.install { request in requests += 1; return request.url!.path == "/drive/v3/about" ? try about() : .init(code:404) }
            do { try await probe.recheckLegacyOne(); throw ProbeFailure(message:"Missing folder released a legacy item") }
            catch GoogleDriveLibraryError.invalidRemoteFolder { }
            try require(probe.coordinator.itemRetries.count == 2 && requests == 2,
                "Missing folder changed terminal provenance or performed an artifact upload")
            probe.coordinator = try GoogleDriveBackgroundUploads(directory:probe.directory,libraryID:probe.ledger.libraryID,
                changed:{},finishedEvents:{_ in},now:{[clock=probe.clock] in clock.now()},factory:probe.native.factory)
            try require(probe.coordinator.itemRetries.filter { $0.legacyProbeAfter != nil }.count == 1,
                "Cold restart forgot the pre-await bounded legacy recheck marker")
            try await probe.recheckLegacyOne { _ in false }
            try require(probe.coordinator.itemRetries.contains { $0.failureReason == .sourceChanged }
                && probe.native.requests.isEmpty, "Withdrawn source was reopened by migration")
        }
        for missing in ["sha256Checksum", "size"] {
            await test("REC-38 incomplete \(missing) retries only metadata after cooldown restart and missing remote") {
                let probe = try PipelineProbe(root: root, count: 1)
                let context = try await probe.stageAudioTasks()[0]
                probe.finish(probe.native.active[0]); await settleUploads()
                var raw = try JSONSerialization.jsonObject(with: audioRemote(context)) as! [String: Any]
                raw.removeValue(forKey: missing)
                let incomplete = try json(raw)
                var requests = 0, missingRemote = false
                MockProtocol.install { request in
                    requests += 1
                    try require(request.httpMethod == "GET", "Incomplete metadata recovery mutated remote content/session")
                    if request.url!.path == "/drive/v3/about" { return try about() }
                    if request.url!.path == "/drive/v3/files/folder-123" { return .init(code: 200, data: try folder(probe.ledger)) }
                    return missingRemote ? .init(code: 404) : .init(code: 200, data: incomplete)
                }
                try await probe.readBackOne()
                let originalNonce = probe.coordinator.records[0].nonce
                let retry = probe.coordinator.itemRetries[0]
                try require(retry.failureReason == .metadataIncomplete && retry.terminal != true
                    && retry.retryAfter == probe.clock.now().addingTimeInterval(15)
                    && probe.ledger.savedAudioCount == 0 && probe.coordinator.records.count == 1,
                    "Missing metadata became success, permanent conflict, or discarded its native attempt")
                probe.coordinator = try GoogleDriveBackgroundUploads(directory: probe.directory, libraryID: probe.ledger.libraryID,
                    changed: {}, finishedEvents: { _ in }, now: { [clock = probe.clock] in clock.now() }, factory: probe.native.factory)
                let admission = GoogleDriveScheduleAdmissionProbe(ledger: probe.ledger, progress: probe.progress,
                    background: probe.coordinator, http: http(), oauth: Tokens())
                let beforeDue = requests
                try await admission.recheckLegacyQuarantine(token: 0, lease: GoogleDriveExecutionLease())
                try require(requests == beforeDue && admission.sourceChecks == 0,
                    "Cold restart bypassed incomplete metadata's durable cooldown")
                // Persistence rounds dates to milliseconds. Honor the decoded
                // deadline, which may be a fraction later than start + 15s.
                let restoredDue = probe.coordinator.earliestRetryAt(in: admission.ledger)!
                probe.clock.advance(restoredDue.timeIntervalSince(probe.clock.now())); missingRemote = true
                try await admission.recheckLegacyQuarantine(token: 0, lease: GoogleDriveExecutionLease())
                let next = try probe.coordinator.nextUpload(in: admission.ledger, progress: probe.progress)
                let deferred = probe.coordinator.itemRetries[0]
                try require(deferred.failureReason == .metadataIncomplete && deferred.failures == 2
                    && deferred.retryAfter == probe.clock.now().addingTimeInterval(30),
                    "A subsequent 404 escaped metadata-only exponential backoff")
                let retained = admission.ledger.jobs[0].artifacts.first { $0.key == context.artifact.key }!
                try require(next?.artifactKey != context.artifact.key && probe.coordinator.records[0].nonce == originalNonce
                    && retained.fileID == context.artifact.fileID && retained.uploadURL == context.artifact.uploadURL,
                    "A subsequent 404 requeued bytes or lost the original ID/session/attempt")
                probe.clock.advance(30); probe.installProtocol()
                try await admission.recheckLegacyQuarantine(token: 0, lease: GoogleDriveExecutionLease())
                try requireAudioReceipts(admission.ledger, [context])
                try require(probe.coordinator.itemRetries.isEmpty && probe.coordinator.records.isEmpty
                    && probe.native.requests.count == 1 && admission.sourceChecks == 4,
                    "Strict recovery did not retire its exact attempt or repeated a body upload")
            }
        }
        await test("REC-38 old artifactInvalid requires strict readback and never requeues a missing remote") {
            let probe = try PipelineProbe(root: root, count: 1); try await probe.makeLegacyQuarantine()
            let state = probe.directory.appendingPathComponent("pipeline.json")
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: state)) as! [String: Any]
            var retries = object["retries"] as! [[String: Any]]
            for index in retries.indices { retries[index]["failureReason"] = "artifactInvalid" }
            object["retries"] = retries; try json(object).write(to: state)
            probe.coordinator = try GoogleDriveBackgroundUploads(directory: probe.directory, libraryID: probe.ledger.libraryID,
                changed: {}, finishedEvents: { _ in }, now: { [clock = probe.clock] in clock.now() }, factory: probe.native.factory)
            let original = probe.coordinator.itemRetries[0]
            let artifact = probe.ledger.jobs[0].artifacts.first { $0.key == original.artifactKey }!
            let admission = GoogleDriveScheduleAdmissionProbe(ledger: probe.ledger, progress: probe.progress,
                background: probe.coordinator, http: http(), oauth: Tokens())
            probe.installProtocol()
            try await admission.recheckLegacyQuarantine(token: 0, lease: GoogleDriveExecutionLease())
            let missing = probe.coordinator.itemRetries.first { $0.artifactKey == original.artifactKey }!
            let candidate = try probe.coordinator.nextUpload(in: admission.ledger, progress: probe.progress)
            try require(missing.failureReason == .metadataIncomplete && missing.bindingSHA256 == original.bindingSHA256
                && candidate == nil && probe.native.requests.isEmpty && admission.ledger.savedAudioCount == 0,
                "Old artifactInvalid was globally cleared or a 404 resumed content upload")
            // The peer's source check fails independently; it cannot release the
            // matching artifact's binding or grant it a receipt.
            admission.sourceIsCurrent = false
            try await admission.recheckLegacyQuarantine(token: 0, lease: GoogleDriveExecutionLease())
            admission.sourceIsCurrent = true
            probe.clock.advance(3_600); probe.remotelyCompleted.insert(artifact.fileID!)
            try await admission.recheckLegacyQuarantine(token: 0, lease: GoogleDriveExecutionLease())
            try require(admission.ledger.jobs[0].artifacts.first { $0.key == artifact.key }!.verifiedAt != nil
                && probe.coordinator.itemRetries.count == 1 && probe.coordinator.itemRetries[0].failureReason == .sourceChanged
                && probe.native.requests.isEmpty, "Strict recovery cleared a peer's isolation or repeated content")
        }
        await test("REC-38 metadata retries cannot run paused revoked or changed grants") {
            let probe = try PipelineProbe(root: root, count: 1)
            try await probe.coordinator.runAvailable(ledger: { probe.ledger }, progress: { probe.progress }, check: {},
                perform: { _ in throw GoogleDriveLibraryError.metadataIncomplete })
            probe.clock.advance(3_600)
            let before = probe.coordinator.itemRetries
            try probe.ledger.setEnabled(false)
            var calls = 0
            let paused = try await probe.coordinator.runLegacyQuarantineReadback(ledger: { probe.ledger }, check: {}, perform: { _ in calls += 1 })
            try require(!paused && calls == 0 && probe.coordinator.itemRetries == before,
                "Paused library consumed metadata recovery or lost evidence")
            try probe.ledger.setEnabled(true)
            var object = try JSONSerialization.jsonObject(with: TransportCodec.encode(probe.ledger)) as! [String: Any]
            object["authorizedAt"] = Date(timeIntervalSince1970: 1_700_000_100).timeIntervalSince1970 * 1_000
            let changed = try TransportCodec.decode(GoogleDriveLibraryLedger.self, from: json(object))
            try require(!probe.coordinator.hasDueLegacyMetadataWork(in: changed), "Metadata retry crossed authorization generation")
            probe.ledger.revoke()
            let revoked = try await probe.coordinator.runLegacyQuarantineReadback(ledger: { probe.ledger }, check: {}, perform: { _ in calls += 1 })
            try require(!revoked && calls == 0 && probe.coordinator.itemRetries.isEmpty,
                "Revoked grant retained runnable metadata recovery")
        }
        await test("ordinary discovery never fabricates a processing parent grant") {
            var ordinary = GoogleDriveExecutionBudget.ParentGrant(now: 0, existingWork: .ordinarySync, systemGranted: false)
            try require(ordinary.takeRound(at: 18, isCancelled: false) == 19, "Ordinary discovery borrowed 120 seconds")
            try require(ordinary.takeRound(at: 18, isCancelled: false) == nil, "Ordinary discovery renewed its deadline")
            var spent = GoogleDriveExecutionBudget.ParentGrant(now: 0, existingWork: .ordinarySync, systemGranted: false)
            try require(spent.takeRound(at: 19, isCancelled: false) == nil, "Spent ordinary lease started more work")
        }
        await test("bounded transport diagnostic privacy and error attribution") {
            _ = try GoogleDriveTransportDiagnosticCases.run()
        }
        await test("bounded transport history survives restart without accepting private strings") {
            _ = try GoogleDriveTransportHistoryCases.run()
        }
        await test("frozen fault reports preserve exact recovery and bounded private evidence") {
            _ = try GoogleDriveFaultReportCases.run()
        }
        await test("fault presentation separates context limits request recovery and storage gaps") {
            _ = try GoogleDriveTransportFaultPresentationCases.run()
        }
        await test("ClosedNoNotify read-only recovery respects trust cancellation and original budget") {
            _ = try await GoogleDriveTLSRecoveryCases.run()
        }
        await test("official endpoint allowlist and redirect refusal") {
            for url in ["https://evil.example/drive/v3/files", "http://www.googleapis.com/drive/v3/files", "https://www.googleapis.com:443/drive/v3/files", "https://www.googleapis.com/drive/v3/files/audio-123/permissions", "https://oauth2.googleapis.com/token?access_token=x"] {
                try require(!GoogleDriveHTTP.allows(URL(string: url)!), "Nonofficial or wider route accepted")
            }
            let transport = http(), session = URLSession(configuration: .ephemeral)
            let request = URLRequest(url: URL(string: "https://evil.example/")!)
            let response = HTTPURLResponse(url: URL(string: "https://www.googleapis.com/drive/v3/files")!, statusCode: 302, httpVersion: nil, headerFields: nil)!
            var denied = false
            transport.urlSession(session, task: session.dataTask(with: request), willPerformHTTPRedirection: response, newRequest: request) { denied = $0 == nil }
            try require(denied, "Redirect delegate forwarded a request")
            session.invalidateAndCancel()
        }
        for status in [403, 429, 500, 503] {
            await test("account HTTP \(status) stays retryable without requesting another login") {
                let trace = Trace()
                MockProtocol.install { request in
                    trace.append(request)
                    try require(request.url!.path == "/drive/v3/about", "Account failure issued a file request")
                    return .init(code: status)
                }
                let client = GoogleDriveClient(http: http(), oauth: Tokens(), accountID: "owner-123", check: {})
                do { try await client.validateAccount(); throw ProbeFailure(message: "Failed account response was accepted") }
                catch GoogleDriveError.http(let observed) { try require(observed == status, "Account HTTP status was discarded") }
                try require(trace.count { _ in true } == 1, "Account failure triggered an extra request")
            }
        }
        await test("account HTTP 401 still requires sign-in") {
            MockProtocol.install { _ in .init(code: 401) }
            let client = GoogleDriveClient(http: http(), oauth: Tokens(), accountID: "owner-123", check: {})
            do { try await client.validateAccount(); throw ProbeFailure(message: "Unauthorized account was accepted") }
            catch GoogleDriveError.needsSignIn { }
        }
        await test("a refreshed token's temporary account error cannot issue file requests or become sign-in failure") {
            let trace = Trace()
            MockProtocol.install { request in
                trace.append(request)
                try require(request.url!.path == "/drive/v3/about", "Unverified refreshed token issued file request")
                return trace.count { _ in true } == 1 ? try about() : .init(code: 503)
            }
            let client = GoogleDriveClient(http: http(), oauth: Tokens(["first", "second"]), accountID: "owner-123", check: {})
            try await client.validateAccount()
            do { _ = try await client.generateID(); throw ProbeFailure(message: "Unavailable refreshed-token account was accepted") }
            catch GoogleDriveError.http(let code) { try require(code == 503, "Refreshed-token account error lost its status") }
            try require(trace.count { _ in true } == 2, "Account retry path reached a file API")
        }
        for status in [400, 403, 429, 500, 503] {
            await test("token HTTP \(status) without proven invalid grant retains its retryable status") {
                let trace = Trace()
                MockProtocol.install { request in
                    trace.append(request)
                    try require(request.url!.host == "oauth2.googleapis.com" && request.url!.path == "/token" && request.httpMethod == "POST",
                        "Exchange reached an unexpected route")
                    // Even an auth-shaped body on 5xx must not disable a valid
                    // grant; unknown 400 errors are not proof of invalid tokens.
                    return .init(code: status, data: try json(["error": status == 400 ? "invalid_request" : "invalid_grant"]))
                }
                let transport = http()
                let client = GoogleDriveClient(http: transport, oauth: ExchangeTokens(transport: transport), accountID: "owner-123", check: {})
                do { try await client.validateAccount(); throw ProbeFailure(message: "Failed token response was accepted") }
                catch GoogleDriveError.http(let observed) { try require(observed == status, "Temporary token error became another classification") }
                try require(trace.count { _ in true } == 1, "Failed token exchange reached account or file APIs")
            }
        }
        for status in [400, 401] {
            await test("token HTTP \(status) proves invalid authorization only on the defined path") {
                MockProtocol.install { _ in .init(code: status, data: status == 401 ? Data() : try json(["error": "invalid_grant"])) }
                let previous = syntheticCredential()
                do {
                    _ = try await GoogleDriveOAuthExchange.exchange(http: http(), clientID: previous.clientID,
                        values: ["grant_type": "refresh_token"], previous: previous)
                    throw ProbeFailure(message: "Invalid authorization was accepted")
                } catch GoogleDriveError.needsSignIn { }
            }
        }
        await test("expired native token refresh receives the same remaining lease as account and file APIs") {
            let trace = Trace()
            MockProtocol.install { request in
                trace.append(request)
                try require(request.timeoutInterval > 0 && request.timeoutInterval <= 2.5,
                    "Token/account request escaped the caller's remaining lease")
                if request.url!.host == "oauth2.googleapis.com" {
                    return .init(code: 200, data: try json(["access_token":"synthetic-next-access", "expires_in":3600, "token_type":"Bearer"]))
                }
                try require(request.url!.path == "/drive/v3/about", "Validation unexpectedly issued a file request")
                return try about()
            }
            let transport = http()
            let client = GoogleDriveClient(http: transport, oauth: ExchangeTokens(transport: transport), accountID: "owner-123",
                check: {}, requestTimeout: { 2.5 })
            try await client.validateAccount()
            try require(trace.count { $0.url!.host == "oauth2.googleapis.com" } == 1 && trace.count { _ in true } == 2,
                "Refresh was skipped, replayed, or did not reach its independently verified account")
        }
        await test("spent refresh budget cannot issue a POST or account request") {
            let trace = Trace(); MockProtocol.install { request in trace.append(request); return try about() }
            let transport = http()
            let client = GoogleDriveClient(http: transport, oauth: ExchangeTokens(transport: transport), accountID: "owner-123",
                check: {}, requestTimeout: { 0 })
            do { try await client.validateAccount(); throw ProbeFailure(message: "Spent token budget was accepted") }
            catch is CancellationError { }
            try require(trace.count { _ in true } == 0, "Spent refresh budget reached HTTP")
        }
        for outcome in ["timeout", "temporary_status"] {
            await test("bounded refresh \(outcome) preserves one eligible retry without becoming authorization failure") {
                let trace = Trace()
                MockProtocol.install { request in
                    trace.append(request)
                    try require(request.url!.host == "oauth2.googleapis.com" && request.timeoutInterval <= 3,
                        "Refresh bypassed its budget or reached a file API")
                    if outcome == "timeout" { throw URLError(.timedOut) }
                    return .init(code: 503, data: try json(["error":"invalid_grant"]))
                }
                let transport = http()
                let client = GoogleDriveClient(http: transport, oauth: ExchangeTokens(transport: transport), accountID: "owner-123",
                    check: {}, requestTimeout: { 3 })
                do { try await client.validateAccount(); throw ProbeFailure(message: "Failed refresh accepted") }
                catch let error as URLError { try require(outcome == "timeout" && error.code == .timedOut, "Refresh timeout classification changed") }
                catch GoogleDriveError.http(let status) { try require(outcome == "temporary_status" && status == 503, "Refresh status classification changed") }
                let expected = outcome == "timeout" ? 2 : 1
                try require(trace.count { _ in true } == expected
                    && trace.count { $0.url!.host != "oauth2.googleapis.com" } == 0,
                    "Refresh exceeded its single eligible retry or reached account/file requests")
            }
        }
        await test("fixed worker report stays bounded and cannot expose a localized error or receipt identity") {
            let now: Int64 = 1_793_246_517_895
            let privateMessage = "synthetic-private-token-and-source-identity"
            let failure = GoogleDriveWorkerReport.Failure(NSError(domain: NSURLErrorDomain, code: -1001,
                userInfo: [NSLocalizedDescriptionKey:privateMessage]))
            let report = GoogleDriveWorkerReport(schemaVersion: 1, processRunID: UUID(), build: "64",
                generatedAtMS: now, sequence: 32, enabled: true, ledgerAvailable: true,
                sourceSnapshotPending: false, discoveryComplete: false, discoveryRemaining: 622,
                authorizedSourceCount: 622, savedAudioCount: 450, pendingArtifactCount: 350,
                nativeCount: 0, readbackCount: 0, itemRetryCount: 0, retryAfterMS: now+3_600_000,
                failureCount: 16, systemGranted: false, lastFailure: failure, lastFailurePhase: .tokenAccess,
                observations: (0..<GoogleDriveWorkerReport.maximumObservations).map { index in
                    .init(atMS: now+Int64(index), event: index == 7 ? .waitingRetry : .roundFailed,
                        phase: .tokenAccess, roundSequence: 32, foreground: false, roundActive: false,
                        remainingMS: 0, pendingCount: 350, nativeCount: 0, readbackCount: 0)
                })
            let bytes = try report.encoded(), text = String(decoding: bytes, as: UTF8.self)
            try require(bytes.count <= 8_192 && !text.contains(privateMessage) && !text.contains("accountID")
                && !text.contains("segmentID") && !text.contains("uploadURL"), "Worker report exceeded its private fixed schema")
            let restored = try TransportCodec.decode(GoogleDriveWorkerReport.self, from: bytes)
            try require(restored.observations.count == 8 && restored.lastFailure?.kind == .network && restored.lastFailure?.code == -1001
                && restored.lastFailurePhase == .tokenAccess && restored.pendingArtifactCount == 350,
                "Worker report lost the numeric blocker or claimed a new upload receipt")
        }
        await test("REC-36 worker external failure returns while observation publisher is locked") {
            try GoogleDriveWorkerDiagnosticCases.runNonBlockingInvalidation(
                root: root.appendingPathComponent("rec36-worker-invalidation"))
        }
        await test("worker diagnostics attribution writer failure recovery and legacy compatibility") {
            workerDiagnosticAssertions = try await GoogleDriveWorkerDiagnosticCases.run(root: root.appendingPathComponent("worker-diagnostics", isDirectory: true))
        }
        for includeScope in [true, false] {
            await test("token refresh preserves binding and minimal scope with explicit scope=\(includeScope)") {
                MockProtocol.install { _ in
                    var value: [String: Any] = ["access_token": "synthetic-next-access", "expires_in": 3600, "token_type": "Bearer"]
                    if includeScope { value["scope"] = GoogleDriveOAuthConfiguration.scope }
                    return .init(code: 200, data: try json(value))
                }
                let previous = syntheticCredential()
                let next = try await GoogleDriveOAuthExchange.exchange(http: http(), clientID: previous.clientID,
                    values: ["grant_type": "refresh_token"], previous: previous)
                try require(next.clientID == previous.clientID && next.accountID == previous.accountID
                    && next.refreshToken == previous.refreshToken && next.accessToken == "synthetic-next-access",
                    "Exchange changed the account/client fence or discarded the refresh token")
            }
        }
        await test("the actual exchange still rejects wider OAuth scope") {
            MockProtocol.install { _ in .init(code: 200, data: try json(["access_token": "synthetic-next-access", "expires_in": 3600,
                "token_type": "Bearer", "scope": GoogleDriveOAuthConfiguration.scope + " https://www.googleapis.com/auth/drive"])) }
            let previous = syntheticCredential()
            do {
                _ = try await GoogleDriveOAuthExchange.exchange(http: http(), clientID: previous.clientID,
                    values: ["grant_type": "refresh_token"], previous: previous)
                throw ProbeFailure(message: "Exchange widened OAuth scope")
            } catch GoogleDriveError.invalidResponse { }
        }
        for boundary in ["initial", "request_rotation", "native_rotation"] {
            for held in ["token", "about"] {
                for outcome in ["cancelled", "expired", "network"] {
                    await test("held \(boundary) \(held) reports exact phase on \(outcome) without transmitting file bytes") {
                        var (ledger, manifest, artifact, file) = try fixture(Data(repeating: 4, count: 16), root: root)
                        if boundary == "native_rotation" {
                            try ledger.recordSession(segmentID: manifest.id, key: artifact.key,
                                url: "https://www.googleapis.com/upload/drive/v3/files?upload_id=phase-synthetic")
                            artifact = ledger.jobs[0].artifacts[0]
                        }
                        let targetCall = boundary == "initial" ? 1 : (boundary == "request_rotation" ? 2 : 4)
                        let tokens = PhaseTokens(targetCall: targetCall, hold: held == "token")
                        let reply = AccountReplyHold(), trace = Trace(), budget = BudgetGate(isForeground: false)
                        var phases: [GoogleDrivePreflightPhase] = [], handoffs = 0
                        MockProtocol.install { request in
                            trace.append(request)
                            if request.url!.path == "/drive/v3/about" {
                                let ordinal = trace.count { $0.url!.path == "/drive/v3/about" }
                                if held == "about" && ordinal == (boundary == "initial" ? 1 : 2) { return try reply.reply() }
                                return try about()
                            }
                            if request.url!.path == "/drive/v3/files/audio-123" { return .init(code: 404) }
                            if request.httpMethod == "PUT", request.httpBody == nil { return .init(code: 308) }
                            throw ProbeFailure(message: "Held account boundary started a file operation")
                        }
                        let client = GoogleDriveClient(http: http(), oauth: tokens, accountID: "owner-123",
                            check: { try Task.checkCancellation(); try budget.check() },
                            requestTimeout: { try Task.checkCancellation(); return try budget.requestTimeout() },
                            phase: { phases.append($0) })
                        let operation = Task<Void, Error> { @MainActor in
                            try await client.validateAccount()
                            if boundary == "request_rotation" { _ = try await client.generateID() }
                            if boundary == "native_rotation" {
                                _ = try await client.upload(file: file, artifact: artifact, manifest: manifest,
                                    folderID: "folder-123", libraryID: ledger.libraryID,
                                    backgroundHandoff: { _, _, _ in handoffs += 1 }, saveSession: { _ in })
                            }
                        }
                        defer { operation.cancel(); tokens.release(); reply.release() }
                        try await awaitPhaseHold { held == "token" ? tokens.entered : reply.entered }
                        let expected: GoogleDrivePreflightPhase = held == "token" ? .tokenAccess : .accountGet
                        let heldPhase = phases.last
                        if outcome == "cancelled" { operation.cancel() }
                        if outcome == "expired" { budget.expire() }
                        if held == "token" { tokens.release(.networkConnectionLost) }
                        else { reply.release(.networkConnectionLost) }
                        do {
                            try await operation.value
                            throw ProbeFailure(message: "Held failing account operation was accepted")
                        } catch is CancellationError {
                            try require(outcome != "network", "Live account network error was hidden")
                        } catch let error as URLError {
                            try require(outcome == "network" && error.code == .networkConnectionLost,
                                "Account cancellation or expiry lost its classification")
                        }
                        try require(heldPhase == expected, "Held await reported the wrong diagnostic phase")
                        try require(phases.last == expected, "Failed await lost its exact diagnostic phase")
                        try require(tokens.calls == targetCall && handoffs == 0,
                            "Held account boundary fetched another token or reached native handoff")
                        try require(trace.count { $0.httpMethod == "POST" || ($0.httpBody?.count ?? 0) > 0 } == 0,
                            "Held account boundary transmitted file bytes")
                        try require(trace.count { $0.url!.path == "/drive/v3/files/generateIds" } == 0,
                            "Unvalidated account reached the file allocation API")
                        accountPhaseEvidence.append(["boundary": boundary, "held": held, "outcome": outcome,
                            "lastPhase": expected.rawValue, "fileByteRequests": 0, "nativeHandoffs": handoffs])
                    }
                }
            }
        }
        for native in [false, true] {
            for rotate in [false, true] {
                await test("successful token lookup restores \(native ? "native" : "request") phase with rotation=\(rotate)") {
                    var (ledger, manifest, artifact, file) = try fixture(Data(repeating: 5, count: 16), root: root)
                    if native {
                        try ledger.recordSession(segmentID: manifest.id, key: artifact.key,
                            url: "https://www.googleapis.com/upload/drive/v3/files?upload_id=phase-success")
                        artifact = ledger.jobs[0].artifacts[0]
                    }
                    let trace = Trace(), tokens = PhaseTokens(targetCall: native ? 4 : 2, hold: false, rotate: rotate)
                    var phases: [GoogleDrivePreflightPhase] = [], handoffs = 0
                    MockProtocol.install { request in
                        trace.append(request)
                        if request.url!.path == "/drive/v3/about" { return try about() }
                        if request.url!.path == "/drive/v3/files/generateIds" { return .init(code: 200, data: try json(["ids": ["phase-generated-id"]])) }
                        if request.url!.path == "/drive/v3/files/audio-123" { return .init(code: 404) }
                        if request.httpMethod == "PUT", request.httpBody == nil { return .init(code: 308) }
                        throw ProbeFailure(message: "Unexpected successful phase route")
                    }
                    let client = GoogleDriveClient(http: http(), oauth: tokens, accountID: "owner-123", check: {}, phase: { phases.append($0) })
                    try await client.validateAccount()
                    if native {
                        do {
                            _ = try await client.upload(file: file, artifact: artifact, manifest: manifest,
                                folderID: "folder-123", libraryID: ledger.libraryID,
                                backgroundHandoff: { _, _, _ in
                                    try require(phases.last == .nativeStage, "Native handoff retained an account diagnostic phase")
                                    handoffs += 1
                                }, saveSession: { _ in })
                            throw ProbeFailure(message: "Synthetic native handoff did not transfer ownership")
                        } catch is GoogleDriveUploadHandoff { }
                        try require(handoffs == 1 && phases.suffix(2) == [.sessionQuery, .nativeStage],
                            "Successful native token await failed to restore its caller phase")
                    } else {
                        _ = try await client.generateID()
                        try require(phases.last == .allocate, "Successful request token await failed to restore its caller phase")
                    }
                    try require(trace.count { $0.url!.path == "/drive/v3/about" } == (rotate ? 2 : 1),
                        "Diagnostic phases changed refreshed-token account verification")
                    try require(phases.filter { $0 == .tokenAccess }.count == (native ? 4 : 2),
                        "A successful token boundary omitted its diagnostic phase")
                }
            }
        }
        for phase in ["account", "file", "token"] {
            for cause in [
                (name: "task", code: URLError.Code.cancelled), (name: "parent", code: .cancelled),
                (name: "deadline", code: .cancelled), (name: "network", code: .cancelled),
                (name: "task", code: .timedOut), (name: "parent", code: .timedOut),
                (name: "deadline", code: .timedOut), (name: "network", code: .timedOut)
            ] {
                await test("\(phase) await error \(cause.code.rawValue) honors \(cause.name) cancellation without hiding a live network error") {
                    let parent = Gate(), budget = BudgetGate(isForeground: true), cancellation = TaskCancellation(), trace = Trace()
                    MockProtocol.install { request in
                        trace.append(request)
                        if phase == "file" && request.url!.path == "/drive/v3/about" { return try about() }
                        switch cause.name {
                        case "task": cancellation.cancel()
                        case "parent": parent.close()
                        case "deadline": budget.advance(120)
                        default: break
                        }
                        throw URLError(cause.code)
                    }
                    let transport = http()
                    let provider: any GoogleDriveTokenProvider
                    if phase == "token" { provider = SharedExchangeTokens(transport: transport) } else { provider = Tokens() }
                    let client = GoogleDriveClient(http: transport, oauth: provider, accountID: "owner-123",
                        check: { try parent.check(); try budget.check() }, requestTimeout: budget.requestTimeout)
                    let operation = Task<Void, Error> { @MainActor in
                        try await client.validateAccount()
                        if phase == "file" { _ = try await client.generateID() }
                    }
                    cancellation.install(operation)
                    do { try await operation.value; throw ProbeFailure(message: "Failed awaited request was accepted") }
                    catch is CancellationError { try require(cause.name != "network", "Live network cancellation was silently hidden") }
                    catch let error as URLError { try require(cause.name == "network" && error.code == cause.code, "System cancellation became an ordinary network failure") }
                    // Shared credential refresh is not owned by a cancelled
                    // upload waiter. It may finish one same-request timeout retry
                    // within its original budget; that waiter still cannot issue
                    // account/file work. Live metadata timeout also gets one retry.
                    let retried = cause.code == .timedOut && (phase == "token" || (phase == "account" && cause.name == "network"))
                    let expected = phase == "file" ? 2 : (retried ? 2 : 1)
                    try require(trace.count { _ in true } == expected, "Boundary exceeded its allowed shared-refresh/metadata retry count")
                    if phase == "token" { try require(trace.count { $0.url!.host != "oauth2.googleapis.com" } == 0,
                        "Expired/cancelled token waiter issued an account or file request") }
                }
            }
        }
        await test("chunked upload, durable session before bytes, remote readback") {
            var (ledger, manifest, artifact, file) = try fixture(Data(repeating: 7, count: 1_048_580), root: root)
            let trace = Trace(), gate = Gate(); var sessions: [String?] = []
            let remoteBytes = try remote(ledger, manifest, artifact)
            MockProtocol.install { request in
                trace.append(request); let path = request.url!.path
                if path == "/drive/v3/about" { return try about() }
                if path == "/drive/v3/files/audio-123" { return trace.count { $0.httpMethod == "PUT" } >= 2 ? .init(code: 200, data: remoteBytes) : .init(code: 404) }
                if request.httpMethod == "POST" { return .init(code: 200, headers: ["Location": "https://www.googleapis.com/upload/drive/v3/files?upload_id=synthetic-session"]) }
                let range = request.value(forHTTPHeaderField: "Content-Range")
                if range == "bytes 0-1048575/1048580" { return .init(code: 308, headers: ["Range": "bytes=0-1048575"]) }
                try require(range == "bytes 1048576-1048579/1048580", "Unexpected chunk range")
                return .init(code: 200)
            }
            let client = GoogleDriveClient(http: http(), oauth: Tokens(), accountID: "owner-123", check: gate.check)
            try await client.validateAccount()
            let result = try await client.upload(file: file, artifact: artifact, manifest: manifest, folderID: "folder-123", libraryID: ledger.libraryID) { url in
                try require(trace.count { $0.httpMethod == "PUT" } == 0, "Bytes sent before session persisted"); sessions.append(url)
            }
            try require(sessions.count == 1, "Session not persisted exactly once")
            try ledger.recordVerified(segmentID: manifest.id, key: artifact.key, file: result, in: "owner-123")
            try requireAudioReceipt(ledger, manifest, artifact)
        }
        await test("resume starts at server-confirmed offset") {
            var (ledger, manifest, artifact, file) = try fixture(Data(repeating: 3, count: 1_048_580), root: root)
            try ledger.recordSession(segmentID: manifest.id, key: artifact.key, url: "https://www.googleapis.com/upload/drive/v3/files?upload_id=original")
            artifact = ledger.jobs[0].artifacts[0]
            let remoteBytes = try remote(ledger, manifest, artifact), trace = Trace()
            MockProtocol.install { request in
                trace.append(request)
                if request.url!.path == "/drive/v3/about" { return try about() }
                if request.url!.path == "/drive/v3/files/audio-123" { return trace.count { $0.httpMethod == "PUT" } >= 2 ? .init(code: 200, data: remoteBytes) : .init(code: 404) }
                try require(request.httpMethod == "PUT", "Resumption created another upload")
                if request.value(forHTTPHeaderField: "Content-Range") == "bytes */1048580" { return .init(code: 308, headers: ["Range": "bytes=0-1048575"]) }
                try require(request.value(forHTTPHeaderField: "Content-Range") == "bytes 1048576-1048579/1048580", "Resumed from wrong offset")
                return .init(code: 200)
            }
            let client = GoogleDriveClient(http: http(), oauth: Tokens(), accountID: "owner-123", check: {})
            let result = try await client.upload(file: file, artifact: artifact, manifest: manifest, folderID: "folder-123", libraryID: ledger.libraryID) { _ in throw ProbeFailure(message: "Live session replaced") }
            try require(ledger.savedAudioCount == 0, "HTTP 200 invented a receipt before exact metadata validation")
            try ledger.recordVerified(segmentID: manifest.id, key: artifact.key, file: result, in: "owner-123")
            try requireAudioReceipt(ledger, manifest, artifact)
        }
        for status in [404, 410] {
            await test("expired session \(status) recreates same preallocated file with exact audio receipt") {
                var (ledger, manifest, artifact, file) = try fixture(Data(repeating: 3, count: 8), root: root)
                try ledger.recordSession(segmentID: manifest.id, key: artifact.key, url: "https://www.googleapis.com/upload/drive/v3/files?upload_id=expired")
                artifact = ledger.jobs[0].artifacts[0]
                let remoteBytes = try remote(ledger, manifest, artifact), trace = Trace(); var saved: [String?] = []
                MockProtocol.install { request in
                    trace.append(request)
                    if request.url!.path == "/drive/v3/about" { return try about() }
                    if request.url!.path == "/drive/v3/files/audio-123" { return trace.count { $0.httpMethod == "PUT" } >= 2 ? .init(code: 200, data: remoteBytes) : .init(code: 404) }
                    if request.httpMethod == "POST" { return .init(code: 200, headers: ["Location": "https://www.googleapis.com/upload/drive/v3/files?upload_id=replacement"]) }
                    return request.url!.query!.contains("expired") ? .init(code: status) : .init(code: 200)
                }
                let client = GoogleDriveClient(http: http(), oauth: Tokens(), accountID: "owner-123", check: {})
                let result = try await client.upload(file: file, artifact: artifact, manifest: manifest, folderID: "folder-123", libraryID: ledger.libraryID) { url in
                    saved.append(url); try ledger.recordSession(segmentID: manifest.id, key: artifact.key, url: url)
                }
                try require(saved.count == 2 && saved[0] == nil && saved[1] != nil, "Expiry did not clear then persist replacement")
                try require(result.id == "audio-123" && ledger.savedAudioCount == 0, "Expiry changed deterministic file ID or HTTP 200 created a receipt")
                try ledger.recordVerified(segmentID: manifest.id, key: artifact.key, file: result, in: "owner-123")
                try requireAudioReceipt(ledger, manifest, artifact)
            }
        }
        await test("409 deterministic readback uses original file ID") {
            var (ledger, manifest, artifact, file) = try fixture(Data(repeating: 1, count: 8), root: root)
            let remoteBytes = try remote(ledger, manifest, artifact), trace = Trace()
            MockProtocol.install { request in
                trace.append(request)
                if request.url!.path == "/drive/v3/about" { return try about() }
                if request.httpMethod == "POST" { return .init(code: 409) }
                return trace.count { $0.httpMethod == "POST" } == 0 ? .init(code: 404) : .init(code: 200, data: remoteBytes)
            }
            let client = GoogleDriveClient(http: http(), oauth: Tokens(), accountID: "owner-123", check: {})
            let result = try await client.upload(file: file, artifact: artifact, manifest: manifest, folderID: "folder-123", libraryID: ledger.libraryID) { _ in throw ProbeFailure(message: "Conflict created session") }
            try require(result.id == artifact.fileID, "Conflict accepted a different file")
            try require(trace.count { $0.httpMethod == "PUT" } == 0, "Conflict sent audio again")
            try ledger.recordVerified(segmentID: manifest.id, key: artifact.key, file: result, in: "owner-123")
            try requireAudioReceipt(ledger, manifest, artifact)
        }
        await test("REC-32 resumable cold ledger restores original uploadURL and server offset before exact audio receipt") {
            let bytes = Data(repeating: 11, count: 1_048_580)
            var (ledger, manifest, artifact, file) = try fixture(bytes, root: root)
            let persisted = root.appendingPathComponent(UUID().uuidString + "-ledger.json")
            let session = "https://www.googleapis.com/upload/drive/v3/files?upload_id=cold-offset"
            let gate = Gate(), initial = Trace(), remoteBytes = try remote(ledger, manifest, artifact)
            MockProtocol.install { request in
                initial.append(request)
                if request.url!.path == "/drive/v3/about" { return try about() }
                if request.httpMethod == "GET" { return .init(code: 404) }
                if request.httpMethod == "POST" { return .init(code: 200, headers: ["Location": session]) }
                let durable = try TransportCodec.decode(GoogleDriveLibraryLedger.self, from: Data(contentsOf: persisted))
                try require(durable.jobs[0].artifacts[0].uploadURL == session && durable.savedAudioCount == 0,
                    "First body PUT preceded durable session persistence or invented a receipt")
                try require(request.value(forHTTPHeaderField: "Content-Range") == "bytes 0-1048575/1048580",
                    "Initial chunk did not begin at zero")
                gate.close(); return .init(code: 308, headers: ["Range": "bytes=0-1048575"])
            }
            let first = GoogleDriveClient(http: http(), oauth: Tokens(), accountID: "owner-123", check: gate.check)
            do {
                _ = try await first.upload(file: file, artifact: artifact, manifest: manifest, folderID: "folder-123", libraryID: ledger.libraryID) { url in
                    try ledger.recordSession(segmentID: manifest.id, key: artifact.key, url: url)
                    try TransportCodec.encode(ledger).write(to: persisted, options: .atomic)
                }
                throw ProbeFailure(message: "Interrupted first process produced a receipt")
            } catch is CancellationError { }
            try require(initial.count { $0.httpMethod == "PUT" } == 1 && ledger.savedAudioCount == 0,
                "Interrupted process advanced past its first chunk")
            ledger = try TransportCodec.decode(GoogleDriveLibraryLedger.self, from: Data(contentsOf: persisted))
            try ledger.validate(); artifact = ledger.jobs[0].artifacts[0]
            try require(artifact.uploadURL == session && artifact.fileID == "audio-123", "Cold reconstruction lost upload identity")
            let resumed = Trace()
            MockProtocol.install { request in
                resumed.append(request)
                if request.url!.path == "/drive/v3/about" { return try about() }
                if request.httpMethod == "GET" {
                    return resumed.count { $0.httpMethod == "PUT" } == 2 ? .init(code: 200, data: remoteBytes) : .init(code: 404)
                }
                try require(request.httpMethod == "PUT" && request.url!.absoluteString == session,
                    "Cold recovery allocated or addressed another session")
                if request.value(forHTTPHeaderField: "Content-Range") == "bytes */1048580" {
                    return .init(code: 308, headers: ["Range": "bytes=0-1048575"])
                }
                try require(request.value(forHTTPHeaderField: "Content-Range") == "bytes 1048576-1048579/1048580",
                    "Cold recovery resent the server-confirmed prefix")
                return .init(code: 200)
            }
            let second = GoogleDriveClient(http: http(), oauth: Tokens(), accountID: "owner-123", check: {})
            let result = try await second.upload(file: file, artifact: artifact, manifest: manifest, folderID: "folder-123", libraryID: ledger.libraryID) { _ in
                throw ProbeFailure(message: "Cold recovery replaced live session")
            }
            try require(ledger.savedAudioCount == 0, "Cold HTTP 200 was credited before metadata verification")
            try ledger.recordVerified(segmentID: manifest.id, key: artifact.key, file: result, in: "owner-123")
            try TransportCodec.encode(ledger).write(to: persisted, options: .atomic)
            let confirmed = try TransportCodec.decode(GoogleDriveLibraryLedger.self, from: Data(contentsOf: persisted))
            try requireAudioReceipt(confirmed, manifest, artifact)
        }
        for anomaly in ["rollback", "stalled", "jump"] {
            await test("REC-32 resumable \(anomaly) offset refuses false progress then reconciles a fresh server offset") {
                let total = 2_097_160
                var (ledger, manifest, artifact, file) = try fixture(Data(repeating: 12, count: total), root: root)
                let session = "https://www.googleapis.com/upload/drive/v3/files?upload_id=offset-" + anomaly
                let trace = Trace(), remoteBytes = try remote(ledger, manifest, artifact)
                MockProtocol.install { request in
                    trace.append(request)
                    if request.url!.path == "/drive/v3/about" { return try about() }
                    if request.httpMethod == "GET" { return .init(code: 404) }
                    if request.httpMethod == "POST" { return .init(code: 200, headers: ["Location": session]) }
                    let range = request.value(forHTTPHeaderField: "Content-Range")
                    if range == "bytes 0-1048575/2097160" { return .init(code: 308, headers: ["Range": "bytes=0-1048575"]) }
                    try require(range == "bytes 1048576-2097151/2097160", "Invalid acknowledgement triggered an extra body PUT")
                    let end = anomaly == "rollback" ? 524_287 : anomaly == "stalled" ? 1_048_575 : 2_097_152
                    return .init(code: 308, headers: ["Range": "bytes=0-\(end)"])
                }
                let first = GoogleDriveClient(http: http(), oauth: Tokens(), accountID: "owner-123", check: {})
                do {
                    _ = try await first.upload(file: file, artifact: artifact, manifest: manifest, folderID: "folder-123", libraryID: ledger.libraryID) { url in
                        try ledger.recordSession(segmentID: manifest.id, key: artifact.key, url: url)
                    }
                    throw ProbeFailure(message: "Invalid acknowledgement was accepted as successful progress")
                } catch GoogleDriveError.invalidResumableOffset { }
                try require(trace.count { $0.httpMethod == "PUT" } == 2 && ledger.savedAudioCount == 0
                    && ledger.jobs[0].artifacts[0].uploadURL == session, "Invalid offset fabricated receipt or destroyed resumable identity")
                ledger = try TransportCodec.decode(GoogleDriveLibraryLedger.self, from: TransportCodec.encode(ledger))
                artifact = ledger.jobs[0].artifacts[0]
                let recovered = Trace()
                MockProtocol.install { request in
                    recovered.append(request)
                    if request.url!.path == "/drive/v3/about" { return try about() }
                    if request.httpMethod == "GET" {
                        return recovered.count { $0.httpMethod == "PUT" } == 3 ? .init(code: 200, data: remoteBytes) : .init(code: 404)
                    }
                    try require(request.httpMethod == "PUT" && request.url!.absoluteString == session,
                        "Offset recovery replaced the original session")
                    switch request.value(forHTTPHeaderField: "Content-Range") {
                    case "bytes */2097160": return .init(code: 308, headers: ["Range": "bytes=0-524287"])
                    case "bytes 524288-1572863/2097160": return .init(code: 308, headers: ["Range": "bytes=0-1572863"])
                    case "bytes 1572864-2097159/2097160": return .init(code: 200)
                    default: throw ProbeFailure(message: "Recovery ignored newly queried server offset")
                    }
                }
                let second = GoogleDriveClient(http: http(), oauth: Tokens(), accountID: "owner-123", check: {})
                let result = try await second.upload(file: file, artifact: artifact, manifest: manifest, folderID: "folder-123", libraryID: ledger.libraryID) { _ in
                    throw ProbeFailure(message: "Offset recovery replaced a live session")
                }
                try require(ledger.savedAudioCount == 0, "Offset recovery used HTTP 200 as a receipt")
                try ledger.recordVerified(segmentID: manifest.id, key: artifact.key, file: result, in: "owner-123")
                try requireAudioReceipt(ledger, manifest, artifact)
            }
        }
        for status in [404, 410] {
            await test("REC-32 resumable mid-chunk expiry \(status) clears URL and retries stable file before exact audio receipt") {
                var (ledger, manifest, artifact, file) = try fixture(Data(repeating: 13, count: 1_048_580), root: root)
                let old = "https://www.googleapis.com/upload/drive/v3/files?upload_id=mid-expired-\(status)"
                let replacement = "https://www.googleapis.com/upload/drive/v3/files?upload_id=mid-replacement-\(status)"
                let remoteBytes = try remote(ledger, manifest, artifact), initial = Trace()
                MockProtocol.install { request in
                    initial.append(request)
                    if request.url!.path == "/drive/v3/about" { return try about() }
                    if request.httpMethod == "GET" { return .init(code: 404) }
                    if request.httpMethod == "POST" { return .init(code: 200, headers: ["Location": old]) }
                    if request.value(forHTTPHeaderField: "Content-Range") == "bytes 0-1048575/1048580" {
                        return .init(code: 308, headers: ["Range": "bytes=0-1048575"])
                    }
                    return .init(code: status)
                }
                let first = GoogleDriveClient(http: http(), oauth: Tokens(), accountID: "owner-123", check: {})
                do {
                    _ = try await first.upload(file: file, artifact: artifact, manifest: manifest, folderID: "folder-123", libraryID: ledger.libraryID) { url in
                        try ledger.recordSession(segmentID: manifest.id, key: artifact.key, url: url)
                    }
                    throw ProbeFailure(message: "Expired body PUT completed")
                } catch GoogleDriveError.expiredSession { }
                ledger = try TransportCodec.decode(GoogleDriveLibraryLedger.self, from: TransportCodec.encode(ledger))
                artifact = ledger.jobs[0].artifacts[0]
                try require(artifact.uploadURL == nil && artifact.fileID == "audio-123" && artifact.verifiedAt == nil
                    && initial.count { $0.httpMethod == "PUT" } == 2 && ledger.savedAudioCount == 0,
                    "Midstream expiry lost stable ID, kept dead URL or invented receipt")
                let retried = Trace(); var saved: [String?] = []
                MockProtocol.install { request in
                    retried.append(request)
                    if request.url!.path == "/drive/v3/about" { return try about() }
                    if request.httpMethod == "GET" {
                        return retried.count { $0.httpMethod == "PUT" } == 2 ? .init(code: 200, data: remoteBytes) : .init(code: 404)
                    }
                    if request.httpMethod == "POST" { return .init(code: 200, headers: ["Location": replacement]) }
                    try require(request.url!.absoluteString == replacement, "Retry reused expired session")
                    if request.value(forHTTPHeaderField: "Content-Range") == "bytes 0-1048575/1048580" {
                        return .init(code: 308, headers: ["Range": "bytes=0-1048575"])
                    }
                    try require(request.value(forHTTPHeaderField: "Content-Range") == "bytes 1048576-1048579/1048580", "Restart lost chunk order")
                    return .init(code: 200)
                }
                let second = GoogleDriveClient(http: http(), oauth: Tokens(), accountID: "owner-123", check: {})
                let result = try await second.upload(file: file, artifact: artifact, manifest: manifest, folderID: "folder-123", libraryID: ledger.libraryID) { url in
                    try require(retried.count { $0.httpMethod == "PUT" } == 0, "Replacement bytes preceded its durable session")
                    saved.append(url); try ledger.recordSession(segmentID: manifest.id, key: artifact.key, url: url)
                }
                try require(saved == [replacement] && ledger.savedAudioCount == 0, "Restart bypassed persistence or strict receipt validation")
                try ledger.recordVerified(segmentID: manifest.id, key: artifact.key, file: result, in: "owner-123")
                try requireAudioReceipt(ledger, manifest, artifact)
            }
        }
        for metadata in ["missing", "wrong_source"] {
            await test("REC-32 resumable HTTP 200 with \(metadata) metadata cannot become a remote_verified receipt") {
                var (ledger, manifest, artifact, file) = try fixture(Data(repeating: 14, count: 8), root: root)
                let session = "https://www.googleapis.com/upload/drive/v3/files?upload_id=unverified-" + metadata
                let remoteBytes = try remote(ledger, manifest, artifact), firstTrace = Trace()
                var mismatched = try JSONSerialization.jsonObject(with: remoteBytes) as! [String: Any]
                var properties = mismatched["appProperties"] as! [String: String]
                properties["rfaSegmentID"] = UUID().uuidString.lowercased(); mismatched["appProperties"] = properties
                let wrongSource = try json(mismatched)
                MockProtocol.install { request in
                    firstTrace.append(request)
                    if request.url!.path == "/drive/v3/about" { return try about() }
                    if request.httpMethod == "POST" { return .init(code: 200, headers: ["Location": session]) }
                    if request.httpMethod == "PUT" { return .init(code: 200) }
                    return metadata == "wrong_source" && firstTrace.count { $0.httpMethod == "PUT" } == 1
                        ? .init(code: 200, data: wrongSource) : .init(code: 404)
                }
                let first = GoogleDriveClient(http: http(), oauth: Tokens(), accountID: "owner-123", check: {})
                do {
                    let result = try await first.upload(file: file, artifact: artifact, manifest: manifest, folderID: "folder-123", libraryID: ledger.libraryID) { url in
                        try ledger.recordSession(segmentID: manifest.id, key: artifact.key, url: url)
                    }
                    try ledger.recordVerified(segmentID: manifest.id, key: artifact.key, file: result, in: "owner-123")
                    throw ProbeFailure(message: "HTTP 200 bypassed exact remote metadata")
                } catch GoogleDriveError.invalidResponse where metadata == "missing" { }
                catch GoogleDriveLibraryError.invalidRemoteFile where metadata == "wrong_source" { }
                artifact = ledger.jobs[0].artifacts[0]
                try require(firstTrace.count { $0.httpMethod == "PUT" } == 1 && artifact.uploadURL == session
                    && artifact.verifiedAt == nil && artifact.verifiedUploadCorrelation == nil && ledger.savedAudioCount == 0,
                    "Missing/wrong-source metadata produced a receipt or dropped the original session")
                MockProtocol.install { request in
                    if request.url!.path == "/drive/v3/about" { return try about() }
                    try require(request.httpMethod == "GET" && request.url!.lastPathComponent == artifact.fileID,
                        "Metadata recovery resent bytes or changed stable file identity")
                    return .init(code: 200, data: remoteBytes)
                }
                let second = GoogleDriveClient(http: http(), oauth: Tokens(), accountID: "owner-123", check: {})
                let result = try await second.upload(file: file, artifact: artifact, manifest: manifest, folderID: "folder-123", libraryID: ledger.libraryID) { _ in
                    throw ProbeFailure(message: "Exact metadata recovery allocated another upload session")
                }
                try ledger.recordVerified(segmentID: manifest.id, key: artifact.key, file: result, in: "owner-123")
                try requireAudioReceipt(ledger, manifest, artifact)
            }
        }
        await test("pause while upload response awaits prevents next request") {
            let (ledger, manifest, artifact, file) = try fixture(Data(repeating: 1, count: 1_048_580), root: root)
            let gate = Gate(), trace = Trace()
            MockProtocol.install { request in
                trace.append(request)
                if request.url!.path == "/drive/v3/about" { return try about() }
                if request.url!.path == "/drive/v3/files/audio-123" { return .init(code: 404) }
                if request.httpMethod == "POST" { return .init(code: 200, headers: ["Location": "https://www.googleapis.com/upload/drive/v3/files?upload_id=pause"]) }
                gate.close(); return .init(code: 308, headers: ["Range": "bytes=0-1048575"])
            }
            let client = GoogleDriveClient(http: http(), oauth: Tokens(), accountID: "owner-123", check: gate.check)
            do {
                _ = try await client.upload(file: file, artifact: artifact, manifest: manifest, folderID: "folder-123", libraryID: ledger.libraryID) { _ in }
                throw ProbeFailure(message: "Paused upload completed")
            } catch is CancellationError { }
            try require(trace.count { $0.httpMethod == "PUT" } == 1, "Pause started another chunk")
        }
        await test("lost final response recovers original ID without another upload") {
            var (ledger, manifest, artifact, file) = try fixture(Data(repeating: 9, count: 8), root: root)
            let remoteBytes = try remote(ledger, manifest, artifact), initial = Trace()
            MockProtocol.install { request in
                initial.append(request)
                if request.url!.path == "/drive/v3/about" { return try about() }
                if request.url!.path == "/drive/v3/files/audio-123" { return .init(code: 404) }
                if request.httpMethod == "POST" { return .init(code: 200, headers: ["Location": "https://www.googleapis.com/upload/drive/v3/files?upload_id=lost-response"]) }
                // The server has stored the bytes, but this process never saw
                // its final response. The session was persisted beforehand.
                throw URLError(.networkConnectionLost)
            }
            let first = GoogleDriveClient(http: http(), oauth: Tokens(), accountID: "owner-123", check: {})
            do {
                _ = try await first.upload(file: file, artifact: artifact, manifest: manifest, folderID: "folder-123", libraryID: ledger.libraryID) { url in
                    try ledger.recordSession(segmentID: manifest.id, key: artifact.key, url: url)
                }
                throw ProbeFailure(message: "Lost final response reported success")
            } catch is URLError { }
            // Reconstruct durable state, exactly as another launch would do.
            ledger = try TransportCodec.decode(GoogleDriveLibraryLedger.self, from: TransportCodec.encode(ledger))
            try ledger.validate(); artifact = ledger.jobs[0].artifacts[0]
            let recovered = Trace()
            MockProtocol.install { request in
                recovered.append(request)
                if request.url!.path == "/drive/v3/about" { return try about() }
                try require(request.httpMethod == "GET" && request.url!.path == "/drive/v3/files/audio-123", "Recovery started another upload")
                return .init(code: 200, data: remoteBytes)
            }
            let second = GoogleDriveClient(http: http(), oauth: Tokens(), accountID: "owner-123", check: {})
            let result = try await second.upload(file: file, artifact: artifact, manifest: manifest, folderID: "folder-123", libraryID: ledger.libraryID) { _ in
                throw ProbeFailure(message: "Recovery allocated another session")
            }
            try ledger.recordVerified(segmentID: manifest.id, key: artifact.key, file: result, in: "owner-123")
            try require(ledger.savedAudioCount == 1 && result.id == "audio-123", "Recovery lost original file identity")
            try requireAudioReceipt(ledger, manifest, artifact)
            try require(recovered.count { $0.httpMethod == "POST" || $0.httpMethod == "PUT" } == 0, "Recovery resent stored bytes")
        }
        await test("verified network recovery clears stale error without claiming completion") {
            var (ledger, manifest, artifact, _) = try fixture(Data(repeating: 7, count: 8), root: root)
            var progress = GoogleDriveSyncProgress()
            let request = progress.snapshot
            progress.acceptSnapshot([manifest], previousIDs: [], request: request)
            progress.recordOperationFailure("Synthetic TLS connection failure", isNetwork: true)
            let selected = GoogleDriveSyncProgress.UploadChoice(segmentID: manifest.id, artifactKey: artifact.key, isPrioritySmall: false)
            do {
                try progress.didVerify(selected, in: ledger.jobs)
                throw ProbeFailure(message: "Unverified upload was accepted as network recovery")
            } catch GoogleDriveLibraryError.invalidState { }
            try require(progress.operationError != nil && ledger.savedAudioCount == 0, "Unverified attempt erased the failure")
            do {
                _ = try acceptSyntheticReceipt(selected, in: &ledger, checksum: String(repeating: "0", count: 64))
                throw ProbeFailure(message: "Invalid remote checksum was accepted")
            } catch GoogleDriveLibraryError.invalidRemoteFile { }
            try require(progress.operationError != nil && ledger.savedAudioCount == 0, "Rejected remote metadata erased the failure")
            _ = try acceptSyntheticReceipt(selected, in: &ledger)
            try progress.didVerify(selected, in: ledger.jobs)
            try require(progress.operationError == nil && progress.errorMessage == nil, "Verified recovery retained stale TLS error")
            try require(progress.remaining.map(\.id) == [manifest.id] && progress.needsDiscovery
                && progress.snapshotRevision == request.revision && progress.revision == request.revision,
                "Network recovery changed discovery coverage")
            try require(ledger.enabled && ledger.savedAudioCount == 1 && ledger.hasPendingFiles,
                "Network recovery changed authorization or marked pending manifest saved")
            try require(progress.phase(hasPendingFiles: ledger.hasPendingFiles) == .discovering,
                "Partial discovery was reported as complete after network recovery")
            try progress.finishRecord(manifest.id, issue: nil)
            progress.finishSlice(observedRevision: request.revision)
            try require(progress.phase(hasPendingFiles: ledger.hasPendingFiles) == .uploading,
                "Network recovery hid the remaining upload")
        }
        await test("new network failure survives replay of an older verified receipt") {
            var (ledger, manifest, artifact, _) = try fixture(Data(repeating: 8, count: 8), root: root)
            var progress = GoogleDriveSyncProgress()
            let audio = GoogleDriveSyncProgress.UploadChoice(segmentID: manifest.id, artifactKey: artifact.key, isPrioritySmall: false)
            progress.recordOperationFailure("Synthetic previous timeout", isNetwork: true)
            _ = try acceptSyntheticReceipt(audio, in: &ledger)
            try progress.didVerify(audio, in: ledger.jobs)
            try require(progress.operationError == nil, "Initial verified recovery did not clear the transport error")
            progress.recordOperationFailure("Synthetic new connection failure", isNetwork: true)
            try progress.didVerify(audio, in: ledger.jobs)
            try require(progress.operationError == "Synthetic new connection failure" && progress.errorMessage != nil,
                "Replayed old receipt hid a later network failure")
            let pending = ledger.jobs[0].artifacts.first { $0.kind == .manifest }!
            let metadata = GoogleDriveSyncProgress.UploadChoice(segmentID: manifest.id, artifactKey: pending.key, isPrioritySmall: true)
            _ = try acceptSyntheticReceipt(metadata, in: &ledger)
            try progress.didVerify(metadata, in: ledger.jobs)
            try require(progress.operationError == nil && progress.smallVerifiedSinceAudio == 1,
                "New remote receipt failed to recover or spend one fairness turn")
            progress.recordOperationFailure("Synthetic later timeout", isNetwork: true)
            try progress.didVerify(metadata, in: ledger.jobs)
            try require(progress.operationError == "Synthetic later timeout" && progress.smallVerifiedSinceAudio == 1,
                "Duplicate metadata receipt hid the next failure or double-credited fairness")
        }
        await test("network recovery preserves local operation errors and derived transcript issues") {
            var (ledger, manifest, artifact, _) = try fixture(Data(repeating: 9, count: 8), root: root)
            let localRoot = root.appendingPathComponent(UUID().uuidString)
            let repository = try TranscriptRepository(root: localRoot)
            let invalid = localRoot.appendingPathComponent("transcripts").appendingPathComponent(manifest.id.uuidString.lowercased() + ".json")
            try Data("synthetic invalid JSON".utf8).write(to: invalid)
            let inspection = GoogleDriveSyncProgress.inspectTranscript(repository: repository, manifest: manifest)
            try require(inspection.issue != nil, "Synthetic corrupt transcript was not detected")
            var progress = GoogleDriveSyncProgress()
            let request = progress.snapshot
            progress.acceptSnapshot([manifest], previousIDs: [], request: request)
            try progress.finishRecord(manifest.id, issue: inspection.issue)
            progress.finishSlice(observedRevision: request.revision)
            progress.recordOperationFailure("Synthetic old TLS failure", isNetwork: true)
            let audio = GoogleDriveSyncProgress.UploadChoice(segmentID: manifest.id, artifactKey: artifact.key, isPrioritySmall: false)
            _ = try acceptSyntheticReceipt(audio, in: &ledger)
            try progress.didVerify(audio, in: ledger.jobs)
            try require(progress.operationError == nil && progress.hasIssues && progress.errorMessage != nil,
                "Remote recovery erased the independent local transcript problem")
            try require(progress.phase(hasPendingFiles: ledger.hasPendingFiles) == .uploading
                && progress.phase(hasPendingFiles: false) == .transcriptIssues(1),
                "Remote recovery incorrectly reported all artifacts complete")
            progress.recordOperationFailure("Synthetic local persistence failure")
            let pending = ledger.jobs[0].artifacts.first { $0.kind == .manifest }!
            let metadata = GoogleDriveSyncProgress.UploadChoice(segmentID: manifest.id, artifactKey: pending.key, isPrioritySmall: false)
            _ = try acceptSyntheticReceipt(metadata, in: &ledger)
            try progress.didVerify(metadata, in: ledger.jobs)
            try require(progress.operationError == "Synthetic local persistence failure" && progress.hasIssues,
                "Successful remote receipt erased a non-network operation error")
            try require(progress.errorMessage?.contains("Synthetic local persistence failure") == true
                && progress.errorMessage?.contains("1") == true, "Independent local problems did not remain visible")
        }
        await test("completion waits for discovery and every existing artifact") {
            let (_, first, _, _) = try fixture(Data(repeating: 1, count: 8), root: root)
            let (_, second, _, _) = try fixture(Data(repeating: 2, count: 8), root: root)
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            var progress = GoogleDriveSyncProgress()
            progress.recordOperationFailure("Synthetic previous network error", isNetwork: true)
            let request = progress.snapshot
            progress.acceptSnapshot([first, second], previousIDs: [], request: request)
            let initial = progress.remaining[0]
            try progress.finishRecord(initial.id, issue: nil)
            progress.finishSlice(observedRevision: request.revision, at: now)
            try require(progress.finishSuccessfulRound(hasPendingFiles: false) == .discovering, "Partial scan claimed completion")
            try require(progress.operationError != nil, "Partial scan erased unproven network error")
            try progress.finishRecord(progress.remaining[0].id, issue: nil)
            progress.finishSlice(observedRevision: request.revision, at: now)
            try require(progress.finishSuccessfulRound(hasPendingFiles: true) == .uploading, "Pending artifact claimed completion")
            try require(progress.operationError != nil, "Pending upload erased old network error")
            try require(progress.finishSuccessfulRound(hasPendingFiles: false) == .complete, "Completed successful scan stayed incomplete")
            try require(progress.errorMessage == nil, "Successful empty queue retained stale network error")
            progress.retryIssuesIfDue(at: now.addingTimeInterval(3_600))
            try require(!progress.hasWork && progress.remaining.isEmpty && progress.issueRetryAt == nil, "Normal missing transcripts created infinite rechecks")
        }
        await test("corrupt derived text stays visible without blocking valid audio") {
            let (ledger, manifest, artifact, file) = try fixture(Data(repeating: 6, count: 8), root: root)
            let localRoot = root.appendingPathComponent(UUID().uuidString)
            let repository = try TranscriptRepository(root: localRoot)
            let invalid = localRoot.appendingPathComponent("transcripts").appendingPathComponent(manifest.id.uuidString.lowercased() + ".json")
            try Data("synthetic invalid JSON".utf8).write(to: invalid)
            let inspection = GoogleDriveSyncProgress.inspectTranscript(repository: repository, manifest: manifest)
            try require(inspection.issue != nil && inspection.transcript == nil, "Corrupt transcript was silently treated as absent")
            var progress = GoogleDriveSyncProgress()
            let request = progress.snapshot
            progress.acceptSnapshot([manifest], previousIDs: [], request: request)
            try progress.finishRecord(manifest.id, issue: inspection.issue)
            progress.finishSlice(observedRevision: request.revision)
            try require(progress.phase(hasPendingFiles: true) == .uploading && progress.hasIssues, "Derived issue blocked original-audio phase")
            let remoteBytes = try remote(ledger, manifest, artifact), trace = Trace()
            MockProtocol.install { request in
                trace.append(request)
                if request.url!.path == "/drive/v3/about" { return try about() }
                if request.url!.path == "/drive/v3/files/audio-123" { return trace.count { $0.httpMethod == "PUT" } > 0 ? .init(code: 200, data: remoteBytes) : .init(code: 404) }
                if request.httpMethod == "POST" { return .init(code: 200, headers: ["Location": "https://www.googleapis.com/upload/drive/v3/files?upload_id=derived-issue"]) }
                return .init(code: 200)
            }
            let client = GoogleDriveClient(http: http(), oauth: Tokens(), accountID: "owner-123", check: {})
            let uploaded = try await client.upload(file: file, artifact: artifact, manifest: manifest, folderID: "folder-123", libraryID: ledger.libraryID) { _ in }
            var verified = ledger
            try verified.recordVerified(segmentID: manifest.id, key: artifact.key, file: uploaded, in: "owner-123")
            try require(verified.savedAudioCount == 1 && verified.enabled, "Bad transcript prevented valid original audio receipt")
            try require(progress.finishSuccessfulRound(hasPendingFiles: false) == .transcriptIssues(1) && progress.errorMessage != nil, "Bad transcript was reported as fully saved")
        }
        await test("only bad transcripts recheck and repair still waits for derived uploads") {
            var (ledger, broken, _, _) = try fixture(Data(repeating: 4, count: 8), root: root)
            let (_, normal, _, _) = try fixture(Data(repeating: 5, count: 8), root: root)
            let localRoot = root.appendingPathComponent(UUID().uuidString)
            let repository = try TranscriptRepository(root: localRoot), now = Date(timeIntervalSince1970: 1_700_000_000)
            let invalid = localRoot.appendingPathComponent("transcripts").appendingPathComponent(broken.id.uuidString.lowercased() + ".json")
            try Data("{}".utf8).write(to: invalid)
            var progress = GoogleDriveSyncProgress()
            let request = progress.snapshot
            progress.acceptSnapshot([broken, normal], previousIDs: [], request: request)
            while let manifest = progress.remaining.first {
                let result = GoogleDriveSyncProgress.inspectTranscript(repository: repository, manifest: manifest)
                try progress.finishRecord(manifest.id, issue: result.issue)
            }
            progress.finishSlice(observedRevision: request.revision, at: now)
            progress.recordOperationFailure("Synthetic previous HTTP 503")
            try require(progress.finishSuccessfulRound(hasPendingFiles: false) == .transcriptIssues(1), "Derived issue disappeared after successful request recovery")
            try require(progress.operationError == nil && progress.errorMessage != nil, "Recovered network error did not remain separate from discovery issue")
            progress.retryIssuesIfDue(at: now.addingTimeInterval(59))
            try require(!progress.needsDiscovery && progress.remaining.isEmpty, "Bad record retried before due time")
            progress.retryIssuesIfDue(at: now.addingTimeInterval(60))
            try require(progress.remaining.map(\.id) == [broken.id], "Issue retry rescanned normal transcript-free records")
            let repaired = SegmentTranscript(segmentID: broken.id, audioSHA256: broken.sha256, locale: "zh-CN", engine: "synthetic-fixture", createdAt: now, text: "合成修复文字", spans: [])
            try TransportCodec.encode(repaired).write(to: invalid, options: .atomic)
            let inspection = GoogleDriveSyncProgress.inspectTranscript(repository: repository, manifest: broken)
            try require(inspection.transcript == repaired && inspection.issue == nil, "Repaired source was not revalidated")
            try ledger.discoverTranscript(repaired, for: broken)
            try progress.finishRecord(broken.id, issue: inspection.issue)
            progress.finishSlice(observedRevision: request.revision, at: now.addingTimeInterval(60))
            try require(!progress.hasIssues && progress.issueRetryAt == nil && progress.errorMessage == nil, "Resolved derived issue stayed stuck")
            try require(ledger.jobs[0].artifacts.count == 4 && progress.finishSuccessfulRound(hasPendingFiles: true) == .uploading, "Repair claimed completion before its JSON/TXT receipts")
            try require(progress.finishSuccessfulRound(hasPendingFiles: false) == .complete, "Repaired and uploaded state never completed")
            progress.retryIssuesIfDue(at: now.addingTimeInterval(600))
            try require(!progress.hasWork, "Repaired issue continued empty rechecks")
        }
        await test("mismatched transcript is an issue and a later absent file can resolve it") {
            let (_, manifest, _, _) = try fixture(Data(repeating: 2, count: 8), root: root)
            let localRoot = root.appendingPathComponent(UUID().uuidString)
            let repository = try TranscriptRepository(root: localRoot), now = Date(timeIntervalSince1970: 1_700_000_000)
            let invalid = localRoot.appendingPathComponent("transcripts").appendingPathComponent(manifest.id.uuidString.lowercased() + ".json")
            let mismatch = SegmentTranscript(segmentID: manifest.id, audioSHA256: String(repeating: "f", count: 64), locale: "zh-CN", engine: "synthetic-fixture", createdAt: now, text: "合成不匹配文字", spans: [])
            try TransportCodec.encode(mismatch).write(to: invalid)
            let inspected = GoogleDriveSyncProgress.inspectTranscript(repository: repository, manifest: manifest)
            try require(inspected.issue != nil && inspected.transcript == nil, "Mismatched audio identity was silently accepted")
            var progress = GoogleDriveSyncProgress(); let request = progress.snapshot
            progress.acceptSnapshot([manifest], previousIDs: [], request: request)
            try progress.finishRecord(manifest.id, issue: inspected.issue)
            progress.finishSlice(observedRevision: request.revision, at: now)
            try require(progress.finishSuccessfulRound(hasPendingFiles: false) == .transcriptIssues(1), "Mismatched transcript claimed completion")
            try FileManager.default.removeItem(at: invalid)
            progress.retryIssuesIfDue(at: now.addingTimeInterval(60))
            let absent = GoogleDriveSyncProgress.inspectTranscript(repository: repository, manifest: manifest)
            try require(absent.transcript == nil && absent.issue == nil, "No-transcript state incorrectly became an error")
            try progress.finishRecord(manifest.id, issue: absent.issue)
            progress.finishSlice(observedRevision: request.revision, at: now.addingTimeInterval(60))
            try require(progress.finishSuccessfulRound(hasPendingFiles: false) == .complete && !progress.hasWork, "Resolved absent source continued issue retry")
        }
        await test("new discovery event during detached snapshot cannot be lost") {
            let (_, old, _, _) = try fixture(Data(repeating: 1, count: 8), root: root)
            let (_, recent, _, _) = try fixture(Data(repeating: 2, count: 8), root: root)
            var progress = GoogleDriveSyncProgress(); let original = progress.snapshot
            progress.requestDiscovery(prioritizing: recent.id)
            progress.acceptSnapshot([old], previousIDs: [], request: original)
            try progress.finishRecord(old.id, issue: nil)
            progress.finishSlice(observedRevision: original.revision)
            try require(progress.needsDiscovery && progress.needsSnapshot, "Old snapshot swallowed a newer recording/transcript event")
            try require(progress.finishSuccessfulRound(hasPendingFiles: false) == .discovering, "Lost-wake state claimed completion")
            let current = progress.snapshot
            progress.acceptSnapshot([old, recent], previousIDs: [old.id], request: current)
            try require(progress.remaining.first?.id == recent.id, "Newest saved transcript lost its discovery priority")
        }
        await test("filename hints accept only canonical top-level lowercase UUID JSON names") {
            let id = UUID(), canonical = id.uuidString.lowercased() + ".json"
            let hints = GoogleDriveSyncProgress.transcriptHints(fileNames: [canonical, canonical,
                id.uuidString.uppercased() + ".json", id.uuidString.lowercased() + ".JSON", "." + canonical,
                "nested/" + canonical, canonical + ".tmp", "../" + canonical, "not-a-uuid.json"])
            try require(hints == [id], "Noncanonical, nested, or temporary names became transcript hints")
        }
        await test("oldest 18 transcript hints precede 263 new jobs without replaying consumed hints") {
            let manifests = orderedManifests(281), hinted = Set(manifests.suffix(18).map(\.id))
            var progress = GoogleDriveSyncProgress(), request = progress.snapshot
            progress.acceptSnapshot(manifests, previousIDs: [], request: request, transcriptHints: hinted)
            try require(Set(progress.remaining.prefix(18).map(\.id)) == hinted, "All-new jobs drowned old transcript hints in date order")
            var consumed = Set<UUID>()
            for _ in 0..<16 {
                let id = progress.remaining.first!.id; consumed.insert(id)
                try progress.finishRecord(id, issue: nil)
            }
            progress.finishSlice(observedRevision: request.revision)
            progress.requestDiscovery(); request = progress.snapshot
            progress.acceptSnapshot(manifests, previousIDs: Set(manifests.map(\.id)), request: request, transcriptHints: hinted)
            try require(Set(progress.remaining.prefix(2).map(\.id)) == hinted.subtracting(consumed), "Another snapshot replayed the first 16 hints ahead of the final two")
            for _ in 0..<2 { try progress.finishRecord(progress.remaining.first!.id, issue: nil) }
            progress.finishSlice(observedRevision: request.revision)
            progress.requestDiscovery(); request = progress.snapshot
            progress.acceptSnapshot(manifests, previousIDs: Set(manifests.map(\.id)), request: request, transcriptHints: hinted)
            try require(progress.remaining.first?.id == manifests[0].id, "Consumed hint repeatedly stole the ordinary scan's first turn")
            progress.requestDiscovery(prioritizing: manifests.last!.id); request = progress.snapshot
            progress.acceptSnapshot(manifests, previousIDs: Set(manifests.map(\.id)), request: request, transcriptHints: hinted)
            try require(progress.remaining.first?.id == manifests.last!.id, "An explicit late transcript save lost priority after its earlier hint was consumed")
            try require(Set(progress.remaining.map(\.id)).count == progress.remaining.count, "Hint discovery duplicated queue entries")
        }
        await test("filename hints cannot expand a future-only grant or introduce an unknown source") {
            let manifests = orderedManifests(3), baseline: Set<UUID> = [manifests[1].id, manifests[2].id]
            let ledger = try priorityLedger(manifests, scope: .futureOnly, baseline: baseline), before = try TransportCodec.encode(ledger)
            var progress = GoogleDriveSyncProgress(); let request = progress.snapshot
            progress.acceptSnapshot(ledger.jobs.map(\.manifest), previousIDs: [], request: request,
                transcriptHints: baseline.union([UUID(), manifests[0].id]))
            try require(progress.remaining.map(\.id) == [manifests[0].id], "A hinted source bypassed the Drive authorization fence")
            let after = try TransportCodec.encode(ledger)
            try require(before == after && ledger.jobs.count == 1, "Priority hints mutated the scope or durable ledger")
        }
        await test("validated transcript job gets manifest JSON TXT before ordinary large audio") {
            let manifests = orderedManifests(2), old = manifests[1]
            var ledger = try priorityLedger(manifests), progress = GoogleDriveSyncProgress()
            try addPriorityTranscript(old, to: &ledger)
            for kind in [GoogleDriveArtifact.Kind.manifest, .transcriptJSON, .transcriptText] {
                let selected = progress.nextUpload(in: ledger.jobs)!
                try require(selected.segmentID == old.id && selected.isPrioritySmall, "New transcript-free jobs delayed the old derived bundle")
                let actualKind = try acceptSyntheticReceipt(selected, in: &ledger)
                try require(actualKind == kind, "Derived upload order lost manifest-before-JSON/TXT binding")
                try progress.didVerify(selected, in: ledger.jobs)
            }
            try require(progress.smallVerifiedSinceAudio == 3, "Three actual small receipts did not create an audio turn")
            let selected = progress.nextUpload(in: ledger.jobs)!
            try require(selected.segmentID == old.id && !selected.isPrioritySmall, "Audio turn ignored the just-published transcript's source audio")
            let kind = try acceptSyntheticReceipt(selected, in: &ledger)
            try require(kind == .audio, "Small-file turn did not yield to original audio")
            try progress.didVerify(selected, in: ledger.jobs)
            try require(progress.smallVerifiedSinceAudio == 0 && progress.nextUpload(in: ledger.jobs)?.segmentID == manifests[0].id,
                "Verified source audio did not return to ordinary delivery")
        }
        await test("audio debt survives a round boundary and new text while resuming original session") {
            let manifests = orderedManifests(3)
            var ledger = try priorityLedger(manifests), progress = GoogleDriveSyncProgress()
            try addPriorityTranscript(manifests[2], to: &ledger)
            let audio = ledger.jobs[0].artifacts.first { $0.kind == .audio }!
            try ledger.allocateFile(segmentID: manifests[0].id, key: audio.key, fileID: "original-audio-123")
            let session = "https://www.googleapis.com/upload/drive/v3/files?upload_id=preserved-priority-session"
            try ledger.recordSession(segmentID: manifests[0].id, key: audio.key, url: session)
            for _ in 0..<3 {
                let selected = progress.nextUpload(in: ledger.jobs)!
                _ = try acceptSyntheticReceipt(selected, in: &ledger); try progress.didVerify(selected, in: ledger.jobs)
            }
            // Model an execution-budget exit, another discovery event, and a
            // durable queue readback while keeping the live coordinator state.
            ledger = try TransportCodec.decode(GoogleDriveLibraryLedger.self, from: TransportCodec.encode(ledger))
            try addPriorityTranscript(manifests[1], to: &ledger)
            progress.requestDiscovery(prioritizing: manifests[1].id)
            progress.acceptSnapshot(ledger.jobs.map(\.manifest), previousIDs: Set(manifests.map(\.id)),
                request: progress.snapshot, transcriptHints: [manifests[1].id])
            let selected = progress.nextUpload(in: ledger.jobs)!
            try require(selected.segmentID == manifests[0].id && selected.artifactKey == audio.key && !selected.isPrioritySmall,
                "Fresh text or a snapshot reset the owed resumable-audio turn")
            do { try progress.didVerify(selected, in: ledger.jobs); throw ProbeFailure(message: "Pending audio reset fairness without a receipt") }
            catch GoogleDriveLibraryError.invalidState { }
            let original = ledger.jobs[0].artifacts.first { $0.kind == .audio }!
            try require(progress.smallVerifiedSinceAudio == 3 && original.fileID == "original-audio-123" && original.uploadURL == session,
                "Selection or cancellation altered the durable file/session identity")
            _ = try acceptSyntheticReceipt(selected, in: &ledger); try progress.didVerify(selected, in: ledger.jobs)
            try require(progress.smallVerifiedSinceAudio == 0 && progress.nextUpload(in: ledger.jobs)?.segmentID == manifests[1].id,
                "Successful audio receipt did not release the next derived bundle")
        }
        await test("late text with an already saved manifest uses audio priorities while closing pending manifests") {
            let manifests = orderedManifests(4), old = manifests[3]
            var ledger = try priorityLedger(manifests), progress = GoogleDriveSyncProgress()
            try addPriorityTranscript(old, to: &ledger)
            let oldManifest = ledger.jobs[3].artifacts.first { $0.kind == .manifest }!
            _ = try acceptSyntheticReceipt(.init(segmentID: old.id, artifactKey: oldManifest.key, isPrioritySmall: false), in: &ledger)
            let firstAudio = ledger.jobs[0].artifacts.first { $0.kind == .audio }!
            _ = try acceptSyntheticReceipt(.init(segmentID: manifests[0].id, artifactKey: firstAudio.key, isPrioritySmall: false), in: &ledger)
            let resumedAudio = ledger.jobs[1].artifacts.first { $0.kind == .audio }!
            try ledger.allocateFile(segmentID: manifests[1].id, key: resumedAudio.key, fileID: "fallback-resume-123")
            try ledger.recordSession(segmentID: manifests[1].id, key: resumedAudio.key,
                url: "https://www.googleapis.com/upload/drive/v3/files?upload_id=fallback-synthetic")
            for expected in [GoogleDriveArtifact.Kind.transcriptJSON, .transcriptText] {
                let selected = progress.nextUpload(in: ledger.jobs)!
                let kind = try acceptSyntheticReceipt(selected, in: &ledger)
                try require(selected.segmentID == old.id && kind == expected, "Late derived files lost their priority")
                try progress.didVerify(selected, in: ledger.jobs)
            }
            try require(progress.smallVerifiedSinceAudio == 2, "Late text unexpectedly consumed a third small turn")
            var selected = progress.nextUpload(in: ledger.jobs)!
            var kind = try acceptSyntheticReceipt(selected, in: &ledger)
            try require(selected.segmentID == manifests[0].id && kind == .manifest, "Audio priority skipped an ordinary pending manifest's existing cleanup turn")
            try progress.didVerify(selected, in: ledger.jobs)
            selected = progress.nextUpload(in: ledger.jobs)!
            try require(selected.segmentID == manifests[1].id && selected.artifactKey == resumedAudio.key, "Two-small fallback ignored an existing resumable audio session")
            _ = try acceptSyntheticReceipt(selected, in: &ledger); try progress.didVerify(selected, in: ledger.jobs)
            selected = progress.nextUpload(in: ledger.jobs)!
            kind = try acceptSyntheticReceipt(selected, in: &ledger)
            try require(selected.segmentID == manifests[1].id && kind == .manifest, "Resumed audio did not retain its ordinary manifest cleanup")
            try progress.didVerify(selected, in: ledger.jobs)
            selected = progress.nextUpload(in: ledger.jobs)!
            try require(selected.segmentID == old.id && selected.artifactKey.hasPrefix("audio-"),
                "Fallback still put unrelated newer audio ahead of the late transcript's source")
        }
        await test("a canonical bad transcript hint remains an issue and does not invent priority uploads") {
            let manifests = orderedManifests(2), localRoot = root.appendingPathComponent(UUID().uuidString)
            let repository = try TranscriptRepository(root: localRoot)
            let target = localRoot.appendingPathComponent("transcripts").appendingPathComponent(manifests[1].id.uuidString.lowercased() + ".json")
            try Data("{}".utf8).write(to: target)
            let names = try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)
            let ledger = try priorityLedger(manifests)
            var progress = GoogleDriveSyncProgress(); let request = progress.snapshot
            progress.acceptSnapshot(ledger.jobs.map(\.manifest), previousIDs: [], request: request,
                transcriptHints: GoogleDriveSyncProgress.transcriptHints(fileNames: names))
            try require(progress.remaining.first?.id == manifests[1].id, "Canonical filename was not inspected first")
            while let manifest = progress.remaining.first {
                let inspection = GoogleDriveSyncProgress.inspectTranscript(repository: repository, manifest: manifest)
                try require(inspection.transcript == nil, "Malformed fixture bypassed actual transcript validation")
                try progress.finishRecord(manifest.id, issue: inspection.issue)
            }
            progress.finishSlice(observedRevision: request.revision)
            let selected = progress.nextUpload(in: ledger.jobs)!
            try require(progress.hasIssues && selected.segmentID == manifests[0].id && !selected.isPrioritySmall,
                "Malformed hinted text blocked audio or acquired a derived upload turn")
            try require(ledger.jobs.allSatisfy { $0.artifacts.count == 2 }, "A filename hint created unchecked JSON/TXT artifacts")
        }
        await test("only checksum-verified durable receipts advance small-file fairness once") {
            let manifests = orderedManifests(1)
            var ledger = try priorityLedger(manifests), progress = GoogleDriveSyncProgress()
            try addPriorityTranscript(manifests[0], to: &ledger)
            let selected = progress.nextUpload(in: ledger.jobs)!
            do { _ = try acceptSyntheticReceipt(selected, in: &ledger, checksum: String(repeating: "f", count: 64)); throw ProbeFailure(message: "Wrong checksum accepted") }
            catch GoogleDriveLibraryError.invalidRemoteFile { }
            let id = ledger.jobs[0].artifacts.first { $0.key == selected.artifactKey }!.fileID
            do { try progress.didVerify(selected, in: ledger.jobs); throw ProbeFailure(message: "Failed remote check spent a small-file turn") }
            catch GoogleDriveLibraryError.invalidState { }
            try require(progress.smallVerifiedSinceAudio == 0 && progress.nextUpload(in: ledger.jobs) == selected, "Failed upload changed priority or spent its turn")
            _ = try acceptSyntheticReceipt(selected, in: &ledger); try progress.didVerify(selected, in: ledger.jobs)
            try progress.didVerify(selected, in: ledger.jobs)
            try require(progress.smallVerifiedSinceAudio == 1 && ledger.jobs[0].artifacts.first { $0.key == selected.artifactKey }!.fileID == id,
                "Duplicate verification spent another turn or allocated a new file ID")
        }
        for context in [
            (foreground: true, processing: false, handoff: false, name: "slow prerequisite GETs make foreground upload progress beyond 19 seconds"),
            (foreground: false, processing: false, handoff: false, name: "same slow prerequisite GETs retain bounded background cancellation"),
            (foreground: false, processing: true, handoff: false, name: "a real processing parent makes progress after slow prerequisite GETs"),
            (foreground: false, processing: true, handoff: true, name: "a processing parent waits out an ordinary round then verifies within its original deadline")
        ] {
            await test(context.name) {
                var (ledger, manifest, artifact, file) = try fixture(Data(repeating: 4, count: 16), root: root)
                let gate: BudgetGate
                if context.handoff {
                    let old = BudgetGate(isForeground: false)
                    var parent = GoogleDriveExecutionBudget.ParentGrant(now: 0, existingWork: .ordinarySync)
                    old.advance(19)
                    do { try old.check(); throw ProbeFailure(message: "Parent extended the old ordinary round") }
                    catch is CancellationError { }
                    guard let deadline = parent.takeRound(at: old.time, isCancelled: false) else {
                        throw ProbeFailure(message: "Valid processing parent could not start its one follow-up round")
                    }
                    gate = BudgetGate(isForeground: false, systemGranted: true, now: old.time, maximumDeadline: deadline)
                    try require(gate.deadline == 120 && parent.takeRound(at: old.time, isCancelled: false) == nil,
                        "Handoff renewed the parent deadline or allowed another processing round")
                } else { gate = BudgetGate(isForeground: context.foreground, systemGranted: context.processing) }
                let startedAt = gate.time, canComplete = context.foreground || context.processing, trace = Trace()
                let remoteBytes = try remote(ledger, manifest, artifact), folderBytes = try folder(ledger)
                MockProtocol.install { request in
                    // Advance a virtual monotonic clock inside the real HTTP
                    // reply boundary. This is deterministic and never sleeps.
                    let remainingTimeout = try gate.requestTimeout()
                    let expectedTimeout = GoogleDriveRecoveryDecision.firstAttemptTimeout(budget:remainingTimeout,
                        path:GoogleDriveHTTP.recoveryPath(for:request))
                    try require(request.timeoutInterval > 0 && abs(request.timeoutInterval - expectedTimeout) < 0.01
                        && request.timeoutInterval <= remainingTimeout,
                        "HTTP request failed to reserve its eligible retry inside the current remaining budget")
                    trace.append(request)
                    if request.httpMethod == "POST" {
                        try require(gate.time >= startedAt + 20, "Prerequisite regression did not cross the old 19-second deadline")
                    }
                    gate.advance(5)
                    switch request.url!.path {
                    case "/drive/v3/about": return try about()
                    case "/drive/v3/files/folder-123": return .init(code: 200, data: folderBytes)
                    case "/drive/v3/files/audio-123":
                        return trace.count { $0.httpMethod == "PUT" } == 0 ? .init(code: 404) : .init(code: 200, data: remoteBytes)
                    default:
                        if request.httpMethod == "POST" { return .init(code: 200, headers: ["Location": "https://www.googleapis.com/upload/drive/v3/files?upload_id=slow-synthetic"]) }
                        try require(request.httpMethod == "PUT", "Unexpected slow-round route")
                        return .init(code: 200)
                    }
                }
                let client = GoogleDriveClient(http: http(), oauth: Tokens(), accountID: "owner-123", check: gate.check,
                    requestTimeout: gate.requestTimeout)
                do {
                    try await client.validateAccount()
                    try await client.ensureFolder(id: "folder-123", libraryID: ledger.libraryID)
                    try await client.verifyFolder(id: "folder-123", libraryID: ledger.libraryID)
                    let result = try await client.upload(file: file, artifact: artifact, manifest: manifest, folderID: "folder-123",
                        libraryID: ledger.libraryID) { url in try ledger.recordSession(segmentID: manifest.id, key: artifact.key, url: url) }
                    try require(canComplete, "Ordinary background execution exceeded its 19-second bound")
                    try ledger.recordVerified(segmentID: manifest.id, key: artifact.key, file: result, in: "owner-123")
                    try require(ledger.savedAudioCount == 1 && gate.time >= startedAt + 32, "Slow authorized round failed to persist verified progress")
                } catch is CancellationError {
                    try require(!canComplete, "Authorized round cancelled before its bounded upload could progress")
                    try require(trace.count { $0.httpMethod == "POST" || $0.httpMethod == "PUT" } == 0, "Expired background round started file transmission")
                    try require(ledger.savedAudioCount == 0, "Expired background round claimed verification")
                }
            }
        }
        await test("background transition shortens a fixed round and cannot renew it") {
            let gate = BudgetGate(isForeground: true)
            try require(gate.deadline == 120, "Foreground round is not bounded at 120 seconds")
            gate.advance(10); gate.enterBackground()
            try require(gate.deadline == 29, "Background transition did not shorten the foreground budget")
            gate.advance(5); gate.enterBackground()
            try require(gate.deadline == 29, "Another lifecycle signal renewed the current round")
            gate.advance(13); try gate.check()
            let finalTimeout = try gate.requestTimeout()
            try require(finalTimeout == 1, "Final request did not use remaining one-second budget")
            gate.advance(1)
            do { try gate.check(); throw ProbeFailure(message: "Transitioned round exceeded its deadline") }
            catch is CancellationError { }
            let late = BudgetGate(isForeground: true)
            late.advance(115); late.enterBackground()
            try require(late.deadline == 120, "Late background transition extended the original foreground bound")
        }
        await test("processing lifecycle signals retain a fixed parent deadline without extending it") {
            let gate = BudgetGate(isForeground: false, systemGranted: true)
            gate.advance(10); gate.enterBackground()
            try require(gate.deadline == 120, "Lifecycle transition shortened a real processing parent's fixed budget")
            gate.advance(105); gate.enterBackground()
            let finalTimeout = try gate.requestTimeout()
            try require(gate.deadline == 120 && finalTimeout == 5, "Lifecycle signal renewed a real processing parent")
            gate.advance(5)
            do { try gate.check(); throw ProbeFailure(message: "Processing parent exceeded its fixed deadline") }
            catch is CancellationError { }
            let ordinary = BudgetGate(isForeground: false, now: 19, maximumDeadline: 120)
            try require(ordinary.deadline == 38, "An absolute cap alone fabricated a real processing grant")
        }
        await test("a parent grants at most one round and cannot extend existing processing or identity work") {
            for existing in [GoogleDriveExecutionBudget.ParentGrant.ExistingWork.none, .ordinarySync] {
                var parent = GoogleDriveExecutionBudget.ParentGrant(now: 10, existingWork: existing)
                try require(parent.takeRound(at: 29, isCancelled: false) == 130, "Parent did not retain its original absolute deadline")
                try require(parent.takeRound(at: 30, isCancelled: false) == nil, "Parent gave a second processing round")
            }
            for existing in [GoogleDriveExecutionBudget.ParentGrant.ExistingWork.systemSync, .identityOperation] {
                var parent = GoogleDriveExecutionBudget.ParentGrant(now: 10, existingWork: existing)
                try require(parent.takeRound(at: 29, isCancelled: false) == nil, "Existing processing or identity work gained another round")
            }
            var cancelled = GoogleDriveExecutionBudget.ParentGrant(now: 0, existingWork: .ordinarySync)
            try require(cancelled.takeRound(at: 19, isCancelled: true) == nil, "Expired parent started a follow-up round")
            var expired = GoogleDriveExecutionBudget.ParentGrant(now: 0, existingWork: .ordinarySync)
            try require(expired.takeRound(at: 120, isCancelled: false) == nil, "A spent absolute budget started a follow-up round")
        }
        for processing in [false, true] {
            await test(processing ? "processing parent expiration during an awaited chunk forbids every following request" : "system expiration during an awaited chunk forbids every following request") {
                var (ledger, manifest, artifact, file) = try fixture(Data(repeating: 7, count: 1_048_580), root: root)
                let gate = BudgetGate(isForeground: !processing, systemGranted: processing), parent = Gate(), trace = Trace()
                MockProtocol.install { request in
                    trace.append(request)
                    if request.url!.path == "/drive/v3/about" { return try about() }
                    if request.httpMethod == "GET" { return .init(code: 404) }
                    if request.httpMethod == "POST" { return .init(code: 200, headers: ["Location": "https://www.googleapis.com/upload/drive/v3/files?upload_id=expire-synthetic"]) }
                    try require(request.httpMethod == "PUT", "Unexpected expiration route")
                    if processing { parent.close() } else { gate.expire() }
                    return .init(code: 308, headers: ["Range": "bytes=0-1048575"])
                }
                let client = GoogleDriveClient(http: http(), oauth: Tokens(), accountID: "owner-123",
                    check: { try parent.check(); try gate.check() },
                    requestTimeout: { try parent.check(); return try gate.requestTimeout() })
                do {
                    _ = try await client.upload(file: file, artifact: artifact, manifest: manifest, folderID: "folder-123", libraryID: ledger.libraryID) { url in
                        try ledger.recordSession(segmentID: manifest.id, key: artifact.key, url: url)
                    }
                    throw ProbeFailure(message: "Expired round accepted the awaited response")
                } catch is CancellationError { }
                try require(trace.count { $0.httpMethod == "PUT" } == 1, "Expiration allowed another chunk")
                try require(trace.count { $0.url!.path == "/drive/v3/files/audio-123" } == 1, "Expiration allowed a later metadata request")
                try require(ledger.savedAudioCount == 0 && ledger.jobs[0].artifacts[0].uploadURL != nil, "Expiration lost the durable session or claimed completion")
            }
        }
        await test("new access token must revalidate same Google account") {
            let trace = Trace()
            MockProtocol.install { request in
                trace.append(request)
                try require(request.url!.path == "/drive/v3/about", "Changed account issued file API")
                return try about(request.value(forHTTPHeaderField: "Authorization") == "Bearer first" ? "owner-123" : "other-owner")
            }
            let client = GoogleDriveClient(http: http(), oauth: Tokens(["first", "second"]), accountID: "owner-123", check: {})
            try await client.validateAccount()
            do { _ = try await client.generateID(); throw ProbeFailure(message: "Changed identity accepted") }
            catch GoogleDriveLibraryError.changedAccount { }
            try require(trace.count { _ in true } == 2, "Account refresh was not checked before file request")
        }

        await test("native body and task mapping are durable before resume without persisting bearer credentials") {
            let (ledger, _, _, file, context) = try backgroundFixture(root: root)
            let directory = root.appendingPathComponent(UUID().uuidString), native = NativeUploads()
            let coordinator = try GoogleDriveBackgroundUploads(directory: directory, libraryID: ledger.libraryID,
                changed: {}, finishedEvents: { _ in }, factory: native.factory)
            native.onResume = { taskID in
                let data = try Data(contentsOf: directory.appendingPathComponent("pipeline.json"))
                let record = try TransportCodec.decode(PipelineState.self, from: data).records.first { $0.taskID == taskID }!
                try require(record.taskID == taskID && !record.completed, "Native upload resumed before its task ID was durable")
                let body = try Data(contentsOf: directory.appendingPathComponent(record.bodyName))
                try require(Int64(body.count) == record.bodyByteCount && GoogleDriveLibraryLedger.digest(body) == record.bodySHA256,
                            "Native upload resumed without its exact immutable body")
                try require(!String(decoding: data, as: UTF8.self).contains("synthetic-private-token")
                            && !String(decoding: data, as: UTF8.self).contains("Bearer"), "Bearer credential leaked into persisted attempt")
                let attrs = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(record.bodyName).path)
                try require((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Native body permissions are not private")
            }
            try await coordinator.start(request: backgroundRequest(context, offset: 64), file: file, offset: 64,
                context: context, isAuthorized: { context.isAuthorized(in: ledger) }, check: {})
            try require(native.resumeFailure == nil && native.resumed.count == 1 && coordinator.hasActiveUpload, "Native durable registration failed")
            try require(native.bodies[0] == Data((64..<128).map { UInt8($0) }) && ledger.savedAudioCount == 0,
                        "Suffix staging changed bytes or native registration created a verified receipt")
        }
        await test("native suffix staging verifies the full source hash and rejects changed content") {
            let (ledger, _, _, file, context) = try backgroundFixture(root: root)
            var bytes = try Data(contentsOf: file); bytes[0] ^= 1; try bytes.write(to: file)
            let directory = root.appendingPathComponent(UUID().uuidString), native = NativeUploads()
            let coordinator = try GoogleDriveBackgroundUploads(directory: directory, libraryID: ledger.libraryID,
                changed: {}, finishedEvents: { _ in }, factory: native.factory)
            do {
                try await coordinator.start(request: backgroundRequest(context, offset: 64), file: file, offset: 64,
                    context: context, isAuthorized: { true }, check: {})
                throw ProbeFailure(message: "Changed bytes before suffix offset were uploaded")
            } catch GoogleDriveLibraryError.changedManifest { }
            try require(native.requests.isEmpty && !coordinator.hasActiveUpload,
                        "Changed source registered a native upload")
            let remainingFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            try require(remainingFiles.isEmpty, "Failed staging left an orphan private body")
        }
        await test("native upload staging refuses symlinks and hardlinked source bytes") {
            for hardlink in [false, true] {
                let (ledger, _, _, file, context) = try backgroundFixture(root: root)
                let linked = root.appendingPathComponent(UUID().uuidString)
                if hardlink { try FileManager.default.linkItem(at: file, to: linked) }
                else { try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: file) }
                let native = NativeUploads()
                let coordinator = try GoogleDriveBackgroundUploads(directory: root.appendingPathComponent(UUID().uuidString),
                    libraryID: ledger.libraryID, changed: {}, finishedEvents: { _ in }, factory: native.factory)
                do {
                    try await coordinator.start(request: backgroundRequest(context), file: linked, offset: 0,
                        context: context, isAuthorized: { true }, check: {})
                    throw ProbeFailure(message: "Aliased source was accepted")
                } catch GoogleDriveLibraryError.changedManifest { }
                try require(native.requests.isEmpty, "Aliased source reached native transport")
            }
        }
        await test("native handoff fences cancellation and revoked grant after staging before registration") {
            for expiredBudget in [false, true] {
                let (ledger, _, _, file, context) = try backgroundFixture(root: root)
                let native = NativeUploads(), gate = Gate()
                var checks = 0
                let coordinator = try GoogleDriveBackgroundUploads(directory: root.appendingPathComponent(UUID().uuidString),
                    libraryID: ledger.libraryID, changed: {}, finishedEvents: { _ in }, factory: native.factory)
                do {
                    try await coordinator.start(request: backgroundRequest(context), file: file, offset: 0, context: context,
                        isAuthorized: { checks += 1; if checks == 1 { if expiredBudget { gate.close() }; return true }; return false },
                        check: { try gate.check() })
                    throw ProbeFailure(message: "Revoked or expired handoff registered a native task")
                } catch is CancellationError { }
                try require(native.requests.isEmpty && ledger.savedAudioCount == 0, "Expired registration sent bytes or claimed a receipt")
            }
        }
        await test("cold start reattaches the exact native task without recreating or resuming it") {
            let (ledger, _, _, file, context) = try backgroundFixture(root: root)
            let directory = root.appendingPathComponent(UUID().uuidString), native = NativeUploads()
            var first: GoogleDriveBackgroundUploads? = try GoogleDriveBackgroundUploads(directory: directory, libraryID: ledger.libraryID,
                changed: {}, finishedEvents: { _ in }, factory: native.factory)
            try await first!.start(request: backgroundRequest(context), file: file, offset: 0,
                context: context, isAuthorized: { true }, check: {})
            let id = first!.identifier; first = nil
            let restored = try GoogleDriveBackgroundUploads(directory: directory, libraryID: ledger.libraryID,
                changed: {}, finishedEvents: { _ in }, factory: native.factory)
            try require(restored.hasActiveUpload && restored.recognizes(id) && !restored.recognizes(id + "other"), "Cold state lost its exact session fence")
            await restored.recover(in: ledger)
            try require(restored.hasActiveUpload && !restored.isUnavailable && native.requests.count == 1 && native.resumed.count == 1,
                        "Cold restoration recreated a PUT or dropped the live task")
            try require(native.cancelled.isEmpty && ledger.savedAudioCount == 0, "Valid native task was cancelled or accepted as verified")
        }
        await test("native tasks absent after registration failure remain uncertain and allow normal remote readback") {
            let (ledger, _, _, file, context) = try backgroundFixture(root: root)
            let directory = root.appendingPathComponent(UUID().uuidString), native = NativeUploads(); native.createFailure = true
            let first = try GoogleDriveBackgroundUploads(directory: directory, libraryID: ledger.libraryID,
                changed: {}, finishedEvents: { _ in }, factory: native.factory)
            do {
                try await first.start(request: backgroundRequest(context), file: file, offset: 0,
                    context: context, isAuthorized: { true }, check: {})
                throw ProbeFailure(message: "Synthetic native failure was swallowed")
            } catch is ProbeFailure { }
            try require(!first.hasActiveUpload, "Registration failure wedged the live slot")
            // Simulate termination between durable attempt and native creation.
            let crashRecord = GoogleDriveBackgroundUploads.Record(schemaVersion: 1, nonce: UUID(), context: context,
                offset: 0, bodyByteCount: context.artifact.byteCount, bodySHA256: context.artifact.sha256)
            try TransportCodec.encode(crashRecord).write(to: directory.appendingPathComponent("attempt.json"))
            let restored = try GoogleDriveBackgroundUploads(directory: directory, libraryID: ledger.libraryID,
                changed: {}, finishedEvents: { _ in }, factory: native.factory)
            await restored.recover(in: ledger)
            try require(!restored.hasActiveUpload && restored.record?.completed == true && ledger.savedAudioCount == 0,
                        "Missing native task either wedged progress or fabricated a receipt")
            try restored.discardCompleted()
        }
        await test("cold restoration cancels all tasks when the exact current grant or source session changed") {
            for fence in ["paused", "revoked", "account", "folder", "library", "authorization", "scope", "session", "verified"] {
                var (ledger, manifest, artifact, file, context) = try backgroundFixture(root: root)
                let directory = root.appendingPathComponent(UUID().uuidString), native = NativeUploads()
                let first = try GoogleDriveBackgroundUploads(directory: directory, libraryID: ledger.libraryID,
                    changed: {}, finishedEvents: { _ in }, factory: native.factory)
                try await first.start(request: backgroundRequest(context), file: file, offset: 0, context: context, isAuthorized: { true }, check: {})
                switch fence {
                case "paused": try ledger.setEnabled(false)
                case "revoked": ledger.revoke()
                case "session": try ledger.recordSession(segmentID: manifest.id, key: artifact.key, url: nil)
                case "verified":
                    let remoteFile = try TransportCodec.decode(GoogleDriveRemoteFile.self, from: remote(ledger, manifest, artifact))
                    try ledger.recordVerified(segmentID: manifest.id, key: artifact.key, file: remoteFile, in: "owner-123")
                default:
                    var object = try JSONSerialization.jsonObject(with: TransportCodec.encode(ledger)) as! [String: Any]
                    switch fence {
                    case "account": object["accountID"] = "other-owner"
                    case "folder": object["folderID"] = "other-folder"
                    case "library": object["libraryID"] = UUID().uuidString
                    case "authorization": object["authorizedAt"] = 1_800_000_000_000
                    case "scope": object["recordingScope"] = "futureOnly"
                    default: break
                    }
                    ledger = try TransportCodec.decode(GoogleDriveLibraryLedger.self, from: json(object))
                }
                let restored = try GoogleDriveBackgroundUploads(directory: directory, libraryID: context.libraryID,
                    changed: {}, finishedEvents: { _ in }, factory: native.factory)
                await restored.recover(in: ledger); await settleUploads()
                try require(native.cancelled == [1] && !restored.hasActiveUpload,
                            "A changed \(fence) fence left native bytes running or wedged completion")
                try require(native.requests.count == 1 && native.resumed.count == 1, "Recovery renewed a revoked upload")
            }
        }
        await test("cold restoration rejects duplicate nonce or changed request metadata without permanent pending state") {
            for changed in ["nonce", "url", "method", "range", "duplicate"] {
                let (ledger, _, _, file, context) = try backgroundFixture(root: root)
                let directory = root.appendingPathComponent(UUID().uuidString), native = NativeUploads()
                let first = try GoogleDriveBackgroundUploads(directory: directory, libraryID: ledger.libraryID,
                    changed: {}, finishedEvents: { _ in }, factory: native.factory)
                try await first.start(request: backgroundRequest(context), file: file, offset: 0, context: context, isAuthorized: { true }, check: {})
                let old = native.active[0]
                let wrong = GoogleDriveUploadTaskInfo(id: changed == "duplicate" ? 2 : old.id,
                    nonce: changed == "nonce" ? UUID().uuidString : old.nonce,
                    url: changed == "url" ? "https://evil.invalid" : old.url,
                    method: changed == "method" ? "POST" : old.method, contentRange: changed == "range" ? "bytes 1-127/128" : old.contentRange)
                native.active = changed == "duplicate" ? [old, wrong] : [wrong]
                let restored = try GoogleDriveBackgroundUploads(directory: directory, libraryID: ledger.libraryID,
                    changed: {}, finishedEvents: { _ in }, factory: native.factory)
                await restored.recover(in: ledger); await settleUploads()
                try require(native.cancelled.contains(wrong.id), "Mismatched native \(changed) was accepted")
                try require(restored.hasActiveUpload == (changed == "duplicate"), "Rejected \(changed) request wedged pending state or removed the valid native task")
                try require(ledger.savedAudioCount == 0, "Task reconciliation created a receipt")
            }
        }
        await test("stale completion cannot drain a newer task and pause cancels the actual live task") {
            let (ledger, _, _, file, context) = try backgroundFixture(root: root)
            let directory = root.appendingPathComponent(UUID().uuidString), native = NativeUploads()
            let coordinator = try GoogleDriveBackgroundUploads(directory: directory, libraryID: ledger.libraryID,
                changed: {}, finishedEvents: { _ in }, factory: native.factory)
            try await coordinator.start(request: backgroundRequest(context), file: file, offset: 0, context: context, isAuthorized: { true }, check: {})
            let live = native.active[0]
            native.complete?(.init(task: .init(id: live.id, nonce: UUID().uuidString, url: live.url, method: "PUT", contentRange: live.contentRange),
                                   responseURL: live.url, status: 200, transportFailed: false))
            await settleUploads()
            try require(coordinator.hasActiveUpload && coordinator.record?.completed == false, "Stale completion replaced the live attempt")
            coordinator.cancel(); await settleUploads()
            try require(native.cancelled == [live.id] && !coordinator.hasActiveUpload && ledger.savedAudioCount == 0,
                        "Stale callback lost cancellation of the actual native task")
        }
        await test("native completion is persisted before drained and must still pass normal remote file verification") {
            var (ledger, manifest, artifact, file, context) = try backgroundFixture(root: root)
            let directory = root.appendingPathComponent(UUID().uuidString), native = NativeUploads()
            var order: [String] = [], drainedSawCompletion = false
            var coordinator: GoogleDriveBackgroundUploads!
            coordinator = try GoogleDriveBackgroundUploads(directory: directory, libraryID: ledger.libraryID,
                changed: { order.append("completion") }, finishedEvents: { _ in
                    drainedSawCompletion = coordinator.record?.completed == true; order.append("drained")
                }, factory: native.factory)
            try await coordinator.start(request: backgroundRequest(context), file: file, offset: 0, context: context, isAuthorized: { true }, check: {})
            native.emit(native.active[0]); native.finished?(BackgroundSessionEventTracker.shared.capture(coordinator.identifier))
            await settleUploads()
            try require(drainedSawCompletion && order == ["completion", "drained"], "UIKit drained before the completion state was durable")
            try require(!coordinator.hasActiveUpload && ledger.savedAudioCount == 0, "HTTP 200 fabricated a verified receipt")
            let remoteBytes = try remote(ledger, manifest, artifact)
            MockProtocol.install { request in
                if request.url!.path == "/drive/v3/about" { return try about() }
                try require(request.httpMethod == "GET" && request.url!.path == "/drive/v3/files/audio-123", "Completion readback issued another body upload")
                return .init(code: 200, data: remoteBytes)
            }
            let client = GoogleDriveClient(http: http(), oauth: Tokens(), accountID: "owner-123", check: {})
            let result = try await client.upload(file: file, artifact: artifact, manifest: manifest, folderID: "folder-123",
                libraryID: ledger.libraryID, saveSession: { _ in throw ProbeFailure(message: "Verified remote replaced upload session") })
            try ledger.recordVerified(segmentID: manifest.id, key: artifact.key, file: result, in: "owner-123")
            try coordinator.discardCompleted()
            try require(ledger.savedAudioCount == 1 && coordinator.record == nil, "Verified readback did not commit and clean its completed body")
        }

        await test("cold restoration cancels a task suspended before initial resume and releases the slot") {
            let (ledger, _, _, file, context) = try backgroundFixture(root: root)
            let directory = root.appendingPathComponent(UUID().uuidString), native = NativeUploads()
            let first = try GoogleDriveBackgroundUploads(directory: directory, libraryID: ledger.libraryID,
                changed: {}, finishedEvents: { _ in }, factory: native.factory)
            try await first.start(request: backgroundRequest(context), file: file, offset: 0, context: context, isAuthorized: { true }, check: {})
            let old = native.active[0]
            native.active = [.init(id: old.id, nonce: old.nonce, url: old.url, method: old.method,
                                   contentRange: old.contentRange, isSuspended: true)]
            let restored = try GoogleDriveBackgroundUploads(directory: directory, libraryID: ledger.libraryID,
                changed: {}, finishedEvents: { _ in }, factory: native.factory)
            await restored.recover(in: ledger); await settleUploads()
            try require(native.cancelled == [old.id] && !restored.hasActiveUpload && ledger.savedAudioCount == 0,
                        "Pre-resume crash left a suspended native task occupying the slot")
        }
        await test("completion received during getAllTasks cannot be resurrected by its stale snapshot") {
            let (ledger, _, _, file, context) = try backgroundFixture(root: root)
            let directory = root.appendingPathComponent(UUID().uuidString), native = NativeUploads()
            let first = try GoogleDriveBackgroundUploads(directory: directory, libraryID: ledger.libraryID,
                changed: {}, finishedEvents: { _ in }, factory: native.factory)
            try await first.start(request: backgroundRequest(context), file: file, offset: 0, context: context, isAuthorized: { true }, check: {})
            let old = native.active[0]
            let restored = try GoogleDriveBackgroundUploads(directory: directory, libraryID: ledger.libraryID,
                changed: {}, finishedEvents: { _ in }, factory: native.factory)
            native.holdEnumeration = true
            let recovery = Task { @MainActor in await restored.recover(in: ledger) }
            await settleUploads()
            try require(native.enumeration != nil, "Controlled native enumeration did not hold")
            native.emit(old); await settleUploads()
            native.releaseEnumeration(); await recovery.value
            try require(!restored.hasActiveUpload && restored.record?.completed == true && ledger.savedAudioCount == 0,
                        "A stale native enumeration resurrected an already consumed completion")
        }
        await test("orphan staging copies are removed on restart without touching unknown files") {
            let (ledger, _, _, _, _) = try backgroundFixture(root: root)
            let directory = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let orphan = UUID().uuidString.lowercased() + ".body"
            let temporary = ".attempt-" + UUID().uuidString.lowercased()
            for name in [orphan, temporary, "preserved.txt"] { try Data("synthetic".utf8).write(to: directory.appendingPathComponent(name)) }
            _ = try GoogleDriveBackgroundUploads(directory: directory, libraryID: ledger.libraryID,
                changed: {}, finishedEvents: { _ in }, factory: NativeUploads().factory)
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            try require(names == ["preserved.txt"], "Restart leaked an orphan body or removed unrelated files")
        }
        await test("cleanup failure retains the durable attempt pointer") {
            let (ledger, _, _, file, context) = try backgroundFixture(root: root)
            let directory = root.appendingPathComponent(UUID().uuidString), native = NativeUploads()
            let coordinator = try GoogleDriveBackgroundUploads(directory: directory, libraryID: ledger.libraryID,
                changed: {}, finishedEvents: { _ in }, factory: native.factory)
            try await coordinator.start(request: backgroundRequest(context), file: file, offset: 0, context: context, isAuthorized: { true }, check: {})
            native.emit(native.active[0]); await settleUploads()
            let body = directory.appendingPathComponent(coordinator.record!.bodyName)
            try FileManager.default.removeItem(at: body)
            try FileManager.default.createDirectory(at: body, withIntermediateDirectories: false)
            do { try coordinator.discardCompleted(); throw ProbeFailure(message: "Invalid body cleanup was silently ignored") }
            catch GoogleDriveLibraryError.invalidState { }
            try require(coordinator.record != nil && FileManager.default.fileExists(atPath: directory.appendingPathComponent("pipeline.json").path),
                        "Failed cleanup removed its only durable pointer")
        }
        for bounded in [false, true] {
            await test(bounded ? "background drained waits only for its bounded sync round" : "background drained does not wait for a held OAuth identity operation") {
                var release: CheckedContinuation<Void, Never>?
                let work = Task { @MainActor in await withCheckedContinuation { release = $0 } }
                await settleUploads()
                var finished = false
                let drain = Task { @MainActor in
                    await GoogleDriveBackgroundEventDrain.finish(work: work, hasBoundedExecution: bounded) { finished = true }
                }
                await settleUploads()
                let expectedState = !bounded
                let actualState = finished
                release?.resume(); await work.value; await drain.value
                try require(actualState == expectedState && finished,
                            "UIKit completion either waited for user login or skipped its current bounded round")
            }
        }


        await test("pause waits for all cancellation callbacks without treating a partially drained set as corruption") {
            let (ledger, _, _, file, context) = try backgroundFixture(root: root)
            let directory = root.appendingPathComponent(UUID().uuidString), native = NativeUploads()
            let first = try GoogleDriveBackgroundUploads(directory: directory, libraryID: ledger.libraryID,
                changed: {}, finishedEvents: { _ in }, factory: native.factory)
            try await first.start(request: backgroundRequest(context), file: file, offset: 0, context: context, isAuthorized: { true }, check: {})
            let live = native.active[0]
            let duplicate = GoogleDriveUploadTaskInfo(id: 2, nonce: live.nonce, url: live.url, method: live.method, contentRange: live.contentRange)
            native.active.append(duplicate); native.autoCancelCompletion = false
            let restored = try GoogleDriveBackgroundUploads(directory: directory, libraryID: ledger.libraryID,
                changed: {}, finishedEvents: { _ in }, factory: native.factory)
            await restored.recover(in: ledger); restored.cancel(); await settleUploads()
            native.complete?(.init(task: live, responseURL: nil, status: nil, transportFailed: true)); await settleUploads()
            try require(!restored.isUnavailable && restored.hasActiveUpload && restored.record?.completed == true,
                        "A valid cancellation was treated as corruption before unknown tasks drained")
            native.complete?(.init(task: duplicate, responseURL: nil, status: nil, transportFailed: true)); await settleUploads()
            try require(!restored.isUnavailable && !restored.hasActiveUpload && restored.record == nil && ledger.savedAudioCount == 0,
                        "Last unknown cancellation failed to release the paused slot")
        }
        for networkFailure in [false, true] {
            await test(networkFailure ? "native network failure consumes one durable backoff only after incomplete readback" : "native HTTP500 consumes one durable backoff before retransmitting its body") {
                var (ledger, manifest, artifact, file, context) = try backgroundFixture(root: root)
                let native = NativeUploads(), clock = RetryClock()
                let coordinator = try GoogleDriveBackgroundUploads(directory: root.appendingPathComponent(UUID().uuidString),
                    libraryID: ledger.libraryID, changed: {}, finishedEvents: { _ in }, now: { clock.now() }, factory: native.factory)
                try await coordinator.start(request: backgroundRequest(context), file: file, offset: 0, context: context, isAuthorized: { true }, check: {})
                native.emit(native.active[0], code: 500, failed: networkFailure); await settleUploads()
                let trace = Trace()
                MockProtocol.install { request in
                    trace.append(request)
                    if request.url!.path == "/drive/v3/about" { return try about() }
                    if request.httpMethod == "GET" { return .init(code: 404) }
                    try require(request.httpMethod == "PUT" && request.value(forHTTPHeaderField: "Content-Range") == "bytes */128",
                                "Failed native task issued an unverified body or replaced its durable session")
                    return .init(code: 308)
                }
                let client = GoogleDriveClient(http: http(), oauth: Tokens(), accountID: "owner-123", check: {})
                do {
                    _ = try await client.upload(file: file, artifact: artifact, manifest: manifest, folderID: "folder-123",
                        libraryID: ledger.libraryID, backgroundHandoff: { request, source, offset in
                            try coordinator.deferUnverifiedRetry(for: manifest.id, artifactKey: artifact.key)
                            try await coordinator.start(request: request, file: source, offset: offset, context: context, isAuthorized: { true }, check: {})
                        }, saveSession: { url in try ledger.recordSession(segmentID: manifest.id, key: artifact.key, url: url) })
                    throw ProbeFailure(message: "Failed native attempt was returned as verified")
                } catch is GoogleDriveUploadRetryDeferred { }
                try require(ledger.failureCount == 0 && ledger.retryAfter == nil && coordinator.itemRetries.count == 1 && coordinator.itemRetries[0].retryAfter > clock.now() && ledger.savedAudioCount == 0
                    && native.requests.count == 1 && !coordinator.hasUnverifiedCompletedAttempt,
                    "Native failure bypassed or repeatedly retained its durable backoff")
                // At the next scheduled opportunity the consumed attempt cannot
                // defer forever; the original session can register one new task.
                clock.advance(11)
                do {
                    _ = try await client.upload(file: file, artifact: artifact, manifest: manifest, folderID: "folder-123",
                        libraryID: ledger.libraryID, backgroundHandoff: { request, source, offset in
                            try require(!coordinator.hasUnverifiedCompletedAttempt, "Consumed failure deferred again")
                            try await coordinator.start(request: request, file: source, offset: offset, context: context, isAuthorized: { true }, check: {})
                        }, saveSession: { url in try ledger.recordSession(segmentID: manifest.id, key: artifact.key, url: url) })
                } catch is GoogleDriveUploadHandoff { }
                try require(native.requests.count == 2 && ledger.savedAudioCount == 0, "Backoff consumption prevented the next authorized retry")
            }
        }


        await test("completed native audio is read back before late transcript priority and preserves fairness") {
            var (ledger, manifest, artifact, file, context) = try backgroundFixture(root: root)
            let native = NativeUploads()
            let coordinator = try GoogleDriveBackgroundUploads(directory: root.appendingPathComponent(UUID().uuidString),
                libraryID: ledger.libraryID, changed: {}, finishedEvents: { _ in }, factory: native.factory)
            try await coordinator.start(request: backgroundRequest(context), file: file, offset: 0,
                context: context, isAuthorized: { true }, check: {})
            native.emit(native.active[0]); await settleUploads()
            try addPriorityTranscript(manifest, to: &ledger)
            var progress = GoogleDriveSyncProgress()
            let ordinary = progress.nextUpload(in: ledger.jobs)!
            try require(ordinary.artifactKey != artifact.key, "Late transcript fixture did not change ordinary queue priority")
            let selected = try coordinator.nextUpload(in: ledger, progress: progress)!
            try require(selected.segmentID == manifest.id && selected.artifactKey == artifact.key
                && !selected.isPrioritySmall && coordinator.hasUnverifiedCompletedAttempt,
                "Late transcript consumed an unrelated native attempt before exact remote readback")
            let bytes = try remote(ledger, manifest, artifact)
            MockProtocol.install { request in
                if request.url!.path == "/drive/v3/about" { return try about() }
                try require(request.httpMethod == "GET" && request.url!.path == "/drive/v3/files/audio-123",
                    "Exact completion readback requested another artifact or sent a new body")
                return .init(code: 200, data: bytes)
            }
            let client = GoogleDriveClient(http: http(), oauth: Tokens(), accountID: "owner-123", check: {})
            let verified = try await client.upload(file: file, artifact: artifact, manifest: manifest,
                folderID: "folder-123", libraryID: ledger.libraryID,
                backgroundHandoff: { _, _, _ in throw ProbeFailure(message: "Verified native audio was retried") },
                saveSession: { _ in throw ProbeFailure(message: "Verified native audio replaced its original session") })
            try ledger.recordVerified(segmentID: selected.segmentID, key: selected.artifactKey, file: verified, in: "owner-123")
            try coordinator.discardCompleted(); try progress.didVerify(selected, in: ledger.jobs)
            let next = try coordinator.nextUpload(in: ledger, progress: progress)
            try require(ledger.savedAudioCount == 1 && ledger.failureCount == 0 && next == ordinary
                && progress.smallVerifiedSinceAudio == 0 && coordinator.record == nil,
                "Exact native receipt changed backoff, blocked late transcripts, or miscredited fairness")
        }

        await test("three exact native small-file receipts still yield an audio turn") {
            var (ledger, manifest, _, _, _) = try backgroundFixture(root: root)
            let transcript = SegmentTranscript(segmentID: manifest.id, audioSHA256: manifest.sha256,
                locale: "zh-CN", engine: "synthetic-priority", createdAt: manifest.endedAt,
                text: "合成排序回归文字", spans: [])
            try ledger.discoverTranscript(transcript, for: manifest)
            var progress = GoogleDriveSyncProgress()
            let native = NativeUploads()
            let coordinator = try GoogleDriveBackgroundUploads(directory: root.appendingPathComponent(UUID().uuidString),
                libraryID: ledger.libraryID, changed: {}, finishedEvents: { _ in }, factory: native.factory)
            for kind in [GoogleDriveArtifact.Kind.manifest, .transcriptJSON, .transcriptText] {
                let choice = try coordinator.nextUpload(in: ledger, progress: progress)!
                var artifact = ledger.jobs[0].artifacts.first(where: { $0.key == choice.artifactKey })!
                try require(artifact.kind == kind && choice.isPrioritySmall, "Native derived upload lost ordinary priority")
                try ledger.allocateFile(segmentID: manifest.id, key: artifact.key, fileID: "native-" + kind.rawValue)
                try ledger.recordSession(segmentID: manifest.id, key: artifact.key,
                    url: "https://www.googleapis.com/upload/drive/v3/files?upload_id=synthetic-" + kind.rawValue)
                artifact = ledger.jobs[0].artifacts.first(where: { $0.key == choice.artifactKey })!
                let context = try GoogleDriveUploadContext(ledger: ledger, manifest: manifest, artifact: artifact)
                let data: Data
                switch kind {
                case .manifest: data = try TransportCodec.encode(GoogleDriveLibraryLedger.exportManifest(manifest))
                case .transcriptJSON: data = try TransportCodec.encode(transcript)
                default: data = GoogleDriveLibraryLedger.readableTranscript(transcript, manifest: manifest)
                }
                let file = root.appendingPathComponent(UUID().uuidString); try data.write(to: file)
                try await coordinator.start(request: backgroundRequest(context), file: file, offset: 0,
                    context: context, isAuthorized: { true }, check: {})
                native.emit(native.active[0]); await settleUploads()
                let readback = try coordinator.nextUpload(in: ledger, progress: progress)!
                try require(readback == choice, "Pinned small-file readback lost its fairness credit")
                _ = try acceptSyntheticReceipt(readback, in: &ledger)
                try coordinator.discardCompleted(); try progress.didVerify(readback, in: ledger.jobs)
            }
            let next = try coordinator.nextUpload(in: ledger, progress: progress)!
            let selectedKind = ledger.jobs[0].artifacts.first(where: { $0.key == next.artifactKey })!.kind
            try require(progress.smallVerifiedSinceAudio == 3 && selectedKind == .audio && !next.isPrioritySmall,
                "Exact native small-file readback starved the next audio turn")
        }

        await test("unrelated artifact cannot consume a completed native attempt or its failure evidence") {
            let (ledger, manifest, artifact, file, context) = try backgroundFixture(root: root)
            let directory = root.appendingPathComponent(UUID().uuidString), native = NativeUploads()
            let coordinator = try GoogleDriveBackgroundUploads(directory: directory, libraryID: ledger.libraryID,
                changed: {}, finishedEvents: { _ in }, factory: native.factory)
            try await coordinator.start(request: backgroundRequest(context), file: file, offset: 0,
                context: context, isAuthorized: { true }, check: {})
            native.emit(native.active[0], code: 500); await settleUploads()
            let nonce = coordinator.record!.nonce
            do {
                try coordinator.deferUnverifiedRetry(for: manifest.id, artifactKey: artifact.key + "-unrelated")
                throw ProbeFailure(message: "Unrelated artifact consumed an existing native failure")
            } catch GoogleDriveLibraryError.invalidState { }
            try require(ledger.failureCount == 0 && coordinator.record?.nonce == nonce
                && coordinator.hasUnverifiedCompletedAttempt && FileManager.default.fileExists(atPath:
                    directory.appendingPathComponent(nonce.uuidString.lowercased() + ".body").path),
                "Unrelated artifact erased body/state evidence or spent another artifact's backoff")
        }

        await test("completed attempt with changed grant or source session is cancelled rather than forced into readback") {
            for fence in ["account", "session", "paused", "revoked"] {
                var (ledger, manifest, artifact, file, context) = try backgroundFixture(root: root)
                let native = NativeUploads()
                let coordinator = try GoogleDriveBackgroundUploads(directory: root.appendingPathComponent(UUID().uuidString),
                    libraryID: ledger.libraryID, changed: {}, finishedEvents: { _ in }, factory: native.factory)
                try await coordinator.start(request: backgroundRequest(context), file: file, offset: 0,
                    context: context, isAuthorized: { true }, check: {})
                native.emit(native.active[0]); await settleUploads()
                switch fence {
                case "session": try ledger.recordSession(segmentID: manifest.id, key: artifact.key, url: nil)
                case "paused": try ledger.setEnabled(false)
                case "revoked": ledger.revoke()
                default:
                    var object = try JSONSerialization.jsonObject(with: TransportCodec.encode(ledger)) as! [String: Any]
                    object["accountID"] = "other-owner"
                    ledger = try TransportCodec.decode(GoogleDriveLibraryLedger.self, from: json(object))
                }
                let ordinary = GoogleDriveSyncProgress().nextUpload(in: ledger.jobs)
                let selected = try coordinator.nextUpload(in: ledger, progress: GoogleDriveSyncProgress())
                try require(coordinator.record == nil && !coordinator.isUnavailable && ledger.failureCount == 0
                    && selected == ordinary && ledger.savedAudioCount == 0,
                    "Changed completed \(fence) context was forced into old native readback or fabricated a receipt")
            }
        }

        await test("normal token-stamped UIKit drain preserves running native ownership") {
            let (ledger, _, _, file, context) = try backgroundFixture(root: root)
            let native = NativeUploads(), tracker = BackgroundSessionEventTracker.shared
            let gate = BackgroundSessionRestorationGate(isForeground: { false })
            var completed = 0
            let coordinator = try GoogleDriveBackgroundUploads(directory: root.appendingPathComponent(UUID().uuidString),
                libraryID: ledger.libraryID, changed: {}, finishedEvents: { event in
                    gate.finish(event.identifier, token: event.token)
                }, factory: native.factory)
            try await coordinator.start(request: backgroundRequest(context), file: file, offset: 0,
                context: context, isAuthorized: { true }, check: {})
            gate.receive(coordinator.identifier) { completed += 1 }
            await coordinator.recover(in: ledger)
            try require(!gate.requiresInvalidation(coordinator.identifier) && coordinator.hasActiveUpload
                && native.cancelled.isEmpty && native.invalidationCount == 0 && completed == 0,
                "A normal UIKit handler cancelled or prematurely completed a valid running native task")
            native.emit(native.active[0]); native.finished?(tracker.capture(coordinator.identifier))
            await settleUploads()
            try require(completed == 1 && coordinator.record?.completed == true && !coordinator.hasActiveUpload
                && native.invalidationCount == 0 && ledger.savedAudioCount == 0,
                "A normal native drain lost its token, bypassed durable callbacks, or became verified")
        }

        await test("native event stream preserves ingress token across a later UIKit handler") {
            let (ledger, _, _, file, context) = try backgroundFixture(root: root)
            let native = NativeUploads(), tracker = BackgroundSessionEventTracker.shared
            let gate = BackgroundSessionRestorationGate(isForeground: { false })
            var first = 0, second = 0
            let coordinator = try GoogleDriveBackgroundUploads(directory: root.appendingPathComponent(UUID().uuidString),
                libraryID: ledger.libraryID, changed: {}, finishedEvents: { event in
                    gate.finish(event.identifier, token: event.token)
                }, factory: native.factory)
            try await coordinator.start(request: backgroundRequest(context), file: file, offset: 0,
                context: context, isAuthorized: { true }, check: {})
            gate.receive(coordinator.identifier) { first += 1 }
            let old = tracker.capture(coordinator.identifier)
            gate.finish(old.identifier, token: old.token)
            gate.receive(coordinator.identifier) { second += 1 }
            // Release the earlier delegate event only after the second UIKit
            // handler was armed. The AsyncStream must carry its original token.
            native.finished?(old); await settleUploads()
            try require(first == 1 && second == 0 && gate.requiresInvalidation(coordinator.identifier)
                && coordinator.hasActiveUpload && native.invalidationCount == 0,
                "A delayed old native drain was retagged and cleared a newer UIKit handler")
        }

        for heldPhase in ["enumeration", "invalidation"] {
            await test("REC-38 migration handoff during " + heldPhase + " cannot resurrect retired session") {
                let (ledger, _, _, file, context) = try backgroundFixture(root: root)
                let settings = GoogleDriveNetworkSettings(defaults: DriveInterleavingDefaults())
                settings.setAllowsCellularAccess(true)
                var sessions: [ControlledDriveSession] = []
                var adapters: [GoogleDriveUploadSession] = []
                let coordinator = try GoogleDriveBackgroundUploads(directory: root.appendingPathComponent(UUID().uuidString),
                    libraryID: ledger.libraryID, changed: {}, finishedEvents: { _ in }, factory: { identifier, complete, finished in
                        let adapter = try GoogleDriveUploadSession(identifier: identifier, complete: complete, finished: finished,
                            networkSettings: settings, configuration: .ephemeral, sessionFactory: { _, delegate in
                                let native = ControlledDriveSession(delegate: delegate,
                                    holdsEnumeration: sessions.isEmpty && heldPhase == "enumeration")
                                sessions.append(native)
                                return native
                            })
                        adapters.append(adapter)
                        return adapter
                    })
                // Migration precedes staging. Cancellation must not even try to
                // read this synthetic source, much less create a native body.
                try FileManager.default.removeItem(at: file)
                let start = Task { @MainActor in
                    try await coordinator.start(request: backgroundRequest(context), file: file, offset: 0,
                        context: context, isAuthorized: { context.isAuthorized(in: ledger) }, check: {})
                }
                try await waitForDriveInterleaving("migration reached " + heldPhase) {
                    guard let old = sessions.first else { return false }
                    return heldPhase == "enumeration" ? old.enumerationCount == 1 : old.gracefulInvalidationCount == 1
                }
                let old = sessions[0]
                var handoffFinished = false
                let handoff = Task { @MainActor in try await coordinator.handoffForPendingEvents(); handoffFinished = true }
                try await waitForDriveInterleaving("handoff began invalidation") { old.cancellationCount == 1 }
                try require(!handoffFinished && sessions.count == 1
                    && !settings.nativeSessionUsesRequestPolicy(coordinator.identifier),
                    "Handoff or migration advanced before the invalidation callback")
                if heldPhase == "enumeration" { old.releaseEnumeration() }
                old.releaseInvalidation()
                do { try await start.value; throw ProbeFailure(message: "Retired migration registered a body") }
                catch is CancellationError { }
                try await handoff.value
                try require(sessions.count == 1 && adapters.count == 1 && old.cancellationCount == 1
                    && old.gracefulInvalidationCount == (heldPhase == "enumeration" ? 0 : 1)
                    && !settings.nativeSessionUsesRequestPolicy(coordinator.identifier)
                    && coordinator.records.isEmpty && coordinator.stagedBodyBytes == 0 && !coordinator.hasActiveUpload,
                    "Migration rebuilt an abandoned session, changed policy, or escaped the handoff boundary")
                do {
                    _ = try adapters[0].create(backgroundRequest(context), file: file, nonce: "retired")
                    throw ProbeFailure(message: "Closed adapter accepted a request")
                } catch is CancellationError { }
                do {
                    try await adapters[0].prepareForNewRequests(allowSessionMigration: true)
                    throw ProbeFailure(message: "Closed adapter reopened")
                } catch is CancellationError { }
                adapters[0].resume(1)
                await adapters[0].invalidateAndCancel()
                try require(sessions.count == 1 && old.cancellationCount == 1, "Repeated close retired a new generation")
                // The coordinator alone owns the next same-identifier adapter.
                await coordinator.recover(in: ledger)
                try require(adapters.count == 2 && sessions.count == 2
                    && adapters[0].identifier == adapters[1].identifier && !coordinator.isUnavailable
                    && ledger.savedAudioCount == 0 && context.isAuthorized(in: ledger),
                    "Fresh recovery lacked an exclusive adapter or changed the grant/session")
                let teardown = Task { @MainActor in await adapters[1].invalidateAndCancel() }
                try await waitForDriveInterleaving("fresh adapter teardown") { sessions[1].cancellationCount == 1 }
                sessions[1].releaseInvalidation(); await teardown.value
            }
        }

        await test("late UIKit event handoff waits for native invalidation and persists every prior completion") {
            let (ledger, _, _, file, context) = try backgroundFixture(root: root)
            let directory = root.appendingPathComponent(UUID().uuidString), native = NativeUploads()
            var finished = 0
            let coordinator = try GoogleDriveBackgroundUploads(directory: directory, libraryID: ledger.libraryID,
                changed: {}, finishedEvents: { _ in finished += 1 }, factory: native.factory)
            try await coordinator.start(request: backgroundRequest(context), file: file, offset: 0, context: context, isAuthorized: { true }, check: {})
            // An earlier drained event had no UIKit handler. A later handler
            // must acquire a new native boundary rather than reuse that event.
            native.finished?(BackgroundSessionEventTracker.shared.capture(coordinator.identifier)); await settleUploads()
            native.holdInvalidation = true
            var completed = false
            let handoff = Task { @MainActor in try await coordinator.handoffForPendingEvents(); completed = true }
            await settleUploads()
            let waitedForNative = !completed && coordinator.hasActiveUpload
            native.releaseInvalidation(); try await handoff.value
            let saved = try TransportCodec.decode(PipelineState.self,
                from: Data(contentsOf: directory.appendingPathComponent("pipeline.json"))).records[0]
            try require(waitedForNative && native.invalidationCount == 1 && saved.completed && !coordinator.hasActiveUpload,
                        "Late handler completed before fresh invalidation and durable completion drainage")
            try require(finished == 1 && ledger.savedAudioCount == 0, "An old drained event was replayed as a new wave or became verified")
        }


        await test("recovery from an invalidated transport cannot mutate a newly registered attempt") {
            let (ledger, _, _, file, context) = try backgroundFixture(root: root)
            let native = NativeUploads()
            let coordinator = try GoogleDriveBackgroundUploads(directory: root.appendingPathComponent(UUID().uuidString),
                libraryID: ledger.libraryID, changed: {}, finishedEvents: { _ in }, factory: native.factory)
            try await coordinator.start(request: backgroundRequest(context), file: file, offset: 0, context: context, isAuthorized: { true }, check: {})
            native.holdEnumeration = true
            let oldRecovery = Task { @MainActor in await coordinator.recover(in: ledger) }
            await settleUploads()
            try await coordinator.handoffForPendingEvents()
            try coordinator.discardCompleted()
            try await coordinator.start(request: backgroundRequest(context), file: file, offset: 0, context: context, isAuthorized: { true }, check: {})
            let newNonce = coordinator.record!.nonce
            native.releaseEnumeration(); await oldRecovery.value
            try require(coordinator.record?.nonce == newNonce && coordinator.record?.completed == false
                && coordinator.hasActiveUpload && !coordinator.isUnavailable,
                "An old getAllTasks result changed a new attempt after UIKit handoff")
        }

        await test("native response URL mismatch fails closed and cannot verify any artifact") {
            let (ledger, _, _, file, context) = try backgroundFixture(root: root)
            let native = NativeUploads()
            let coordinator = try GoogleDriveBackgroundUploads(directory: root.appendingPathComponent(UUID().uuidString),
                libraryID: ledger.libraryID, changed: {}, finishedEvents: { _ in }, factory: native.factory)
            try await coordinator.start(request: backgroundRequest(context), file: file, offset: 0, context: context, isAuthorized: { true }, check: {})
            native.emit(native.active[0], responseURL: "https://evil.invalid")
            await settleUploads()
            try require(coordinator.isUnavailable && ledger.savedAudioCount == 0, "A redirected upload was accepted as success")
        }
        await test("corrupt or aliased durable attempt blocks restoration") {
            for aliased in [false, true] {
                let (ledger, _, _, _, _) = try backgroundFixture(root: root)
                let directory = root.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                let state = directory.appendingPathComponent("attempt.json")
                if aliased {
                    let target = root.appendingPathComponent(UUID().uuidString); try Data("{}".utf8).write(to: target)
                    try FileManager.default.createSymbolicLink(at: state, withDestinationURL: target)
                } else { try Data("broken".utf8).write(to: state) }
                do {
                    _ = try GoogleDriveBackgroundUploads(directory: directory, libraryID: ledger.libraryID,
                        changed: {}, finishedEvents: { _ in }, factory: NativeUploads().factory)
                    throw ProbeFailure(message: "Malformed durable state was accepted")
                } catch is ProbeFailure { throw ProbeFailure(message: "Malformed durable state was accepted") }
                catch { }
            }
        }
        for resumed in [false, true] {
            await test(resumed ? "client native handoff uses the exact Google-confirmed resumable suffix" : "client saves a new resumable URL before native handoff without ephemeral body PUT") {
                var (ledger, manifest, artifact, file) = try fixture(Data(repeating: 7, count: 1_048_580), root: root)
                if resumed {
                    try ledger.recordSession(segmentID: manifest.id, key: artifact.key,
                        url: "https://www.googleapis.com/upload/drive/v3/files?upload_id=existing-native")
                    artifact = ledger.jobs[0].artifacts[0]
                }
                let trace = Trace(); var handed = false
                MockProtocol.install { request in
                    trace.append(request)
                    if request.url!.path == "/drive/v3/about" { return try about() }
                    if request.httpMethod == "GET" { return .init(code: 404) }
                    if request.httpMethod == "POST" { return .init(code: 200, headers: ["Location": "https://www.googleapis.com/upload/drive/v3/files?upload_id=new-native"]) }
                    try require(resumed && request.value(forHTTPHeaderField: "Content-Range") == "bytes */1048580",
                                "Native mode issued an ephemeral body PUT")
                    return .init(code: 308, headers: ["Range": "bytes=0-1048575"])
                }
                let client = GoogleDriveClient(http: http(), oauth: Tokens(), accountID: "owner-123", check: {})
                do {
                    _ = try await client.upload(file: file, artifact: artifact, manifest: manifest, folderID: "folder-123",
                        libraryID: ledger.libraryID, backgroundHandoff: { request, body, offset in
                            handed = true
                            try require(request.httpBody == nil && request.httpBodyStream == nil && body == file,
                                        "Native registration materialized a RAM body or changed the source")
                            try require(offset == (resumed ? 1_048_576 : 0)
                                && request.value(forHTTPHeaderField: "Content-Length") == (resumed ? "4" : "1048580"),
                                "Native mode ignored the confirmed resumable suffix")
                            try require(request.url?.absoluteString == ledger.jobs[0].artifacts[0].uploadURL,
                                        "Native bytes preceded the durable upload session")
                        }, saveSession: { url in try ledger.recordSession(segmentID: manifest.id, key: artifact.key, url: url) })
                    throw ProbeFailure(message: "Native registration was returned as a verified file")
                } catch is GoogleDriveUploadHandoff { }
                try require(handed && ledger.savedAudioCount == 0 && trace.count { $0.httpMethod == "PUT" } == (resumed ? 1 : 0),
                            "Native handoff fabricated a receipt or used ephemeral audio bytes")
            }
        }

        await test("pipeline production loop hands eight real files to native before the first completion") {
            let probe = try PipelineProbe(root: root); probe.installProtocol()
            let registered = try await probe.fill()
            try require(registered == 8 && probe.native.requests.count == 8 && probe.coordinator.nativeActiveCount == 8,
                "Single handoff ended the production loop before a real native batch was registered")
            try require(probe.ledger.savedAudioCount == 0 && probe.coordinator.records.allSatisfy { !$0.completed },
                "Native registration fabricated completion receipts")
            let state = try TransportCodec.decode(PipelineState.self, from: Data(contentsOf: probe.directory.appendingPathComponent("pipeline.json")))
            try require(state.schemaVersion == 2 && state.records.count == 8 && Set(state.records.compactMap(\.taskID)).count == 8,
                "Pipeline did not persist each exact task before yielding")
            let next = try probe.coordinator.nextUpload(in: probe.ledger, progress: probe.progress, allowPipelineFill: true)
            try require(!probe.coordinator.canProcess && next == nil,
                "Full native queue kept producing empty work")
        }
        await test("cold restoration keeps live uploads and fills remaining native slots without duplicate PUTs") {
            let probe = try PipelineProbe(root: root); probe.installProtocol(); var checks = 0
            do { try await probe.fill { checks += 1; if checks == 3 { throw CancellationError() } } }
            catch is CancellationError { }
            try require(probe.native.requests.count == 2, "Bounded parent did not stop precisely before its third item")
            let firstIDs = Set(probe.native.resumed)
            probe.coordinator = try GoogleDriveBackgroundUploads(directory: probe.directory, libraryID: probe.ledger.libraryID,
                changed: {}, finishedEvents: { _ in }, factory: probe.native.factory)
            await probe.coordinator.recover(in: probe.ledger)
            let more = try await probe.fill()
            try require(more == 6 && probe.native.requests.count == 8 && probe.native.resumed.count == 8
                && firstIDs.isSubset(of: Set(probe.native.resumed)) && probe.native.cancelled.isEmpty,
                "Recovered active tasks blocked filling or were recreated/cancelled")
        }
        await test("completed receipts cannot reduce the refill floor to one native task") {
            let probe = try PipelineProbe(root: root); probe.installProtocol(); var checks = 0
            do { try await probe.fill { checks += 1; if checks == 2 { throw CancellationError() } } }
            catch is CancellationError { }
            probe.finish(probe.native.active[0]); await settleUploads()
            let completed = probe.coordinator.records[0]
            let selected = try probe.coordinator.nextUpload(in: probe.ledger, progress: probe.progress, allowPipelineFill: true)
            try require(selected?.segmentID != completed.context.manifest.id || selected?.artifactKey != completed.context.artifact.key,
                "Metadata readback consumed the only native refill opportunity")
            try await probe.fill()
            try require(probe.ledger.savedAudioCount == 1 && probe.coordinator.nativeActiveCount >= 2,
                "Prefill either lost exact readback or failed to leave real native work")
        }
        await test("pipeline queue reservations preserve three-small audio fairness without spending receipt credit") {
            let probe = try PipelineProbe(root: root, count: 6, transcripts: true); probe.installProtocol()
            try await probe.fill()
            try require(Array(probe.selectedKinds.prefix(4)) == [.manifest,.transcriptJSON,.transcriptText,.audio]
                && Array(probe.selectedKinds.suffix(4)) == [.manifest,.transcriptJSON,.transcriptText,.audio],
                "Prequeued small files starved audio turns")
            try require(probe.progress.smallVerifiedSinceAudio == 0 && probe.ledger.savedTranscriptCount == 0,
                "Queue reservations were committed as verified receipt credit")
        }
        await test("out-of-order completion verifies and retires only each exact native record before refill") {
            let probe = try PipelineProbe(root: root); probe.installProtocol(); try await probe.fill()
            let tasks = probe.native.active, completedIDs = [tasks[6].id,tasks[1].id]
            for task in [tasks[6],tasks[1]] { probe.finish(task) }; await settleUploads()
            try require(probe.coordinator.pendingReadbackCount == 2 && probe.coordinator.nativeActiveCount == 6,
                "Native completion was not isolated per task")
            try await probe.fill()
            try require(probe.coordinator.records.count == 8 && probe.coordinator.nativeActiveCount == 8
                && probe.coordinator.records.allSatisfy { !completedIDs.contains($0.taskID ?? -1) }
                && probe.ledger.jobs.flatMap(\.artifacts).filter { $0.verifiedAt != nil }.count == 2,
                "Exact remote receipts dropped another live task or failed to refill capacity")
        }
        await test("a native failure backs off only its exact item while healthy pipeline slots continue") {
            let probe = try PipelineProbe(root: root); probe.installProtocol(); try await probe.fill()
            let task = probe.native.active[3], kept = Set(probe.coordinator.records.filter { $0.taskID != task.id }.map(\.nonce))
            probe.finish(task,code:500); await settleUploads()
            let added = try await probe.fill()
            try require(probe.ledger.failureCount == 0 && probe.ledger.retryAfter == nil && probe.coordinator.itemRetries.count == 1
                && kept.isSubset(of:Set(probe.coordinator.records.map(\.nonce))) && probe.coordinator.nativeActiveCount == 8 && added == 1,
                "One failed item delayed healthy sources or consumed their immutable bodies")
        }
        await test("paused pipeline persists cancellation before delayed out-of-order completion cleanup") {
            let probe = try PipelineProbe(root: root); probe.installProtocol(); try await probe.fill()
            probe.native.autoCancelCompletion = false; try probe.ledger.setEnabled(false); probe.coordinator.cancel(); await settleUploads()
            try require(probe.native.cancelled.count == 8 && probe.coordinator.records.allSatisfy(\.cancelled),
                "Pause failed to fence every registered task")
            for task in probe.native.cancelledEvents.reversed() {
                probe.native.complete?(.init(task:task,responseURL:nil,status:nil,transportFailed:true)); await settleUploads()
                try require(!probe.coordinator.isUnavailable, "Normal cancellation order failed closed")
            }
            try require(probe.coordinator.records.isEmpty && probe.ledger.jobs.flatMap(\.artifacts).allSatisfy { $0.verifiedAt == nil },
                "Cancelled native events fabricated receipts or leaked durable body pointers")
        }
        await test("cold pipeline source fence cancels changed source only and retains other exact tasks") {
            let probe = try PipelineProbe(root: root); probe.installProtocol(); try await probe.fill()
            let changed = probe.coordinator.records[0].context.manifest.id
            let expected = probe.coordinator.records.filter { $0.context.manifest.id == changed }.count
            var object = try JSONSerialization.jsonObject(with: TransportCodec.encode(probe.ledger)) as! [String:Any]
            var jobs = object["jobs"] as! [[String:Any]]
            let index = jobs.firstIndex { UUID(uuidString: ($0["manifest"] as! [String:Any])["id"] as! String) == changed }!
            var manifest = jobs[index]["manifest"] as! [String:Any]; manifest["sequence"] = (manifest["sequence"] as! Int) + 100
            jobs[index]["manifest"] = manifest
            let revised = try TransportCodec.decode(SegmentManifest.self, from: json(manifest))
            let bytes = try TransportCodec.encode(GoogleDriveLibraryLedger.exportManifest(revised))
            var artifacts = jobs[index]["artifacts"] as! [[String:Any]]
            for i in artifacts.indices where artifacts[i]["kind"] as? String == "manifest" {
                artifacts[i]["sha256"] = GoogleDriveLibraryLedger.digest(bytes); artifacts[i]["byteCount"] = bytes.count
            }
            jobs[index]["artifacts"] = artifacts; object["jobs"] = jobs
            probe.ledger = try TransportCodec.decode(GoogleDriveLibraryLedger.self, from: json(object)); try probe.ledger.validate()
            probe.coordinator = try GoogleDriveBackgroundUploads(directory:probe.directory,libraryID:probe.ledger.libraryID,
                changed:{},finishedEvents:{_ in},factory:probe.native.factory)
            await probe.coordinator.recover(in:probe.ledger); await settleUploads()
            try require(probe.native.cancelled.count == expected && probe.coordinator.nativeActiveCount == 8 - expected
                && probe.coordinator.records.allSatisfy { $0.context.manifest.id != changed },
                "Changed source either remained authorized or cancelled unrelated source uploads")
        }
        await test("revoked pipeline cold recovery cancels all native scopes without recording success") {
            let probe = try PipelineProbe(root:root);probe.installProtocol();try await probe.fill()
            probe.ledger.revoke()
            probe.coordinator = try GoogleDriveBackgroundUploads(directory:probe.directory,libraryID:probe.ledger.libraryID,
                changed:{},finishedEvents:{_ in},factory:probe.native.factory)
            await probe.coordinator.recover(in:probe.ledger);await settleUploads()
            try require(probe.native.cancelled.count == 8 && probe.coordinator.records.isEmpty
                && probe.ledger.jobs.flatMap(\.artifacts).allSatisfy { $0.verifiedAt == nil },
                "Revoked batch survived cold recovery or claimed success")
        }
        await test("legacy single attempt migration preserves exact session file task and immutable body") {
            let (ledger,_,_,file,context) = try backgroundFixture(root:root)
            let directory = root.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
            let saved = GoogleDriveBackgroundUploads.Record(schemaVersion:1,nonce:UUID(),context:context,offset:0,
                bodyByteCount:context.artifact.byteCount,bodySHA256:context.artifact.sha256,taskID:42)
            try TransportCodec.encode(saved).write(to:directory.appendingPathComponent("attempt.json"))
            try FileManager.default.copyItem(at:file,to:directory.appendingPathComponent(saved.bodyName))
            let native = NativeUploads();native.active=[.init(id:42,nonce:saved.nonce.uuidString.lowercased(),url:context.artifact.uploadURL,
                method:"PUT",contentRange:saved.contentRange)]
            let restored = try GoogleDriveBackgroundUploads(directory:directory,libraryID:ledger.libraryID,changed:{},finishedEvents:{_ in},factory:native.factory)
            await restored.recover(in:ledger)
            try require(restored.records.count == 1 && restored.record?.nonce == saved.nonce && restored.record?.context == context
                && restored.record?.taskID == 42 && !FileManager.default.fileExists(atPath:directory.appendingPathComponent("attempt.json").path)
                && native.requests.isEmpty && native.cancelled.isEmpty,
                "Legacy migration replaced original file/session/task or duplicated upload bytes")
        }
        await test("crash after pipeline commit before legacy unlink retries migration without dual recovery") {
            let (ledger,_,_,file,context)=try backgroundFixture(root:root)
            let directory=root.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
            let saved=GoogleDriveBackgroundUploads.Record(schemaVersion:1,nonce:UUID(),context:context,offset:0,
                bodyByteCount:context.artifact.byteCount,bodySHA256:context.artifact.sha256,taskID:42)
            try TransportCodec.encode(saved).write(to:directory.appendingPathComponent("attempt.json"))
            try TransportCodec.encode(PipelineState(schemaVersion:2,records:[saved])).write(to:directory.appendingPathComponent("pipeline.json"))
            try FileManager.default.copyItem(at:file,to:directory.appendingPathComponent(saved.bodyName))
            let restored=try GoogleDriveBackgroundUploads(directory:directory,libraryID:ledger.libraryID,changed:{},finishedEvents:{_ in},factory:NativeUploads().factory)
            try require(restored.records.count == 1 && restored.record?.context == context
                && !FileManager.default.fileExists(atPath:directory.appendingPathComponent("attempt.json").path),
                "Interrupted migration created two recovery authorities")
        }
        await test("conflicting legacy and pipeline authority fails closed before native creation") {
            let (ledger,_,_,_,context)=try backgroundFixture(root:root)
            let directory=root.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
            let a=GoogleDriveBackgroundUploads.Record(schemaVersion:1,nonce:UUID(),context:context,offset:0,bodyByteCount:context.artifact.byteCount,bodySHA256:context.artifact.sha256)
            let b=GoogleDriveBackgroundUploads.Record(schemaVersion:1,nonce:UUID(),context:context,offset:0,bodyByteCount:context.artifact.byteCount,bodySHA256:context.artifact.sha256)
            try TransportCodec.encode(a).write(to:directory.appendingPathComponent("attempt.json"))
            try TransportCodec.encode(PipelineState(schemaVersion:2,records:[b])).write(to:directory.appendingPathComponent("pipeline.json"))
            do {_=try GoogleDriveBackgroundUploads(directory:directory,libraryID:ledger.libraryID,changed:{},finishedEvents:{_ in},factory:NativeUploads().factory)
                throw ProbeFailure(message:"Conflicting migration authorities were merged")}
            catch is ProbeFailure { throw ProbeFailure(message:"Conflicting migration authorities were merged") }
            catch { }
        }
        await test("absolute body bound rejects invalid and overflowing byte counts before file staging") {
            let probe=try PipelineProbe(root:root,count:1)
            try require(!probe.coordinator.canReserve(bytes:0) && !probe.coordinator.canReserve(bytes:-1)
                && probe.coordinator.canReserve(bytes:64*1_024*1_024)
                && probe.coordinator.canReserve(bytes:130*1_024*1_024)
                && !probe.coordinator.canReserve(bytes:130*1_024*1_024+1)
                && !probe.coordinator.canReserve(bytes:Int64.max),"Absolute artifact bound or overflow guard failed")
        }
        await test("actual immutable body staging stops at 64MiB including completed unverified bodies") {
            let probe=try PipelineProbe(root:root,count:4,audioBytes:16*1_024*1_024)
            for job in probe.ledger.jobs {
                let artifact=job.artifacts.first { $0.kind == .audio }!, context=try GoogleDriveUploadContext(ledger:probe.ledger,manifest:job.manifest,artifact:artifact)
                try await probe.coordinator.start(request:backgroundRequest(context),file:probe.files[job.id.uuidString.lowercased()+"/"+artifact.key]!,offset:0,
                    context:context,isAuthorized:{context.isAuthorized(in:probe.ledger)},check:{})
            }
            try require(probe.coordinator.stagedBodyBytes == 64*1_024*1_024 && !probe.coordinator.canReserve(bytes:1),"Real staged bodies exceeded the 64MiB batch bound")
            probe.native.emit(probe.native.active[0]);await settleUploads()
            try require(probe.coordinator.nativeActiveCount == 3 && !probe.coordinator.canReserve(bytes:1),"HTTP completion released unverified private body capacity")
            try probe.coordinator.discardCompleted(nonce:probe.coordinator.records.first { $0.completed }!.nonce)
            try require(probe.coordinator.canReserve(bytes:16*1_024*1_024),"Exact completed-body cleanup failed to release its capacity")
        }
        await test("single oversized real file occupies the whole bounded queue until verified cleanup") {
            let probe=try PipelineProbe(root:root,count:1,audioBytes:65*1_024*1_024),job=probe.ledger.jobs[0]
            let artifact=job.artifacts.first { $0.kind == .audio }!,context=try GoogleDriveUploadContext(ledger:probe.ledger,manifest:job.manifest,artifact:artifact)
            try await probe.coordinator.start(request:backgroundRequest(context),file:probe.files[job.id.uuidString.lowercased()+"/"+artifact.key]!,offset:0,
                context:context,isAuthorized:{context.isAuthorized(in:probe.ledger)},check:{})
            try require(probe.coordinator.records.count == 1 && probe.coordinator.stagedBodyBytes == 65*1_024*1_024
                && !probe.coordinator.canReserve(bytes:1),"Oversized exception allowed concurrent extra staging")
        }

        await test("live source invalidation keeps cancelled native slots occupied until actual completion") {
            let probe = try PipelineProbe(root:root); probe.installProtocol(); try await probe.fill()
            let original = probe.native.active, changed = probe.coordinator.records[0].context.manifest.id
            probe.native.autoCancelCompletion = false
            try probe.changeSourceMetadata(changed); try probe.coordinator.cancelUnauthorized(in:probe.ledger); await settleUploads()
            let cancelled = probe.native.cancelledEvents
            try require(!cancelled.isEmpty && original.count == 8 && !probe.coordinator.canReserve(bytes:1),
                "Cancel request released native slots before their completion callbacks")
            let added = try await probe.fill()
            try require(added == 0 && probe.native.requests.count == 8 && probe.coordinator.records.filter(\.cancelled).count == cancelled.count,
                "A ninth real task was created while cancellation callbacks were outstanding")
            for task in cancelled { probe.native.complete?(.init(task:task,responseURL:nil,status:nil,transportFailed:true)) }
            await settleUploads(); try await probe.fill()
            try require(probe.native.requests.count == 8 + cancelled.count && probe.coordinator.nativeActiveCount == 8
                && !probe.coordinator.isUnavailable,
                "Actual cancellation completion did not release only its own source slots")
        }
        await test("all eight deferred items persist a future wake without repeated empty account rounds and recover when due") {
            let probe = try PipelineProbe(root:root,count:4); probe.installProtocol(); try await probe.fill()
            let original = probe.native.active
            for task in original { probe.finish(task,code:500) }; await settleUploads()
            let added = try await probe.fill()
            let due = probe.coordinator.earliestRetryAt(in:probe.ledger)
            let next = try probe.coordinator.nextUpload(in:probe.ledger,progress:probe.progress,allowPipelineFill:true)
            let wake = try probe.coordinator.nextWorkDate(in:probe.ledger,progress:probe.progress,fallback:probe.clock.now().addingTimeInterval(15))
            try require(added == 0 && probe.coordinator.itemRetries.count == 8 && probe.coordinator.records.isEmpty
                && next == nil && due != nil && wake == due && due! > probe.clock.now()
                && probe.ledger.retryAfter == nil && !probe.coordinator.hasActiveUpload,
                "Future-only work either ran an empty round, lost its durable wake or blocked unrelated scope")
            let previousRequests = probe.native.requests.count
            for _ in 0..<3 { try await probe.fill() }
            try require(probe.native.requests.count == previousRequests,"Future-deferred files repeated native body registrations")
            probe.coordinator = try GoogleDriveBackgroundUploads(directory:probe.directory,libraryID:probe.ledger.libraryID,
                changed:{},finishedEvents:{_ in},now:{[clock=probe.clock] in clock.now()},factory:probe.native.factory)
            try require(probe.coordinator.itemRetries.count == 8 && abs(probe.coordinator.earliestRetryAt(in:probe.ledger)!.timeIntervalSince(due!)) < 0.001,
                "Cold launch discarded per-item retry times")
            probe.clock.advance(11); let resumed = try await probe.fill()
            try require(resumed == 8 && probe.native.requests.count == 16 && probe.coordinator.nativeActiveCount == 8,
                "Durable due items did not recover after their finite wait")
        }
        await test("one deferred readback keeps its body while a healthy completed peer verifies and new files fill") {
            let probe = try PipelineProbe(root:root); probe.installProtocol(); try await probe.fill()
            let first = probe.native.active[0], second = probe.native.active[1]
            probe.finish(first,code:500); probe.finish(second); await settleUploads()
            let failed = probe.coordinator.records.first { $0.taskID == first.id }!, failedID = failed.context.artifact.fileID!
            let healthyID = probe.coordinator.records.first { $0.taskID == second.id }!.context.artifact.fileID!
            MockProtocol.install { request in
                if request.url!.path == "/drive/v3/about" { return try about() }
                if request.url!.lastPathComponent == failedID { return .init(code:503) }
                if request.httpMethod == "GET", request.url!.lastPathComponent == healthyID {
                    let artifact = probe.ledger.jobs.flatMap(\.artifacts).first { $0.fileID == healthyID }!
                    let job = probe.ledger.jobs.first { $0.artifacts.contains(artifact) }!
                    let remote = GoogleDriveRemoteFile(id:healthyID,size:String(artifact.byteCount),sha256Checksum:artifact.sha256,
                        parents:[probe.ledger.folderID!],ownedByMe:true,shared:false,trashed:false,
                        appProperties:["rfaSchema":"1","rfaLibraryID":probe.ledger.libraryID.uuidString.lowercased(),
                            "rfaSegmentID":job.id.uuidString.lowercased(),"rfaKind":artifact.kind.rawValue,
                            "rfaAudioSHA256":job.manifest.sha256,"rfaContentSHA256":artifact.sha256],
                        permissions:[.init(id:"owner-123",type:"user",role:"owner")])
                    return .init(code:200,data:try TransportCodec.encode(remote))
                }
                return .init(code:request.httpMethod == "GET" ? 404 : 308)
            }
            let added = try await probe.fill()
            try require(added == 2 && probe.coordinator.itemRetries.count == 1 && probe.coordinator.itemRetries[0].attemptNonce == failed.nonce
                && probe.coordinator.records.contains { $0.nonce == failed.nonce && $0.completed }
                && probe.coordinator.nativeActiveCount == 8 && probe.ledger.jobs.flatMap(\.artifacts).filter { $0.verifiedAt != nil }.count == 1
                && probe.ledger.failureCount == 0,
                "One uncertain readback lost its body or stopped healthy verification/fill")
        }
        await test("due incomplete readback spends its existing item wait once before a new native attempt") {
            let probe = try PipelineProbe(root:root,count:1); probe.installProtocol(); try await probe.fill()
            let task = probe.native.active[0]
            probe.finish(task,code:500); await settleUploads()
            let saved = probe.coordinator.records.first { $0.taskID == task.id }!, id = saved.context.artifact.fileID!
            MockProtocol.install { request in
                if request.url!.path == "/drive/v3/about" { return try about() }
                if request.url!.lastPathComponent == id { return .init(code:503) }
                return .init(code:request.httpMethod == "GET" ? 404 : 308)
            }
            try await probe.fill(); try require(probe.coordinator.records.contains { $0.nonce == saved.nonce },"Network failure discarded uncertain body")
            probe.clock.advance(11); probe.installProtocol(); let added = try await probe.fill()
            try require(added == 1 && probe.coordinator.itemRetries.first?.failures == 1 && !probe.coordinator.records.contains { $0.nonce == saved.nonce },
                "Due readback added another wait instead of consuming its exact prior uncertainty once")
        }
        await test("finite production loop caps immediately verified work independently of the lease clock") {
            let probe = try PipelineProbe(root:root,count:20); probe.installProtocol()
            var operations = 0
            let added = try await probe.coordinator.runAvailable(ledger:{probe.ledger},progress:{probe.progress},check:{}) { selected in
                operations += 1
                _ = try acceptSyntheticReceipt(selected,in:&probe.ledger)
            }
            try require(added == 0 && operations == 16 && probe.ledger.hasPendingFiles,
                "Instant metadata success ran an unbounded loop without monotonic time advancing")
        }
        await test("P-60 new sources outrank historical prepared pins and historical progress survives cold rounds") {
            let manifests = orderedManifests(715), authorizedAt = manifests[11].startedAt.addingTimeInterval(-30)
            var ledger = try priorityLedger(manifests, authorizedAt: authorizedAt), progress = GoogleDriveSyncProgress()
            let history = ledger.jobs[12], historyAudio = history.artifacts.first { $0.kind == .audio }!
            let originalSession = "https://www.googleapis.com/upload/drive/v3/files?upload_id=p60-history"
            try ledger.allocateFile(segmentID: history.id, key: historyAudio.key, fileID: "p60-history")
            try ledger.recordSession(segmentID: history.id, key: historyAudio.key, url: originalSession)
            let pin = try GoogleDrivePreflightPin(ledger: ledger,
                selected: .init(segmentID: history.id, artifactKey: historyAudio.key, isPrioritySmall: false))
            let directory = root.appendingPathComponent(UUID().uuidString), native = NativeUploads()
            var choices: [GoogleDriveSyncProgress.UploadChoice] = []
            for _ in 0..<8 {
                let coordinator = try GoogleDriveBackgroundUploads(directory: directory, libraryID: ledger.libraryID,
                    changed: {}, finishedEvents: { _ in }, factory: native.factory)
                try await coordinator.runAvailable(ledger: { ledger }, progress: { progress }, check: {}, preflight: { pin },
                    maximumOperations: 1) { selected in
                    choices.append(selected)
                    if choices.count <= 3 {
                        let retained = ledger.jobs.first { $0.id == history.id }!.artifacts.first { $0.key == historyAudio.key }!
                        try require(retained.uploadURL == originalSession && retained.fileID == "p60-history",
                            "New-source scheduling changed a historical resumable file/session")
                    }
                    _ = try acceptSyntheticReceipt(selected, in: &ledger)
                    try progress.didVerify(selected, in: ledger.jobs)
                }
            }
            let recent = Set(manifests.prefix(12).map(\.id))
            let recentTurns = choices.map { recent.contains($0.segmentID) }
            try require(choices.first?.segmentID == manifests[0].id && recentTurns == [true, true, true, false, true, true, true, false]
                && ledger.jobs.filter { !recent.contains($0.id) }.flatMap(\.artifacts).filter { $0.verifiedAt != nil }.count == 2
                && native.requests.isEmpty,
                "Cold reconstruction reset source fairness or a historical prepared pin delayed the newest source")
        }
        await test("P-60 newest recent source precedes an older prepared session without replacing its identity") {
            let manifests = orderedManifests(2)
            var ledger = try priorityLedger(manifests), progress = GoogleDriveSyncProgress()
            let older = ledger.jobs[1], audio = older.artifacts.first { $0.kind == .audio }!
            let session = "https://www.googleapis.com/upload/drive/v3/files?upload_id=p60-older-recent"
            try ledger.allocateFile(segmentID: older.id, key: audio.key, fileID: "p60-older-recent")
            try ledger.recordSession(segmentID: older.id, key: audio.key, url: session)
            let pin = try GoogleDrivePreflightPin(ledger: ledger,
                selected: .init(segmentID: older.id, artifactKey: audio.key, isPrioritySmall: false))
            let coordinator = try GoogleDriveBackgroundUploads(directory: root.appendingPathComponent(UUID().uuidString),
                libraryID: ledger.libraryID, changed: {}, finishedEvents: { _ in }, factory: NativeUploads().factory)
            var choices: [GoogleDriveSyncProgress.UploadChoice] = []
            try await coordinator.runAvailable(ledger: { ledger }, progress: { progress }, check: {}, preflight: { pin },
                maximumOperations: 3) { selected in
                choices.append(selected)
                let retained = ledger.jobs.first { $0.id == older.id }!.artifacts.first { $0.key == audio.key }!
                try require(retained.fileID == "p60-older-recent" && retained.uploadURL == session,
                    "Choosing newer work replaced the existing resumable session")
                _ = try acceptSyntheticReceipt(selected, in: &ledger)
                try progress.didVerify(selected, in: ledger.jobs)
            }
            try require(choices.map(\.segmentID) == [manifests[0].id, manifests[0].id, older.id]
                && choices.last?.artifactKey == audio.key && ledger.savedAudioCount == 2,
                "Prepared older work delayed the newest source or failed to resume afterward")
        }
        await test("P-60 cancelled recent turns preserve the historical opportunity across reconstruction") {
            let manifests = orderedManifests(5), authorizedAt = manifests[1].startedAt.addingTimeInterval(-30)
            var ledger = try priorityLedger(manifests, authorizedAt: authorizedAt)
            let directory = root.appendingPathComponent(UUID().uuidString), native = NativeUploads()
            let progress = GoogleDriveSyncProgress(), original = try TransportCodec.encode(ledger)
            for _ in 0..<3 {
                let coordinator = try GoogleDriveBackgroundUploads(directory: directory, libraryID: ledger.libraryID,
                    changed: {}, finishedEvents: { _ in }, factory: native.factory)
                do {
                    try await coordinator.runAvailable(ledger: { ledger }, progress: { progress }, check: {}, maximumOperations: 1) { selected in
                        try require(selected.segmentID == manifests[0].id, "A fresh grant skipped its newest source")
                        throw CancellationError()
                    }
                    throw ProbeFailure(message: "A cancelled lease completed unexpectedly")
                } catch is CancellationError { }
                let unchanged = try TransportCodec.encode(ledger)
                try require(coordinator.itemRetries.isEmpty && unchanged == original,
                    "Cancellation invented a remote receipt or a per-item network retry")
            }
            let resumed = try GoogleDriveBackgroundUploads(directory: directory, libraryID: ledger.libraryID,
                changed: {}, finishedEvents: { _ in }, factory: native.factory)
            var verified: UUID?
            try await resumed.runAvailable(ledger: { ledger }, progress: { progress }, check: {}, maximumOperations: 1) { selected in
                verified = selected.segmentID
                _ = try acceptSyntheticReceipt(selected, in: &ledger)
            }
            let next = try resumed.nextUpload(in: ledger, progress: progress)
            try require(verified == manifests[2].id && ledger.savedAudioCount == 1
                && next?.segmentID == manifests[0].id,
                "Repeated cancelled fresh work starved the historical backlog or failed to restore fresh priority")
        }
        await test("P-60 completed historical readback waits for fresh work then receives its durable fair turn") {
            let probe = try PipelineProbe(root: root, count: 4, authorizedAt: Date(timeIntervalSince1970: 1_700_000_150))
            let history = probe.ledger.jobs[2], artifact = history.artifacts.first { $0.kind == .audio }!
            let context = try GoogleDriveUploadContext(ledger: probe.ledger, manifest: history.manifest, artifact: artifact)
            try await probe.coordinator.start(request: backgroundRequest(context), file: probe.files[history.id.uuidString.lowercased() + "/" + artifact.key]!,
                offset: 0, context: context, isAuthorized: { context.isAuthorized(in: probe.ledger) }, check: {})
            probe.finish(probe.native.active[0]); await settleUploads()
            let prematureReadback = try await probe.readBackOne()
            try require(!prematureReadback && probe.ledger.savedAudioCount == 0,
                "Historical completed metadata jumped ahead of fresh pending sources")
            for _ in 0..<3 {
                do {
                    try await probe.coordinator.runAvailable(ledger: { probe.ledger }, progress: { probe.progress }, check: {}, maximumOperations: 1) { selected in
                        try require(selected.segmentID == probe.ledger.jobs[0].id, "Fresh source unexpectedly lost its attempt")
                        throw CancellationError()
                    }
                } catch is CancellationError { }
            }
            probe.coordinator = try GoogleDriveBackgroundUploads(directory: probe.directory, libraryID: probe.ledger.libraryID,
                changed: {}, finishedEvents: { _ in }, factory: probe.native.factory)
            await probe.coordinator.recover(in: probe.ledger)
            probe.installProtocol(); let readback = try await probe.readBackOne()
            try require(readback && probe.ledger.savedAudioCount == 1 && probe.coordinator.records.isEmpty
                && probe.ledger.jobs.first { $0.id == history.id }!.artifacts.first { $0.key == artifact.key }!.verifiedAt != nil,
                "Fresh cancellation starved a historical strict readback or retired the wrong source")
        }
        await test("P-60 progress first short lease and durable snapshot cursor") {
            try await GoogleDriveProgressFirstCases.run(root: root.appendingPathComponent("p60-progress"))
        }
        await test("REC-36 live transport failure preserves bounded local discovery and original failure") {
            try await GoogleDriveDiscoveryFailureCases.run(root: root.appendingPathComponent("rec36-discovery"))
        }
        await test("REC-36 expired lease before local discovery preserves network failure and phase") {
            try await GoogleDriveDiscoveryFailureCases.runInterruptedRecovery(
                root: root.appendingPathComponent("rec36-discovery-expired-before"), stop: .beforeDiscovery)
        }
        await test("REC-36 local discovery errors preserve network failure and phase") {
            try await GoogleDriveDiscoveryFailureCases.runInterruptedRecovery(
                root: root.appendingPathComponent("rec36-discovery-failed"), stop: .duringDiscovery)
        }
        await test("REC-36 expired lease after local discovery preserves network failure and durable admission") {
            try await GoogleDriveDiscoveryFailureCases.runInterruptedRecovery(
                root: root.appendingPathComponent("rec36-discovery-expired-after"), stop: .afterDiscovery)
        }
        await test("concurrent immutable staging reserves native slots before detached file IO") {
            let probe = try PipelineProbe(root:root,count:12,audioBytes:2*1_024*1_024)
            let tasks = probe.ledger.jobs.map { job in
                Task { @MainActor in
                    let artifact = job.artifacts.first { $0.kind == .audio }!
                    do {
                        let context = try GoogleDriveUploadContext(ledger:probe.ledger,manifest:job.manifest,artifact:artifact)
                        try await probe.coordinator.start(request:backgroundRequest(context),
                            file:probe.files[job.id.uuidString.lowercased()+"/"+artifact.key]!,offset:0,context:context,
                            isAuthorized:{context.isAuthorized(in:probe.ledger)},check:{})
                        return true
                    } catch { return false }
                }
            }
            var results:[Bool]=[];for task in tasks { results.append(await task.value) }
            try require(results.filter { $0 }.count == 8 && probe.native.requests.count == 8
                && probe.coordinator.records.count == 8 && probe.coordinator.stagedBodyBytes == 16*1_024*1_024,
                "Concurrent staging overbooked the eight real native slots or lost an accepted body")
        }
        await test("revoking a deferred scope removes only its retry evidence and never schedules old source work") {
            let probe = try PipelineProbe(root:root,count:1); probe.installProtocol(); try await probe.fill()
            for task in probe.native.active { probe.finish(task,code:500) };await settleUploads();try await probe.fill()
            try require(probe.coordinator.itemRetries.count == 2,"Fixture lacked deferred state")
            probe.ledger.revoke();try probe.coordinator.cancelUnauthorized(in:probe.ledger)
            try require(probe.coordinator.itemRetries.isEmpty && probe.coordinator.earliestRetryAt(in:probe.ledger) == nil,
                "Old scope retained runnable or schedulable retry bindings after local revocation")
        }

        await test("full retained-body queue with only future readbacks becomes runnable exactly when durable due arrives") {
            let probe = try PipelineProbe(root:root,count:8,audioBytes:8*1_024*1_024)
            for job in probe.ledger.jobs {
                let artifact=job.artifacts.first { $0.kind == .audio }!,context=try GoogleDriveUploadContext(ledger:probe.ledger,manifest:job.manifest,artifact:artifact)
                try await probe.coordinator.start(request:backgroundRequest(context),file:probe.files[job.id.uuidString.lowercased()+"/"+artifact.key]!,offset:0,
                    context:context,isAuthorized:{context.isAuthorized(in:probe.ledger)},check:{})
            }
            for task in probe.native.active { probe.finish(task,code:500) };await settleUploads()
            try await probe.coordinator.runAvailable(ledger:{probe.ledger},progress:{probe.progress},check:{}) { _ in throw GoogleDriveError.http(503) }
            let next=try probe.coordinator.nextUpload(in:probe.ledger,progress:probe.progress,allowPipelineFill:true)
            let wake=try probe.coordinator.nextWorkDate(in:probe.ledger,progress:probe.progress,fallback:probe.clock.now().addingTimeInterval(15))
            try require(probe.coordinator.records.count == 8 && probe.coordinator.itemRetries.count == 8
                && !probe.coordinator.canProcess && probe.coordinator.readyReadbackCount == 0 && next == nil
                && wake == probe.coordinator.earliestRetryAt(in:probe.ledger),
                "A full future-deferred queue remained runnable or lost its durable wake")
            probe.clock.advance(11)
            let ready=try probe.coordinator.nextUpload(in:probe.ledger,progress:probe.progress,allowPipelineFill:true)
            try require(probe.coordinator.canProcess && probe.coordinator.readyReadbackCount == 8 && ready != nil,
                "Due readback was blocked by its own retained-body capacity")
        }
        await test("finite production loop separately caps eight handoffs even without native completion or clock progress") {
            let probe=try PipelineProbe(root:root,count:1)
            var operations=0
            let registered=try await probe.coordinator.runAvailable(ledger:{probe.ledger},progress:{probe.progress},check:{}) { _ in
                operations += 1;throw GoogleDriveUploadHandoff()
            }
            try require(registered == 8 && operations == 8,"Finite round exceeded eight handoffs")
        }

        await test("cold ordinary background lease reconciles completed records before filling without foreground or UIKit grant") {
            let probe=try PipelineProbe(root:root);probe.installProtocol();var checks=0
            do { try await probe.fill { checks += 1;if checks == 2 { throw CancellationError() } } }catch is CancellationError { }
            probe.finish(probe.native.active[0]);await settleUploads()
            probe.coordinator=try GoogleDriveBackgroundUploads(directory:probe.directory,libraryID:probe.ledger.libraryID,
                changed:{},finishedEvents:{_ in},factory:probe.native.factory)
            let budget=BudgetGate(isForeground:false)
            try require(probe.coordinator.isReconciling,"Fixture was not cold")
            await probe.coordinator.recover(in:probe.ledger,check:{try budget.check()})
            try await probe.fill(check:{try budget.check()})
            try require(!probe.coordinator.isReconciling && probe.coordinator.nativeActiveCount >= 2 && probe.ledger.savedAudioCount == 1,
                "A valid finite ordinary window remained blocked waiting for foreground or a session-specific grant")
        }
        await test("expired ordinary lease cannot attach a cold session and later valid window may retry recovery") {
            let probe=try PipelineProbe(root:root);probe.installProtocol();var checks=0
            do { try await probe.fill { checks += 1;if checks == 2 { throw CancellationError() } } }catch is CancellationError { }
            var factories=0
            probe.coordinator=try GoogleDriveBackgroundUploads(directory:probe.directory,libraryID:probe.ledger.libraryID,
                changed:{},finishedEvents:{_ in},factory:{identifier,complete,finished in
                    factories += 1;return try probe.native.factory(identifier,complete,finished)
                })
            await probe.coordinator.recover(in:probe.ledger,check:{throw CancellationError()})
            try require(factories == 0 && probe.coordinator.isReconciling && !probe.coordinator.isUnavailable,
                "Expired background work attached a session or permanently failed the queue")
            let budget=BudgetGate(isForeground:false)
            await probe.coordinator.recover(in:probe.ledger,check:{try budget.check()})
            try require(factories == 1 && !probe.coordinator.isReconciling && probe.coordinator.nativeActiveCount == 1,
                "A later genuine finite lease could not retry cold restoration")
        }
        await test("ordinary lease expiry during native enumeration leaves recovery required and does not duplicate tasks") {
            let probe=try PipelineProbe(root:root);probe.installProtocol();var checks=0
            do { try await probe.fill { checks += 1;if checks == 2 { throw CancellationError() } } }catch is CancellationError { }
            probe.coordinator=try GoogleDriveBackgroundUploads(directory:probe.directory,libraryID:probe.ledger.libraryID,
                changed:{},finishedEvents:{_ in},factory:probe.native.factory)
            let budget=BudgetGate(isForeground:false);probe.native.holdEnumeration=true
            let restoring=Task { @MainActor in await probe.coordinator.recover(in:probe.ledger,check:{try budget.check()}) }
            while probe.native.enumeration == nil { await Task.yield() }
            budget.advance(20);probe.native.releaseEnumeration();await restoring.value
            try require(probe.coordinator.isReconciling && !probe.coordinator.isUnavailable && probe.native.requests.count == 1,
                "Expired enumeration reopened filling before the actual queue was reconciled")
            probe.native.holdEnumeration=false
            await probe.coordinator.recover(in:probe.ledger)
            try require(!probe.coordinator.isReconciling && probe.native.cancelled.isEmpty && probe.native.requests.count == 1,
                "A second valid window recreated or cancelled an already running exact task")
        }

        await test("a pending transcript inspection wakes before a longer durable item wait") {
            let probe=try PipelineProbe(root:root,count:1);probe.installProtocol();try await probe.fill()
            for task in probe.native.active { probe.finish(task,code:500) };await settleUploads();try await probe.fill()
            let revision=probe.progress.snapshot
            probe.progress.acceptSnapshot(probe.ledger.jobs.map(\.manifest),previousIDs:[],request:revision)
            for manifest in probe.ledger.jobs.map(\.manifest) { try probe.progress.finishRecord(manifest.id,issue:"synthetic issue") }
            probe.progress.finishSlice(observedRevision:revision.revision,at:probe.clock.now().addingTimeInterval(-55))
            let wake=try probe.coordinator.nextWorkDate(in:probe.ledger,progress:probe.progress,fallback:probe.clock.now().addingTimeInterval(15))
            try require(wake == probe.progress.issueRetryAt && wake! < probe.coordinator.earliestRetryAt(in:probe.ledger)!,
                "Per-item upload backoff starved an independent transcript reinspection")
        }


        await test("cold historical source restoration admits discovery without inventing an external wake") {
            let manifests = orderedManifests(2), received = Set(manifests.map(\.id))
            try require(!GoogleDriveSyncProgress.sourceChangeNeedsWake(previousManifests: nil,
                previousReceivedIDs: nil, manifests: manifests, receivedIDs: received),
                "An unknown cold cache treated historical receipts as a new external work event")
            var progress = GoogleDriveSyncProgress()
            progress.requestDiscovery()
            let admitted = try GoogleDriveSyncProgress.SourceSnapshot(ledger: try priorityLedger([manifests[0]]),
                manifests: manifests, receivedIDs: received, request: progress.snapshot)
            progress.acceptSourceSnapshot(admitted)
            try require(admitted.ledger.jobs.count == 2 && !progress.needsSnapshot && progress.needsDiscovery,
                "Suppressing a cold wake also suppressed source admission or pending transcript discovery")
        }
        await test("warm source and durable receipt changes still retain the background wake") {
            let manifests = orderedManifests(2)
            try require(GoogleDriveSyncProgress.sourceChangeNeedsWake(previousManifests: [manifests[0]],
                previousReceivedIDs: [manifests[0].id], manifests: manifests, receivedIDs: Set(manifests.map(\.id))),
                "A new warm source could be erased by completion of an older background task")
            try require(GoogleDriveSyncProgress.sourceChangeNeedsWake(previousManifests: manifests,
                previousReceivedIDs: [manifests[0].id], manifests: manifests, receivedIDs: Set(manifests.map(\.id))),
                "A newly durable receipt with unchanged manifests lost its background wake")
        }
        await test("unchanged warm history and incomplete cache restoration do not manufacture new work") {
            let manifests = orderedManifests(1), received = Set(manifests.map(\.id))
            try require(!GoogleDriveSyncProgress.sourceChangeNeedsWake(previousManifests: manifests,
                previousReceivedIDs: received, manifests: manifests, receivedIDs: received)
                && !GoogleDriveSyncProgress.sourceChangeNeedsWake(previousManifests: manifests,
                    previousReceivedIDs: nil, manifests: manifests, receivedIDs: received)
                && !GoogleDriveSyncProgress.sourceChangeNeedsWake(previousManifests: nil,
                    previousReceivedIDs: received, manifests: manifests, receivedIDs: received),
                "Historical or partially restored source metadata advanced the external work generation")
        }

        await test("new received sources are durably admitted and prioritized while network leases expire") {
            let e = try PreflightExperiment(root: root.appendingPathComponent(UUID().uuidString))
            let original = e.progress.nextUpload(in: e.ledger.jobs)!
            let originalSession = "https://www.googleapis.com/upload/drive/v3/files?upload_id=source-admission-original"
            try e.ledger.allocateFile(segmentID: original.segmentID, key: original.artifactKey, fileID: "source-admission-original")
            try e.ledger.recordSession(segmentID: original.segmentID, key: original.artifactKey, url: originalSession)
            try e.pinStore.capture(ledger: e.ledger, selected: original)
            var all = e.ledger.jobs.map(\.manifest)
            for _ in 0..<4 {
                all += orderedManifests(4)
                e.progress.requestDiscovery()
                let admitted = try GoogleDriveSyncProgress.SourceSnapshot(ledger: e.ledger,
                    manifests: all, receivedIDs: Set(all.map(\.id)), request: e.progress.snapshot)
                // Same durable-ledger-before-progress ordering as the worker.
                e.ledger = try TransportCodec.decode(GoogleDriveLibraryLedger.self,
                    from: TransportCodec.encode(admitted.ledger))
                e.progress.acceptSourceSnapshot(admitted)
                try e.stageAll(); try e.persistRoundTrip()
                let row = try await e.run(dedup: true, delay: 7, localSeconds: 0)
                let selected = e.chosen.last!
                let selectedManifest = e.ledger.jobs.first { $0.id == selected.segmentID }!.manifest
                try require(row["outcome"] as? String == "cancelled" && selected.segmentID != original.segmentID
                    && selectedManifest.startedAt == all.map(\.startedAt).max(),
                    "An older preparation displaced newly admitted sources in an exhausted lease")
                try require(e.ledger.jobs.count == all.count && !e.progress.needsSnapshot
                    && e.progress.needsDiscovery && !e.progress.remaining.isEmpty,
                    "Prepared-request retries hid newly admitted sources or claimed transcript coverage")
                let retained = e.ledger.jobs.first { $0.id == original.segmentID }!.artifacts.first { $0.key == original.artifactKey }!
                try require(retained.fileID == "source-admission-original" && retained.uploadURL == originalSession
                    && e.pinStore.pin?.matches(selected.segmentID, selected.artifactKey) == true,
                    "Source admission replaced the older file/session or failed to persist the new preparation")
            }
            try require(e.ledger.jobs.count == 17 && e.ledger.savedAudioCount == 0
                && e.ledger.jobs.flatMap(\.artifacts).allSatisfy { $0.verifiedAt == nil }
                && e.native.resumed.isEmpty,
                "Metadata source admission invented a native upload or remote receipt")
            preparationEvidence["sourceAdmissionDuringBlockedNetwork"] = e.rounds
        }
        await test("metadata admission retains an existing network retry without granting a cloud receipt") {
            let manifests = orderedManifests(2)
            var ledger = try priorityLedger([manifests[0]])
            let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
            ledger.recordFailure(at: timestamp)
            let retry = ledger.retryAfter, failuresBefore = ledger.failureCount
            var progress = GoogleDriveSyncProgress()
            let admitted = try GoogleDriveSyncProgress.SourceSnapshot(ledger: ledger,
                manifests: manifests, receivedIDs: Set(manifests.map(\.id)), request: progress.snapshot)
            let persisted = try TransportCodec.decode(GoogleDriveLibraryLedger.self,
                from: TransportCodec.encode(admitted.ledger))
            progress.acceptSourceSnapshot(admitted)
            try require(persisted.jobs.count == 2 && persisted.retryAfter == retry
                && persisted.failureCount == failuresBefore && persisted.hasPendingFiles
                && persisted.savedAudioCount == 0 && !progress.needsSnapshot,
                "Metadata-only admission reset backoff, omitted a source, or invented remote success")
        }
        await test("source admission preserves future-only grant missing receipt and newer revision fences") {
            let manifests = orderedManifests(3), allowed = manifests[0], excluded = manifests[1], unreceived = manifests[2]
            let original = try priorityLedger([allowed], scope: .futureOnly, baseline: [excluded.id])
            var progress = GoogleDriveSyncProgress()
            let request = progress.snapshot
            let admitted = try GoogleDriveSyncProgress.SourceSnapshot(ledger: original,
                manifests: [allowed, excluded, unreceived], receivedIDs: [allowed.id, excluded.id], request: request,
                transcriptHints: [excluded.id, unreceived.id])
            progress.requestDiscovery(prioritizing: allowed.id)
            progress.acceptSourceSnapshot(admitted)
            try require(admitted.ledger == original && admitted.addedCount == 0
                && admitted.ledger.baselineIDs == [excluded.id],
                "Source admission widened a grant or accepted a source without a durable receipt")
            try require(progress.needsSnapshot && progress.needsDiscovery
                && Set(progress.remaining.map(\.id)) == [allowed.id],
                "An old source snapshot swallowed a newer event or queued an unauthorized transcript hint")
            try progress.finishRecord(allowed.id, issue: nil)
            progress.finishSlice(observedRevision: progress.revision)
            try require(progress.needsSnapshot && progress.needsDiscovery
                && progress.finishSuccessfulRound(hasPendingFiles: false) == .discovering,
                "Finishing an older transcript slice erased a source event received during snapshot IO")
        }

        await test("eight new transcript arrivals precede an older pin and its exact session resumes after new work completes") {
            let e=try PreflightExperiment(root:root.appendingPathComponent(UUID().uuidString),withTranscript:true)
            let original = e.progress.nextUpload(in: e.ledger.jobs)!
            let originalSession = "https://www.googleapis.com/upload/drive/v3/files?upload_id=eight-arrivals-original"
            try e.ledger.allocateFile(segmentID: original.segmentID, key: original.artifactKey, fileID: "eight-arrivals-original")
            try e.ledger.recordSession(segmentID: original.segmentID, key: original.artifactKey, url: originalSession)
            try e.pinStore.capture(ledger: e.ledger, selected: original)
            for n in 0..<8 {
                try e.addNewTranscript(n + 1)
                try e.persistRoundTrip()
                let row=try await e.run(dedup:true,localSeconds:3.1)
                let selected = e.chosen.last!, latest = e.ledger.jobs.max { $0.manifest.startedAt < $1.manifest.startedAt }!
                let retained = e.ledger.jobs.first { $0.id == original.segmentID }!.artifacts.first { $0.key == original.artifactKey }!
                try require(selected.segmentID == latest.id && retained.fileID == "eight-arrivals-original"
                    && retained.uploadURL == originalSession && row["outcome"] as? String == "cancelled",
                    "Cold restoration lost the original session or let its pin displace a newer source")
            }
            preparationEvidence["newSourcesBeforeOlderPinEightRounds"] = e.rounds
            try require(e.ledger.savedAudioCount==0 && e.rounds.allSatisfy{($0["verifiedReceiptCount"] as? Int)==0},
                "Cancelled preparation falsely created a cloud receipt")
            // P-60 deliberately supersedes the old policy that let a pin outrank
            // every newer source. Once the finite arrivals stop, exercise real
            // native registration, completion and strict provider readback until
            // the original prepared session gets its turn. No receipt is seeded.
            var registrations = 0, originalResumed = false, originalVerified = false
            for _ in 0..<100 where !originalVerified {
                try e.persistRoundTrip()
                let row = try await e.run(dedup: true, localSeconds: 3.1)
                guard row["nativeRegistered"] as? Int == 1 else { continue }
                registrations += 1
                let selected = e.chosen.last!
                if selected == original {
                    let saved = e.coordinator.records.first { $0.context.manifest.id == original.segmentID && $0.context.artifact.key == original.artifactKey }!
                    originalResumed = saved.context.artifact.fileID == "eight-arrivals-original"
                        && saved.context.artifact.uploadURL == originalSession
                        && e.native.requests.last?.url?.absoluteString == originalSession
                }
                await e.finishNative()
                let readback = try await e.run(dedup: true, delay: 1, readback: true)
                try require(readback["outcome"] as? String == "verified" && e.chosen.last == selected
                    && e.coordinator.records.isEmpty,
                    "Native completion failed exact remote confirmation or retired another item")
                originalVerified = e.ledger.jobs.first { $0.id == original.segmentID }!.artifacts.first { $0.key == original.artifactKey }!.verifiedAt != nil
            }
            try require(originalResumed && originalVerified && registrations == 33 && e.native.resumed.count == registrations
                && e.ledger.savedAudioCount == 8,
                "Finite newer work starved the original preparation or replaced its stable file/session before native resumption")
            preparationEvidence["olderSessionAfterFiniteArrivals"] = ["newSourceCount": 8,
                "nativeRegistrations": registrations, "originalSessionPreserved": originalResumed,
                "originalStrictlyVerified": originalVerified]
        }
        await test("dedup without pin remains a controlled zero-native negative under the same eight arrivals") {
            let e=try PreflightExperiment(root:root.appendingPathComponent(UUID().uuidString),withTranscript:true);e.usePin=false
            for n in 0..<8 {if n>0{try e.addNewTranscript(n)};_=try await e.run(dedup:true,localSeconds:3.1)}
            preparationEvidence["withoutPinEightRounds"] = e.rounds
            try require(e.native.resumed.isEmpty && Set(e.chosen.map(\.segmentID)).count==8,
                "No-pin control did not reproduce repeated preparation restarts")
        }
        await test("preflight pin atomically survives allocation crash gap without replacing an old identity") {
            let manifests=orderedManifests(1);var ledger=try priorityLedger(manifests);let progress=GoogleDriveSyncProgress()
            let selected=progress.nextUpload(in:ledger.jobs)!,dir=root.appendingPathComponent(UUID().uuidString)
            let store=try GoogleDrivePreflightPinStore(directory:dir);try store.capture(ledger:ledger,selected:selected)
            let initial=try Data(contentsOf:dir.appendingPathComponent("preflight-pin.json"))
            try ledger.allocateFile(segmentID:selected.segmentID,key:selected.artifactKey,fileID:"preflight-original")
            // Simulate termination after ledger commit but before pin update.
            let cold=try GoogleDrivePreflightPinStore(directory:dir);try cold.reconcile(in:ledger)
            try require(cold.pin?.artifact.fileID=="preflight-original" && cold.pin?.matches(selected.segmentID,selected.artifactKey)==true,
                "Cold allocation progress lost its exact authorized source")
            try ledger.recordSession(segmentID:selected.segmentID,key:selected.artifactKey,url:"https://www.googleapis.com/upload/drive/v3/files?upload_id=original-private-synthetic")
            try cold.reconcile(in:ledger)
            let pinned=cold.pin!
            try require(pinned.artifact.uploadURL==ledger.jobs[0].artifacts[0].uploadURL,"Original resumable URL was not retained")
            try ledger.recordSession(segmentID:selected.segmentID,key:selected.artifactKey,url:"https://www.googleapis.com/upload/drive/v3/files?upload_id=different-synthetic")
            try cold.reconcile(in:ledger)
            try require(cold.pin==nil,"A nonnil original session identity was silently replaced")
            try require(!initial.isEmpty,"Initial durable pin was absent")
            _=progress
        }
        for invalidation in ["pause","revoke","source","account","folder","scope","latest_manifest","received"] {
            await test("preflight pin withdraws on "+invalidation) {
                let manifests=orderedManifests(2);var ledger=try priorityLedger(manifests)
                let selected=GoogleDriveSyncProgress().nextUpload(in:ledger.jobs)!
                let dir=root.appendingPathComponent(UUID().uuidString),store=try GoogleDrivePreflightPinStore(directory:dir)
                try store.capture(ledger:ledger,selected:selected)
                var latest:[SegmentManifest]?=nil,received:Set<UUID>?=nil
                switch invalidation {
                case "pause":try ledger.setEnabled(false)
                case "revoke":ledger.revoke()
                case "source":
                    let old=manifests[0]
                    var raw=try JSONSerialization.jsonObject(with:TransportCodec.encode(ledger)) as! [String:Any]
                    var jobs=raw["jobs"] as! [[String:Any]];var manifest=jobs[0]["manifest"] as! [String:Any]
                    manifest["sessionID"]=UUID().uuidString.lowercased();jobs[0]["manifest"]=manifest
                    let changed=try TransportCodec.decode(SegmentManifest.self,from:json(manifest))
                    let bytes=try TransportCodec.encode(GoogleDriveLibraryLedger.exportManifest(changed))
                    var artifacts=jobs[0]["artifacts"] as! [[String:Any]]
                    let index=artifacts.firstIndex{($0["kind"] as? String)=="manifest"}!
                    artifacts[index]["sha256"]=GoogleDriveLibraryLedger.digest(bytes);artifacts[index]["byteCount"]=bytes.count
                    jobs[0]["artifacts"]=artifacts;raw["jobs"]=jobs
                    ledger=try TransportCodec.decode(GoogleDriveLibraryLedger.self,from:json(raw));_=old
                case "account","folder","scope":
                    var raw=try JSONSerialization.jsonObject(with:TransportCodec.encode(ledger)) as! [String:Any]
                    if invalidation=="account" {raw["accountID"]="other-owner"}
                    else if invalidation=="folder" {raw["folderID"]="other-folder"}
                    else {raw["authorizedAt"]=(raw["authorizedAt"] as! Double)+1}
                    ledger=try TransportCodec.decode(GoogleDriveLibraryLedger.self,from:json(raw))
                case "latest_manifest":latest=[manifests[1]]
                default:received=[]
                }
                try store.reconcileSources(in:ledger,manifests:latest,receivedIDs:received)
                try require(store.pin==nil && !FileManager.default.fileExists(atPath:dir.appendingPathComponent("preflight-pin.json").path),"Invalidated preparation remained pinned")
            }
        }
        for shape in ["malformed","oversized","symlink","hardlink"] {
            await test("preflight private control rejects "+shape) {
                let dir=root.appendingPathComponent(UUID().uuidString);try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
                let file=dir.appendingPathComponent("preflight-pin.json")
                if shape=="malformed" {try Data("{".utf8).write(to:file)}
                else if shape=="oversized" {try Data(repeating:0,count:GoogleDrivePreflightPinStore.maximumBytes+1).write(to:file)}
                else {
                    let target=dir.appendingPathComponent("other");try Data("{}".utf8).write(to:target)
                    if shape=="symlink" {try FileManager.default.createSymbolicLink(at:file,withDestinationURL:target)}
                    else {try FileManager.default.linkItem(at:target,to:file)}
                }
                do {_=try GoogleDrivePreflightPinStore(directory:dir);throw ProbeFailure(message:"Unsafe preflight control accepted")}
                catch is ProbeFailure {throw ProbeFailure(message:"Unsafe preflight control accepted")}
                catch {}
            }
        }
        await test("preflight file permissions and one-choice bound survive cold reload") {
            let manifests=orderedManifests(2),ledger=try priorityLedger(manifests),progress=GoogleDriveSyncProgress()
            let selected=progress.nextUpload(in:ledger.jobs)!,dir=root.appendingPathComponent(UUID().uuidString)
            let store=try GoogleDrivePreflightPinStore(directory:dir);try store.capture(ledger:ledger,selected:selected)
            let alternate=GoogleDriveSyncProgress.UploadChoice(segmentID:manifests[1].id,artifactKey:ledger.jobs[1].artifacts[0].key,isPrioritySmall:false)
            try store.capture(ledger:ledger,selected:alternate)
            let file=dir.appendingPathComponent("preflight-pin.json"),attributes=try FileManager.default.attributesOfItem(atPath:file.path)
            try require((attributes[.posixPermissions] as? NSNumber)?.intValue==0o600 && (attributes[.size] as? NSNumber)!.intValue<=GoogleDrivePreflightPinStore.maximumBytes,
                "Preparation state exceeded its private file limit")
            let cold=try GoogleDrivePreflightPinStore(directory:dir)
            try require(cold.pin?.matches(selected.segmentID,selected.artifactKey)==true,"A second item replaced the single prepared choice")
        }
        await test("preflight preference cannot spend overdue audio credit or bypass eligibility") {
            let manifests=orderedManifests(2);var ledger=try priorityLedger(manifests),progress=GoogleDriveSyncProgress()
            try addPriorityTranscript(manifests[1],to:&ledger)
            let original=progress.nextUpload(in:ledger.jobs)!
            for _ in 0..<3 {
                let selected=progress.nextUpload(in:ledger.jobs)!;_=try acceptSyntheticReceipt(selected,in:&ledger);try progress.didVerify(selected,in:ledger.jobs)
            }
            // New derived version offers a different lawful small choice.
            try addPriorityTranscript(manifests[0],to:&ledger)
            let preferred=GoogleDriveSyncProgress.UploadChoice(segmentID:manifests[0].id,artifactKey:ledger.jobs[0].artifacts.first{$0.kind == .manifest}!.key,isPrioritySmall:true)
            let selected=progress.nextUpload(in:ledger.jobs,preferred:preferred)!
            try require(ledger.jobs.first{$0.id==selected.segmentID}!.artifacts.first{$0.key==selected.artifactKey}!.kind == .audio,
                "Prepared small file bypassed the owed audio turn")
            let excluded=Set([preferred.segmentID.uuidString.lowercased()+"/"+preferred.artifactKey])
            try require(progress.nextUpload(in:ledger.jobs,excluding:excluded,preferred:preferred)?.artifactKey != preferred.artifactKey,
                "Prepared item bypassed exclusion")
            try require(progress.nextUpload(in:ledger.jobs,preferred:preferred,mayReserve:{_ in false})==nil,
                "Prepared item bypassed body capacity")
            _=original
        }
        await test("owed audio atomically replaces a small preflight without losing its remote identity") {
            let manifests=orderedManifests(2);var ledger=try priorityLedger(manifests),progress=GoogleDriveSyncProgress()
            try addPriorityTranscript(manifests[0],to:&ledger);try addPriorityTranscript(manifests[1],to:&ledger)
            let small=progress.nextUpload(in:ledger.jobs)!
            try ledger.allocateFile(segmentID:small.segmentID,key:small.artifactKey,fileID:"old-small-identity")
            let store=try GoogleDrivePreflightPinStore(directory:root.appendingPathComponent(UUID().uuidString))
            try store.capture(ledger:ledger,selected:small)
            let donor=manifests[1]
            for artifact in ledger.jobs.first(where:{$0.id==donor.id})!.artifacts.filter({$0.kind != .audio}) {
                let selected=GoogleDriveSyncProgress.UploadChoice(segmentID:donor.id,artifactKey:artifact.key,isPrioritySmall:true)
                _=try acceptSyntheticReceipt(selected,in:&ledger);try progress.didVerify(selected,in:ledger.jobs)
            }
            let audio=progress.nextUpload(in:ledger.jobs,preferred:store.pin?.choice)!
            try require(ledger.jobs.first{$0.id==audio.segmentID}!.artifacts.first{$0.key==audio.artifactKey}!.kind == .audio,
                "An outstanding small pin jumped ahead of owed audio")
            try store.capture(ledger:ledger,selected:audio)
            try require(store.pin?.artifact.kind == .audio && store.pin?.matches(audio.segmentID,audio.artifactKey)==true,
                "Small preparation blocked the legitimate audio continuation")
            try require(ledger.jobs.first{$0.id==small.segmentID}!.artifacts.first{$0.key==small.artifactKey}!.fileID=="old-small-identity",
                "Fairness transfer rewrote a prior remote identity")
        }
        await test("completed native remote readback precedes a different prepared pin") {
            let probe=try PipelineProbe(root:root,count:2);probe.installProtocol();var checks=0
            do{try await probe.fill{checks+=1;if checks==2{throw CancellationError()}}}catch is CancellationError{}
            probe.finish(probe.native.active[0]);await settleUploads()
            let plain=probe.progress.nextUpload(in:probe.ledger.jobs,excluding:Set([probe.coordinator.record!.context.manifest.id.uuidString.lowercased()+"/"+probe.coordinator.record!.context.artifact.key]))!
            let pin=try GoogleDrivePreflightPin(ledger:probe.ledger,selected:plain)
            let chosen=try probe.coordinator.nextUpload(in:probe.ledger,progress:probe.progress,allowPipelineFill:true,preflight:pin)!
            try require(probe.coordinator.completedRecord(for:chosen.segmentID,artifactKey:chosen.artifactKey) != nil,
                "Local preflight choice jumped ahead of strict native readback")
        }

        for shape in ["valid", "missing_receipt", "wrong_hash", "wrong_size", "wrong_id", "malformed", "symlink", "hardlink", "missing_manifest", "changed_manifest"] {
            await test("cold pin exact source metadata "+shape) {
                let manifest=orderedManifests(1)[0],ledger=try priorityLedger([manifest])
                let selected=GoogleDriveSyncProgress().nextUpload(in:ledger.jobs)!
                let pin=try GoogleDrivePreflightPin(ledger:ledger,selected:selected)
                let directory=root.appendingPathComponent(UUID().uuidString),repository=try RecordingRepository(root:directory)
                let name=manifest.id.uuidString.lowercased()+".json"
                let manifestFile=directory.appendingPathComponent("manifests").appendingPathComponent(name)
                let receiptFile=directory.appendingPathComponent("receipts").appendingPathComponent(name)
                var rawManifest=try JSONSerialization.jsonObject(with:TransportCodec.encode(manifest)) as! [String:Any]
                if shape=="changed_manifest" {rawManifest["sessionID"]=UUID().uuidString.lowercased()}
                if shape != "missing_manifest" {try json(rawManifest).write(to:manifestFile)}
                let receipt=SegmentReceipt(segmentID:shape=="wrong_id" ? UUID() : manifest.id,
                    sha256:shape=="wrong_hash" ? String(repeating:"f",count:64) : manifest.sha256,
                    byteCount:shape=="wrong_size" ? manifest.byteCount+1 : manifest.byteCount)
                let data=shape=="malformed" ? Data("{".utf8) : try TransportCodec.encode(receipt)
                if shape=="symlink" || shape=="hardlink" {
                    let target=directory.appendingPathComponent("metadata-target");try data.write(to:target)
                    if shape=="symlink" {try FileManager.default.createSymbolicLink(at:receiptFile,withDestinationURL:target)}
                    else {try FileManager.default.linkItem(at:target,to:receiptFile)}
                } else if shape != "missing_receipt" {try data.write(to:receiptFile)}
                var accepted=false
                do{accepted=try pin.sourceIsCurrent(in:repository)}catch{accepted=false}
                try require(accepted == (shape=="valid"),"Exact metadata gate accepted a withdrawn or changed source")
                try require(!FileManager.default.fileExists(atPath:directory.appendingPathComponent("audio").appendingPathComponent(manifest.fileName).path),
                    "Metadata-only fixture unexpectedly required audio")
            }
        }
        await test("pin same-source transcript notice withdraws while another source does not") {
            let manifests=orderedManifests(2),ledger=try priorityLedger(manifests)
            let selected=GoogleDriveSyncProgress().nextUpload(in:ledger.jobs)!,store=try GoogleDrivePreflightPinStore(directory:root.appendingPathComponent(UUID().uuidString))
            try store.capture(ledger:ledger,selected:selected)
            let other=manifests.first{$0.id != selected.segmentID}!
            let otherChanged = try store.transcriptDidChange(for:other.id)
            try require(!otherChanged,"Unrelated transcript erased exact preparation")
            let sameChanged = try store.transcriptDidChange(for:selected.segmentID)
            try require(sameChanged && store.pin==nil,"Same-source transcript failed to withdraw preparation")
        }
        await test("cold derived pin requires the current exact transcript version") {
            let manifest=orderedManifests(1)[0];var ledger=try priorityLedger([manifest]);try addPriorityTranscript(manifest,to:&ledger)
            let artifact=ledger.jobs[0].artifacts.first{$0.kind == .transcriptJSON}!
            let selected=GoogleDriveSyncProgress.UploadChoice(segmentID:manifest.id,artifactKey:artifact.key,isPrioritySmall:true)
            let pin=try GoogleDrivePreflightPin(ledger:ledger,selected:selected)
            let original=SegmentTranscript(segmentID:manifest.id,audioSHA256:manifest.sha256,locale:"zh-CN",engine:"synthetic-priority",createdAt:manifest.endedAt,text:"合成排序回归文字",spans:[])
            let updated=SegmentTranscript(segmentID:manifest.id,audioSHA256:manifest.sha256,locale:"zh-CN",engine:"synthetic-priority",createdAt:manifest.endedAt,text:"合成新版本",spans:[])
            let originalMatches = try pin.matchesCurrentTranscript(original,in:ledger)
            try require(originalMatches,"Current exact transcript was refused")
            try ledger.discoverTranscript(updated,for:manifest)
            let updatedMatches = try pin.matchesCurrentTranscript(updated,in:ledger)
            let missingMatches = try pin.matchesCurrentTranscript(nil,in:ledger)
            try require(!updatedMatches,"Append-only ledger disguised a newer local transcript as the pin version")
            try require(!missingMatches,"Missing transcript was treated as current")
        }
        for fault in ["account_401","wrong_account","shared_folder","wrong_owner","wrong_library","wrong_schema","expired_budget","changed_digest","revoked_before_handoff"] {
            await test("continued pin retains strict "+fault+" refusal") {
                let e=try PreflightExperiment(root:root.appendingPathComponent(UUID().uuidString),allocated:true,withTranscript:true)
                let selected=e.progress.nextUpload(in:e.ledger.jobs)!
                try e.pinStore.capture(ledger:e.ledger,selected:selected)
                if fault=="changed_digest" {try Data("tampered synthetic".utf8).write(to:e.files[selected.segmentID.uuidString+"/"+selected.artifactKey]!)}
                if fault=="revoked_before_handoff" {e.denyHandoff=true}
                let row=try await e.run(dedup:true,delay:fault=="expired_budget" ? 20 : 0.1,
                    fault:fault,localSeconds:3.1)
                try require((row["discoveryDeferred"] as? Bool)==true && e.native.resumed.isEmpty && e.ledger.savedAudioCount==0,
                    "Pinned continuation bypassed a live authorization/content/budget refusal")
                if ["shared_folder","wrong_owner","wrong_library","wrong_schema"].contains(fault) {
                    try require((row["outcome"] as? String) == "invalid_remote_folder"
                        && e.ledger.enabled && e.coordinator.itemRetries.isEmpty,
                        "Folder refusal lost its library-level classification or quarantined a healthy pinned item")
                }
            }
        }

        await test("P-60 13-second background lease confirms one of 703 sources before snapshot cancellation") {
            let probe = try PipelineProbe(root: root, count: 703); probe.installProtocol()
            try await probe.coordinator.runAvailable(ledger: { probe.ledger }, progress: { probe.progress }, check: {},
                maximumOperations: 1, perform: { try await probe.perform($0) })
            probe.finish(probe.native.active[0]); await settleUploads()
            let completed = probe.coordinator.records[0], selected = completed.context
            let original = probe.files[selected.manifest.id.uuidString.lowercased() + "/" + selected.artifact.key]!
            try FileManager.default.removeItem(at: original)
            let metadataRoot = root.appendingPathComponent(UUID().uuidString), repository = try RecordingRepository(root: metadataRoot)
            let name = selected.manifest.id.uuidString.lowercased() + ".json"
            try TransportCodec.encode(selected.manifest).write(to: metadataRoot.appendingPathComponent("manifests").appendingPathComponent(name))
            try TransportCodec.encode(SegmentReceipt(segmentID: selected.manifest.id, sha256: selected.manifest.sha256,
                byteCount: selected.manifest.byteCount)).write(to: metadataRoot.appendingPathComponent("receipts").appendingPathComponent(name))
            probe.progress = GoogleDriveSyncProgress()
            let legacy = BudgetGate(isForeground: false, systemGranted: true, maximumDeadline: 13)
            var legacyReachedRemote = false
            do {
                try await GoogleDriveProgressFirstRound.run(background: false, check: { try legacy.check() }, advance: {
                    legacyReachedRemote = true
                }, discover: { legacy.advance(13); try legacy.check() })
                throw ProbeFailure(message: "Discovery-first negative control exceeded the system deadline")
            } catch is CancellationError { }
            try require(!legacyReachedRemote && probe.ledger.savedAudioCount == 0,
                "Discovery-first negative control reached provider confirmation")
            let budget = BudgetGate(isForeground: false, systemGranted: true, maximumDeadline: 13)
            let world = PreflightRouteWorld(gate: budget, delay: 4, folderData: try folder(probe.ledger))
            world.remoteByID[selected.artifact.fileID!] = try TransportCodec.encode(GoogleDriveRemoteFile(
                id: selected.artifact.fileID!, size: String(selected.artifact.byteCount), sha256Checksum: selected.artifact.sha256,
                parents: [probe.ledger.folderID!], ownedByMe: true, shared: false, trashed: false,
                appProperties: ["rfaSchema":"1", "rfaLibraryID":probe.ledger.libraryID.uuidString.lowercased(),
                    "rfaSegmentID":selected.manifest.id.uuidString.lowercased(), "rfaKind":selected.artifact.kind.rawValue,
                    "rfaAudioSHA256":selected.manifest.sha256, "rfaContentSHA256":selected.artifact.sha256],
                permissions: [.init(id: "owner-123", type: "user", role: "owner")]))
            MockProtocol.install { try world.route($0) }
            var receiptTime: TimeInterval?, scans = 0
            do {
                try await GoogleDriveProgressFirstRound.run(background: true, check: { try budget.check() }, advance: {
                    try await probe.readBackOne(check: { try budget.check() }, timeout: budget.requestTimeout,
                        validateSource: { try $0.sourceIsCurrent(in: repository) })
                    receiptTime = budget.time
                }, discover: {
                    scans += 1; budget.advance(budget.deadline - budget.time); try budget.check()
                })
                throw ProbeFailure(message: "Cancelled snapshot unexpectedly finished")
            } catch is CancellationError { }
            try require(probe.ledger.jobs.count == 703 && probe.ledger.savedAudioCount == 1 && receiptTime == 12
                && budget.time == 13 && scans == 1 && probe.progress.needsSnapshot
                && world.trace == ["account", "folder", "file_lookup"]
                && !FileManager.default.fileExists(atPath: original.path),
                "A 13-second grant failed to strictly confirm a pending source before its snapshot was cancelled")
            completionEvidence["p60ShortLease"] = ["pendingSourcesBefore": 703, "budgetSeconds": 13,
                "firstRemoteVerifiedSecond": 12, "remoteVerifiedAudio": 1, "snapshotCancelled": true,
                "discoveryFirstNegativeControlReceipts": 0, "localAudioPresent": false]
        }
        await test("cold completed upload gets strict remote confirmation before an expensive discovery scan without local audio") {
            let probe = try PipelineProbe(root: root, count: 2); probe.installProtocol(); var checks = 0
            do { try await probe.fill { checks += 1; if checks == 2 { throw CancellationError() } } } catch is CancellationError { }
            probe.finish(probe.native.active[0]); await settleUploads()
            let completed = probe.coordinator.records[0], selected = completed.context
            let original = probe.files[selected.manifest.id.uuidString.lowercased()+"/"+selected.artifact.key]!
            try FileManager.default.removeItem(at: original)
            let metadataRoot = root.appendingPathComponent(UUID().uuidString), repository = try RecordingRepository(root: metadataRoot)
            let name = selected.manifest.id.uuidString.lowercased()+".json"
            try TransportCodec.encode(selected.manifest).write(to: metadataRoot.appendingPathComponent("manifests").appendingPathComponent(name))
            try TransportCodec.encode(SegmentReceipt(segmentID: selected.manifest.id, sha256: selected.manifest.sha256,
                byteCount: selected.manifest.byteCount)).write(to: metadataRoot.appendingPathComponent("receipts").appendingPathComponent(name))
            // A genuine cold derived state still owes a snapshot. Model the old
            // sequence's expensive scan against the same 19-second lease.
            probe.progress = GoogleDriveSyncProgress()
            let legacy = BudgetGate(isForeground: false); legacy.advance(20)
            var legacyReachedRemote = false
            do { try legacy.check(); legacyReachedRemote = true } catch is CancellationError { }
            try require(!legacyReachedRemote && probe.ledger.savedAudioCount == 0 && probe.coordinator.pendingReadbackCount == 1,
                "Legacy discovery-first negative control unexpectedly reached the receipt boundary")
            let budget = BudgetGate(isForeground: false)
            let world = PreflightRouteWorld(gate: budget, delay: 4, folderData: try folder(probe.ledger))
            let job = probe.ledger.jobs.first { $0.id == selected.manifest.id }!
            world.remoteByID[selected.artifact.fileID!] = try TransportCodec.encode(GoogleDriveRemoteFile(
                id: selected.artifact.fileID!, size: String(selected.artifact.byteCount), sha256Checksum: selected.artifact.sha256,
                parents: ["folder-123"], ownedByMe: true, shared: false, trashed: false,
                appProperties: ["rfaSchema":"1", "rfaLibraryID":probe.ledger.libraryID.uuidString.lowercased(),
                    "rfaSegmentID":job.id.uuidString.lowercased(), "rfaKind":selected.artifact.kind.rawValue,
                    "rfaAudioSHA256":job.manifest.sha256, "rfaContentSHA256":selected.artifact.sha256],
                permissions:[.init(id:"owner-123",type:"user",role:"owner")]))
            MockProtocol.install { try world.route($0) }
            let attempted = try await probe.readBackOne(check: { try budget.check() }, timeout: budget.requestTimeout,
                validateSource: { try $0.sourceIsCurrent(in: repository) })
            try require(attempted && probe.ledger.savedAudioCount == 1 && probe.coordinator.pendingReadbackCount == 0
                && budget.time == 12 && world.trace == ["account","folder","file_lookup"]
                && probe.progress.needsSnapshot && !FileManager.default.fileExists(atPath: original.path),
                "Completed metadata readback read audio, scanned the cold library, renewed its budget or skipped strict confirmation")
            // The same lease is spent after later discovery; the committed exact
            // receipt survives, while discovery remains honestly incomplete.
            budget.advance(20)
            do { try budget.check(); throw ProbeFailure(message:"Lease was renewed after readback") } catch is CancellationError { }
            completionEvidence["coldReadbackBeforeDiscovery"] = ["legacyDiscoverySeconds":20,"legacyRemoteReached":false,
                "priorityReadbackSeconds":12,"requests":3,"budgetSeconds":19,"verifiedAudio":1,
                "localAudioPresent":false,"sourceSnapshotStillPending":true]
        }
        await test("completed readback turn is durably fair across lease cancellation and cold restart") {
            let probe = try PipelineProbe(root: root, count: 3); probe.installProtocol(); try await probe.fill()
            let firstTasks = Array(probe.native.active.prefix(2))
            for task in firstTasks { probe.finish(task) }; await settleUploads()
            let first = probe.coordinator.records.first { $0.completed }!
            let second = probe.coordinator.records.first { $0.completed && $0.nonce != first.nonce }!
            let budget = BudgetGate(isForeground: false), world = PreflightRouteWorld(gate: budget, delay: 20, folderData: try folder(probe.ledger))
            MockProtocol.install { try world.route($0) }
            do { try await probe.readBackOne(check: { try budget.check() }, timeout: budget.requestTimeout)
                throw ProbeFailure(message:"Lease-consuming account timeout was accepted") } catch is CancellationError { }
            try require(probe.coordinator.pendingReadbackCount == 2 && probe.coordinator.itemRetries.isEmpty,
                "Lease cancellation lost a body or was misreported as a network retry")
            probe.coordinator = try GoogleDriveBackgroundUploads(directory:probe.directory,libraryID:probe.ledger.libraryID,
                changed:{},finishedEvents:{_ in},now:{[clock=probe.clock] in clock.now()},factory:probe.native.factory)
            await probe.coordinator.recover(in: probe.ledger)
            let next = try probe.coordinator.nextUpload(in: probe.ledger, progress: probe.progress)!
            try require(next.segmentID == second.context.manifest.id && next.artifactKey == second.context.artifact.key,
                "Cold restart replayed the slow completed head instead of a healthy peer")
            probe.installProtocol(); try await probe.readBackOne()
            try require(probe.coordinator.records.contains { $0.nonce == first.nonce }
                && !probe.coordinator.records.contains { $0.nonce == second.nonce }
                && probe.ledger.jobs.flatMap(\.artifacts).filter { $0.verifiedAt != nil }.count == 1,
                "Fair continuation retired the wrong body or credited an unverified slow attempt")
            completionEvidence["coldCancelledReadback"] = ["pendingBefore":2,"pendingAfterPeer":1,
                "newStrictReceipts":1,"cancelledLeaseNetworkFailures":0,"durableFairness":true]
        }
        await test("ordinary pipeline completed head cannot starve a peer across a cancelled lease and cold restart") {
            let probe = try PipelineProbe(root:root,count:4); probe.installProtocol()
            _ = try await probe.stageAudioTasks()
            for task in Array(probe.native.active.prefix(2)) { probe.finish(task) }; await settleUploads()
            let head = probe.coordinator.records.first { $0.completed }!
            let peer = probe.coordinator.records.first { $0.completed && $0.nonce != head.nonce }!
            let budget = BudgetGate(isForeground:false), world = PreflightRouteWorld(gate:budget,delay:20,folderData:try folder(probe.ledger))
            MockProtocol.install { try world.route($0) }
            do {
                try await probe.coordinator.runAvailable(ledger:{probe.ledger},progress:{probe.progress},check:{try budget.check()}) { _ in
                    let client = GoogleDriveClient(http:http(),oauth:Tokens(),accountID:"owner-123",
                        check:{try budget.check()},requestTimeout:budget.requestTimeout)
                    try await client.validateAccount()
                }
                throw ProbeFailure(message:"Ordinary finite lease unexpectedly survived the held account timeout")
            } catch is CancellationError { }
            probe.coordinator = try GoogleDriveBackgroundUploads(directory:probe.directory,libraryID:probe.ledger.libraryID,
                changed:{},finishedEvents:{_ in},factory:probe.native.factory)
            await probe.coordinator.recover(in:probe.ledger)
            let selected = try probe.coordinator.nextUpload(in:probe.ledger,progress:probe.progress)!
            try require(selected.segmentID == peer.context.manifest.id && selected.artifactKey == peer.context.artifact.key
                && probe.coordinator.records.contains{$0.nonce == head.nonce} && probe.coordinator.itemRetries.isEmpty,
                "Ordinary pipeline cancellation pinned the same completed head across a cold restart")
            try requireAudioReceipts(probe.ledger, [])
            probe.installProtocol(); try await probe.readBackOne()
            try requireAudioReceipts(probe.ledger, [peer.context])
            try require(probe.coordinator.records.contains { $0.nonce == head.nonce }
                && !probe.coordinator.records.contains { $0.nonce == peer.nonce },
                "Peer receipt retired the cancelled head or another source")
            try await probe.readBackOne()
            try requireAudioReceipts(probe.ledger, [peer.context, head.context])
        }
        for nativeState in ["live", "missing", "suspended"] {
            await test("REC-32 native \(nativeState) cold recovery reaches exact audio receipts") {
                let probe = try PipelineProbe(root: root, count: 3); probe.installProtocol()
                let contexts = try await probe.stageAudioTasks(), original = probe.coordinator.records
                let tasks = probe.native.active
                if nativeState == "missing" { probe.native.active = [] }
                if nativeState == "suspended" {
                    probe.native.active = tasks.map { .init(id: $0.id, nonce: $0.nonce, url: $0.url,
                        method: $0.method, contentRange: $0.contentRange, isSuspended: true) }
                }
                probe.coordinator = try GoogleDriveBackgroundUploads(directory: probe.directory, libraryID: probe.ledger.libraryID,
                    changed: {}, finishedEvents: { _ in }, now: { [clock = probe.clock] in clock.now() }, factory: probe.native.factory)
                await probe.coordinator.recover(in: probe.ledger); await settleUploads()
                try require(probe.native.requests.count == 3 && probe.native.resumed.count == 3
                    && probe.coordinator.records.map(\.nonce) == original.map(\.nonce)
                    && probe.coordinator.records.map(\.context) == original.map(\.context),
                    "Cold native recovery replaced a durable session/source or submitted duplicate bytes")
                try requireAudioReceipts(probe.ledger, [])
                if nativeState == "live" {
                    try require(probe.native.cancelled.isEmpty && probe.coordinator.nativeActiveCount == 3,
                        "Exact running native tasks were cancelled during cold restore")
                    for task in tasks.reversed() { probe.finish(task) }
                    await settleUploads()
                } else {
                    try require(probe.coordinator.pendingReadbackCount == 3
                        && (nativeState != "suspended" || probe.native.cancelled == Set(tasks.map(\.id))),
                        "Missing/suspended native tasks were not routed to metadata-only reconciliation")
                    // Model remotely stored bytes independently of native status.
                    probe.remotelyCompleted = Set(contexts.map { $0.artifact.fileID! })
                }
                try requireAudioReceipts(probe.ledger, [])
                for index in contexts.indices {
                    try await probe.readBackOne()
                    try requireAudioReceipts(probe.ledger, Array(contexts.prefix(index + 1)))
                }
                try require(probe.coordinator.records.isEmpty && probe.native.requests.count == 3,
                    "Strict recovery left stale bodies or restarted an already stored audio")
            }
        }
        for path in ["ordinary", "priority"] {
            for range in ["bytes=1-4", "bytes=0-8"] {
                await test("REC-32 invalid session offset \(path) \(range) defers only its audio and preserves peer progress") {
                    let probe = try PipelineProbe(root: root, count: 4); probe.installProtocol()
                    let contexts = try await probe.stageAudioTasks(), tasks = probe.native.active
                    probe.finish(tasks[0], code: 500); probe.finish(tasks[1]); await settleUploads()
                    let head = contexts[0], peer = contexts[1]
                    MockProtocol.install { request in
                        if request.url!.path == "/drive/v3/about" { return try about() }
                        if request.url!.lastPathComponent == "folder-123" { return .init(code: 200, data: try folder(probe.ledger)) }
                        if request.httpMethod == "GET" {
                            return request.url!.lastPathComponent == peer.artifact.fileID
                                ? .init(code: 200, data: try audioRemote(peer)) : .init(code: 404)
                        }
                        try require(request.httpMethod == "PUT" && request.url!.absoluteString == head.artifact.uploadURL
                            && request.value(forHTTPHeaderField: "Content-Range") == "bytes */8",
                            "Invalid offset fixture sent body bytes or queried a different session")
                        return .init(code: 308, headers: ["Range": range])
                    }
                    if path == "ordinary" {
                        _ = try await probe.coordinator.runAvailable(ledger: { probe.ledger }, progress: { probe.progress },
                            check: {}, maximumOperations: 2, perform: { try await probe.perform($0) })
                    } else {
                        try await probe.readBackOne(); try await probe.readBackOne()
                    }
                    try requireAudioReceipts(probe.ledger, [peer])
                    let retry = probe.coordinator.itemRetries.first
                    try require(probe.coordinator.itemRetries.count == 1 && retry?.segmentID == head.manifest.id
                        && retry?.artifactKey == head.artifact.key && retry?.terminal != true
                        && retry.map { $0.retryAfter > probe.clock.now() } == true
                        && retry?.attemptNonce == probe.coordinator.completedRecord(for: head.manifest.id, artifactKey: head.artifact.key)?.nonce
                        && probe.coordinator.completedRecord(for: head.manifest.id, artifactKey: head.artifact.key)?.context == head
                        && probe.native.requests.count == 4 && probe.ledger.failureCount == 0 && probe.ledger.retryAfter == nil,
                        "Invalid session offset escaped item backoff, lost identity or credited another audio")
                    probe.coordinator = try GoogleDriveBackgroundUploads(directory: probe.directory, libraryID: probe.ledger.libraryID,
                        changed: {}, finishedEvents: { _ in }, now: { [clock = probe.clock] in clock.now() }, factory: probe.native.factory)
                    await probe.coordinator.recover(in: probe.ledger)
                    // TransportCodec persists dates at millisecond precision.
                    let restoredRetries = try TransportCodec.encode(probe.coordinator.itemRetries)
                    let originalRetries = try TransportCodec.encode([retry!])
                    try require(restoredRetries == originalRetries, "Cold restore lost offset-failure backoff")
                    let beforeDue = try probe.coordinator.nextUpload(in: probe.ledger, progress: probe.progress, allowPipelineFill: true)
                    try require(beforeDue?.segmentID != head.manifest.id || beforeDue?.artifactKey != head.artifact.key,
                        "Cold queue selected the failed audio before its durable retry deadline")
                    probe.clock.advance(11)
                    MockProtocol.install { request in
                        if request.url!.path == "/drive/v3/about" { return try about() }
                        if request.httpMethod == "GET" { return .init(code: 404) }
                        try require(request.httpMethod == "PUT" && request.url!.absoluteString == head.artifact.uploadURL
                            && request.value(forHTTPHeaderField: "Content-Range") == "bytes */8",
                            "Recovery changed the original resumable session")
                        return .init(code: 308, headers: ["Range": "bytes=0-3"])
                    }
                    _ = try await probe.coordinator.runAvailable(ledger: { probe.ledger }, progress: { probe.progress },
                        check: {}, maximumOperations: 1, perform: { try await probe.perform($0) })
                    let resumed = probe.coordinator.records.first { $0.context.manifest.id == head.manifest.id }!
                    try require(resumed.context == head && resumed.offset == 4 && probe.native.requests.count == 5
                        && probe.native.requests.last?.value(forHTTPHeaderField: "Content-Range") == "bytes 4-7/8"
                        && probe.native.bodies.last == Data(repeating: 1, count: 4),
                        "Valid requery did not hand off exactly the server-confirmed suffix")
                    try requireAudioReceipts(probe.ledger, [peer])
                    probe.finish(probe.native.active.first { $0.id == resumed.taskID }!); await settleUploads()
                    probe.installProtocol(); try await probe.readBackOne()
                    try requireAudioReceipts(probe.ledger, [head, peer])
                    try require(probe.coordinator.itemRetries.isEmpty && probe.coordinator.nativeActiveCount == 2,
                        "Recovered offset did not clear only its own retry and preserve other active sources")
                }
            }
        }
        for deliveryTimeout in [false, true] {
            await test("REC-32 plus REC-36 invalid offset then delivery timeout=\(deliveryTimeout) retains item retry and admits local sources") {
                let probe = try PipelineProbe(root: root, count: 4); probe.installProtocol()
                let contexts = try await probe.stageAudioTasks(), tasks = probe.native.active
                probe.finish(tasks[0], code: 500); probe.finish(tasks[1]); await settleUploads()
                let head = contexts[0], peer = contexts[1], original = probe.ledger
                let repository = try RecordingRepository(root: root.appendingPathComponent(UUID().uuidString),
                    recoverTransactionsOnInitialization: false)
                let newlyReceived = orderedManifests(1)[0]
                for manifest in contexts.map(\.manifest) + [newlyReceived] {
                    let name = manifest.id.uuidString.lowercased() + ".json"
                    try TransportCodec.encode(manifest).write(to: repository.root.appendingPathComponent("manifests").appendingPathComponent(name))
                    try TransportCodec.encode(SegmentReceipt(segmentID: manifest.id, sha256: manifest.sha256,
                        byteCount: manifest.byteCount, receivedAt: manifest.endedAt)).write(to:
                            repository.root.appendingPathComponent("receipts").appendingPathComponent(name))
                }
                probe.progress.requestDiscovery()
                let source = GoogleDriveSourceSnapshotProbe(repository: repository, directory: probe.directory, ledger: probe.ledger)
                source.progress = probe.progress
                let round = GoogleDriveDiscoveryFailureProbe(source: source)
                MockProtocol.install { request in
                    if request.url!.path == "/drive/v3/about" { return try about() }
                    if request.url!.lastPathComponent == "folder-123" { return .init(code: 200, data: try folder(probe.ledger)) }
                    if request.httpMethod == "GET" {
                        return request.url!.lastPathComponent == peer.artifact.fileID
                            ? .init(code: 200, data: try audioRemote(peer)) : .init(code: 404)
                    }
                    try require(request.httpMethod == "PUT" && request.url!.absoluteString == head.artifact.uploadURL
                        && request.value(forHTTPHeaderField: "Content-Range") == "bytes */8",
                        "Combined round sent bytes while checking the failed session")
                    return .init(code: 308, headers: ["Range": "bytes=1-4"])
                }
                // Connect the actual readback/client and finite delivery loop to
                // the extracted production advance boundary and source cursor.
                round.readbackOperation = {
                    try await probe.readBackOne(check: { try round.checkWork(0) })
                    source.ledger = probe.ledger; source.progress = probe.progress
                }
                round.deliveryOperation = {
                    if deliveryTimeout {
                        MockProtocol.install { request in
                            try require(request.url!.path == "/drive/v3/about",
                                "Account failure reached an artifact or native handoff")
                            throw URLError(.timedOut)
                        }
                    }
                    let client = GoogleDriveClient(http: http(), oauth: Tokens(), accountID: "owner-123",
                        check: { try round.checkWork(0) }, phase: { round.setPhase($0) })
                    try await client.validateAccount()
                    _ = try await probe.coordinator.runAvailable(ledger: { probe.ledger }, progress: { probe.progress },
                        check: { try round.checkWork(0) }, maximumOperations: 1, perform: { try await probe.perform($0) })
                    source.ledger = probe.ledger; source.progress = probe.progress
                }
                do {
                    try await GoogleDriveProgressFirstRound.run(background: true,
                        check: { try round.checkWork(0) },
                        advance: { try await round.advanceKnownItems(token: 0, lease: round.lease, discoverAfterFailure: true) },
                        discover: { try await round.discoverLocal(token: 0) })
                    try require(!deliveryTimeout, "Combined round swallowed the live account timeout")
                } catch let failure as URLError {
                    try require(deliveryTimeout && failure.code == .timedOut && round.currentPhase == .accountGet,
                        "Combined round replaced the original network error or diagnostic boundary")
                }
                probe.ledger = source.ledger; probe.progress = source.progress
                try requireAudioReceipts(probe.ledger, deliveryTimeout ? [] : [peer])
                let retries = try TransportCodec.encode(probe.coordinator.itemRetries)
                try require(round.calls == ["readback", "delivery", "discovery"]
                    && probe.ledger.jobs.count == 5 && probe.ledger.jobs.contains { $0.id == newlyReceived.id }
                    && !source.progress.needsSnapshot && source.progress.needsDiscovery
                    && probe.coordinator.itemRetries.count == 1
                    && probe.coordinator.itemRetries[0].segmentID == head.manifest.id
                    && probe.coordinator.itemRetries[0].artifactKey == head.artifact.key
                    && probe.coordinator.completedRecord(for: head.manifest.id, artifactKey: head.artifact.key)?.context == head
                    && probe.ledger.jobs.first { $0.id == head.manifest.id } == original.jobs.first { $0.id == head.manifest.id }
                    && probe.ledger.failureCount == original.failureCount && probe.ledger.retryAfter == original.retryAfter
                    && probe.native.requests.count == 4,
                    "Combined round starved/repeated discovery, widened item retry, changed the session or invented progress")
                let durable = try TransportCodec.decode(GoogleDriveLibraryLedger.self,
                    from: Data(contentsOf: probe.directory.appendingPathComponent("ledger.json")))
                // Receipts carry wall-clock dates; persistence uses milliseconds.
                let durableBytes = try TransportCodec.encode(durable)
                let expectedBytes = try TransportCodec.encode(probe.ledger)
                try require(durableBytes == expectedBytes, "Combined local source admission was not durable")
                probe.coordinator = try GoogleDriveBackgroundUploads(directory: probe.directory, libraryID: probe.ledger.libraryID,
                    changed: {}, finishedEvents: { _ in }, now: { [clock = probe.clock] in clock.now() }, factory: probe.native.factory)
                await probe.coordinator.recover(in: probe.ledger)
                let restoredRetries = try TransportCodec.encode(probe.coordinator.itemRetries)
                try require(restoredRetries == retries, "Local discovery or cold reconstruction replaced offset backoff")
                if deliveryTimeout {
                    probe.installProtocol(); try await probe.readBackOne()
                    try requireAudioReceipts(probe.ledger, [peer])
                }
                try require(probe.coordinator.itemRetries.count == 1 && probe.native.requests.count == 4
                    && probe.coordinator.nativeActiveCount == 2,
                    "Peer recovery consumed the deferred head or duplicated active audio")
                let media = try FileManager.default.contentsOfDirectory(atPath: repository.root.appendingPathComponent("segments").path)
                try require(media.isEmpty, "Metadata discovery created source audio")
            }
        }
        await test("REC-32 invalid account response stays outside resumable item retry") {
            let probe = try PipelineProbe(root: root, count: 2); probe.installProtocol()
            let contexts = try await probe.stageAudioTasks()
            for task in Array(probe.native.active) { probe.finish(task) }; await settleUploads()
            MockProtocol.install { _ in try about("") }
            do { try await probe.readBackOne(); throw ProbeFailure(message: "Invalid account was treated as an item failure") }
            catch GoogleDriveError.invalidResponse { }
            try requireAudioReceipts(probe.ledger, [])
            try require(probe.coordinator.itemRetries.isEmpty && probe.coordinator.pendingReadbackCount == 2,
                "Account validation poisoned or retired an individual audio")
            probe.installProtocol(); try await probe.readBackOne()
            try requireAudioReceipts(probe.ledger, [contexts[1]])
        }
        for fault in ["503", "timeout"] {
            await test("REC-32 failing audio head \(fault) yields strict peer receipt and recovers itself") {
                let probe = try PipelineProbe(root: root, count: 4); probe.installProtocol()
                let contexts = try await probe.stageAudioTasks(), tasks = probe.native.active
                probe.finish(tasks[0], code: 500); probe.finish(tasks[1]); await settleUploads()
                let head = contexts[0], peer = contexts[1], headID = head.artifact.fileID!
                MockProtocol.install { request in
                    if request.url!.path == "/drive/v3/about" { return try about() }
                    if request.url!.lastPathComponent == headID {
                        if fault == "timeout" { throw URLError(.timedOut) }
                        return .init(code: 503)
                    }
                    try require(request.httpMethod == "GET" && request.url!.lastPathComponent == peer.artifact.fileID,
                        "Item failure caused a new upload or unrelated request")
                    return .init(code: 200, data: try audioRemote(peer))
                }
                _ = try await probe.coordinator.runAvailable(ledger: { probe.ledger }, progress: { probe.progress },
                    check: {}, maximumOperations: 2, perform: { try await probe.perform($0) })
                try requireAudioReceipts(probe.ledger, [peer])
                try require(probe.coordinator.itemRetries.count == 1
                    && probe.coordinator.itemRetries[0].segmentID == head.manifest.id
                    && probe.coordinator.itemRetries[0].artifactKey == head.artifact.key
                    && probe.coordinator.completedRecord(for: head.manifest.id, artifactKey: head.artifact.key) != nil
                    && probe.ledger.failureCount == 0 && probe.ledger.retryAfter == nil,
                    "Failed head blocked the grant, lost its body or credited the peer as its recovery")
                let due = probe.coordinator.earliestRetryAt(in: probe.ledger)!
                probe.coordinator = try GoogleDriveBackgroundUploads(directory: probe.directory, libraryID: probe.ledger.libraryID,
                    changed: {}, finishedEvents: { _ in }, now: { [clock = probe.clock] in clock.now() }, factory: probe.native.factory)
                await probe.coordinator.recover(in: probe.ledger)
                try require(abs(probe.coordinator.earliestRetryAt(in: probe.ledger)!.timeIntervalSince(due)) < 0.001,
                    "Cold retry reset the failed audio's durable deadline")
                probe.clock.advance(11); probe.remotelyCompleted.insert(headID); probe.installProtocol()
                try await probe.readBackOne()
                try requireAudioReceipts(probe.ledger, [head, peer])
                try require(probe.coordinator.itemRetries.isEmpty && probe.native.requests.count == 4
                    && probe.coordinator.nativeActiveCount == 2,
                    "Exact original recovery duplicated native tasks or consumed unrelated active audio")
            }
        }
        await test("REC-32 concurrent native completions preserve cancelled readback order and exact receipts") {
            let probe = try PipelineProbe(root: root, count: 3); probe.installProtocol()
            let contexts = try await probe.stageAudioTasks(), tasks = probe.native.active
            probe.finish(tasks[0]); await settleUploads()
            var held: CheckedContinuation<Void, Never>?
            let work = Task { @MainActor in
                try await probe.coordinator.runCompletedReadback(ledger: { probe.ledger }, progress: { probe.progress },
                    check: { try Task.checkCancellation() }) { selected in
                    try require(selected.segmentID == contexts[0].manifest.id, "Held turn selected the wrong source")
                    await withCheckedContinuation { held = $0 }
                    try Task.checkCancellation()
                    throw ProbeFailure(message: "Cancelled readback continued to receipt commit")
                }
            }
            defer { held?.resume(); work.cancel() }
            try await awaitPhaseHold { held != nil }
            let rotated = probe.coordinator.records.map(\.nonce)
            // These callbacks race the suspended readback, arrive out of order,
            // and include a duplicate for the still-held source.
            probe.finish(tasks[2]); probe.finish(tasks[1]); probe.finish(tasks[0])
            await settleUploads()
            let disk = try TransportCodec.decode(PipelineState.self,
                from: Data(contentsOf: probe.directory.appendingPathComponent("pipeline.json")))
            try require(probe.coordinator.records.map(\.nonce) == rotated && disk.records.map(\.nonce) == rotated
                && probe.coordinator.pendingReadbackCount == 3 && !probe.coordinator.isUnavailable,
                "Concurrent/duplicate completion reordered the already rotated durable queue")
            try requireAudioReceipts(probe.ledger, [])
            work.cancel(); held!.resume(); held = nil
            do { _ = try await work.value; throw ProbeFailure(message: "Held cancellation completed successfully") }
            catch is CancellationError { }
            probe.coordinator = try GoogleDriveBackgroundUploads(directory: probe.directory, libraryID: probe.ledger.libraryID,
                changed: {}, finishedEvents: { _ in }, factory: probe.native.factory)
            await probe.coordinator.recover(in: probe.ledger)
            var received: [GoogleDriveUploadContext] = []
            for index in [1, 2, 0] {
                let selected = try probe.coordinator.nextUpload(in: probe.ledger, progress: probe.progress)
                try require(selected?.segmentID == contexts[index].manifest.id,
                    "Cold restore lost the held turn's stable fairness order")
                try await probe.readBackOne(); received.append(contexts[index])
                try requireAudioReceipts(probe.ledger, received)
            }
            try require(probe.coordinator.records.isEmpty && probe.coordinator.itemRetries.isEmpty
                && probe.native.requests.count == 3,
                "Concurrency lost a body, invented network backoff or duplicated upload work")
        }
        await test("readback priority is one item per round and leaves real native refill possible") {
            let probe = try PipelineProbe(root: root, count: 6); probe.installProtocol(); try await probe.fill()
            for task in Array(probe.native.active.prefix(3)) { probe.finish(task) }; await settleUploads()
            try await probe.readBackOne()
            try require(probe.coordinator.pendingReadbackCount == 2 && probe.coordinator.nativeActiveCount == 5
                && probe.ledger.jobs.flatMap(\.artifacts).filter { $0.verifiedAt != nil }.count == 1,
                "Priority path drained an unbounded batch or treated active tasks as receipts")
            try await probe.fill()
            try require(probe.coordinator.nativeActiveCount == 8 && probe.coordinator.pendingReadbackCount == 0,
                "Priority readback prevented normal native refill in the remainder of the round")
        }
        await test("incomplete completion uses existing durable item backoff without creating a session or sending bytes") {
            let probe = try PipelineProbe(root: root, count: 1); probe.installProtocol(); try await probe.fill()
            for task in Array(probe.native.active) { probe.finish(task, code: 500) }; await settleUploads()
            var methods: [String] = []
            MockProtocol.install { request in
                methods.append(request.httpMethod ?? "GET")
                if request.url!.path == "/drive/v3/about" { return try about() }
                if request.url!.path == "/drive/v3/files/folder-123" { return .init(code:200,data:try folder(probe.ledger)) }
                if request.httpMethod == "GET" { return .init(code:404) }
                try require(request.httpMethod == "PUT" && request.httpBody == nil
                    && request.value(forHTTPHeaderField:"Content-Range")?.hasPrefix("bytes */") == true,
                    "Completed readback created a new session or transmitted file content")
                return .init(code:308)
            }
            let originalCount = probe.coordinator.records.count
            try await probe.readBackOne()
            try require(probe.coordinator.itemRetries.count == 1 && probe.coordinator.records.count == originalCount-1
                && probe.ledger.savedAudioCount == 0 && probe.ledger.failureCount == 0
                && methods == ["GET","GET","GET","PUT"],
                "Incomplete completion fabricated a receipt, lost durable retry or repeated a byte upload")
            let due = probe.coordinator.earliestRetryAt(in: probe.ledger)!
            probe.coordinator = try GoogleDriveBackgroundUploads(directory:probe.directory,libraryID:probe.ledger.libraryID,
                changed:{},finishedEvents:{_ in},now:{[clock=probe.clock] in clock.now()},factory:probe.native.factory)
            try require(probe.coordinator.itemRetries.count == 1
                && abs(probe.coordinator.earliestRetryAt(in: probe.ledger)!.timeIntervalSince(due)) < 0.001 && due > probe.clock.now(),
                "Cold launch forgot the completed attempt's existing bounded retry deadline")
        }
        for status in [404, 410] {
            await test("expired completed session \(status) durably clears URL keeps ID and yields to healthy work") {
                let probe = try PipelineProbe(root:root,count:2); probe.installProtocol(); try await probe.fill()
                let task = probe.native.active[0]; probe.finish(task,code:500); await settleUploads()
                let completed = probe.coordinator.records.first { $0.completed }!
                let oldID = completed.context.artifact.fileID
                MockProtocol.install { request in
                    if request.url!.path == "/drive/v3/about" { return try about() }
                    if request.url!.path == "/drive/v3/files/folder-123" { return .init(code:200,data:try folder(probe.ledger)) }
                    if request.httpMethod == "GET" { return .init(code:404) }
                    try require(request.httpMethod == "PUT" && request.httpBody == nil && request.httpBodyStream == nil
                        && request.value(forHTTPHeaderField:"Content-Range")?.hasPrefix("bytes */") == true,
                        "Expired readback sent content or created another upload session")
                    return .init(code:status)
                }
                try await probe.readBackOne()
                let current = probe.ledger.jobs.first { $0.id == completed.context.manifest.id }!.artifacts.first { $0.key == completed.context.artifact.key }!
                try require(current.fileID == oldID && current.uploadURL == nil && current.verifiedAt == nil
                    && probe.coordinator.itemRetries.contains { $0.segmentID == completed.context.manifest.id
                        && $0.artifactKey == current.key && $0.terminal != true && $0.retryAfter > probe.clock.now() }
                    && !probe.coordinator.records.contains { $0.nonce == completed.nonce },
                    "Expired session retained priority, lost stable ID, or fabricated a receipt instead of durable backoff")
                let healthy = probe.coordinator.records.first { !$0.completed }!
                probe.finish(probe.native.active.first { healthy.matches($0) }!); await settleUploads()
                probe.installProtocol(); try await probe.readBackOne()
                try require(probe.ledger.jobs.flatMap(\.artifacts).filter { $0.verifiedAt != nil }.count == 1,
                    "An expired session blocked a different healthy completion")
            }
        }
        for status in [200,201,308,404,410] {
            await test("completed session \(status) is not independently a remote receipt or new upload") {
                let (ledger, manifest, artifact, _, _) = try backgroundFixture(root: root)
                var requests = 0, fileGets = 0
                MockProtocol.install { request in
                    requests += 1
                    if request.url!.path == "/drive/v3/about" { return try about() }
                    if request.httpMethod == "GET" { fileGets += 1; return .init(code:404) }
                    try require(request.httpMethod == "PUT" && request.httpBody == nil,
                        "Readback emitted session creation/content")
                    return .init(code:status)
                }
                let client = GoogleDriveClient(http:http(),oauth:Tokens(),accountID:"owner-123",check:{})
                if status == 200 || status == 201 {
                    do { _ = try await client.readBackCompletedUpload(artifact:artifact, manifest:manifest)
                        throw ProbeFailure(message:"Session hint without exact file metadata was accepted") }
                    catch GoogleDriveError.invalidResponse { }
                    try require(fileGets == 2,"Completed session did not require exact file metadata readback")
                } else {
                    let value = try await client.readBackCompletedUpload(artifact:artifact, manifest:manifest)
                    let expected: GoogleDriveCompletedReadBack = (status == 404 || status == 410) ? .sessionExpired : .pending
                    try require(value == expected && fileGets == 1,"Incomplete/expired session became a verified file")
                }
                try require(requests <= 4 && ledger.savedAudioCount == 0 && manifest.id == ledger.jobs[0].id,
                    "Metadata-only check exceeded its finite request chain or mutated a receipt")
            }
        }
        for fault in ["sha256Checksum","size","parents","shared","rfaSegmentID","rfaContentSHA256","permissions"] {
            await test("completed metadata-only readback preserves strict \(fault) refusal") {
                let probe = try PipelineProbe(root:root,count:1); probe.installProtocol(); try await probe.fill()
                let task = probe.native.active[0]; probe.finish(task); await settleUploads()
                let saved = probe.coordinator.records.first { $0.completed }!, context = saved.context
                var raw = try JSONSerialization.jsonObject(with: TransportCodec.encode(GoogleDriveRemoteFile(
                    id:context.artifact.fileID!, size:String(context.artifact.byteCount), sha256Checksum:context.artifact.sha256,
                    parents:[context.folderID], ownedByMe:true, shared:false, trashed:false,
                    appProperties:["rfaSchema":"1","rfaLibraryID":context.libraryID.uuidString.lowercased(),
                        "rfaSegmentID":context.manifest.id.uuidString.lowercased(),"rfaKind":context.artifact.kind.rawValue,
                        "rfaAudioSHA256":context.manifest.sha256,"rfaContentSHA256":context.artifact.sha256],
                    permissions:[.init(id:"owner-123",type:"user",role:"owner")]))) as! [String:Any]
                switch fault {
                case "sha256Checksum": raw[fault] = String(repeating:"f",count:64)
                case "size": raw[fault] = "99999"
                case "parents": raw[fault] = ["foreign-folder"]
                case "shared": raw[fault] = true
                case "permissions": raw[fault] = [["id":"foreign-owner","type":"user","role":"owner"]]
                default: var props = raw["appProperties"] as! [String:String]; props[fault] = "foreign-value"; raw["appProperties"] = props
                }
                let invalid = try json(raw)
                MockProtocol.install { request in
                    if request.url!.path == "/drive/v3/about" { return try about() }
                    if request.url!.path == "/drive/v3/files/folder-123" { return .init(code:200,data:try folder(probe.ledger)) }
                    return .init(code:200,data:invalid)
                }
                try await probe.readBackOne()
                try require(probe.ledger.savedAudioCount == 0 && probe.ledger.enabled
                    && probe.coordinator.itemRetries.contains { $0.segmentID == context.manifest.id
                        && $0.artifactKey == context.artifact.key && $0.terminal == true && $0.failureReason == .remoteConflict }
                    && !probe.coordinator.records.contains { $0.nonce == saved.nonce },
                    "Invalid metadata was not durably isolated before retiring its completed body, or invented receipt credit")
            }
        }
        for mutation in ["receipt_withdrawn", "manifest_changed", "transcript_changed"] {
            await test("completed readback refuses an in-flight \(mutation) before receipt commit") {
                let probe = try PipelineProbe(root:root,count:1,transcripts:true)
                let job = probe.ledger.jobs[0]
                let artifact = job.artifacts.first { $0.kind == (mutation == "transcript_changed" ? .transcriptJSON : .audio) }!
                let context = try GoogleDriveUploadContext(ledger:probe.ledger,manifest:job.manifest,artifact:artifact)
                try await probe.coordinator.start(request:backgroundRequest(context),
                    file:probe.files[job.id.uuidString.lowercased()+"/"+artifact.key]!,offset:0,context:context,
                    isAuthorized:{context.isAuthorized(in:probe.ledger)},check:{})
                probe.finish(probe.native.active[0]); await settleUploads()
                let nonce = probe.coordinator.records[0].nonce
                let metadataRoot = root.appendingPathComponent(UUID().uuidString)
                let repository = try RecordingRepository(root:metadataRoot), transcripts = try TranscriptRepository(root:metadataRoot)
                let name = job.id.uuidString.lowercased()+".json"
                let manifestFile = metadataRoot.appendingPathComponent("manifests").appendingPathComponent(name)
                let receiptFile = metadataRoot.appendingPathComponent("receipts").appendingPathComponent(name)
                try TransportCodec.encode(job.manifest).write(to:manifestFile)
                try TransportCodec.encode(SegmentReceipt(segmentID:job.id,sha256:job.manifest.sha256,
                    byteCount:job.manifest.byteCount)).write(to:receiptFile)
                let text = SegmentTranscript(segmentID:job.id,audioSHA256:job.manifest.sha256,locale:"zh-CN",engine:"synthetic-priority",
                    createdAt:job.manifest.endedAt,text:"合成排序回归文字",spans:[])
                try transcripts.save(text,for:job.manifest)
                let validRemote = try json(["id":artifact.fileID!,"size":String(artifact.byteCount),"sha256Checksum":artifact.sha256,
                    "parents":[context.folderID],"ownedByMe":true,"shared":false,"trashed":false,
                    "permissions":[["id":"owner-123","type":"user","role":"owner"]],
                    "appProperties":["rfaSchema":"1","rfaLibraryID":context.libraryID.uuidString.lowercased(),
                        "rfaSegmentID":job.id.uuidString.lowercased(),"rfaKind":artifact.kind.rawValue,
                        "rfaAudioSHA256":job.manifest.sha256,"rfaContentSHA256":artifact.sha256]])
                var mutated = false, validations = 0
                MockProtocol.install { request in
                    if request.url!.path == "/drive/v3/about" { return try about() }
                    if request.url!.path == "/drive/v3/files/folder-123" { return .init(code:200,data:try folder(probe.ledger)) }
                    if mutation == "receipt_withdrawn" { try FileManager.default.removeItem(at:receiptFile) }
                    else if mutation == "manifest_changed" {
                        var raw = try JSONSerialization.jsonObject(with:TransportCodec.encode(job.manifest)) as! [String:Any]
                        raw["sequence"] = job.manifest.sequence+1; try json(raw).write(to:manifestFile)
                    } else {
                        try transcripts.save(SegmentTranscript(segmentID:job.id,audioSHA256:job.manifest.sha256,locale:"zh-CN",
                            engine:"synthetic-priority",createdAt:job.manifest.endedAt,text:"合成等待期间更新后的版本",spans:[]),for:job.manifest)
                    }
                    mutated = true
                    return .init(code:200,data:validRemote)
                }
                try await probe.readBackOne(validateSource:{ pin in
                    validations += 1
                    return try pin.completedSourceIsCurrent(in:repository,transcripts:transcripts,ledger:probe.ledger)
                })
                try require(mutated && validations == 2 && probe.ledger.jobs.flatMap(\.artifacts).allSatisfy{$0.verifiedAt == nil}
                    && probe.coordinator.itemRetries.contains { $0.segmentID == job.id && $0.artifactKey == artifact.key
                        && $0.terminal == true && $0.failureReason == .sourceChanged }
                    && !probe.coordinator.records.contains{$0.nonce == nonce} && probe.ledger.enabled,
                    "A source change during HTTP invented receipt credit or retired its body before durable artifact isolation")
            }
        }

        if cases == 0 { failures.append("No regression case matched the requested filter") }
        let report: [String: Any] = ["status": failures.isEmpty ? "passed" : "failed", "caseCount": cases, "failures": failures,
            "preflightEvidence": preparationEvidence, "accountPhaseEvidence": accountPhaseEvidence,
            "completedReadbackEvidence":completionEvidence,
            "workerDiagnosticAssertionCount":workerDiagnosticAssertions,
            "scope": "Actual official HTTPS transport and resumable client with synthetic URLProtocol replies and tokens; no Google network, login, recording, Keychain, device or cloud operations."]
        try json(report).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
        if !failures.isEmpty { throw ProbeFailure(message: "Synthetic Drive probe failed; inspect report") }
    }
}
