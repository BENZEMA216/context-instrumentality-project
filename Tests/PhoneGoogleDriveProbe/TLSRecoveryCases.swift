import Darwin
import Foundation
import RecordingCore

/// Exercises the real transport using synthetic URLProtocol replies only.
/// No real network, recording, credential store, cloud or device is accessed.
enum GoogleDriveTLSRecoveryCases {
    private struct Failure: Error { let message: String }
    private enum Reply {
        case fail(NSError, delay: TimeInterval = 0)
        case success
        case http(Int)
    }
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private let replies: [Reply]
        private var requests: [URLRequest] = []
        private var diagnostics: [GoogleDriveTransportDiagnostic] = []
        private var completions: [GoogleDriveRequestCompletion] = []
        private let beforeFirstReply: (@Sendable () -> Void)?
        init(_ replies: [Reply], beforeFirstReply: (@Sendable () -> Void)? = nil) {
            self.replies = replies; self.beforeFirstReply = beforeFirstReply
        }
        func take(_ request: URLRequest) -> Reply {
            lock.lock()
            requests.append(request)
            let first = requests.count == 1
            let reply: Reply = requests.count <= replies.count ? replies[requests.count - 1]
                : .fail(NSError(domain: "SyntheticUnexpectedRetry", code: requests.count))
            lock.unlock()
            if first { beforeFirstReply?() }
            return reply
        }
        func record(_ diagnostic: GoogleDriveTransportDiagnostic) {
            lock.lock(); diagnostics.append(diagnostic); lock.unlock()
        }
        func finish(_ completion: GoogleDriveRequestCompletion) { lock.lock(); completions.append(completion); lock.unlock() }
        var finished: [GoogleDriveRequestCompletion] { lock.lock(); defer { lock.unlock() }; return completions }
        var captured: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
        var phases: [GoogleDriveTransportDiagnostic.Phase] {
            lock.lock(); defer { lock.unlock() }; return diagnostics.map(\.phase)
        }
        var observations: [GoogleDriveTransportDiagnostic] { lock.lock(); defer { lock.unlock() }; return diagnostics }
    }
    private final class MockTransportProtocol: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var state: State?
        private let stoppedLock = NSLock()
        private var stopped = false
        static func install(_ value: State) { lock.lock(); state = value; lock.unlock() }
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lock.lock(); let state = Self.state; Self.lock.unlock()
            guard let state else { client?.urlProtocol(self, didFailWithError: Failure(message: "Missing synthetic route")); return }
            let reply = state.take(request)
            if case .fail(_, let delay) = reply, delay > 0 { Thread.sleep(forTimeInterval: delay) }
            stoppedLock.lock(); let stopped = self.stopped; stoppedLock.unlock()
            guard !stopped else { return }
            switch reply {
            case .fail(let error, _): client?.urlProtocol(self, didFailWithError: error)
            case .success, .http:
                let status: Int
                if case .http(let value) = reply { status = value } else { status = 200 }
                let response = HTTPURLResponse(url: request.url!, statusCode: status,
                    httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data("{}".utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
        }
        override func stopLoading() { stoppedLock.lock(); stopped = true; stoppedLock.unlock() }
    }
    private final class LinkedError: NSError, @unchecked Sendable {
        weak var next: NSError?
        override var userInfo: [String: Any] {
            var result: [String: Any] = ["_kCFStreamErrorDomainKey": 3, "_kCFStreamErrorCodeKey": -9816]
            if let next { result[NSUnderlyingErrorKey] = next }
            return result
        }
        init() { super.init(domain: NSURLErrorDomain, code: -1200, userInfo: nil) }
        required init?(coder: NSCoder) { fatalError("Not a fixture archive") }
    }
    /// Uses the production lease budget while deliberately withholding Swift
    /// task cancellation, just like the native expiry-to-main-actor boundary.
    private final class Lease: @unchecked Sendable {
        private let lock = NSLock()
        private var budget = GoogleDriveExecutionBudget(isForeground: true, now: 0)
        private var now: TimeInterval = 0
        private var recoveryChecks = 0
        func backgroundThenAdvance(to time: TimeInterval) {
            lock.lock(); budget.enterBackground(at: 10); now = time; lock.unlock()
        }
        func check() throws { lock.lock(); defer { lock.unlock() }; try budget.check(at: now) }
        func remaining() throws -> TimeInterval {
            lock.lock(); defer { lock.unlock() }; return try budget.requestTimeout(at: now)
        }
        func recoveryRemaining() throws -> TimeInterval {
            lock.lock(); defer { lock.unlock() }; recoveryChecks += 1
            return try budget.requestTimeout(at: now)
        }
        var checks: Int { lock.lock(); defer { lock.unlock() }; return recoveryChecks }
    }
    @MainActor private final class Tokens: GoogleDriveTokenProvider {
        func accessToken(for accountID: String) async throws -> String { "SYNTHETIC_ONLY" }
    }
    private static func error(_ code: Int = -1200, ssl: Int? = -9816,
                              underlying: NSError? = nil, domain: String = NSURLErrorDomain) -> NSError {
        var info: [String: Any] = [:]
        if let ssl { info["_kCFStreamErrorDomainKey"] = 3; info["_kCFStreamErrorCodeKey"] = ssl }
        if let underlying { info[NSUnderlyingErrorKey] = underlying }
        return NSError(domain: domain, code: code, userInfo: info)
    }
    private static func request(_ url: String = "https://www.googleapis.com/drive/v3/about?fields=user(permissionId)",
                                method: String = "GET") -> URLRequest {
        var value = URLRequest(url: URL(string: url)!)
        value.httpMethod = method
        value.setValue("Bearer SYNTHETIC_ONLY", forHTTPHeaderField: "Authorization")
        value.setValue("application/json", forHTTPHeaderField: "Content-Type")
        value.setValue("synthetic-preserved", forHTTPHeaderField: "X-Synthetic-Probe")
        return value
    }
    private static func transport(_ state: State) -> GoogleDriveHTTP {
        MockTransportProtocol.install(state)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockTransportProtocol.self]
        let http = GoogleDriveHTTP(configuration: configuration)
        http.setTransportDiagnosticHandler { state.record($0) }
        http.setRequestCompletionHandler { state.finish($0) }
        return http
    }

    static func run() async throws -> Int {
        var count = 0
        func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
            guard value() else { throw Failure(message: message) }; count += 1
        }
        let eligible = request(), closed = error()
        for (budget, expected) in [(1.0, 1.0), (8.0, 8.0), (30.0, 8.0)] {
            try require(GoogleDriveHTTP.recoveryTimeout(for: eligible, error: closed, remaining: budget) == expected,
                        "Eligible GET recovery did not retain its bounded remaining budget")
        }
        for budget in [0.0, 0.5, -1.0, Double.infinity, -Double.infinity, Double.nan] {
            try require(GoogleDriveHTTP.recoveryTimeout(for: eligible, error: closed, remaining: budget) == nil,
                        "Insufficient/nonfinite execution budget allowed recovery")
        }
        let nested = error(ssl: nil, underlying: error(domain: "kCFErrorDomainCFNetwork"))
        try require(GoogleDriveHTTP.recoveryTimeout(for: eligible, error: nested, remaining: 5) == 5,
                    "Exact underlying ClosedNoNotify cause was not recognized")
        let rejectedErrors = [error(-1202), error(underlying: error(-1202)), error(ssl: -9806),
            error(ssl: -9824), error(ssl: nil), error(domain: "kCFErrorDomainSSL"),
            error(underlying: error(ssl: -9807)), error(underlying: error(domain: NSPOSIXErrorDomain)),
            NSError(domain: NSURLErrorDomain, code: -1200, userInfo: ["_kCFStreamErrorDomainKey": "3", "_kCFStreamErrorCodeKey": -9816]),
            NSError(domain: NSURLErrorDomain, code: -1200, userInfo: ["_kCFStreamErrorDomainKey": 3, "_kCFStreamErrorCodeKey": -9816,
                                                                            NSUnderlyingErrorKey: "not-an-error"])]
        for rejected in rejectedErrors {
            try require(GoogleDriveHTTP.recoveryTimeout(for: eligible, error: rejected, remaining: 8) == nil,
                        "Unknown, malformed, certificate or conflicting cause permitted recovery")
        }
        let linked = (0..<5).map { _ in LinkedError() }
        for index in 0..<4 { linked[index].next = linked[index + 1] }
        try require(GoogleDriveHTTP.recoveryTimeout(for: eligible, error: linked[0], remaining: 8) == nil,
                    "A cause chain exceeding four links permitted recovery")
        linked[1].next = linked[0]
        try require(GoogleDriveHTTP.recoveryTimeout(for: eligible, error: linked[0], remaining: 8) == nil,
                    "A cyclic NSError cause chain permitted recovery")
        let deniedURLs = ["https://www.googleapis.com/drive/v3/files?fields=id",
            "https://www.googleapis.com/drive/v3/files/generateIds?count=1",
            "https://www.googleapis.com/drive/v3/files/generateIds?fields=ids",
            "https://www.googleapis.com/drive/v3/about", "https://www.googleapis.com/drive/v3/about?fields=",
            "https://www.googleapis.com/drive/v3/about?fields=id&fields=name",
            "https://www.googleapis.com/drive/v3/about?fields=id&secret=synthetic",
            "https://www.googleapis.com:443/drive/v3/about?fields=id",
            "https://www.googleapis.com/drive/v3/about?fields=id#fragment",
            "http://www.googleapis.com/drive/v3/about?fields=id",
            "https://oauth2.googleapis.com/token", "https://other.invalid/drive/v3/about?fields=id"]
        for url in deniedURLs {
            try require(GoogleDriveHTTP.recoveryTimeout(for: request(url), error: closed, remaining: 8) == nil,
                        "A non-metadata endpoint or inexact query permitted recovery")
        }
        var body = eligible; body.httpBody = Data("synthetic".utf8)
        try require(GoogleDriveHTTP.recoveryTimeout(for: body, error: closed, remaining: 8) == nil,
                    "A GET carrying a body permitted recovery")
        var stream = eligible; stream.httpBodyStream = InputStream(data: Data("synthetic".utf8))
        try require(GoogleDriveHTTP.recoveryTimeout(for: stream, error: closed, remaining: 8) == nil,
                    "A GET carrying a body stream permitted recovery")

        // Actual send: the fresh session retains the injected synthetic protocol.
        let recoveryState = State([.fail(closed), .success])
        let recoveryHTTP = transport(recoveryState)
        let (bytes, response) = try await recoveryHTTP.send(eligible, timeout: 20)
        let recovered = recoveryState.captured
        try require(response.statusCode == 200 && bytes == Data("{}".utf8) && recovered.count == 2,
                    "Eligible GET failed to recover exactly once through the actual send path")
        try require(recoveryState.phases == [.apiRequest, .apiRecovery], "Recovery diagnostic phases were not distinct")
        try require(recoveryState.observations[0].requestID != nil
            && recoveryState.observations[0].requestID == recoveryState.observations[1].requestID
            && recoveryState.finished.count == 1
            && recoveryState.finished[0].requestID == recoveryState.observations[0].requestID
            && recoveryState.finished[0].attemptCount == 2 && recoveryState.finished[0].outcome == .recovered,
            "Initial, recovery and terminal outcome did not share one logical request UUID")
        for captured in recovered {
            try require(captured.url == eligible.url && captured.httpMethod == "GET"
                && captured.httpBody == nil && captured.httpBodyStream == nil,
                "Recovery changed exact URL, method or body")
            try require(captured.value(forHTTPHeaderField: "Authorization") == eligible.value(forHTTPHeaderField: "Authorization")
                && captured.value(forHTTPHeaderField: "Content-Type") == eligible.value(forHTTPHeaderField: "Content-Type")
                && captured.value(forHTTPHeaderField: "X-Synthetic-Probe") == "synthetic-preserved",
                "Recovery changed credential/content/custom headers")
        }
        try require(recovered[1].timeoutInterval > 0 && recovered[1].timeoutInterval <= 8,
                    "Recovery extended its short request timeout")
        let fileState = State([.fail(closed), .success])
        _ = try await transport(fileState).send(request("https://www.googleapis.com/drive/v3/files/synthetic-123?fields=id,name"), timeout: 10)
        try require(fileState.captured.count == 2, "File metadata GET was not eligible for one recovery")
        for status in [204, 302, 304] {
            let state = State([.fail(closed), .http(status)])
            _ = try await transport(state).send(eligible, timeout: 20)
            try require(state.finished.last?.outcome == .httpFailure,
                        "A non-200 metadata recovery was mislabeled as recovered")
        }
        let cancelledWithoutSwiftTask = State([.fail(URLError(.cancelled) as NSError)])
        do { _ = try await transport(cancelledWithoutSwiftTask).send(eligible, timeout: 20) }
        catch {}
        try require(cancelledWithoutSwiftTask.finished.last?.outcome == .cancelled,
                    "URLSession cancellation without Task.cancel was mislabeled as retry ineligibility")

        let failureState = State([.fail(closed), .fail(closed), .success])
        do { _ = try await transport(failureState).send(eligible, timeout: 20); throw Failure(message: "Recovery failure was hidden") }
        catch let failure as Failure { throw failure }
        catch { try require((error as NSError).code == -1200, "Recovery changed the real transport error") }
        try require(failureState.captured.count == 2 && failureState.phases == [.apiRequest, .apiRecovery],
                    "Failed recovery repeated beyond one retry")
        try require(failureState.finished.count == 1 && failureState.finished[0].outcome == .recoveryFailed,
                    "A second transport failure had no terminal failure outcome")

        let mutations = [request("https://www.googleapis.com/drive/v3/files?fields=id", method: "POST"),
            request("https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable", method: "PUT"),
            request("https://oauth2.googleapis.com/token", method: "POST"),
            request("https://oauth2.googleapis.com/revoke", method: "POST")]
        for mutation in mutations {
            let state = State([.fail(closed), .success])
            do { _ = try await transport(state).send(mutation, timeout: 20); throw Failure(message: "Mutation unexpectedly recovered") }
            catch let failure as Failure { throw failure }
            catch { try require((error as NSError).code == -1200, "Mutation lost its original error") }
            try require(state.captured.count == 1 && state.phases == [.apiRequest], "Mutation/OAuth request replayed")
            try require(state.finished.count == 1 && state.finished[0].outcome == .notEligible
                && state.finished[0].attemptCount == 1, "Mutation/OAuth failure lacked a no-retry outcome")
        }
        let timedOut = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: nil)
        var token = request("https://oauth2.googleapis.com/token", method: "POST")
        token.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        token.httpBody = Data("grant_type=refresh_token&refresh_token=SYNTHETIC_ONLY".utf8)
        try require(GoogleDriveHTTP.recoveryTimeout(for: token, error: timedOut, remaining: 8) == 8,
                    "A natural token timeout was not eligible inside the remaining budget")
        try require(GoogleDriveHTTP.recoveryTimeout(for: token, error: closed, remaining: 8) == nil,
                    "ClosedNoNotify replayed a token POST")
        try require(GoogleDriveHTTP.recoveryTimeout(for: eligible, error: timedOut, remaining: 8) == 8,
                    "A natural metadata timeout was not eligible")
        try require(GoogleDriveRecoveryDecision.firstAttemptTimeout(budget: 30, path: .tokenPOST) == 22,
                    "A refresh-token request left no reserve for one natural-timeout retry")
        try require(GoogleDriveRecoveryDecision.firstAttemptTimeout(budget: 30, path: .other) == 30,
                    "An ineligible path shortened its caller timeout")
        try require(GoogleDriveRecoveryDecision.firstAttemptTimeout(budget: 1.5, path: .aboutGET) == 1.5,
                    "A budget too small for a retry was rewritten")
        let posixTimeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT), userInfo: nil)])
        try require(GoogleDriveHTTP.recoveryTimeout(for: eligible, error: posixTimeout, remaining: 8) == 8,
                    "A POSIX ETIMEDOUT under NSURLErrorTimedOut was rejected")
        let streamTimeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [
            "_kCFStreamErrorDomainKey": 3, "_kCFStreamErrorCodeKey": Int(ETIMEDOUT)])
        try require(GoogleDriveHTTP.recoveryTimeout(for: eligible, error: streamTimeout, remaining: 8) == nil,
                    "A stream-domain timeout was treated as a natural timeout")
        let tokenState = State([.fail(timedOut), .success])
        let (tokenBytes, tokenResponse) = try await transport(tokenState).send(token, timeout: 20)
        try require(tokenResponse.statusCode == 200 && tokenBytes == Data("{}".utf8) && tokenState.captured.count == 2,
                    "Token POST did not retry once after a natural timeout")
        try require(tokenState.observations.count >= 2
            && tokenState.observations[0].requestID == tokenState.observations[1].requestID
            && tokenState.finished.count == 1 && tokenState.finished[0].requestID == tokenState.observations[0].requestID
            && tokenState.finished[0].attemptCount == 2 && tokenState.finished[0].outcome == .recovered
            && tokenState.finished[0].origin == .natural,
            "Natural token recovery did not stay on the original request")
        let closedToken = State([.fail(closed), .success])
        do { _ = try await transport(closedToken).send(token, timeout: 20); throw Failure(message: "ClosedNoNotify token POST recovered") }
        catch let failure as Failure { throw failure } catch {}
        try require(closedToken.captured.count == 1 && closedToken.finished.last?.outcome == .notEligible,
                    "ClosedNoNotify token POST was retried")
        var revoke = request("https://oauth2.googleapis.com/revoke", method: "POST")
        revoke.httpBody = Data("token=SYNTHETIC_ONLY".utf8)
        let revokeState = State([.fail(timedOut), .success])
        do { _ = try await transport(revokeState).send(revoke, timeout: 20); throw Failure(message: "Revoke recovered after timeout") }
        catch let failure as Failure { throw failure } catch {}
        try require(revokeState.captured.count == 1 && revokeState.finished.last?.outcome == .notEligible,
                    "Revoke POST retried after a natural timeout")
        let uploadState = State([.fail(timedOut), .success])
        do {
            _ = try await transport(uploadState).send(request("https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable", method: "PUT"), timeout: 20)
            throw Failure(message: "Upload recovered after timeout")
        } catch let failure as Failure { throw failure } catch {}
        try require(uploadState.captured.count == 1 && uploadState.finished.last?.outcome == .notEligible,
                    "Upload PUT retried after a natural timeout")
        let aboutTimeout = State([.fail(timedOut), .success])
        _ = try await transport(aboutTimeout).send(eligible, timeout: 20)
        try require(aboutTimeout.captured.count == 2 && aboutTimeout.finished.last?.outcome == .recovered
            && aboutTimeout.observations[0].requestID == aboutTimeout.observations[1].requestID,
            "About GET did not recover once on the same request after a natural timeout")
        let fileURL = "https://www.googleapis.com/drive/v3/files/synthetic-123?fields=id"
        let fileTimeout = State([.fail(timedOut), .success])
        _ = try await transport(fileTimeout).send(request(fileURL), timeout: 20)
        try require(fileTimeout.captured.count == 2 && fileTimeout.finished.last?.outcome == .recovered,
                    "File metadata GET did not recover once after a natural timeout")
        let acceptedMissing = State([.fail(timedOut), .http(404)])
        _ = try await transport(acceptedMissing).send(request(fileURL), timeout: 20, acceptsMissingMetadata: true)
        try require(acceptedMissing.captured.count == 2 && acceptedMissing.finished.last?.outcome == .recovered
            && acceptedMissing.finished.last?.requestID == acceptedMissing.observations[0].requestID,
            "A caller-accepted file metadata 404 was labeled http_failure")
        let unacceptedMissing = State([.fail(timedOut), .http(404)])
        _ = try await transport(unacceptedMissing).send(request(fileURL), timeout: 20)
        try require(unacceptedMissing.finished.last?.outcome == .httpFailure,
                    "An unaccepted file metadata 404 was labeled recovered")
        let aboutMissing = State([.fail(timedOut), .http(404)])
        _ = try await transport(aboutMissing).send(eligible, timeout: 20, acceptsMissingMetadata: true)
        try require(aboutMissing.finished.last?.outcome == .httpFailure,
                    "An about 404 was labeled recovered")
        let spentTimeout = State([.fail(timedOut), .success])
        do { _ = try await transport(spentTimeout).send(token, timeout: 0.001); throw Failure(message: "Spent token budget recovered") }
        catch let failure as Failure { throw failure } catch {}
        try require(spentTimeout.captured.count == 1 && spentTimeout.finished.last?.outcome == .budgetExpired,
                    "A spent natural-timeout budget launched a second token POST")
        let otherSuccess = State([.success])
        _ = try await transport(otherSuccess).send(eligible, timeout: 20)
        try require(otherSuccess.finished.last?.outcome == .succeeded
            && otherSuccess.finished.last?.requestID != spentTimeout.finished.last?.requestID,
            "A later request's success was treated as recovery of the timed-out request")
        for rejected in [error(-1202), error(underlying: error(-1202)), error(ssl: -9806), error(ssl: -9824)] {
            let state = State([.fail(rejected), .success])
            do { _ = try await transport(state).send(eligible, timeout: 20); throw Failure(message: "Unsafe TLS cause unexpectedly recovered") }
            catch let failure as Failure { throw failure }
            catch {}
            try require(state.captured.count == 1 && state.phases == [.apiRequest], "Certificate/unknown TLS failure replayed")
        }

        let spent = State([.fail(closed, delay: 0.025), .success])
        do { _ = try await transport(spent).send(eligible, timeout: 0.001); throw Failure(message: "Spent budget unexpectedly recovered") }
        catch let failure as Failure { throw failure }
        catch {}
        try require(spent.captured.count == 1 && !spent.phases.contains(.apiRecovery), "Spent request budget was renewed")
        try require(spent.finished.count == 1 && spent.finished[0].outcome == .budgetExpired,
                    "Spent request budget lacked its terminal reason")

        let cancelled = State([.fail(closed, delay: 0.1), .success]), cancelledHTTP = transport(cancelled)
        let task = Task { try await cancelledHTTP.send(eligible, timeout: 20) }
        let stopAt = ProcessInfo.processInfo.systemUptime + 2
        while cancelled.captured.isEmpty && ProcessInfo.processInfo.systemUptime < stopAt { await Task.yield() }
        try require(!cancelled.captured.isEmpty, "Cancellation fixture never reached the synthetic request")
        task.cancel()
        do { _ = try await task.value; throw Failure(message: "Cancelled request returned success") }
        catch is CancellationError {}
        catch { throw Failure(message: "Cancellation did not override network recovery: \(type(of: error))") }
        try require(cancelled.captured.count == 1 && !cancelled.phases.contains(.apiRecovery), "Cancellation launched recovery")
        try require(cancelled.finished.count == 1 && cancelled.finished[0].outcome == .cancelled,
                    "A cancelled send lacked a terminal cancellation outcome")

        let shortenedLease = Lease()
        let shortened = State([.fail(closed), .success], beforeFirstReply: { shortenedLease.backgroundThenAdvance(to: 25) })
        _ = try await transport(shortened).send(eligible, timeout: 30,
            recoveryBudget: { try shortenedLease.recoveryRemaining() })
        try require(shortenedLease.checks == 1 && shortened.captured.count == 2
            && shortened.captured[1].timeoutInterval <= 4 && shortened.phases == [.apiRequest, .apiRecovery],
            "Recovery failed to adopt the shortened foreground-to-background lease")

        // The initial 30-second request budget remains unspent in wall time,
        // and this task has never been cancelled. Only the current lease gate
        // can stop an expired foreground-to-background transition from replaying.
        let expiredLease = Lease()
        let expired = State([.fail(closed), .success], beforeFirstReply: { expiredLease.backgroundThenAdvance(to: 30) })
        do {
            _ = try await transport(expired).send(eligible, timeout: 30,
                recoveryBudget: { try expiredLease.recoveryRemaining() })
            throw Failure(message: "Expired current lease returned a response before task cancellation arrived")
        } catch is CancellationError {} catch { throw error }
        try require(!Task.isCancelled && expiredLease.checks == 1 && expired.captured.count == 1
            && expired.phases == [.apiRequest], "An expired lease launched a second request before Task.cancel")
        try require(expired.finished.count == 1 && expired.finished[0].outcome == .callerBudgetRejected,
                    "The current caller gate rejection lacked its own terminal reason")

        let narrowLease = Lease()
        let narrow = State([.fail(closed), .success], beforeFirstReply: { narrowLease.backgroundThenAdvance(to: 28.5) })
        do {
            _ = try await transport(narrow).send(eligible, timeout: 30,
                recoveryBudget: { try narrowLease.recoveryRemaining() })
            throw Failure(message: "Insufficient shortened current lease returned a response")
        } catch let failure as Failure { throw failure } catch {}
        try require(narrow.captured.count == 1 && narrowLease.checks == 1,
                    "Less than one second of current lease was renewed into a recovery")

        // Validate the real client's static account GET path, not just direct
        // send: validateAccount must propagate its current check/timeout gate.
        let accountLease = Lease()
        let accountState = State([.fail(closed), .success], beforeFirstReply: { accountLease.backgroundThenAdvance(to: 30) })
        let accountHTTP = transport(accountState)
        let accountClient = await GoogleDriveClient(http: accountHTTP, oauth: Tokens(), accountID: "synthetic-owner",
            check: { try accountLease.check() }, requestTimeout: { try accountLease.remaining() })
        do {
            try await accountClient.validateAccount()
            throw Failure(message: "Account GET bypassed its client's expired lease gate")
        } catch is CancellationError {} catch { throw error }
        try require(!Task.isCancelled && accountState.captured.count == 1 && accountState.phases == [.apiRequest],
                    "The real client's account GET launched recovery after its lease expired")
        count += try await uploadCorrelationCases()
#if DEBUG
        count += try await debugInjectionCases()
#endif
        return count
    }

    @MainActor private static func uploadCorrelationCases() async throws -> Int {
        var count = 0
        func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
            guard value() else { throw Failure(message: message) }; count += 1
        }
        let initiatingJob = GoogleDriveUploadCorrelation(segmentID: UUID(), kind: .audio,
            manifestSHA256: String(repeating: "a", count: 64))
        let waitingJob = GoogleDriveUploadCorrelation(segmentID: UUID(), kind: .manifest,
            manifestSHA256: String(repeating: "b", count: 64))
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let state = State([.fail(timeout), .success, .success]), http = transport(state)
        try await GoogleDriveUploadTrace.$current.withValue(initiatingJob) {
            _ = try await http.send(request(), timeout: 20)
        }
        _ = try await http.send(request(), timeout: 20)
        try require(state.observations.count == 3
            && state.observations.prefix(2).allSatisfy { $0.uploadCorrelation == initiatingJob }
            && state.finished.first?.uploadCorrelation == initiatingJob,
            "Natural timeout, same-request retry and completion lost the initiating upload key")
        try require(state.observations.last?.uploadCorrelation == nil && state.finished.last?.uploadCorrelation == nil,
            "An unrelated later request inherited a prior upload key")

        var refreshRequest = request("https://oauth2.googleapis.com/token", method: "POST")
        refreshRequest.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        refreshRequest.httpBody = GoogleDriveHTTP.form(["grant_type": "refresh_token", "refresh_token": "SYNTHETIC_PRIVATE_REFRESH"])
        let credential = GoogleDriveCredential(clientID: "SYNTHETIC_PRIVATE_CLIENT", accessToken: "SYNTHETIC_PRIVATE_ACCESS",
            refreshToken: "SYNTHETIC_PRIVATE_REFRESH", expiresAt: Date(timeIntervalSinceNow: 3600), accountID: "SYNTHETIC_PRIVATE_ACCOUNT")
        let refresh = GoogleDriveCredentialRefresh()
        let refreshState = State([.fail(timeout), .success]), refreshHTTP = transport(refreshState)
        var gate: CheckedContinuation<Void, Never>?
        var operationStarted = false, waiterStarted = false, operationCount = 0
        let first = Task { @MainActor in
            try await GoogleDriveUploadTrace.$current.withValue(initiatingJob) {
                try await refresh.value {
                    operationCount += 1
                    await withCheckedContinuation { gate = $0; operationStarted = true }
                    _ = try await refreshHTTP.send(refreshRequest, timeout: 20)
                    return credential
                }
            }
        }
        while !operationStarted { await Task.yield() }
        let second = Task { @MainActor in
            try await GoogleDriveUploadTrace.$current.withValue(waitingJob) {
                waiterStarted = true
                return try await refresh.value { operationCount += 1; return credential }
            }
        }
        while !waiterStarted { await Task.yield() }
        gate?.resume()
        _ = try await (first.value, second.value)
        try require(operationCount == 1 && refreshState.observations.count == 2,
            "Concurrent upload token waiters no longer shared one refresh with one bounded timeout retry")
        try require(refreshState.observations.allSatisfy { $0.uploadCorrelation == initiatingJob }
            && refreshState.finished.count == 1 && refreshState.finished[0].uploadCorrelation == initiatingJob,
            "A later upload waiter relabeled the shared refresh's initiating job")

        let sharedState = State([.success]), sharedHTTP = transport(sharedState)
        _ = try await refresh.value {
            _ = try await sharedHTTP.send(refreshRequest, timeout: 20)
            return credential
        }
        try require(sharedState.observations.first?.uploadCorrelation == .shared
            && sharedState.finished.first?.uploadCorrelation == .shared,
            "A refresh initiated outside an upload did not carry an explicit shared attribution")
        let encoded = String(decoding: try JSONEncoder().encode(refreshState.observations), as: UTF8.self)
            + String(decoding: try JSONEncoder().encode(refreshState.finished), as: UTF8.self)
            + refreshState.observations.map(\.logFields).joined()
        try require(!encoded.contains("SYNTHETIC_PRIVATE") && !encoded.contains("https://")
            && !encoded.contains("Authorization") && !encoded.contains("refresh_token"),
            "Shared-refresh correlation leaked account, credentials, URL or request body")
        return count
    }

#if DEBUG
    private static func debugInjectionCases() async throws -> Int {
        var count = 0
        func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
            guard value() else { throw Failure(message: message) }; count += 1
        }
        let eligible = request()
        let plainState = State([.success]), plain = transport(plainState)
        _ = try await plain.send(eligible, timeout: 20)
        try require(plain.debugClosedNoNotifyInjectionCount == 0 && plainState.captured.count == 1
            && plainState.phases == [.apiRequest], "A default Debug instance injected a fault")

        var body = eligible; body.httpBody = Data("synthetic".utf8)
        var stream = eligible; stream.httpBodyStream = InputStream(data: Data("synthetic".utf8))
        let excluded = [request("https://www.googleapis.com/drive/v3/files/synthetic-123?fields=id"),
            request("https://www.googleapis.com/drive/v3/files/generateIds?fields=ids"),
            request("https://www.googleapis.com/drive/v3/about"),
            request("https://www.googleapis.com/drive/v3/about?fields="),
            request("https://www.googleapis.com/drive/v3/about?fields=id&fields=name"),
            request("https://www.googleapis.com/drive/v3/about?fields=id&alt=json"),
            request(method: "POST"), request("https://oauth2.googleapis.com/token", method: "POST"),
            request("https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable", method: "PUT"), body, stream]
        let onceState = State(Array(repeating: .success, count: excluded.count + 2)), once = transport(onceState)
        once.debugInjectClosedNoNotifyOnce(); once.debugInjectClosedNoNotifyOnce()
        for excludedRequest in excluded {
            _ = try await once.send(excludedRequest, timeout: 20)
            try require(once.debugClosedNoNotifyInjectionCount == 0,
                        "An ineligible request consumed the about-only Debug fault")
        }
        let (bytes, response) = try await once.send(eligible, timeout: 20)
        let firstRecovery = onceState.observations.suffix(2)
        try require(bytes == Data("{}".utf8) && response.statusCode == 200
            && once.debugClosedNoNotifyInjectionCount == 1 && onceState.captured.count == excluded.count + 1
            && firstRecovery.map(\.phase) == [.apiRequest, .apiRecovery],
            "The Debug fault did not enter the unmodified recovery send path exactly once")
        let synthetic = firstRecovery.first!
        try require(synthetic.errors.map(\.domain) == [NSURLErrorDomain, "kCFErrorDomainCFNetwork"]
            && synthetic.errors.map(\.code) == [-1200, -1200] && synthetic.streamErrorDomain == 3
            && synthetic.streamErrorCode == -9816 && synthetic.metrics == nil,
            "The fixed Debug fault did not retain the captured numeric cause chain")
        try require(firstRecovery.allSatisfy { $0.origin == .controlledFault }
            && onceState.finished.last?.origin == .controlledFault,
                    "Controlled injection or recovery was mislabeled as natural")
        let recovered = onceState.captured.last!
        try require(recovered.url == eligible.url && recovered.allHTTPHeaderFields == eligible.allHTTPHeaderFields
            && recovered.httpMethod == "GET" && recovered.httpBody == nil && recovered.httpBodyStream == nil
            && recovered.timeoutInterval > 0 && recovered.timeoutInterval <= 8,
            "Debug recovery changed the request or bypassed the bounded production timeout")
        once.debugInjectClosedNoNotifyOnce()
        _ = try await once.send(eligible, timeout: 20)
        try require(once.debugClosedNoNotifyInjectionCount == 1 && onceState.captured.count == excluded.count + 2
            && onceState.phases.last == .apiRequest, "A consumed Debug instance was rearmed")

        // A second live instance remains unaffected by arming its neighbour.
        let isolatedState = State([.success, .success]), armed = transport(isolatedState), neighbour = transport(isolatedState)
        armed.debugInjectClosedNoNotifyOnce()
        _ = try await neighbour.send(eligible, timeout: 20)
        try require(neighbour.debugClosedNoNotifyInjectionCount == 0 && armed.debugClosedNoNotifyInjectionCount == 0
            && isolatedState.phases == [.apiRequest], "Debug injection escaped its selected instance")
        _ = try await armed.send(eligible, timeout: 20)
        try require(armed.debugClosedNoNotifyInjectionCount == 1 && isolatedState.captured.count == 2,
                    "The armed instance lost its one-shot fault to another instance")

        let smallState = State([]), small = transport(smallState)
        small.debugInjectClosedNoNotifyOnce()
        do { _ = try await small.send(eligible, timeout: 0.5); throw Failure(message: "Debug fault renewed a short budget") }
        catch let failure as Failure { throw failure } catch {}
        try require(small.debugClosedNoNotifyInjectionCount == 1 && smallState.captured.isEmpty
            && smallState.phases == [.apiRequest], "Debug fault launched recovery with less than one second remaining")

        let expiredState = State([]), expired = transport(expiredState)
        expired.debugInjectClosedNoNotifyOnce()
        do {
            _ = try await expired.send(eligible, timeout: 20, recoveryBudget: { throw CancellationError() })
            throw Failure(message: "Debug fault ignored the current lease fence")
        } catch is CancellationError {} catch { throw error }
        try require(expired.debugClosedNoNotifyInjectionCount == 1 && expiredState.captured.isEmpty
            && expiredState.phases == [.apiRequest], "An expired caller lease allowed Debug recovery")

        let cancelledState = State([]), cancelled = transport(cancelledState)
        cancelled.debugInjectClosedNoNotifyOnce()
        let cancelledTask = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await cancelled.send(eligible, timeout: 20)
        }
        do { _ = try await cancelledTask.value; throw Failure(message: "Precancelled Debug request returned success") }
        catch is CancellationError {} catch { throw error }
        try require(cancelled.debugClosedNoNotifyInjectionCount == 0 && cancelledState.captured.isEmpty
            && cancelledState.observations.isEmpty, "Cancellation consumed a fault or launched a request")

        // Neither another concurrent task nor a later request inherits this
        // observer. The normal diagnostic handler still receives every event.
        let observedState = State([.success, .success, .success]), observed = transport(observedState), scoped = State([])
        try await GoogleDriveHTTP.$debugDiagnosticObserver.withValue({ scoped.record($0) }) {
            _ = try await observed.send(eligible, timeout: 20)
            _ = try await Task.detached { try await observed.send(eligible, timeout: 20) }.value
        }
        _ = try await observed.send(eligible, timeout: 20)
        try require(scoped.phases == [.apiRequest] && observedState.phases == [.apiRequest, .apiRequest, .apiRequest],
                    "Task-local Debug observation replaced normal history or captured an unrelated request")

        let concurrentState = State([.success, .success]), concurrent = transport(concurrentState)
        concurrent.debugInjectClosedNoNotifyOnce()
        async let first = concurrent.send(eligible, timeout: 20)
        async let second = concurrent.send(eligible, timeout: 20)
        _ = try await (first, second)
        try require(concurrent.debugClosedNoNotifyInjectionCount == 1 && concurrentState.captured.count == 2
            && concurrentState.observations.filter { !$0.errors.isEmpty }.count == 1
            && concurrentState.phases.filter { $0 == .apiRecovery }.count == 1,
            "Concurrent sends consumed the instance-local fault more than once")
        return count
    }
#endif
}
