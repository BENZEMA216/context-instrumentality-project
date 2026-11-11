import Foundation
import RecordingCore
#if canImport(UIKit)
import AuthenticationServices
import CryptoKit
import Security
import UIKit
#endif

struct GoogleDriveCredential: Codable, Sendable {
    let clientID: String
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    var accountID: String?
    // Missing in the original Keychain record. A retained revocation token is
    // never an upload identity, including after a cold launch.
    var revocationOnly: Bool? = nil
    var permitsAccessToken: Bool { revocationOnly != true }
}

/// The coordinator owns the durable stop intent. It can deny token access
/// before any fallible ledger/Keychain operation and restore that denial on
/// launch, without deleting the credential needed to retry remote revocation.
@MainActor
protocol GoogleDriveAuthorization: GoogleDriveTokenProvider {
    var configuration: GoogleDriveOAuthConfiguration? { get }
    var hasCredential: Bool { get }
    var hasRevocationCredential: Bool { get }
    func authorize() async throws -> GoogleDriveCredential
    func commit(_ value: GoogleDriveCredential, accountID: String) throws
    func revoke() async throws -> Bool
    func suspendUploadAccess()
    func resumeUploadAccessAfterAuthorization()
}

/// The production revoke transaction, exercised with synthetic storage and HTTP.
/// A failed POST retains its exact token for a later, explicit revoke attempt.
@MainActor
enum GoogleDriveCredentialRevocation {
    static func revoke(current: GoogleDriveCredential?, http: GoogleDriveHTTP,
        persist: (GoogleDriveCredential) throws -> Void, remove: () throws -> Void,
        check: () throws -> Void) async throws -> Bool {
        guard var current else { return false }
        try Task.checkCancellation()
        try check()
        current.revocationOnly = true
        try persist(current)
        try check()
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
        request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = GoogleDriveHTTP.form(["token": current.refreshToken])
        let (_, response) = try await http.send(request)
        try Task.checkCancellation()
        try check()
        guard response.statusCode == 200 else { return false }
        try remove()
        return true
    }
}

/// The same exchange is used by native OAuth and the isolated HTTP probe. It
/// never reads the Keychain, opens login UI, or logs a token/error response body.
enum GoogleDriveOAuthExchange {
    static func exchange(http: GoogleDriveHTTP, clientID: String, values: [String: String],
                         previous: GoogleDriveCredential?, timeout: TimeInterval? = nil) async throws -> GoogleDriveCredential {
        struct Response: Decodable { let access_token: String; let refresh_token: String?; let expires_in: Double; let token_type: String; let scope: String? }
        struct Failure: Decodable { let error: String }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        // Both grants share the original 30-second exchange budget. Only a
        // refresh grant reserves time for an idle-timeout retry; a one-use
        // authorization code keeps the full timeout and must never replay.
        request.timeoutInterval = 30
        request.httpMethod = "POST"; request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = GoogleDriveHTTP.form(values)
        let (data, response) = try await http.send(request, timeout: timeout)
        if response.statusCode == 401 || (response.statusCode == 400
            && (try? JSONDecoder().decode(Failure.self, from: data))?.error == "invalid_grant") {
            throw GoogleDriveError.needsSignIn
        }
        guard response.statusCode == 200 else { throw GoogleDriveError.http(response.statusCode) }
        let result = try JSONDecoder().decode(Response.self, from: data)
        guard result.token_type.caseInsensitiveCompare("Bearer") == .orderedSame,
              !result.access_token.isEmpty, result.access_token.utf8.count <= 16_384,
              result.expires_in.isFinite, (60...86_400).contains(result.expires_in),
              let refresh = result.refresh_token ?? previous?.refreshToken, !refresh.isEmpty, refresh.utf8.count <= 16_384,
              result.scope.map({ Set($0.split(separator: " ").map(String.init)) == [GoogleDriveOAuthConfiguration.scope] }) ?? (previous != nil)
        else { throw GoogleDriveError.invalidResponse }
        return .init(clientID: clientID, accessToken: result.access_token, refreshToken: refresh,
                     expiresAt: Date(timeIntervalSinceNow: result.expires_in), accountID: previous?.accountID)
    }
}

/// A completed refresh belongs to the credential, not to a cancelled upload
/// waiter. Coalesce concurrent callers. `exchange` still issues one `send`;
/// that send may retry the same refresh-token POST once after a natural
/// timeout inside the original budget. Authorization codes, revoke, uploads,
/// and TLS faults are not retried.
/// Revoke/commit invalidates a result before anything can be written to the Keychain.
@MainActor
final class GoogleDriveCredentialRefresh {
    private var flight: (id: UUID, task: Task<GoogleDriveCredential, Error>)?
    func value(operation: @escaping @MainActor () async throws -> GoogleDriveCredential) async throws -> GoogleDriveCredential {
        let current: (id: UUID, task: Task<GoogleDriveCredential, Error>)
        if let flight { current = flight }
        else {
            // Freeze the initiating upload before creating the shared task.
            // Later waiters never relabel the in-flight request. Refreshes
            // initiated outside an upload are explicitly shared.
            let correlation = GoogleDriveUploadTrace.current ?? .shared
            current = (UUID(), Task { @MainActor in
                try await GoogleDriveUploadTrace.$current.withValue(correlation) { try await operation() }
            })
            flight = current
        }
        defer { if flight?.id == current.id { flight = nil } }
        do {
            let value = try await current.task.value
            try Task.checkCancellation()
            return value
        } catch {
            // A failed credential exchange must not turn a cancelled upload
            // waiter back into a live network operation either.
            try Task.checkCancellation()
            throw error
        }
    }
    /// Shared production refresh boundary, also exercised without Keychain by
    /// the offline integration probe. A cancelled/expired upload waiter cannot
    /// cancel another waiter's credential exchange or discard its safe commit.
    /// The exchange retains its original finite HTTP budget; the client rechecks
    /// its own (possibly shortened) lease before any account/file request.
    func accessToken(current: GoogleDriveCredential, accountID: String, http: GoogleDriveHTTP,
                     timeout: TimeInterval?, isCurrent: @escaping @MainActor () -> Bool,
                     commit: @escaping @MainActor (GoogleDriveCredential) throws -> Void) async throws -> String {
        try Task.checkCancellation()
        guard current.permitsAccessToken, current.accountID == accountID else { throw GoogleDriveError.needsSignIn }
        if current.expiresAt.timeIntervalSinceNow > 60 { return current.accessToken }
        let next = try await value {
            let next = try await GoogleDriveOAuthExchange.exchange(http: http, clientID: current.clientID,
                values: ["client_id": current.clientID, "refresh_token": current.refreshToken, "grant_type": "refresh_token"],
                previous: current, timeout: timeout)
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            try commit(next)
            return next
        }
        return next.accessToken
    }
    func invalidate() { flight?.task.cancel(); flight = nil }
}

#if canImport(UIKit)
@MainActor
final class GoogleDriveOAuth: NSObject, ASWebAuthenticationPresentationContextProviding, GoogleDriveAuthorization {
    let configuration: GoogleDriveOAuthConfiguration?
    private let http: GoogleDriveHTTP
    private var authentication: ASWebAuthenticationSession?
    private var credential: GoogleDriveCredential?
    private var loaded = false
    private var revision: UInt64 = 0
    private var uploadAccessAllowed = true
    private let refresh = GoogleDriveCredentialRefresh()
    private let service = (Bundle.main.bundleIdentifier ?? "RecordForAgent") + ".google-drive"
    init(http: GoogleDriveHTTP, bundle: Bundle = .main) {
        self.http = http
        let schemes = (bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? [])
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        configuration = try? GoogleDriveOAuthConfiguration(
            clientID: bundle.object(forInfoDictionaryKey: "WRGoogleDriveOAuthClientID") as? String ?? "",
            reversedClientID: bundle.object(forInfoDictionaryKey: "WRGoogleDriveReversedClientID") as? String ?? "",
            registeredBundleID: bundle.object(forInfoDictionaryKey: "WRGoogleDriveOAuthRegisteredBundleID") as? String ?? "",
            actualBundleID: bundle.bundleIdentifier ?? "", registeredSchemes: schemes)
        super.init()
    }
    var hasCredential: Bool { uploadAccessAllowed && (try? load())?.permitsAccessToken == true }
    func suspendUploadAccess() {
        uploadAccessAllowed = false; revision &+= 1; refresh.invalidate()
    }
    func resumeUploadAccessAfterAuthorization() { uploadAccessAllowed = true }
    // The ledger supplies the pending-revoke gate. A previous Keychain write
    // failure may leave a legacy active record on disk; it is still a valid
    // source for retrying revoke, never permission to resume that paused grant.
    var hasRevocationCredential: Bool { (try? load()) != nil }
    func authorize() async throws -> GoogleDriveCredential {
        guard let config = configuration, authentication == nil else { throw GoogleDriveError.unavailable }
        let verifier = try Self.random(), state = try Self.random()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let url = try config.authorizationURL(state: state, challenge: challenge)
        let callback: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: config.reversedClientID) { [weak self] callback, error in
                    Task { @MainActor in
                        self?.authentication = nil
                        if let callback { continuation.resume(returning: callback) }
                        else { continuation.resume(throwing: error == nil ? GoogleDriveError.invalidResponse : GoogleDriveError.cancelled) }
                    }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = true
                authentication = session
                if !session.start() { authentication = nil; continuation.resume(throwing: GoogleDriveError.unavailable) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.authentication?.cancel() } }
        try Task.checkCancellation()
        let code = try config.authorizationCode(from: callback, expectedState: state)
        return try await exchange(["client_id": config.clientID, "code": code, "code_verifier": verifier,
            "redirect_uri": config.redirectURI, "grant_type": "authorization_code"], previous: nil)
    }
    func commit(_ value: GoogleDriveCredential, accountID: String) throws {
        guard value.clientID == configuration?.clientID, value.permitsAccessToken else { throw GoogleDriveError.credentials }
        var bound = value; bound.accountID = accountID
        try write(bound); credential = bound; loaded = true; revision &+= 1
        refresh.invalidate()
    }
    func accessToken(for accountID: String) async throws -> String {
        try await accessToken(for: accountID, timeout: nil)
    }
    func accessToken(for accountID: String, timeout: TimeInterval?) async throws -> String {
        guard uploadAccessAllowed, let current = try load(), current.permitsAccessToken, current.accountID == accountID else { throw GoogleDriveError.needsSignIn }
        let observedRevision = revision
        return try await refresh.accessToken(current: current, accountID: accountID, http: http, timeout: timeout,
            isCurrent: { [self] in revision == observedRevision },
            commit: { [self] next in try write(next); credential = next })
    }
    /// Removes upload access first, retaining a revocation-only Keychain record
    /// until Google confirms. A late old response cannot delete a newer login.
    func revoke() async throws -> Bool {
        suspendUploadAccess()
        let current = try load()
        revision &+= 1
        let observedRevision = revision
        refresh.invalidate()
        authentication?.cancel(); authentication = nil
        return try await GoogleDriveCredentialRevocation.revoke(current: current, http: http,
            persist: { [self] value in
                // Also fence this process if Keychain persistence is unavailable;
                // the separately paused ledger prevents cold-launch upload work.
                credential = value; loaded = true
                try write(value)
            }, remove: { [self] in
                try delete(); credential = nil; loaded = true
            }, check: { [self] in
                guard revision == observedRevision else { throw CancellationError() }
            })
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
    private func exchange(_ values: [String: String], previous: GoogleDriveCredential?, timeout: TimeInterval? = nil) async throws -> GoogleDriveCredential {
        guard let configuration else { throw GoogleDriveError.unavailable }
        return try await GoogleDriveOAuthExchange.exchange(http: http, clientID: configuration.clientID,
            values: values, previous: previous, timeout: timeout)
    }
    private func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "native-oauth-v1", kSecAttrSynchronizable as String: false]
    }
    private func load() throws -> GoogleDriveCredential? {
        guard configuration != nil else { return nil }
        if loaded { return credential }
        var q = query(); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let result = SecItemCopyMatching(q as CFDictionary, &value)
        if result == errSecItemNotFound { loaded = true; return nil }
        guard result == errSecSuccess, let data = value as? Data, data.count <= 65_536 else { throw GoogleDriveError.credentials }
        let decoded = try TransportCodec.decode(GoogleDriveCredential.self, from: data)
        guard decoded.clientID == configuration?.clientID, !decoded.refreshToken.isEmpty,
              !decoded.accessToken.isEmpty, decoded.accountID != nil else { throw GoogleDriveError.credentials }
        credential = decoded; loaded = true; return decoded
    }
    private func write(_ value: GoogleDriveCredential) throws {
        let data = try TransportCodec.encode(value)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let result = SecItemUpdate(query() as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            var q = query(); attributes.forEach { q[$0.key] = $0.value }
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw GoogleDriveError.credentials }
        } else if result != errSecSuccess { throw GoogleDriveError.credentials }
    }
    private func delete() throws {
        let result = SecItemDelete(query() as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw GoogleDriveError.credentials }
    }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw GoogleDriveError.credentials }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
#endif
