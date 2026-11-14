import Foundation
import RecordingCore

private struct Failure: Error { let message: String }
private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw Failure(message: message) }
}
private final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { lock.lock(); defer { lock.unlock() }; return values[key] }
    override func set(_ value: Any?, forKey key: String) { lock.lock(); defer { lock.unlock() }; values[key] = value }
}
private final class Trace: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []
    private var completions: [GoogleDriveUploadCompletion] = []
    var captured: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    var completed: [GoogleDriveUploadCompletion] { lock.lock(); defer { lock.unlock() }; return completions }
    func complete(_ value: GoogleDriveUploadCompletion) { lock.lock(); completions.append(value); lock.unlock() }
    func append(_ request: URLRequest) -> Int {
        lock.lock(); defer { lock.unlock() }; requests.append(request); return requests.count
    }
}
private final class OfflineProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: ((URLRequest) throws -> Void)?
    static func install(_ handler: @escaping (URLRequest) throws -> Void) { lock.lock(); self.handler = handler; lock.unlock() }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let handler = Self.handler; Self.lock.unlock()
        do {
            guard let handler else { throw Failure(message: "Missing offline route") }
            try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
private func configuration() -> URLSessionConfiguration {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [OfflineProtocol.self]
    return config
}
private func request(_ url: String, method: String = "GET") -> URLRequest {
    var request = URLRequest(url: URL(string: url)!)
    request.httpMethod = method
    return request
}

@main private enum Probe {
    @MainActor static func main() async throws {
        let settings = GoogleDriveNetworkSettings(defaults: MemoryDefaults())
        let http = GoogleDriveHTTP(configuration: configuration(), networkSettings: settings)
        let trace = Trace()
        OfflineProtocol.install { _ = trace.append($0) }
        let requests = [
            request("https://oauth2.googleapis.com/token", method: "POST"),
            request("https://www.googleapis.com/drive/v3/files/synthetic-file?fields=id,size,sha256Checksum"),
            request("https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable", method: "POST"),
            request("https://www.googleapis.com/upload/drive/v3/files?upload_id=synthetic-session", method: "PUT")
        ]
        for allows in [false, true, false] {
            settings.setAllowsCellularAccess(allows)
            for original in requests {
                var value = original
                value.allowsCellularAccess = !allows // caller defaults cannot bypass the setting
                _ = try await http.send(value)
                try require(trace.captured.last?.allowsCellularAccess == allows, "HTTP stage ignored network preference")
            }
        }

        let recoveryTrace = Trace()
        OfflineProtocol.install { value in
            if recoveryTrace.append(value) == 1 {
                settings.setAllowsCellularAccess(true)
                throw NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
            }
        }
        settings.setAllowsCellularAccess(false)
        _ = try await http.send(requests[1], timeout: 8)
        try require(recoveryTrace.captured.count == 2, "Expected one bounded synthetic recovery")
        try require(recoveryTrace.captured.allSatisfy { !$0.allowsCellularAccess }, "Recovery expanded the in-flight request's network permission")

        let legacyTrace = Trace()
        OfflineProtocol.install { _ = legacyTrace.append($0) }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let body = root.appendingPathComponent("synthetic-body.json")
        try Data("{}".utf8).write(to: body)
        let native = try GoogleDriveUploadSession(identifier: "synthetic-network-policy", complete: { legacyTrace.complete($0) }, finished: { _ in },
            networkSettings: settings, configuration: configuration())
        settings.setAllowsCellularAccess(false)
        let legacy = try native.create(requests[3], file: body, nonce: "synthetic-legacy")
        settings.setAllowsCellularAccess(true)
        try await native.prepareForNewRequests(allowSessionMigration: true)
        try require(!settings.nativeSessionUsesRequestPolicy(native.identifier), "Legacy task's session permission was expanded")
        let legacyPeer = try native.create(requests[3], file: body, nonce: "synthetic-healthy-peer")
        try require(legacy != legacyPeer, "Healthy peer replaced the legacy task")
        native.resume(legacy); native.resume(legacyPeer)
        for _ in 0..<100 where legacyTrace.completed.count < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        try require(legacyTrace.captured.count == 2 && legacyTrace.captured.allSatisfy { !$0.allowsCellularAccess },
            "Legacy task or healthy peer lost Wi-Fi-only admission")
        try require(Set(legacyTrace.completed.map { $0.task.id }) == [legacy, legacyPeer]
            && Set(legacyTrace.completed.compactMap { $0.task.nonce }) == ["synthetic-legacy", "synthetic-healthy-peer"]
            && legacyTrace.completed.allSatisfy { !$0.transportFailed && $0.status == 200 },
            "Allowing cellular cancelled, replaced or replayed the legacy task")
        await native.invalidateAndCancel() // drained synthetic fixture teardown only

        let heldTrace = Trace()
        OfflineProtocol.install { _ = heldTrace.append($0) }
        let held = try GoogleDriveUploadSession(identifier: "synthetic-metadata-incomplete", complete: { heldTrace.complete($0) }, finished: { _ in },
            networkSettings: settings, configuration: configuration())
        // A completed metadataIncomplete record can remain indefinitely. It
        // prevents migration, but must not prevent a healthy peer from starting.
        try await held.prepareForNewRequests(allowSessionMigration: false)
        try require(!settings.nativeSessionUsesRequestPolicy(held.identifier), "Durable completed record allowed premature migration")
        let healthy = try held.create(requests[3], file: body, nonce: "synthetic-metadata-peer")
        held.resume(healthy)
        for _ in 0..<100 where heldTrace.completed.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        try require(heldTrace.captured.count == 1 && heldTrace.captured[0].allowsCellularAccess == false
            && heldTrace.completed.count == 1 && heldTrace.completed[0].task.id == healthy
            && heldTrace.completed[0].task.nonce == "synthetic-metadata-peer"
            && !heldTrace.completed[0].transportFailed,
            "Incomplete metadata blocked or replaced a healthy legacy-session peer")
        await held.invalidateAndCancel()

        let nativeTrace = Trace()
        OfflineProtocol.install { _ = nativeTrace.append($0) }
        let migrated = try GoogleDriveUploadSession(identifier: "synthetic-drained-network-policy", complete: { nativeTrace.complete($0) }, finished: { _ in },
            networkSettings: settings, configuration: configuration())
        try await migrated.prepareForNewRequests(allowSessionMigration: true)
        try require(settings.nativeSessionUsesRequestPolicy(migrated.identifier), "Fully drained session failed to migrate")

        settings.setAllowsCellularAccess(false)
        let first = try migrated.create(requests[3], file: body, nonce: "synthetic-first")
        settings.setAllowsCellularAccess(true)
        let second = try migrated.create(requests[3], file: body, nonce: "synthetic-second")
        try require(first != second, "Policy change reused a live native task ID")
        settings.setAllowsCellularAccess(false)
        migrated.resume(first); migrated.resume(second)
        for _ in 0..<100 where nativeTrace.completed.count < 2 { try await Task.sleep(nanoseconds: 10_000_000) }
        try require(nativeTrace.captured.count == 2, "Native requests did not finish through the offline route")
        try require(nativeTrace.captured.filter(\.allowsCellularAccess).count == 1, "Existing native task lost its captured network choice")
        try require(nativeTrace.captured.allSatisfy { $0.url == requests[3].url && $0.httpMethod == "PUT" }, "Policy change altered resumable session identity")
        try require(Set(nativeTrace.completed.map { $0.task.id }) == [first, second]
            && Set(nativeTrace.completed.compactMap { $0.task.nonce }) == ["synthetic-first", "synthetic-second"],
            "Policy change replaced native attempt identity")
        await migrated.invalidateAndCancel()
        // A task cancellation without UIKit handoff leaves a retired session
        // pending. A later eligible opportunity, not the cancelled task, owns
        // its one replacement; false admission must never use the retired one.
        let cancelledSettings = GoogleDriveNetworkSettings(defaults: DriveInterleavingDefaults())
        var cancelledSessions: [ControlledDriveSession] = []
        let cancelled = try GoogleDriveUploadSession(identifier: "synthetic-cancelled-migration", complete: { _ in }, finished: { _ in },
            networkSettings: cancelledSettings, configuration: .ephemeral, sessionFactory: { _, delegate in
                let value = ControlledDriveSession(delegate: delegate); cancelledSessions.append(value); return value
            })
        let migration = Task { @MainActor in try await cancelled.prepareForNewRequests(allowSessionMigration: true) }
        try await waitForDriveInterleaving("cancelled migration began invalidation") {
            cancelledSessions[0].gracefulInvalidationCount == 1
        }
        migration.cancel()
        try require(cancelledSessions.count == 1 && !cancelledSettings.nativeSessionUsesRequestPolicy(cancelled.identifier),
            "Task cancellation committed a new policy before native invalidation")
        cancelledSessions[0].releaseInvalidation()
        do { try await migration.value; throw Failure(message: "Cancelled migration rebuilt a session") }
        catch is CancellationError { }
        try require(cancelledSessions.count == 1 && !cancelledSettings.nativeSessionUsesRequestPolicy(cancelled.identifier),
            "Cancelled migration rebuilt or persisted policy after invalidation")
        do {
            try await cancelled.prepareForNewRequests(allowSessionMigration: false)
            throw Failure(message: "Retired session accepted non-migrating preparation")
        } catch is GoogleDriveUploadRetryDeferred { }
        do {
            _ = try cancelled.create(requests[3], file: body, nonce: "cancelled-migration")
            throw Failure(message: "Retired session accepted a native request")
        } catch is GoogleDriveUploadRetryDeferred { }
        cancelled.resume(1)
        try await cancelled.prepareForNewRequests(allowSessionMigration: true)
        try require(cancelledSessions.count == 2 && cancelledSessions[0].enumerationCount == 1
            && cancelledSessions[0].gracefulInvalidationCount == 1
            && cancelledSettings.nativeSessionUsesRequestPolicy(cancelled.identifier),
            "A new opportunity failed to resume exactly the already-retired migration")
        let cancelledTeardown = Task { @MainActor in await cancelled.invalidateAndCancel() }
        try await waitForDriveInterleaving("cancelled-migration teardown") { cancelledSessions[1].cancellationCount == 1 }
        cancelledSessions[1].releaseInvalidation(); await cancelledTeardown.value
        print("passed: 12 HTTP stage/preference cases; 1 in-flight recovery case; 4 native legacy/healthy-peer/drained/pending-task policy cases; 1 cancelled-migration interleaving (18 total)")
    }
}
