import Combine
import Darwin
import Foundation
import RecordingCore

// Only OS opportunity notifications, browser/Keychain and native scheduling are
// inert. The entire production Library (including init and LocalFiles) is built.
// Keep revocation isolated from live NWPathMonitor callbacks. Path policy is
// covered separately by PhoneGoogleDriveNetworkProbe.
@MainActor final class GoogleDriveNetworkMonitor {
    init(changed: @escaping @MainActor (GoogleDriveNetworkPath, Bool) -> Void) {}
    func start() {}
    func stop() {}
    func settingsDidChange() {}
}
@MainActor final class UIApplication {
    enum State { case active, inactive, background }
    static let shared = UIApplication()
    var applicationState = State.background
    static let didBecomeActiveNotification = Notification.Name("synthetic-active")
    static let willResignActiveNotification = Notification.Name("synthetic-inactive")
    static let didEnterBackgroundNotification = Notification.Name("synthetic-background")
    static let willEnterForegroundNotification = Notification.Name("synthetic-foreground")
}
final class GoogleDriveExecutionLease: @unchecked Sendable {
    let isSystemGranted: Bool, deadline: TimeInterval
    var ended = false
    init(_ systemGranted: Bool, _ maximum: TimeInterval?) {
        isSystemGranted = systemGranted
        deadline = min(ProcessInfo.processInfo.systemUptime + 19, maximum ?? .greatestFiniteMagnitude)
    }
    @MainActor static func begin(systemGranted: Bool, maximumDeadline: TimeInterval? = nil,
                      onExpiration: @escaping @Sendable () -> Void) -> GoogleDriveExecutionLease {
        .init(systemGranted, maximumDeadline)
    }
    func check() throws { if ended || ProcessInfo.processInfo.systemUptime >= deadline { throw CancellationError() } }
    func requestTimeout() throws -> TimeInterval { try check(); return min(19, deadline - ProcessInfo.processInfo.systemUptime) }
    func end() { ended = true }
}
@MainActor final class PhoneBackgroundSync {
    static let shared = PhoneBackgroundSync()
    static var requests = 0
    static func noteNewWork() { requests += 1 }
    func schedule(earliestBeginDate: Date) { Self.requests += 1 }
}
@MainActor final class AutomaticDeliveryBackgroundEvents {
    static let shared = AutomaticDeliveryBackgroundEvents()
    func registerDrive(_ library: GoogleDriveLibrary) {}
    func registerRestore(_ identifier: String, restore: @escaping () -> Void) {}
    func unregisterRestore(_ identifier: String) {}
    func hasPendingCompletion(_ identifier: String) -> Bool { false }
    func requiresInvalidation(_ identifier: String) -> Bool { false }
    func canRestore(_ identifier: String) -> Bool { false }
    func beginHandoff(_ identifier: String) -> UUID { UUID() }
    func completeHandoff(_ identifier: String, token: UUID) {}
    func cancelUnrestorable(_ identifier: String) {}
    func finish(_ identifier: String, token: UUID?) {}
}

@MainActor final class CredentialStorage {
    var value: GoogleDriveCredential? = .init(clientID: "synthetic-client.apps.googleusercontent.com",
        accessToken: "synthetic-access", refreshToken: "synthetic-refresh",
        expiresAt: Date(timeIntervalSinceNow: -60), accountID: "synthetic-owner")
}
@MainActor final class GoogleDriveOAuth: GoogleDriveAuthorization {
    let configuration = try? GoogleDriveOAuthConfiguration(clientID: "synthetic-client.apps.googleusercontent.com",
        reversedClientID: "com.googleusercontent.apps.synthetic-client", registeredBundleID: "offline.probe",
        actualBundleID: "offline.probe", registeredSchemes: ["com.googleusercontent.apps.synthetic-client"])
    let storage: CredentialStorage
    var allowed = true, failCommit = false, revokeConfirmed = false
    var revokeCalls = 0, tokenCalls = 0, refreshCalls = 0, authorizeCalls = 0, commits = 0
    init(http: GoogleDriveHTTP, storage: CredentialStorage = CredentialStorage()) { self.storage = storage }
    var hasCredential: Bool { allowed && storage.value?.permitsAccessToken == true }
    var hasRevocationCredential: Bool { storage.value != nil }
    func suspendUploadAccess() { allowed = false }
    func resumeUploadAccessAfterAuthorization() { allowed = true }
    func authorize() async throws -> GoogleDriveCredential {
        authorizeCalls += 1
        return .init(clientID: "synthetic-client.apps.googleusercontent.com", accessToken: "synthetic-new-access",
            refreshToken: "synthetic-new-refresh", expiresAt: Date(timeIntervalSinceNow: 3600))
    }
    func commit(_ value: GoogleDriveCredential, accountID: String) throws {
        if failCommit { throw GoogleDriveError.credentials }
        var bound = value; bound.accountID = accountID; storage.value = bound; commits += 1
    }
    func revoke() async throws -> Bool {
        revokeCalls += 1
        storage.value?.revocationOnly = true
        if revokeConfirmed { storage.value = nil }
        return revokeConfirmed
    }
    func accessToken(for accountID: String) async throws -> String { try await accessToken(for: accountID, timeout: nil) }
    func accessToken(for accountID: String, timeout: TimeInterval?) async throws -> String {
        tokenCalls += 1
        guard allowed, let value = storage.value, value.permitsAccessToken, value.accountID == accountID else { throw GoogleDriveError.needsSignIn }
        if value.expiresAt < Date() { refreshCalls += 1 }
        return value.accessToken
    }
}

final class MockHTTP: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var requests = 0, unexpected = 0, account = "synthetic-owner"
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests += 1
        let accepted = request.url?.host == "www.googleapis.com" && request.url?.path == "/drive/v3/about" && request.httpMethod == "GET"
        if !accepted { Self.unexpected += 1 }
        let account = Self.account
        Self.lock.unlock()
        guard accepted else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "OfflineUnexpectedRequest", code: 1)); return
        }
        let data = try! JSONSerialization.data(withJSONObject: ["user": ["permissionId": account, "displayName": "Offline"]])
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func reset() { lock.lock(); requests = 0; unexpected = 0; account = "synthetic-owner"; lock.unlock() }
}

struct Failure: Error { let message: String }
func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    if !(try value()) { throw Failure(message: message) }
}
@MainActor final class WriteFault {
    var leaf: String? = "ledger.json"
    var remaining = 1, count = 0
    var failingLedgerWrite: Int?
    func beforeRename(_ file: URL) throws {
        if file.lastPathComponent == "ledger.json" { count += 1 }
        if let failingLedgerWrite, file.lastPathComponent == "ledger.json", count == failingLedgerWrite {
            throw GoogleDriveMetadataIOError(code: EIO)
        }
        if file.lastPathComponent == leaf && remaining > 0 { remaining -= 1; throw GoogleDriveMetadataIOError(code: EIO) }
    }
}
@MainActor final class Fixture {
    let root: URL, directory: URL, ledgerURL: URL, stopURL: URL
    let repository: RecordingRepository, transcripts: TranscriptRepository
    let storage = CredentialStorage()
    let original: GoogleDriveLibraryLedger
    let originalBytes: Data
    init(_ parent: URL) throws {
        root = parent.appendingPathComponent(UUID().uuidString)
        repository = try RecordingRepository(root: root, recoverTransactionsOnInitialization: false)
        transcripts = try TranscriptRepository(root: root)
        directory = root.appendingPathComponent("GoogleDriveLibrary")
        ledgerURL = directory.appendingPathComponent("ledger.json"); stopURL = directory.appendingPathComponent("stop-intent.json")
        var ledger = GoogleDriveLibraryLedger()
        try ledger.bind(accountID: "synthetic-owner", label: "Offline")
        try ledger.authorize(.existingAndFuture, knownIDs: [], at: Date(timeIntervalSince1970: 1_700_000_000))
        // Metadata only: a nonempty pending queue, with no audio file created.
        let id = UUID(), start = Date(timeIntervalSince1970: 1_700_000_000)
        let manifest = SegmentManifest(id: id, sessionID: UUID(), sequence: 1, startedAt: start,
            endedAt: start.addingTimeInterval(30), sampleRate: 16_000, frameCount: 480_000,
            fileName: id.uuidString.lowercased() + ".caf", byteCount: 8, sha256: String(repeating: "1", count: 64))
        try ledger.discover(manifests: [manifest], receivedIDs: [id])
        try ledger.allocateFolder("synthetic-folder")
        original = ledger; originalBytes = try TransportCodec.encode(ledger)
        try GoogleDriveLocalFiles.write(originalBytes, to: ledgerURL)
    }
    func make(_ fault: WriteFault? = nil) -> (GoogleDriveLibrary, GoogleDriveOAuth) {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockHTTP.self]
        let http = GoogleDriveHTTP(configuration: config), oauth = GoogleDriveOAuth(http: http, storage: storage)
        let library = GoogleDriveLibrary(repository: repository, transcriptRepository: transcripts,
            http: http, authorization: oauth, beforeMetadataRename: { try fault?.beforeRename($0) })
        return (library, oauth)
    }
    func readLedger() throws -> GoogleDriveLibraryLedger {
        try TransportCodec.decode(GoogleDriveLibraryLedger.self, from: GoogleDriveLocalFiles.read(ledgerURL))
    }
    func awaitIdentity(_ library: GoogleDriveLibrary) async throws {
        for _ in 0..<3_000 {
            if !library.isBusy { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw Failure(message: "Identity did not finish in bounded synthetic turn")
    }
    func deny(_ library: GoogleDriveLibrary, oauth: GoogleDriveOAuth) async throws {
        try require(!library.isEnabled && !library.isConnected && library.isRevocationPending,
            "Full Library restored active admission after revoke")
        let starts = PhoneBackgroundSync.requests
        library.resume(); library.continueSync()
        _ = await library.prepareBackgroundDelivery(isCancelled: { false }, systemGranted: true)
        try require(!library.isBusy && !library.isEnabled && PhoneBackgroundSync.requests == starts,
            "Resume/continue/real background opportunity admitted stopped grant")
        do { _ = try await oauth.accessToken(for: "synthetic-owner"); throw Failure(message: "Stopped token was returned") }
        catch GoogleDriveError.needsSignIn {}
        try require(oauth.refreshCalls == 0 && MockHTTP.requests == 0, "Stopped grant reached refresh/HTTP")
    }
}

@main struct Main {
    @MainActor static func main() async throws {
        let parent = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var reports: [[String: Any]] = []
        let filter = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
        func run(_ name: String, _ body: @MainActor () async throws -> Void) async {
            if !filter.isEmpty && !name.contains(filter) { return }
            MockHTTP.reset()
            do { try await body(); reports.append(["name": name, "passed": true]) }
            catch { reports.append(["name": name, "passed": false, "error": String(describing: error)]) }
        }
        await run("first ledger rename fails: actual Library cold reload stays stopped") {
            let f = try Fixture(parent), fault = WriteFault()
            var current: GoogleDriveLibrary?; var oauth: GoogleDriveOAuth?
            (current, oauth) = f.make(fault)
            try require(current!.isEnabled && current!.isConnected, "Active baseline absent")
            current!.revoke()
            try require(try Data(contentsOf: f.ledgerURL) == f.originalBytes, "Injected pre-rename failure changed old ledger")
            try require(oauth!.revokeCalls == 0 && f.storage.value?.revocationOnly != true, "Credential/remote touched before durable ledger")
            try await f.deny(current!, oauth: oauth!)
            current = nil; oauth = nil
            let (cold, coldOAuth) = f.make()
            try await f.deny(cold, oauth: coldOAuth)
            try require(FileManager.default.fileExists(atPath: f.stopURL.path), "Stop intent was not durable")
            try require(coldOAuth.revokeCalls == 0 && cold.canRetryRevocation, "Cold stop lost retryable credential")
        }
        await run("stop intent failure: current process denied with honest unsaved status") {
            let f = try Fixture(parent), fault = WriteFault(); fault.leaf = "stop-intent.json"
            let (library, oauth) = f.make(fault); library.revoke()
            try require(!FileManager.default.fileExists(atPath: f.stopURL.path), "Failed fence fabricated durability")
            try require(try Data(contentsOf: f.ledgerURL) == f.originalBytes, "Fence failure changed ledger")
            try require(library.activity.contains("保存失败"), "Fence failure claimed durable local stop")
            try require(oauth.revokeCalls == 0, "Fence failure reached credential mutation")
            try await f.deny(library, oauth: oauth)
        }
        await run("legacy saved revocation denies active credential without a stop file") {
            let f = try Fixture(parent)
            var ledger = f.original; ledger.revoke()
            try GoogleDriveLocalFiles.write(TransportCodec.encode(ledger), to: f.ledgerURL)
            let (cold, oauth) = f.make()
            try require(!FileManager.default.fileExists(atPath: f.stopURL.path), "Legacy fixture created a new fence")
            try await f.deny(cold, oauth: oauth)
        }
        await run("cold stop retry makes explicit revoke and retains fence") {
            let f = try Fixture(parent), fault = WriteFault()
            let (first, _) = f.make(fault); first.revoke()
            let (cold, oauth) = f.make(); cold.revoke(); try await f.awaitIdentity(cold)
            try require(oauth.revokeCalls == 1 && f.storage.value?.revocationOnly == true, "Explicit retry did not revoke")
            let saved = try f.readLedger()
            try require(!saved.enabled && saved.revokedLocally && !saved.remoteRevocationConfirmed, "Retry invented remote confirmation")
            try require(FileManager.default.fileExists(atPath: f.stopURL.path), "Retry cleared durable stop")
        }
        await run("same account explicit reauthorization clears fence only after paused ledger") {
            let f = try Fixture(parent), fault = WriteFault()
            let (library, oauth) = f.make(fault); library.revoke()
            library.connect(); try await f.awaitIdentity(library)
            let saved = try f.readLedger()
            try require(library.isConnected && !library.isEnabled && !library.isRevocationPending, "Reauthorization did not stay paused")
            try require(!FileManager.default.fileExists(atPath: f.stopURL.path), "Successful explicit consent retained stale fence")
            try require(saved.libraryID == f.original.libraryID && saved.recordingScope == f.original.recordingScope
                && saved.authorizedAt == f.original.authorizedAt && saved.folderID == f.original.folderID
                && saved.baselineIDs == f.original.baselineIDs && saved.jobs == f.original.jobs && !saved.enabled,
                "Reauthorization changed grant, folder, baseline or jobs")
            try require(oauth.commits == 1 && oauth.refreshCalls == 0 && MockHTTP.requests == 1 && MockHTTP.unexpected == 0,
                "Reauthorization sent unexpected request")
            library.continueSync(); try require(library.isEnabled, "Explicit continue remained fenced")
            library.pause()
        }
        await run("reauthorization credential commit failure retains cold stop") {
            let f = try Fixture(parent), fault = WriteFault()
            let (library, oauth) = f.make(fault); library.revoke(); oauth.failCommit = true
            library.connect(); try await f.awaitIdentity(library)
            try require(FileManager.default.fileExists(atPath: f.stopURL.path) && !library.isEnabled,
                "Failed credential commit removed stop")
            MockHTTP.reset(); let (cold, coldOAuth) = f.make(); try await f.deny(cold, oauth: coldOAuth)
        }
        await run("reauthorization final ledger rename failure retains cold stop despite active credential") {
            let f = try Fixture(parent), fault = WriteFault()
            let (library, oauth) = f.make(fault); library.revoke()
            fault.failingLedgerWrite = fault.count + 3 // connect pause, account fence, final paused state
            library.connect(); try await f.awaitIdentity(library)
            try require(oauth.commits == 1 && f.storage.value?.permitsAccessToken == true, "Counterexample lacks committed credential")
            try require(FileManager.default.fileExists(atPath: f.stopURL.path) && !library.isConnected && !library.isEnabled,
                "Final ledger failure reopened token access")
            MockHTTP.reset(); let (cold, coldOAuth) = f.make(); try await f.deny(cold, oauth: coldOAuth)
        }
        await run("foreign account reauthorization never clears original stop") {
            let f = try Fixture(parent), fault = WriteFault()
            let (library, oauth) = f.make(fault); library.revoke(); MockHTTP.account = "synthetic-foreign"
            library.connect(); try await f.awaitIdentity(library)
            try require(oauth.commits == 0 && FileManager.default.fileExists(atPath: f.stopURL.path), "Wrong account cleared stop")
            MockHTTP.reset(); let (cold, coldOAuth) = f.make(); try await f.deny(cold, oauth: coldOAuth)
        }
        await run("corrupt or foreign stop metadata is unavailable, not legacy absence") {
            for bytes in [Data("{broken".utf8), try JSONSerialization.data(withJSONObject:
                ["schemaVersion": 1, "libraryID": UUID().uuidString, "accountID": "synthetic-owner"])] {
                let f = try Fixture(parent); try GoogleDriveLocalFiles.write(bytes, to: f.stopURL)
                let (cold, oauth) = f.make(); cold.resume(); cold.continueSync()
                try require(!cold.isEnabled && !cold.isConnected && cold.error != nil && oauth.refreshCalls == 0,
                    "Malformed/foreign stop metadata became permission")
                try require(MockHTTP.requests == 0, "Invalid fence sent HTTP")
            }
        }
        let failed = reports.filter { $0["passed"] as? Bool != true }.count
        let result: [String: Any] = ["cases": reports.count, "failures": failed, "results": reports,
            "fullProductionLibrary": true, "deviceAccess": false, "realKeychainAccess": false,
            "realNetworkAccess": false, "audioAccess": false]
        let bytes = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try bytes.write(to: parent.appendingPathComponent("report.json"))
        print(String(decoding: bytes, as: UTF8.self))
        if failed > 0 { exit(1) }
    }
}
