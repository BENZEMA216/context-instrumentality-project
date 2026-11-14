import CryptoKit
import Foundation
import RecordingCore
import Security

struct AutomaticReceiverPairingPayload: Codable, Sendable {
    let schemaVersion: Int
    let endpoint: String
    let receiverID: UUID
    let token: String
    let certificateSHA256: String

    static func parse(_ input: String) throws -> Self {
        guard input.utf8.count <= 16_384, let data = input.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["schemaVersion", "endpoint", "receiverID", "token", "certificateSHA256"] else {
            throw AutomaticReceiverError.invalidPairing
        }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schemaVersion == 1, let url = Self.endpointURL(value.endpoint),
              url.absoluteString == value.endpoint || url.absoluteString + "/" == value.endpoint,
              isDigest(value.certificateSHA256), validToken(value.token) else { throw AutomaticReceiverError.invalidPairing }
        return Self(schemaVersion: 1, endpoint: url.absoluteString, receiverID: value.receiverID,
            token: value.token, certificateSHA256: value.certificateSHA256)
    }

    static func endpointURL(_ value: String) -> URL? {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              var parts = URLComponents(string: value), parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              ["", "/"].contains(parts.path) else { return nil }
        parts.path = ""
        return parts.url
    }

    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func validToken(_ value: String) -> Bool {
        guard value.utf8.count == 43, value.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }) else { return false }
        let base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="
        return Data(base64Encoded: base64)?.count == 32
    }
}

enum AutomaticReceiverError: LocalizedError {
    case invalidPairing, credentialsUnavailable, scopeChanged, invalidArchive, invalidReceipt, invalidCertificate
    case notConfigured, localStateUnavailable, noSelection, duplicateReceiver, invalidReceiverName
    var errorDescription: String? {
        switch self {
        case .invalidPairing: return "配对信息无效，请重新复制接收端显示的完整配对信息。"
        case .credentialsUnavailable: return "无法安全读取或保存配对凭据，请解锁手机后重试。"
        case .scopeChanged: return "接收端或授权范围已变化，已停止该接收端的旧队列，请重新配对。"
        case .invalidArchive: return "待交付文件未通过核对，原录音仍保留。"
        case .invalidReceipt: return "接收端返回的保存回执不匹配，未标记为已交付。"
        case .invalidCertificate: return "接收端证书与配对时不一致，已停止向该端发送，请核对后重新配对。"
        case .notConfigured: return "先配对接收 AGENT，再开启自动同步。"
        case .localStateUnavailable: return "自动同步记录无法安全读取，已暂停交付，原录音仍保留。"
        case .noSelection: return "请选择要交付的现有录音，或允许同步之后新收到的片段。"
        case .duplicateReceiver: return "此接收端已经配对。已有队列与授权保持不变；需要重新配对时，请先解除对应接收端。"
        case .invalidReceiverName: return "请为接收端填写简短名称。"
        }
    }
}

struct AutomaticReceiverCredentials: Codable, Sendable {
    let scope: AutomaticDeliveryScope
    let token: String
}

struct AutomaticReceiverStoredPairing: Codable, Sendable {
    let displayName: String
    let credentials: AutomaticReceiverCredentials
    // A legacy nil keeps the previous grant's durable pause setting authoritative.
    var enabled: Bool?
}

protocol AutomaticReceiverKeychainStorage: AnyObject {
    func read(_ account: String) throws -> Data?
    func write(_ data: Data, account: String) throws
    func remove(_ account: String) throws
}

final class SystemAutomaticReceiverKeychainStorage: AutomaticReceiverKeychainStorage {
    private let service = (Bundle.main.bundleIdentifier ?? "RecordForAgent") + ".automatic-receiver"
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
    func read(_ account: String) throws -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw AutomaticReceiverError.credentialsUnavailable }
        return data
    }
    func write(_ data: Data, account: String) throws {
        let values: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query(account) as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var request = query(account)
            values.forEach { request[$0.key] = $0.value }
            guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else { throw AutomaticReceiverError.credentialsUnavailable }
        } else if status != errSecSuccess { throw AutomaticReceiverError.credentialsUnavailable }
    }
    func remove(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AutomaticReceiverError.credentialsUnavailable }
    }
}

protocol AutomaticReceiverCredentialStorage: AnyObject {
    func installationID() throws -> UUID
    func loadAll() throws -> [AutomaticReceiverStoredPairing]
    func saveAll(_ pairings: [AutomaticReceiverStoredPairing]) throws
}

/// One atomic, device-only Keychain value owns all active credentials. An empty
/// collection is a tombstone: the legacy single pairing can never be resurrected.
final class AutomaticReceiverCredentialVault: AutomaticReceiverCredentialStorage {
    private let storage: any AutomaticReceiverKeychainStorage
    private let collectionAccount = "receiver-pairings-v1"
    private struct Collection: Codable {
        let schemaVersion: Int
        let pairings: [AutomaticReceiverStoredPairing]
    }

    init(storage: any AutomaticReceiverKeychainStorage = SystemAutomaticReceiverKeychainStorage()) {
        self.storage = storage
    }

    func installationID() throws -> UUID {
        if let data = try storage.read("source-installation") {
            guard let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text) else {
                throw AutomaticReceiverError.credentialsUnavailable
            }
            return id
        }
        let id = UUID()
        try storage.write(Data(id.uuidString.lowercased().utf8), account: "source-installation")
        return id
    }

    func loadAll() throws -> [AutomaticReceiverStoredPairing] {
        if let data = try storage.read(collectionAccount) {
            let collection = try TransportCodec.decode(Collection.self, from: data)
            guard collection.schemaVersion == 1 else { throw AutomaticReceiverError.credentialsUnavailable }
            try validate(collection.pairings)
            return collection.pairings
        }
        guard let legacy = try storage.read("active-pairing") else { return [] }
        let credentials = try TransportCodec.decode(AutomaticReceiverCredentials.self, from: legacy)
        let name = URL(string: credentials.scope.endpoint)?.host ?? "已配对接收端"
        let pairings = [AutomaticReceiverStoredPairing(displayName: name, credentials: credentials, enabled: nil)]
        // No queue, scope, receipt or setting is rewritten during migration.
        try saveAll(pairings)
        try? storage.remove("active-pairing")
        return pairings
    }

    func saveAll(_ pairings: [AutomaticReceiverStoredPairing]) throws {
        try validate(pairings)
        try storage.write(TransportCodec.encode(Collection(schemaVersion: 1, pairings: pairings)), account: collectionAccount)
    }

    private func validate(_ pairings: [AutomaticReceiverStoredPairing]) throws {
        guard Set(pairings.map { $0.credentials.scope.receiverID }).count == pairings.count,
              Set(pairings.map { $0.credentials.scope.grantEpoch }).count == pairings.count else {
            throw AutomaticReceiverError.duplicateReceiver
        }
        guard !pairings.isEmpty else { return }
        let installation = try installationID()
        for pairing in pairings {
            let value = pairing.credentials
            guard !pairing.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  pairing.displayName.utf8.count <= 256,
                  AutomaticReceiverPairingPayload.validToken(value.token),
                  AutomaticReceiverPairingPayload.endpointURL(value.scope.endpoint) != nil,
                  AutomaticReceiverPairingPayload.isDigest(value.scope.certificateSHA256),
                  value.scope.sourceInstallationID == installation else {
                throw AutomaticReceiverError.invalidPairing
            }
        }
    }
}

struct AutomaticReceiverTransferResult: Sendable {
    let scope: AutomaticDeliveryScope
    let deliveryID: UUID
    let receipt: AutomaticDeliveryReceipt?
    let statusCode: Int?
    let message: String?
    let requiresRepair: Bool
    let failureCategory: AutomaticReceiverFailureCategory?
    /// Nil identifies tasks retained from a build that stored UUID-only descriptions.
    let attemptCount: Int?

    init(scope: AutomaticDeliveryScope, deliveryID: UUID, receipt: AutomaticDeliveryReceipt?,
         statusCode: Int?, message: String?, requiresRepair: Bool, attemptCount: Int? = nil,
         failureCategory: AutomaticReceiverFailureCategory? = nil) {
        self.scope = scope; self.deliveryID = deliveryID; self.receipt = receipt
        self.statusCode = statusCode; self.message = message; self.requiresRepair = requiresRepair
        self.attemptCount = attemptCount
        self.failureCategory = requiresRepair ? .pairingRepairRequired : failureCategory
    }
}

protocol AutomaticReceiverTransport: AnyObject, Sendable {
    var identifier: String { get }
    func activeDeliveryIDs() async -> Set<UUID>
    func activeTransfers() async -> [AutomaticDeliveryTransferProgress]
    func cancelTransfer(ifUnchanged progress: AutomaticDeliveryTransferProgress) async -> Bool
    func upload(deliveryID: UUID, attemptCount: Int, archiveURL: URL, sha256: String) throws
    func cancelAll()
    func cancelTransfers() async
    func invalidateAndDrain() async
}

typealias AutomaticReceiverClientFactory = (
    AutomaticReceiverCredentials,
    @escaping @Sendable (AutomaticReceiverTransferResult) async -> Void,
    @escaping @Sendable (BackgroundSessionEvent) -> Void
) throws -> any AutomaticReceiverTransport

/// Delegate callbacks cross executors, so explicitly preserve their delivery
/// order through persistence and only then release the system background event.
final class AutomaticReceiverEventDrain: @unchecked Sendable {
    private let lock = NSLock()
    private var tail: Task<Void, Never>?

    func append(_ event: @escaping @Sendable () async -> Void) {
        lock.lock()
        let previous = tail
        tail = Task {
            await previous?.value
            await event()
        }
        lock.unlock()
    }
}

/// The invalidation delegate is queued after task delegates. Its completion is
/// additionally chained after our asynchronous receipt persistence callbacks.
final class AutomaticReceiverInvalidationBarrier: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    private var completed = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func whileActive(_ operation: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard !requested else { throw AutomaticReceiverError.notConfigured }
        try operation()
    }

    func request(_ invalidate: () -> Void) {
        lock.lock()
        let first = !requested
        requested = true
        lock.unlock()
        if first { invalidate() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if completed { lock.unlock(); continuation.resume() }
            else { waiters.append(continuation); lock.unlock() }
        }
    }

    func complete() {
        lock.lock()
        requested = true
        completed = true
        let ready = waiters
        waiters.removeAll()
        lock.unlock()
        ready.forEach { $0.resume() }
    }
}

/// Pairing trusts one exact certificate while keeping TLS hostname and validity
/// checks. Keeping this separate makes the pin policy independently verifiable.
enum AutomaticReceiverPinnedTLS {
    static func accepts(_ trust: SecTrust, host: String, certificateSHA256: String) -> Bool {
        guard AutomaticReceiverPairingPayload.isDigest(certificateSHA256), !host.isEmpty,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return false }
        let bytes = SecCertificateCopyData(leaf) as Data
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard digest == certificateSHA256,
              SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, host as CFString)) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [leaf] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess else { return false }
        return SecTrustEvaluateWithError(trust, nil)
    }
}

/// One immutable scope per background session. Replacement pairings use a new
/// identifier, and neither credentials nor old completion events can cross scopes.
final class AutomaticReceiverClient: NSObject, URLSessionDataDelegate, AutomaticReceiverTransport, @unchecked Sendable {
    let scope: AutomaticDeliveryScope
    let identifier: String
    private let token: String
    private let endpoint: URL
    private let complete: @Sendable (AutomaticReceiverTransferResult) async -> Void
    private let finishedEvents: @Sendable (BackgroundSessionEvent) -> Void
    private let delegateQueue: OperationQueue
    private var responseData: [Int: Data] = [:]
    private var rejectedTrust = Set<Int>()
    private var oversizedResponses = Set<Int>()
    private var rejectedSessionTrust = false
    private var session: URLSession!
    private let maximumResponseBytes = 256 * 1_024
    // Accessed only by the serial URLSession delegate queue. A MainActor hop
    // alone does not make UIKit's finish event wait for our durable receipt work.
    private let deliveryEvents = AutomaticReceiverEventDrain()
    private let invalidation = AutomaticReceiverInvalidationBarrier()

    static func sessionIdentifier(for scope: AutomaticDeliveryScope) -> String {
        (Bundle.main.bundleIdentifier ?? "RecordForAgent") + ".automatic-delivery." + scope.grantEpoch.uuidString.lowercased()
    }

    init(credentials: AutomaticReceiverCredentials,
         complete: @escaping @Sendable (AutomaticReceiverTransferResult) async -> Void,
         finishedEvents: @escaping @Sendable (BackgroundSessionEvent) -> Void) throws {
        guard let endpoint = AutomaticReceiverPairingPayload.endpointURL(credentials.scope.endpoint),
              AutomaticReceiverPairingPayload.isDigest(credentials.scope.certificateSHA256),
              AutomaticReceiverPairingPayload.validToken(credentials.token) else { throw AutomaticReceiverError.invalidPairing }
        scope = credentials.scope
        token = credentials.token
        self.endpoint = endpoint
        identifier = Self.sessionIdentifier(for: credentials.scope)
        self.complete = complete
        self.finishedEvents = finishedEvents
        delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.name = "RecordForAgent.automatic-receiver"
        super.init()
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = false
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        // Background sessions may keep retrying beyond the request timeout.
        // Bound one attempt so a retained task cannot hold this receiver for days.
        configuration.timeoutIntervalForResource = AutomaticDeliveryTransferLiveness.resourceTimeout
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }

    static func taskIdentity(_ description: String?) -> (deliveryID: UUID, attemptCount: Int?)? {
        guard let description else { return nil }
        let parts = description.split(separator: ":", omittingEmptySubsequences: false)
        guard let first = parts.first, let id = UUID(uuidString: String(first)) else { return nil }
        if parts.count == 1 { return (id, nil) }
        guard parts.count == 2, let attempt = Int(parts[1]),
              (1...AutomaticDeliveryLedger.maximumAttempts).contains(attempt) else { return nil }
        return (id, attempt)
    }

    func activeDeliveryIDs() async -> Set<UUID> {
        let tasks = await session.allTasks
        return Set(tasks.compactMap { Self.taskIdentity($0.taskDescription)?.deliveryID })
    }

    func activeTransfers() async -> [AutomaticDeliveryTransferProgress] {
        let tasks = await session.allTasks
        return tasks.compactMap { task in
            guard task.state != .completed,
                  let identity = Self.taskIdentity(task.taskDescription) else { return nil }
            return .init(deliveryID: identity.deliveryID, bytesSent: task.countOfBytesSent,
                         bytesReceived: task.countOfBytesReceived, attemptCount: identity.attemptCount)
        }
    }

    func cancelTransfer(ifUnchanged progress: AutomaticDeliveryTransferProgress) async -> Bool {
        let tasks = await session.allTasks
        var cancelled = false
        for task in tasks {
            guard task.state != .completed, let identity = Self.taskIdentity(task.taskDescription),
                  identity.deliveryID == progress.deliveryID, identity.attemptCount == progress.attemptCount,
                  task.countOfBytesSent == progress.bytesSent,
                  task.countOfBytesReceived == progress.bytesReceived else { continue }
            // No actor hop between the final counter/attempt check and cancel:
            // reconnection while obtaining allTasks must not kill fresh progress.
            task.cancel()
            cancelled = true
        }
        return cancelled
    }

    func upload(deliveryID: UUID, attemptCount: Int, archiveURL: URL, sha256: String) throws {
        guard archiveURL.isFileURL, AutomaticReceiverPairingPayload.isDigest(sha256),
              (1...AutomaticDeliveryLedger.maximumAttempts).contains(attemptCount) else { throw AutomaticReceiverError.invalidArchive }
        var request = URLRequest(url: endpoint.appendingPathComponent("v1/imports"))
        request.httpMethod = "POST"
        request.setValue("application/zip", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue(deliveryID.uuidString.lowercased(), forHTTPHeaderField: "X-Delivery-ID")
        request.setValue(sha256, forHTTPHeaderField: "X-Archive-SHA256")
        try invalidation.whileActive {
            let task = session.uploadTask(with: request, fromFile: archiveURL)
            task.taskDescription = deliveryID.uuidString.lowercased() + ":" + String(attemptCount)
            task.resume()
        }
    }

    func cancelAll() { invalidation.request { session.invalidateAndCancel() } }

    func invalidateAndDrain() async {
        cancelAll()
        await invalidation.wait()
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        let invalidation = invalidation
        deliveryEvents.append { invalidation.complete() }
    }

    func cancelTransfers() async {
        let tasks = await session.allTasks
        tasks.forEach { $0.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let credential = trustedCredential(for: challenge) else {
            rejectedTrust.insert(task.taskIdentifier)
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, credential)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let credential = trustedCredential(for: challenge) else {
            rejectedSessionTrust = true
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, credential)
    }

    private func trustedCredential(for challenge: URLAuthenticationChallenge) -> URLCredential? {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host.caseInsensitiveCompare(endpoint.host ?? "") == .orderedSame,
              let trust = challenge.protectionSpace.serverTrust,
              AutomaticReceiverPinnedTLS.accepts(trust, host: challenge.protectionSpace.host,
                certificateSHA256: scope.certificateSHA256) else {
            return nil
        }
        return URLCredential(trust: trust)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let existing = responseData[dataTask.taskIdentifier] ?? Data()
        guard existing.count + data.count <= maximumResponseBytes else {
            oversizedResponses.insert(dataTask.taskIdentifier)
            dataTask.cancel()
            return
        }
        responseData[dataTask.taskIdentifier] = existing + data
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let data = responseData.removeValue(forKey: task.taskIdentifier) ?? Data()
        let rejected = rejectedTrust.remove(task.taskIdentifier) != nil || rejectedSessionTrust
        let oversized = oversizedResponses.remove(task.taskIdentifier) != nil
        guard let identity = Self.taskIdentity(task.taskDescription) else { return }
        let deliveryID = identity.deliveryID
        let response = task.response as? HTTPURLResponse
        let status = response?.statusCode
        let receipt: AutomaticDeliveryReceipt?
        var message: String?
        var failureCategory: AutomaticReceiverFailureCategory?
        var repair = rejected
        if rejected {
            receipt = nil
            message = AutomaticReceiverError.invalidCertificate.localizedDescription
            failureCategory = .certificate
        } else if oversized {
            receipt = nil
            message = AutomaticReceiverError.invalidReceipt.localizedDescription
            failureCategory = .invalidResponse
        } else if let error {
            receipt = nil
            failureCategory = .networkFailure(error: error) ?? .localState
            message = failureCategory == .localState
                ? AutomaticReceiverFailureCategory.localState.hint
                : "暂未连接到配对电脑，稍后会自动重试。"
        } else if !AutomaticReceiverResponseURLPolicy.matches(
            expected: endpoint.appendingPathComponent("v1/imports"), response: response?.url) {
            receipt = nil
            repair = true
            message = "电脑服务地址发生变化，已停止发送，请重新配对。"
            failureCategory = .invalidResponse
        } else if let status, (200...299).contains(status) {
            receipt = try? TransportCodec.decode(AutomaticDeliveryReceipt.self, from: data)
            if receipt == nil {
                message = AutomaticReceiverError.invalidReceipt.localizedDescription
                failureCategory = .invalidResponse
                repair = true
            }
        } else {
            receipt = nil
            let category = AutomaticReceiverFailureCategory.classify(error: nil, statusCode: status)
            failureCategory = category == .unsupportedProbe ? .invalidResponse : category
            repair = status.map { (300...499).contains($0) && ![408, 429].contains($0) } ?? false
            if status == 401 || status == 403 { message = "电脑不再接受这份配对凭据，请重新配对。" }
            else if repair { message = "电脑未接受交付请求，请检查接收程序后重新配对。" }
            else { message = "电脑暂未完成保存，稍后会自动重试。" }
        }
        let result = AutomaticReceiverTransferResult(scope: scope, deliveryID: deliveryID, receipt: receipt,
            statusCode: repair ? (status ?? 403) : status, message: message, requiresRepair: repair,
            attemptCount: identity.attemptCount, failureCategory: failureCategory)
        let complete = complete
        deliveryEvents.append {
            await complete(result)
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let finished = finishedEvents
        let event = BackgroundSessionEventTracker.shared.capture(identifier)
        deliveryEvents.append {
            finished(event)
        }
    }
}
