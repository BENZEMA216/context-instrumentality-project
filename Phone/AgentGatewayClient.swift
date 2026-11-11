import Foundation
import RecordingCore
import Security

struct AgentGatewayConfiguration: Sendable {
    let baseURL: URL?
    let unavailableReason: String?

    init(bundle: Bundle = .main) {
        self.init(rawValue: bundle.object(forInfoDictionaryKey: "WRAgentGatewayBaseURL") as? String)
    }

    init(rawValue: String?) {
        guard let rawValue, !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            baseURL = nil
            unavailableReason = "Agent 服务尚未配置。配置完成后才能登录和授权。"
            return
        }
        guard rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
              var parts = URLComponents(string: rawValue), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, ["", "/"].contains(parts.path) else {
            baseURL = nil
            unavailableReason = "Agent 服务地址无效，请使用不含账户、路径、查询参数或片段的 HTTPS 地址。"
            return
        }
        parts.scheme = "https"
        parts.host = host.lowercased()
        parts.path = ""
        baseURL = parts.url
        #if targetEnvironment(simulator)
        unavailableReason = "模拟器不连接真实 Agent 服务。请在已配置的 iPhone 上使用。"
        #else
        unavailableReason = parts.url == nil ? "Agent 服务地址无效。" : nil
        #endif
    }
}

enum AgentGatewayError: LocalizedError, Equatable {
    case unavailable, invalidResponse, invalidRequest, unauthorized, accountChanged, scopeUnavailable
    case noEligibleRecordings, noCachedRecordings, cacheDeleted, challengeExpired, authorizationExpired
    case keychain, cancelled, http(Int, String), transport

    var errorDescription: String? {
        switch self {
        case .unavailable: return "Agent 服务尚未就绪。"
        case .invalidResponse: return "服务返回的信息无法核对，请稍后重试。"
        case .invalidRequest: return "请求内容无效，尚未提交。"
        case .unauthorized: return "登录已失效，请重新使用 Apple 登录。"
        case .accountChanged: return "iCloud 账户或服务地址发生变化，已停止操作，请使用原账户重新登录。"
        case .scopeUnavailable: return "请先把首批录音保存到 iCloud，再连接 Agent。"
        case .noEligibleRecordings: return "首批录音中还没有同时完成 iCloud 保存和有效转写的片段。"
        case .noCachedRecordings: return "请先同步转写，确认服务已缓存可授权的片段。"
        case .cacheDeleted: return "这段录音的服务缓存已删除，不能自动恢复原来的授权。手机和 iCloud 原录音仍保留。"
        case .challengeExpired: return "本次 Apple 登录准备已过期，请重新准备。"
        case .authorizationExpired: return "这次授权已过期，请从 Agent 重新发起连接。"
        case .keychain: return "无法安全保存或读取登录凭据，请解锁手机后重试。"
        case .cancelled: return "操作已停止。已完成的缓存和原始录音仍保留。"
        case .transport: return "暂时无法连接 Agent 服务，请检查网络后重试。"
        case .http(let status, let code):
            if status == 429 { return "尝试次数较多，请稍等一分钟再试。" }
            if status == 503 { return "Agent 服务配置尚未完成，请稍后重试。" }
            if status == 404 { return "没有找到有效的待授权请求，请检查代码或重新发起连接。" }
            if status == 409 { return "服务中的内容或授权状态已变化，请刷新后重试。" }
            if status == 413 { return "这段转写超过服务支持的大小，尚未缓存。" }
            if code == "scope_mismatch" { return "这次请求与账户或录音范围不一致，尚未授权。" }
            if code == "authorization_revoked" { return "这项 Agent 授权已撤销。" }
            return "服务未接受这次请求，请刷新后重试。"
        }
    }
}

enum AgentReadScope: String, Codable, CaseIterable, Sendable {
    case recordings = "recordings:read"
    case transcripts = "transcripts:read"
    var title: String { self == .recordings ? "录音时间、时长等信息" : "转写文字" }
}

struct AgentChallenge: Codable, Sendable {
    let challengeID: UUID
    let nonce: String
    let expiresAt: Date
}

struct AgentLoginResponse: Codable, Sendable {
    let ownerID: UUID
    let deviceToken: String
    let expiresAt: Date
    let cloudKitAccountFingerprint: String
}

struct AgentUploadRequest: Encodable, Sendable {
    struct CloudMetadata: Encodable, Sendable {
        let accountFingerprint: String
        let containerIdentifier: String
        let environment: String
        let recordName: String
        let savedAt: Date
    }
    let manifest: SegmentManifest
    let transcript: SegmentTranscript
    let clientReportedCloudKit: CloudMetadata
    let expectedRevision: Int?
}

struct AgentUploadResponse: Codable, Sendable {
    let recordingID: UUID
    let revision: Int
    let status: String
    let transcriptStatus: String
    let cachedAt: Date
    let cloudMetadataVerification: String
}

struct AgentRecordingRevision: Codable, Sendable {
    let recordingID: UUID
    let revision: Int
    let deleted: Bool
}

struct AgentAuthorizationRequest: Codable, Identifiable, Sendable {
    let authorizationID: UUID
    let clientID: String
    let clientName: String
    let clientURI: String?
    let clientDomain: String?
    let redirectHost: String
    let redirectIsLoopback: Bool
    let requestedScopes: [AgentReadScope]
    let expiresAt: Date
    var id: UUID { authorizationID }
}

struct AgentConnection: Codable, Identifiable, Sendable {
    let connectionID: UUID
    let clientID: String
    let clientName: String
    let recordingIDs: [UUID]
    let scopes: [AgentReadScope]
    let status: String
    let createdAt: Date
    let revokedAt: Date?
    var id: UUID { connectionID }
    var isActive: Bool { status == "active" }
}

protocol AgentGatewayServing: Sendable {
    var baseURL: URL? { get }
    var unavailableReason: String? { get }
    func challenge() async throws -> AgentChallenge
    func login(challengeID: UUID, identityToken: String, fingerprint: String) async throws -> AgentLoginResponse
    func upload(_ request: AgentUploadRequest, token: String) async throws -> AgentUploadResponse
    func revision(recordingID: UUID, token: String) async throws -> AgentRecordingRevision?
    func lookup(code: String, token: String) async throws -> AgentAuthorizationRequest
    func approve(authorizationID: UUID, recordingIDs: [UUID], scopes: [AgentReadScope], token: String) async throws -> AgentConnection
    func connections(token: String) async throws -> [AgentConnection]
    func revoke(connectionID: UUID, token: String) async throws -> AgentConnection
    func logout(token: String) async throws
}

/// No cookies, persistent HTTP cache, credentials, or redirect forwarding. Tokens
/// are attached to one configured origin on each request, never to URL parameters.
final class AgentGatewayClient: AgentGatewayServing, @unchecked Sendable {
    let baseURL: URL?
    let unavailableReason: String?
    private let session: URLSession
    private let redirectGuard: AgentRedirectGuard?

    init(configuration: AgentGatewayConfiguration = AgentGatewayConfiguration()) {
        baseURL = configuration.baseURL
        unavailableReason = configuration.unavailableReason
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 45
        let guardDelegate = AgentRedirectGuard()
        redirectGuard = guardDelegate
        session = URLSession(configuration: config, delegate: guardDelegate, delegateQueue: nil)
    }

    /// Synthetic URLProtocol sessions can exercise transport without enabling a
    /// simulator production bypass. The reserved host can never name the backend.
    init(syntheticProtocol: URLProtocol.Type) {
        baseURL = URL(string: "https://gateway.invalid")!
        unavailableReason = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [syntheticProtocol]
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let guardDelegate = AgentRedirectGuard()
        redirectGuard = guardDelegate
        session = URLSession(configuration: config, delegate: guardDelegate, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func challenge() async throws -> AgentChallenge {
        try await request("v1/auth/challenge", method: "POST", body: Empty())
    }

    func login(challengeID: UUID, identityToken: String, fingerprint: String) async throws -> AgentLoginResponse {
        struct Body: Encodable { let challengeID: UUID; let identityToken: String; let cloudKitAccountFingerprint: String }
        return try await request("v1/auth/apple", method: "POST",
            body: Body(challengeID: challengeID, identityToken: identityToken, cloudKitAccountFingerprint: fingerprint))
    }

    func upload(_ value: AgentUploadRequest, token: String) async throws -> AgentUploadResponse {
        try value.transcript.validate(against: value.manifest)
        return try await request("v1/recordings", method: "PUT", body: value, token: token)
    }

    func revision(recordingID: UUID, token: String) async throws -> AgentRecordingRevision? {
        do {
            return try await request("v1/recordings/" + recordingID.uuidString.lowercased() + "/revision",
                method: "GET", body: Optional<Empty>.none, token: token)
        } catch AgentGatewayError.http(404, "not_found") { return nil }
    }

    func lookup(code: String, token: String) async throws -> AgentAuthorizationRequest {
        struct Body: Encodable { let code: String }
        return try await request("v1/authorizations/lookup", method: "POST", body: Body(code: code), token: token)
    }

    func approve(authorizationID: UUID, recordingIDs: [UUID], scopes: [AgentReadScope], token: String) async throws -> AgentConnection {
        struct Body: Encodable { let authorizationID: UUID; let recordingIDs: [UUID]; let scopes: [AgentReadScope] }
        return try await request("v1/authorizations/approve", method: "POST",
            body: Body(authorizationID: authorizationID, recordingIDs: recordingIDs, scopes: scopes), token: token)
    }

    func connections(token: String) async throws -> [AgentConnection] {
        struct Envelope: Decodable { let connections: [AgentConnection] }
        let result: Envelope = try await request("v1/authorizations", method: "GET", body: Optional<Empty>.none, token: token)
        return result.connections
    }

    func revoke(connectionID: UUID, token: String) async throws -> AgentConnection {
        struct Body: Encodable { let connectionID: UUID }
        return try await request("v1/authorizations/revoke", method: "POST", body: Body(connectionID: connectionID), token: token)
    }

    func logout(token: String) async throws {
        struct Result: Decodable { let status: String }
        let result: Result = try await request("v1/auth/logout", method: "POST", body: Empty(), token: token)
        guard result.status == "revoked" else { throw AgentGatewayError.invalidResponse }
    }

    private struct Empty: Encodable {}
    private struct FailureEnvelope: Decodable {
        struct Failure: Decodable { let code: String }
        let error: Failure
    }

    private func request<Body: Encodable, Result: Decodable>(_ path: String, method: String,
        body: Body?, token: String? = nil) async throws -> Result {
        guard unavailableReason == nil, let baseURL else { throw AgentGatewayError.unavailable }
        try Task.checkCancellation()
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            let data = try TransportCodec.encode(body)
            guard data.count <= 1_024 * 1_024 else { throw AgentGatewayError.invalidRequest }
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token {
            guard token.utf8.count == 43,
                  token.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else {
                throw AgentGatewayError.unauthorized
            }
            request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse, response.url == url, data.count <= 2 * 1_024 * 1_024 else {
                throw AgentGatewayError.invalidResponse
            }
            if response.statusCode == 401 { throw AgentGatewayError.unauthorized }
            guard (200...299).contains(response.statusCode) else {
                let code = (try? JSONDecoder().decode(FailureEnvelope.self, from: data).error.code) ?? "unknown"
                throw AgentGatewayError.http(response.statusCode, code)
            }
            do { return try TransportCodec.decode(Result.self, from: data) }
            catch { throw AgentGatewayError.invalidResponse }
        } catch let error as AgentGatewayError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch let error as URLError where error.code == .cancelled { throw CancellationError() }
        catch { throw AgentGatewayError.transport }
    }
}

private final class AgentRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct AgentDeviceSession: Codable, Sendable {
    let ownerID: UUID
    let deviceToken: String
    let expiresAt: Date
    let endpoint: String
    let cloudKitAccountFingerprint: String
}

@MainActor
protocol AgentSessionVault {
    func load() throws -> AgentDeviceSession?
    func save(_ session: AgentDeviceSession) throws
    func clear() throws
}

/// Device-only and explicitly non-synchronizable. No credential enters defaults,
/// Info.plist, the pasteboard, a log, a URL, or the app's ordinary data directory.
@MainActor
final class AgentKeychainSessionVault: AgentSessionVault {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "RecordForAgent") + ".agent-device-session",
         kSecAttrAccount as String: "current-device", kSecAttrSynchronizable as String: false]
    }

    func load() throws -> AgentDeviceSession? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw AgentGatewayError.keychain }
        do { return try TransportCodec.decode(AgentDeviceSession.self, from: data) }
        catch { try clear(); throw AgentGatewayError.unauthorized }
    }

    func save(_ session: AgentDeviceSession) throws {
        let data = try TransportCodec.encode(session)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            var request = query
            attributes.forEach { request[$0.key] = $0.value }
            guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else { throw AgentGatewayError.keychain }
        } else if result != errSecSuccess { throw AgentGatewayError.keychain }
    }

    func clear() throws {
        let result = SecItemDelete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw AgentGatewayError.keychain }
    }
}
