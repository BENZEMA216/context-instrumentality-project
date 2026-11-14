import Foundation
import Darwin
import RecordingCore

/// Upload identity is carried in task context, never in HTTP headers or URLs.
/// Every transport snapshots it before awaiting; delegate callbacks receive the
/// snapshot explicitly because URLSession does not preserve Swift task locals.
enum GoogleDriveUploadTrace {
    @TaskLocal static var current: GoogleDriveUploadCorrelation?
}

extension GoogleDriveUploadCorrelation {
    var logFields: String {
        guard isValid else { return "upload_scope=none upload_job_key=none upload_kind=none" }
        return "upload_scope=\(scope.rawValue) upload_job_key=\(jobKey ?? "none") upload_kind=\(kind?.rawValue ?? "none")"
    }
}

/// Errors intentionally contain no tokens, authorization URLs or server bodies.
enum GoogleDriveError: LocalizedError, Equatable {
    case unavailable, cancelled, credentials, needsSignIn, invalidResponse, http(Int), expiredSession, invalidResumableOffset, interrupted
    case apiFailure(Int, GoogleDriveAPIReason)
    static func response(status: Int, data: Data) -> Self {
        GoogleDriveAPIReason.parse(status: status, data: data).map { .apiFailure(status, $0) } ?? .http(status)
    }
    var errorDescription: String? {
        switch self {
        case .unavailable: return "此版本尚未配置有效的 Google iOS 登录信息，暂时无法连接。"
        case .cancelled: return "已取消 Google 登录，未启用云盘同步。"
        case .credentials: return "无法安全保存 Google 凭据，请解锁手机后重试。"
        case .needsSignIn: return "Google 授权已失效，请重新连接原账户。"
        case .invalidResponse: return "Google 返回的信息未通过核对，未继续上传。"
        case .http(let code): return "Google Drive 暂未完成操作（HTTP \(code)）。原录音仍保留，可稍后重试。"
        case .apiFailure(_, let reason): return reason.explanation
        case .expiredSession: return "上传会话已过期，将使用原文件编号重新尝试。"
        case .invalidResumableOffset: return "上传进度未通过核对，已保留会话，可稍后重试。"
        case .interrupted: return "本次同步时间已结束，队列和上传进度已保留。"
        }
    }
}

/// All API requests use this session. Redirects are rejected before a credential
/// can be forwarded; only exact official Google endpoints are allowed.
final class GoogleDriveHTTP: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    typealias RecoveryBudget = @MainActor @Sendable () throws -> TimeInterval
    private var session: URLSession!
    private var recoveryConfiguration: URLSessionConfiguration!
    private let networkSettings: GoogleDriveNetworkSettings
    private let diagnosticLock = NSLock()
    private var transportDiagnosticHandler: (@Sendable (GoogleDriveTransportDiagnostic) -> Void)?
    private var requestCompletionHandler: (@Sendable (GoogleDriveRequestCompletion) -> Void)?
#if DEBUG
    /// A probe observes only diagnostics emitted by its own async task. The
    /// normal history handler remains installed, including for other requests.
    @TaskLocal static var debugDiagnosticObserver: (@Sendable (GoogleDriveTransportDiagnostic) -> Void)?
    private enum DebugClosedNoNotifyState { case disabled, armed, consumed }
    private let debugFaultLock = NSLock()
    private var debugClosedNoNotifyState = DebugClosedNoNotifyState.disabled

    /// Arm only an explicitly selected probe instance. Once consumed, this
    /// instance cannot be rearmed, even if callers repeat this method.
    func debugInjectClosedNoNotifyOnce() {
        debugFaultLock.lock(); defer { debugFaultLock.unlock() }
        if case .disabled = debugClosedNoNotifyState { debugClosedNoNotifyState = .armed }
    }
    var debugClosedNoNotifyInjectionCount: Int {
        debugFaultLock.lock(); defer { debugFaultLock.unlock() }
        if case .consumed = debugClosedNoNotifyState { return 1 }
        return 0
    }
    private func debugTakeClosedNoNotify(for request: URLRequest) -> NSError? {
        guard request.httpMethod == "GET", request.httpBody == nil, request.httpBodyStream == nil,
              let url = request.url, Self.allows(url),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.host == "www.googleapis.com", parts.path == "/drive/v3/about",
              let query = parts.queryItems, query.count == 1, query[0].name == "fields",
              let fields = query[0].value, !fields.isEmpty else { return nil }
        debugFaultLock.lock()
        guard case .armed = debugClosedNoNotifyState else { debugFaultLock.unlock(); return nil }
        debugClosedNoNotifyState = .consumed
        debugFaultLock.unlock()
        // This is deliberately synthetic. The probe must label its independent
        // report controlled_fault; the following recovery still uses real send.
        let underlying = NSError(domain: "kCFErrorDomainCFNetwork", code: NSURLErrorSecureConnectionFailed,
            userInfo: ["_kCFStreamErrorDomainKey": 3, "_kCFStreamErrorCodeKey": -9816])
        return NSError(domain: NSURLErrorDomain, code: NSURLErrorSecureConnectionFailed,
            userInfo: [NSUnderlyingErrorKey: underlying, "_kCFStreamErrorDomainKey": 3, "_kCFStreamErrorCodeKey": -9816])
    }
#endif
    init(configuration: URLSessionConfiguration = .ephemeral,
         networkSettings: GoogleDriveNetworkSettings = .shared) {
        self.networkSettings = networkSettings
        super.init()
        let config = configuration
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil; config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 60
        // The immutable session must permit both choices. Every request below
        // explicitly captures the user's choice, including token and recovery.
        config.allowsCellularAccess = true
        recoveryConfiguration = config.copy() as? URLSessionConfiguration
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }
    func setTransportDiagnosticHandler(_ handler: @escaping @Sendable (GoogleDriveTransportDiagnostic) -> Void) {
        diagnosticLock.lock(); transportDiagnosticHandler = handler; diagnosticLock.unlock()
    }
    func setRequestCompletionHandler(_ handler: @escaping @Sendable (GoogleDriveRequestCompletion) -> Void) {
        diagnosticLock.lock(); requestCompletionHandler = handler; diagnosticLock.unlock()
    }
    private func finish(_ value: GoogleDriveRequestCompletion) {
        diagnosticLock.lock(); let handler = requestCompletionHandler; diagnosticLock.unlock()
        handler?(value)
    }
    private func report(_ value: GoogleDriveTransportDiagnostic) {
        diagnosticLock.lock(); let handler = transportDiagnosticHandler; diagnosticLock.unlock()
        handler?(value)
#if DEBUG
        Self.debugDiagnosticObserver?(value)
#endif
    }
    static func allows(_ url: URL) -> Bool {
        guard let p = URLComponents(url: url, resolvingAgainstBaseURL: false), p.scheme == "https",
              p.port == nil, p.user == nil, p.password == nil, p.fragment == nil else { return false }
        if p.host == "oauth2.googleapis.com" { return ["/token", "/revoke"].contains(p.path) && p.query == nil }
        if p.host == "www.googleapis.com" {
            return p.path == "/drive/v3/about" || p.path == "/drive/v3/files/generateIds"
                || p.path == "/drive/v3/files" || (p.path.hasPrefix("/drive/v3/files/") && GoogleDriveLibraryLedger.validFileID(String(p.path.dropFirst("/drive/v3/files/".count))))
                || GoogleDriveLibraryLedger.validUploadURL(url.absoluteString)
        }
        return false
    }
    func send(_ original: URLRequest, timeout: TimeInterval? = nil,
              recoveryBudget: RecoveryBudget? = nil,
              acceptsMissingMetadata: Bool = false) async throws -> (Data, HTTPURLResponse) {
        let requestID = UUID()
        let uploadCorrelation = GoogleDriveUploadTrace.current
        var origin = GoogleDriveTransportDiagnostic.Origin.natural
        var attemptCount = 0
        var outcome = GoogleDriveRequestCompletion.Outcome.invalidResponse
        defer { finish(.init(requestID: requestID, origin: origin, attemptCount: attemptCount, outcome: outcome,
                             uploadCorrelation: uploadCorrelation)) }
        if Task.isCancelled { outcome = .cancelled }
        try Task.checkCancellation()
        let startedAt = ProcessInfo.processInfo.systemUptime
        var request = original
        request.allowsCellularAccess = networkSettings.allowsCellularAccess
        let path = Self.recoveryPath(for: request)
        if let timeout {
            guard timeout.isFinite, timeout > 0 else { outcome = .budgetExpired; throw CancellationError() }
            request.timeoutInterval = min(30, timeout)
        }
        guard let url = request.url, Self.allows(url) else { throw GoogleDriveError.invalidResponse }
        // A retry shares the original request's finite budget. It cannot renew
        // a background execution lease or extend the caller's timeout.
        // Eligible refresh-token and metadata calls reserve time for recovery
        // after an idle timeout. Authorization codes are ineligible and retain
        // the full caller timeout because they may already have been consumed.
        let budget = min(30, timeout ?? request.timeoutInterval)
        if GoogleDriveRecoveryDecision.reservesRetry(path) {
            request.timeoutInterval = GoogleDriveRecoveryDecision.firstAttemptTimeout(budget: budget, path: path)
        }
        do {
            attemptCount = 1
#if DEBUG
            try Task.checkCancellation()
            if let injected = debugTakeClosedNoNotify(for: request) {
                origin = .controlledFault
                report(.capture(error: injected, request: request, phase: .apiRequest, requestID: requestID, origin: origin,
                                uploadCorrelation: uploadCorrelation))
                throw injected
            }
#endif
            let result = try await perform(request, session: session, phase: .apiRequest, requestID: requestID, origin: origin,
                                           uploadCorrelation: uploadCorrelation)
            outcome = (200...299).contains(result.1.statusCode) ? .succeeded : .httpFailure
            return result
        }
        catch {
            if Task.isCancelled { outcome = .cancelled }
            try Task.checkCancellation()
            if (error as NSError).domain == NSURLErrorDomain, (error as NSError).code == NSURLErrorCancelled {
                outcome = .cancelled; throw error
            }
            var remaining = budget - (ProcessInfo.processInfo.systemUptime - startedAt)
            // A foreground lease can shorten while the first await is pending.
            // Its synchronous expiry flag is authoritative even before the
            // main-actor cancellation callback has reached this Swift task.
            guard Self.recoveryTimeout(for: request, error: error, remaining: remaining) != nil else {
                outcome = (!remaining.isFinite || remaining < 1) ? .budgetExpired : .notEligible
                throw error
            }
            if let recoveryBudget {
                let checkStartedAt = ProcessInfo.processInfo.systemUptime
                let currentRemaining: TimeInterval
                do { currentRemaining = try await recoveryBudget() }
                catch { outcome = Task.isCancelled ? .cancelled : .callerBudgetRejected; throw error }
                if Task.isCancelled { outcome = .cancelled }
                try Task.checkCancellation()
                let checkedAt = ProcessInfo.processInfo.systemUptime
                guard currentRemaining.isFinite, currentRemaining > 0 else { outcome = .budgetExpired; throw CancellationError() }
                // Conservatively charge the whole actor hop to the returned
                // current lease budget, as well as the original request budget.
                remaining = min(budget - (checkedAt - startedAt), currentRemaining - (checkedAt - checkStartedAt))
            }
            guard let retryTimeout = Self.recoveryTimeout(for: request, error: error, remaining: remaining) else {
                outcome = .budgetExpired; throw error
            }
            guard let config = recoveryConfiguration.copy() as? URLSessionConfiguration else {
                outcome = .notEligible; throw error
            }
            var retryRequest = request
            retryRequest.timeoutInterval = retryTimeout
            config.timeoutIntervalForRequest = retryTimeout
            config.timeoutIntervalForResource = retryTimeout
            // Preserve system trust, the captured network policy, exact endpoints and redirect refusal.
            // A separate session drops this API session's pooled connection;
            // metrics, rather than this allocation, prove a fresh handshake.
            if Task.isCancelled { outcome = .cancelled }
            try Task.checkCancellation()
            let recovery = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            defer { recovery.finishTasksAndInvalidate() }
            attemptCount = 2
            do {
                let result = try await perform(retryRequest, session: recovery, phase: .apiRecovery, requestID: requestID, origin: origin,
                                               uploadCorrelation: uploadCorrelation)
                let second = GoogleDriveRecoveryDecision.secondAttempt(result.1.statusCode, path: path,
                    callerAcceptsMissingFile: acceptsMissingMetadata)
                outcome = second == .recovered ? .recovered : .httpFailure
                return result
            } catch {
                let cancelled = (error as NSError).domain == NSURLErrorDomain && (error as NSError).code == NSURLErrorCancelled
                outcome = Task.isCancelled || error is CancellationError || cancelled ? .cancelled : .recoveryFailed
                throw error
            }
        }
    }
    /// ClosedNoNotify metadata GETs, and natural timeouts of those GETs or the
    /// refresh-token POST, may retry once inside the same request budget.
    /// Authorization codes, uploads, revoke, certificates and other TLS errors
    /// never replay. A different request's success is never this request's recovery.
    static func recoveryTimeout(for request: URLRequest, error: Error, remaining: TimeInterval) -> TimeInterval? {
        let fault: GoogleDriveRecoveryDecision.Fault
        if isClosedNoNotify(error) { fault = .closedNoNotify }
        else if isNaturalTimeout(error) { fault = .naturalTimeout }
        else { fault = .other }
        return GoogleDriveRecoveryDecision.retryAllowance(path: recoveryPath(for: request), fault: fault, remaining: remaining)
    }
    static func recoveryPath(for request: URLRequest) -> GoogleDriveRecoveryDecision.Path {
        guard let url = request.url, allows(url),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return .other }
        if parts.host == "oauth2.googleapis.com", parts.path == "/token", parts.query == nil,
           request.httpMethod == "POST", request.httpBodyStream == nil,
           let body = request.httpBody, (1...65_536).contains(body.count),
           isRefreshTokenForm(body, contentType: request.value(forHTTPHeaderField: "Content-Type")) {
            return .tokenPOST
        }
        guard request.httpMethod == "GET", request.httpBody == nil, request.httpBodyStream == nil,
              parts.host == "www.googleapis.com", parts.path != "/drive/v3/files/generateIds",
              let query = parts.queryItems, query.count == 1, query[0].name == "fields",
              let fields = query[0].value, !fields.isEmpty else { return .other }
        if parts.path == "/drive/v3/about" { return .aboutGET }
        if parts.path.hasPrefix("/drive/v3/files/"),
           GoogleDriveLibraryLedger.validFileID(String(parts.path.dropFirst("/drive/v3/files/".count))) {
            return .fileMetadataGET
        }
        return .other
    }
    /// Fail closed on ambiguous or malformed forms. In particular, deciding
    /// from the first grant_type alone could replay a one-use authorization
    /// code if the server selected a different occurrence of the same key.
    private static func isRefreshTokenForm(_ body: Data, contentType: String?) -> Bool {
        guard let contentType else { return false }
        let type = contentType.split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .init(charactersIn: " \t")).lowercased() }
        guard type.first == "application/x-www-form-urlencoded", type.count <= 2 else { return false }
        if type.count == 2 {
            let charset = type[1].split(separator: "=", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .init(charactersIn: " \t")) }
            guard charset.count == 2, charset[0] == "charset",
                  ["utf-8", "\"utf-8\""].contains(charset[1]) else { return false }
        }
        guard let form = String(data: body, encoding: .utf8) else { return false }
        var grant: String?
        for pair in form.split(separator: "&", omittingEmptySubsequences: false) {
            guard let equals = pair.firstIndex(of: "="),
                  let name = decodeFormComponent(pair[..<equals]), !name.isEmpty,
                  let value = decodeFormComponent(pair[pair.index(after: equals)...]) else { return false }
            if name == "grant_type" {
                guard grant == nil else { return false }
                grant = value
            }
        }
        return grant == "refresh_token"
    }
    private static func decodeFormComponent(_ component: Substring) -> String? {
        // Foundation's percent decoder rejects incomplete escapes and invalid
        // UTF-8. Decode '+' first: an escaped %2B must remain a literal plus.
        guard let value = String(component).replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
    }
    private static func isClosedNoNotify(_ error: Error) -> Bool {
        let first = error as NSError
        guard first.domain == NSURLErrorDomain, first.code == NSURLErrorSecureConnectionFailed else { return false }
        var current: NSError? = first, seen = Set<ObjectIdentifier>(), depth = 0, closedWithoutNotify = false
        while let value = current {
            guard depth < 4, seen.insert(ObjectIdentifier(value)).inserted,
                  [NSURLErrorDomain, "kCFErrorDomainCFNetwork"].contains(value.domain),
                  value.code == NSURLErrorSecureConnectionFailed else { return false }
            let domain = value.userInfo["_kCFStreamErrorDomainKey"] as? Int
            let code = value.userInfo["_kCFStreamErrorCodeKey"] as? Int
            guard value.userInfo["_kCFStreamErrorDomainKey"] == nil || domain != nil,
                  value.userInfo["_kCFStreamErrorCodeKey"] == nil || code != nil else { return false }
            if domain != nil || code != nil {
                guard domain == 3, code == -9816 else { return false }
                closedWithoutNotify = true
            }
            let underlying = value.userInfo[NSUnderlyingErrorKey]
            guard underlying == nil || underlying is NSError else { return false }
            current = underlying as? NSError
            depth += 1
        }
        return closedWithoutNotify
    }
    // The worker shares this conservative classification when deciding whether
    // a failed request may leave time for local metadata work. That local work
    // neither retries the request nor changes its recorded transport outcome.
    static func isNaturalTimeout(_ error: Error) -> Bool {
        let first = error as NSError
        guard first.domain == NSURLErrorDomain, first.code == NSURLErrorTimedOut else { return false }
        var current: NSError? = first, seen = Set<ObjectIdentifier>(), depth = 0
        let certificates = [NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
            NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
            NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired]
        while let value = current {
            guard depth < 4, seen.insert(ObjectIdentifier(value)).inserted else { return false }
            if value.domain == "kCFErrorDomainSSL" || value.code == NSURLErrorSecureConnectionFailed { return false }
            if certificates.contains(value.code), value.domain == NSURLErrorDomain { return false }
            if let domain = value.userInfo["_kCFStreamErrorDomainKey"] {
                guard let domain = domain as? Int, domain != 3 else { return false }
            }
            if value.userInfo["_kCFStreamErrorCodeKey"] != nil, !(value.userInfo["_kCFStreamErrorCodeKey"] is Int) { return false }
            let allowed = (value.domain == NSURLErrorDomain && value.code == NSURLErrorTimedOut)
                || (value.domain == "kCFErrorDomainCFNetwork" && value.code == NSURLErrorTimedOut)
                || (value.domain == NSPOSIXErrorDomain && value.code == Int(ETIMEDOUT))
            guard allowed else { return false }
            let underlying = value.userInfo[NSUnderlyingErrorKey]
            guard underlying == nil || underlying is NSError else { return false }
            current = underlying as? NSError
            depth += 1
        }
        return true
    }
    private func perform(_ request: URLRequest, session: URLSession,
                         phase: GoogleDriveTransportDiagnostic.Phase, requestID: UUID,
                         origin: GoogleDriveTransportDiagnostic.Origin,
                         uploadCorrelation: GoogleDriveUploadCorrelation?) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        guard let url = request.url, Self.allows(url) else { throw GoogleDriveError.invalidResponse }
        let observation = GoogleDriveRequestObservation()
        let result: (Data, URLResponse)
        do { result = try await session.data(for: request, delegate: observation) }
        catch {
            // URLSession may report NSURLErrorCancelled instead of Swift's
            // CancellationError. Preserve real network errors on a live task.
            try Task.checkCancellation()
            report(.capture(error: error, request: request, phase: phase, metrics: observation.snapshot, requestID: requestID, origin: origin,
                            uploadCorrelation: uploadCorrelation))
            throw error
        }
        try Task.checkCancellation()
        let (data, response) = result
        var diagnostic = GoogleDriveTransportDiagnostic.capture(error: nil, request: request, phase: phase,
                        httpStatus: (response as? HTTPURLResponse)?.statusCode, metrics: observation.snapshot, requestID: requestID, origin: origin,
                        uploadCorrelation: uploadCorrelation)
        if let status = (response as? HTTPURLResponse)?.statusCode {
            diagnostic.apiReason = GoogleDriveAPIReason.parse(status: status, data: data)
        }
        report(diagnostic)
        guard let response = response as? HTTPURLResponse, response.url == url,
              data.count <= 1_048_576 else { throw GoogleDriveError.invalidResponse }
        return (data, response)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return Data(values.sorted { $0.key < $1.key }.map {
            $0.key.addingPercentEncoding(withAllowedCharacters: allowed)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").utf8)
    }
}

/// A per-task observer avoids attributing another concurrent request's metrics
/// to a failed OAuth/API operation. It never changes server trust handling.
private final class GoogleDriveRequestObservation: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var value: GoogleDriveTransportMetrics?
    var snapshot: GoogleDriveTransportMetrics? { lock.lock(); defer { lock.unlock() }; return value }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let captured = GoogleDriveTransportMetrics.capture(metrics)
        lock.lock(); value = captured; lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}


@MainActor
protocol GoogleDriveTokenProvider: AnyObject {
    func accessToken(for accountID: String) async throws -> String
    func accessToken(for accountID: String, timeout: TimeInterval?) async throws -> String
}

extension GoogleDriveTokenProvider {
    // Existing synthetic/non-network providers need no timeout. The native
    // provider overrides this boundary before issuing a refresh POST.
    func accessToken(for accountID: String, timeout: TimeInterval?) async throws -> String {
        try await accessToken(for: accountID)
    }
}

/// Deliberately cannot represent a URL, token, body, recording identity,
/// certificate or localized server/error description. Both URLSession adapters
/// use this fixed vocabulary to retain the numeric cause of transport failures.
struct GoogleDriveTransportDiagnostic: Codable, Equatable, Sendable {
    enum Origin: String, Codable, Sendable { case natural, controlledFault = "controlled_fault", legacyUnknown = "legacy_unknown" }
    enum Phase: String, Codable, Sendable {
        case apiRequest = "api_request", apiRecovery = "api_recovery", nativeUpload = "native_upload"
    }
    enum Endpoint: String, Codable, Sendable {
        case oauthToken = "oauth_token", oauthRevoke = "oauth_revoke"
        case driveAbout = "drive_about", driveIDs = "drive_ids", driveFiles = "drive_files"
        case driveUpload = "drive_upload", unknown
    }
    enum Method: String, Codable, Sendable { case GET, POST, PUT, PATCH, DELETE, HEAD, unknown }
    struct ErrorCode: Codable, Equatable, Sendable {
        let domain: String
        let code: Int
    }

    let phase: Phase
    let endpoint: Endpoint
    let method: Method
    let httpStatus: Int?
    let errors: [ErrorCode]
    let streamErrorDomain: Int?
    let streamErrorCode: Int?
    let metrics: GoogleDriveTransportMetrics?
    // Optional additions keep schema-1 files readable. The UUID is generated
    // locally per send; it is never derived from an account, URL or recording.
    let requestID: UUID?
    let origin: Origin?
    var uploadCorrelation: GoogleDriveUploadCorrelation? = nil
    var apiReason: GoogleDriveAPIReason? = nil

    /// Native background delegates recover this identity from their validated
    /// durable upload context after the URLSession callback arrives.
    func withUploadCorrelation(_ correlation: GoogleDriveUploadCorrelation) -> Self {
        var value = self
        value.uploadCorrelation = correlation.isValid ? correlation : nil
        return value
    }

    static func capture(error: Error?, request: URLRequest?, phase: Phase,
                        httpStatus: Int? = nil, metrics: GoogleDriveTransportMetrics? = nil,
                        requestID: UUID? = nil, origin: Origin? = nil,
                        uploadCorrelation: GoogleDriveUploadCorrelation? = nil) -> Self {
        var errors: [ErrorCode] = [], seen = Set<ObjectIdentifier>()
        var current = error.map { $0 as NSError }
        var streamDomain: Int?, streamCode: Int?
        while let value = current, errors.count < 4, seen.insert(ObjectIdentifier(value)).inserted {
            errors.append(.init(domain: safeDomain(value.domain), code: value.code))
            // These CFNetwork keys carry integers only. Never inspect failing
            // URLs, peer trust objects, descriptions, headers or response data.
            if streamDomain == nil { streamDomain = value.userInfo["_kCFStreamErrorDomainKey"] as? Int }
            if streamCode == nil { streamCode = value.userInfo["_kCFStreamErrorCodeKey"] as? Int }
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return .init(phase: phase, endpoint: endpoint(for: request?.url),
                     method: request?.httpMethod.flatMap(Method.init(rawValue:)) ?? .unknown,
                     httpStatus: httpStatus.flatMap { (100...599).contains($0) ? $0 : nil }, errors: errors,
                     streamErrorDomain: streamDomain, streamErrorCode: streamCode, metrics: metrics,
                     requestID: requestID, origin: origin,
                     uploadCorrelation: uploadCorrelation.flatMap { $0.isValid ? $0 : nil })
    }

    private static func safeDomain(_ value: String) -> String {
        switch value {
        case NSURLErrorDomain, NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain,
             "kCFErrorDomainCFNetwork", "kCFErrorDomainSSL": return value
        default: return "other"
        }
    }

    private static func endpoint(for url: URL?) -> Endpoint {
        guard let url, let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.port == nil, parts.user == nil,
              parts.password == nil, parts.fragment == nil else { return .unknown }
        if parts.host == "oauth2.googleapis.com", parts.query == nil {
            if parts.path == "/token" { return .oauthToken }
            if parts.path == "/revoke" { return .oauthRevoke }
        }
        guard parts.host == "www.googleapis.com" else { return .unknown }
        switch parts.path {
        case "/drive/v3/about": return .driveAbout
        case "/drive/v3/files/generateIds": return .driveIDs
        case "/drive/v3/files": return .driveFiles
        case let path where path.hasPrefix("/drive/v3/files/"): return .driveFiles
        case "/upload/drive/v3/files": return .driveUpload
        case let path where path.hasPrefix("/upload/drive/v3/files/"): return .driveUpload
        default: return .unknown
        }
    }

    var logFields: String {
        let chain = errors.enumerated().map { " error\($0.offset)_domain=\($0.element.domain) error\($0.offset)_code=\($0.element.code)" }.joined()
        return "transport_phase=\(phase.rawValue) endpoint=\(endpoint.rawValue) method=\(method.rawValue)"
            + " api_reason=\(apiReason?.rawValue ?? "none")"
            + " transport_http_status=\(httpStatus.map(String.init) ?? "none") error_depth=\(errors.count)" + chain
            + " stream_error_domain=\(streamErrorDomain.map(String.init) ?? "none") stream_error_code=\(streamErrorCode.map(String.init) ?? "none")"
            + (metrics.map { " " + $0.logFields } ?? " metrics=none")
            + " " + (uploadCorrelation?.logFields ?? "upload_scope=none upload_job_key=none upload_kind=none")
    }
}

/// Only the last transaction's bounded connection facts. Network addresses,
/// certificate data and URLSession's raw request/response objects never escape.
struct GoogleDriveTransportMetrics: Codable, Equatable, Sendable {
    enum NetworkProtocol: String, Codable, Sendable { case h2, h3, http11 = "http1.1", unknown }
    let networkProtocol: NetworkProtocol
    let reusedConnection: Bool
    let proxyConnection: Bool
    let cellular: Bool
    let dnsMS: Int?
    let connectMS: Int?
    let tlsMS: Int?
    let tlsStarted: Bool
    let tlsFinished: Bool
    let requestStarted: Bool
    let responseStarted: Bool
    let tlsProtocolVersion: Int?

    static func capture(_ metrics: URLSessionTaskMetrics) -> Self? {
        guard let value = metrics.transactionMetrics.last else { return nil }
        let networkProtocol: NetworkProtocol = value.networkProtocolName == "http/1.1" ? .http11
            : NetworkProtocol(rawValue: value.networkProtocolName ?? "") ?? .unknown
        return .init(networkProtocol: networkProtocol,
                     reusedConnection: value.isReusedConnection, proxyConnection: value.isProxyConnection,
                     cellular: value.isCellular, dnsMS: milliseconds(value.domainLookupStartDate, value.domainLookupEndDate),
                     connectMS: milliseconds(value.connectStartDate, value.connectEndDate),
                     tlsMS: milliseconds(value.secureConnectionStartDate, value.secureConnectionEndDate),
                     tlsStarted: value.secureConnectionStartDate != nil, tlsFinished: value.secureConnectionEndDate != nil,
                     requestStarted: value.requestStartDate != nil, responseStarted: value.responseStartDate != nil,
                     tlsProtocolVersion: value.negotiatedTLSProtocolVersion.flatMap { version in
                         let number = Int(version.rawValue)
                         return (0...65_535).contains(number) ? number : nil
                     })
    }

    private static func milliseconds(_ start: Date?, _ end: Date?) -> Int? {
        guard let start, let end else { return nil }
        let elapsed = end.timeIntervalSince(start)
        guard elapsed.isFinite, elapsed >= 0 else { return nil }
        return Int(min(3_600_000, elapsed * 1_000))
    }

    var logFields: String {
        "protocol=\(networkProtocol.rawValue) reused_connection=\(reusedConnection) proxy_connection=\(proxyConnection) cellular=\(cellular)"
            + " dns_ms=\(dnsMS.map(String.init) ?? "none") connect_ms=\(connectMS.map(String.init) ?? "none") tls_ms=\(tlsMS.map(String.init) ?? "none")"
            + " tls_started=\(tlsStarted) tls_finished=\(tlsFinished) request_started=\(requestStarted) response_started=\(responseStarted)"
            + " tls_version=\(tlsProtocolVersion.map(String.init) ?? "none")"
    }
}

/// A diagnostic history is untrusted after disk readback. Validate the
/// complete decoded vocabulary before keeping its bounded suffix; arbitrary
/// Codable error-domain strings can never become a later report/log channel.
struct GoogleDriveTransportHistory {
    static let maximumFileBytes = 64 * 1_024
    struct Observation: Codable, Equatable {
        let timestamp: Date
        let diagnostic: GoogleDriveTransportDiagnostic
    }
    private struct Report: Codable {
        let schemaVersion: Int
        let failures: [Observation]
        let successes: [Observation]
    }
    private(set) var failures: [Observation] = []
    private(set) var successes: [Observation] = []

    static func restored(from data: Data, now: Date = Date()) -> Self? {
        guard !data.isEmpty, data.count <= maximumFileBytes,
              let report = try? TransportCodec.decode(Report.self, from: data), [1, 2].contains(report.schemaVersion),
              report.failures.allSatisfy({ valid($0, failed: true, now: now) }),
              report.successes.allSatisfy({ valid($0, failed: false, now: now) }) else { return nil }
        var history = Self()
        history.failures = Array(report.failures.suffix(16))
        history.successes = Array(report.successes.suffix(8))
        return history
    }

    /// Returns false for invalid observations or a sampled success. This is
    /// diagnostic-only state and never an upload/remote-verification receipt.
    mutating func record(_ value: GoogleDriveTransportDiagnostic, at timestamp: Date = Date()) -> Bool {
        let observation = Observation(timestamp: timestamp, diagnostic: value)
        let failed = !value.errors.isEmpty
        guard Self.valid(observation, failed: failed, now: timestamp) else { return false }
        if failed {
            failures.append(observation); failures = Array(failures.suffix(16))
        } else {
            // Preserve each keyed request in the bounded suffix. Global time
            // sampling must not discard another upload's first success, or a
            // refresh/readback merely because metadata just completed.
            if value.uploadCorrelation == nil, value.phase != .apiRecovery,
               let last = successes.last, timestamp.timeIntervalSince(last.timestamp) < 10,
               (failures.last?.timestamp ?? .distantPast) < last.timestamp { return false }
            successes.append(observation); successes = Array(successes.suffix(8))
        }
        return true
    }

    func encoded() -> Data? {
        guard let bytes = try? TransportCodec.encode(Report(schemaVersion: 2, failures: failures, successes: successes)),
              bytes.count <= Self.maximumFileBytes else { return nil }
        return bytes
    }

    private static func valid(_ observation: Observation, failed: Bool, now: Date) -> Bool {
        let timestamp = observation.timestamp.timeIntervalSince1970, reference = now.timeIntervalSince1970
        guard timestamp.isFinite, reference.isFinite, timestamp >= 0, timestamp <= reference + 300 else { return false }
        let value = observation.diagnostic
        return !value.errors.isEmpty == failed && validDiagnostic(value)
    }

    static func validDiagnostic(_ value: GoogleDriveTransportDiagnostic) -> Bool {
        guard value.uploadCorrelation.map(\.isValid) ?? true, value.errors.count <= 4,
              value.errors.allSatisfy({ error in
                  [NSURLErrorDomain, NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain,
                   "kCFErrorDomainCFNetwork", "kCFErrorDomainSSL", "other"].contains(error.domain)
                    && Int64(error.code) >= Int64(Int32.min) && Int64(error.code) <= Int64(Int32.max)
              }), value.httpStatus.map({ (100...599).contains($0) }) ?? true,
              value.streamErrorDomain.map({ (0...Int(Int32.max)).contains($0) }) ?? true,
              value.streamErrorCode.map({ (Int(Int32.min)...Int(Int32.max)).contains($0) }) ?? true else { return false }
        guard let metrics = value.metrics else { return true }
        return [metrics.dnsMS, metrics.connectMS, metrics.tlsMS].allSatisfy { $0.map { (0...3_600_000).contains($0) } ?? true }
            && (metrics.tlsProtocolVersion.map { (0...65_535).contains($0) } ?? true)
    }
}
