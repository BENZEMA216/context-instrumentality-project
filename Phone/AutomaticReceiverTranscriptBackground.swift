import CryptoKit
import Darwin
import Foundation
import RecordingCore
import Security

struct ReceiverTranscriptNativeTask: Sendable {
    let taskID: Int
    let nonce: UUID?
    let requestURL: URL?
    let method: String?
    let bodySHA256: String?
    let bodyBytes: Int64
    let suspended: Bool
}

enum ReceiverTranscriptNativeFailure: String, Codable, Sendable {
    case network, cancelled, tls, http, response, interrupted
}

/// Only fixed, reviewed classifications may leave the native callback. Never
/// include NSError userInfo, descriptions, endpoints or response bytes.
enum ReceiverTranscriptNativeErrorCode: String, Sendable {
    case none, cancelled, timedOut = "timed_out", connectionLost = "connection_lost"
    case cannotFindHost = "cannot_find_host", cannotConnect = "cannot_connect"
    case offline, tls, backgroundDisconnected = "background_disconnected"
    case backgroundOwnerConflict = "background_owner_conflict", other

    static func classify(_ error: Error?) -> Self {
        guard let error else { return .none }
        let value = error as NSError
        guard value.domain == NSURLErrorDomain else { return .other }
        switch URLError.Code(rawValue: value.code) {
        case .cancelled: return .cancelled
        case .timedOut: return .timedOut
        case .networkConnectionLost: return .connectionLost
        case .cannotFindHost, .dnsLookupFailed: return .cannotFindHost
        case .cannotConnectToHost: return .cannotConnect
        case .notConnectedToInternet: return .offline
        case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .clientCertificateRejected, .clientCertificateRequired: return .tls
        case .backgroundSessionWasDisconnected: return .backgroundDisconnected
        case .backgroundSessionInUseByAnotherProcess: return .backgroundOwnerConflict
        default: return .other
        }
    }
}

struct ReceiverTranscriptNativeResult: Sendable {
    let taskID: Int
    let nonce: UUID
    let body: Data?
    let failure: ReceiverTranscriptNativeFailure?
    let errorCode: ReceiverTranscriptNativeErrorCode

    init(taskID: Int, nonce: UUID, body: Data?, failure: ReceiverTranscriptNativeFailure?,
         errorCode: ReceiverTranscriptNativeErrorCode = .none) {
        self.taskID = taskID; self.nonce = nonce; self.body = body; self.failure = failure; self.errorCode = errorCode
    }
}

protocol ReceiverTranscriptNativeTransport: AnyObject, Sendable {
    var identifier: String { get }
    func tasks() async -> [ReceiverTranscriptNativeTask]
    func create(nonce: UUID, file: URL, due: Date) throws -> Int
    func resume(_ taskID: Int)
    func invalidateAndDrain() async
}

typealias ReceiverTranscriptNativeFactory = (
    AutomaticReceiverCredentials, BackgroundSessionEventTracker,
    @escaping @Sendable (ReceiverTranscriptNativeResult) async -> Void,
    @escaping @Sendable (BackgroundSessionEvent) async -> Void
) throws -> any ReceiverTranscriptNativeTransport

/// This session transfers a real capability query and its response, without
/// waiting for the app's timer. It never uploads audio or asks the Mac to run ASR.
final class ReceiverTranscriptNativeClient: NSObject, ReceiverTranscriptNativeTransport, URLSessionDataDelegate, @unchecked Sendable {
    let identifier: String
    private let credentials: AutomaticReceiverCredentials
    private let endpoint: URL
    private let tracker: BackgroundSessionEventTracker
    private let complete: @Sendable (ReceiverTranscriptNativeResult) async -> Void
    private let finished: @Sendable (BackgroundSessionEvent) async -> Void
    private let events = AutomaticReceiverEventDrain()
    private let invalidation = AutomaticReceiverInvalidationBarrier()
    private var session: URLSession!
    // The serial delegate queue owns these dictionaries.
    private var bodies: [Int: Data] = [:]
    private var rejected: [Int: ReceiverTranscriptNativeFailure] = [:]
    private var rejectedSessionTLS = false

    static func identifier(for scope: AutomaticDeliveryScope) -> String {
        (Bundle.main.bundleIdentifier ?? "RecordForAgent") + ".transcript-query." + scope.grantEpoch.uuidString.lowercased()
    }

    static func sessionConfiguration(identifier: String) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.isDiscretionary = false; config.sessionSendsLaunchEvents = true
        config.waitsForConnectivity = true; config.allowsCellularAccess = false
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil; config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        // Delayed queries were observed timing out before their planned start.
        // Keep the finite seven-day Foundation default so a one-hour retry
        // or one-day future plan has scheduling and transfer headroom.
        config.timeoutIntervalForResource = 7 * 24 * 60 * 60
        return config
    }

    init(credentials: AutomaticReceiverCredentials, tracker: BackgroundSessionEventTracker,
         complete: @escaping @Sendable (ReceiverTranscriptNativeResult) async -> Void,
         finished: @escaping @Sendable (BackgroundSessionEvent) async -> Void) throws {
        guard let base = AutomaticReceiverPairingPayload.endpointURL(credentials.scope.endpoint),
              AutomaticReceiverPairingPayload.isDigest(credentials.scope.certificateSHA256),
              AutomaticReceiverPairingPayload.validToken(credentials.token) else { throw AutomaticReceiverError.invalidPairing }
        self.credentials = credentials; self.tracker = tracker; self.complete = complete; self.finished = finished
        endpoint = base.appendingPathComponent("v1/transcripts/query")
        identifier = Self.identifier(for: credentials.scope)
        super.init()
        let config = Self.sessionConfiguration(identifier: identifier)
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        queue.name = "RecordForAgent.transcript-query"
        session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }

    func tasks() async -> [ReceiverTranscriptNativeTask] {
        await session.allTasks.filter { $0.state != .completed }.map {
            let request = $0.originalRequest
            let description = $0.taskDescription.flatMap(UUID.init(uuidString:))
            let header = request?.value(forHTTPHeaderField: "X-Query-Attempt").flatMap(UUID.init(uuidString:))
            return .init(taskID: $0.taskIdentifier, nonce: description == header ? description : nil,
                requestURL: request?.url, method: request?.httpMethod,
                bodySHA256: request?.value(forHTTPHeaderField: "X-Query-Body-SHA256"),
                bodyBytes: $0.countOfBytesClientExpectsToSend, suspended: $0.state == .suspended)
        }
    }
    func create(nonce: UUID, file: URL, due: Date) throws -> Int {
        var result = 0
        try invalidation.whileActive {
            let bytes = try ReceiverTranscriptPrivateFiles.read(file, limit: 32 * 1_024)
            guard bytes.count <= 32 * 1_024 else { throw AutomaticReceiverTranscriptError.invalidResponse }
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer " + credentials.token, forHTTPHeaderField: "Authorization")
            request.setValue(nonce.uuidString.lowercased(), forHTTPHeaderField: "X-Query-Attempt")
            request.setValue(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), forHTTPHeaderField: "X-Query-Body-SHA256")
            let task = session.uploadTask(with: request, fromFile: file)
            task.taskDescription = nonce.uuidString.lowercased()
            task.earliestBeginDate = due
            task.countOfBytesClientExpectsToSend = Int64(bytes.count)
            task.countOfBytesClientExpectsToReceive = Int64(AutomaticReceiverTranscriptClient.maximumResponseBytes)
            result = task.taskIdentifier
        }
        return result
    }
    func resume(_ taskID: Int) {
        session.getAllTasks { tasks in tasks.first { $0.taskIdentifier == taskID }?.resume() }
    }
    func invalidateAndDrain() async {
        invalidation.request { session.invalidateAndCancel() }
        await invalidation.wait()
    }
    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        let barrier = invalidation
        events.append { barrier.complete() }
    }
    private func credential(_ challenge: URLAuthenticationChallenge) -> URLCredential? {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              Self.acceptsPeer(trust, host: challenge.protectionSpace.host, port: challenge.protectionSpace.port,
                scope: credentials.scope) else { return nil }
        return URLCredential(trust: trust)
    }
    static func acceptsPeer(_ trust: SecTrust, host: String, port: Int, scope: AutomaticDeliveryScope) -> Bool {
        guard let base = AutomaticReceiverPairingPayload.endpointURL(scope.endpoint),
              host.caseInsensitiveCompare(base.host ?? "") == .orderedSame,
              port == (base.port ?? 443) else { return false }
        return AutomaticReceiverPinnedTLS.accepts(trust, host: host, certificateSHA256: scope.certificateSHA256)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let value = credential(challenge) else {
            rejected[task.taskIdentifier] = .tls; completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        completionHandler(.useCredential, value)
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard let value = credential(challenge) else {
            rejectedSessionTLS = true; completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        completionHandler(.useCredential, value)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse,
              AutomaticReceiverResponseURLPolicy.matches(expected: endpoint, response: response.url),
              response.mimeType == "application/json", response.expectedContentLength <= Int64(AutomaticReceiverTranscriptClient.maximumResponseBytes) else {
            rejected[dataTask.taskIdentifier] = .response; completionHandler(.cancel); return
        }
        guard response.statusCode == 200 else {
            rejected[dataTask.taskIdentifier] = .http; completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let previous = bodies[dataTask.taskIdentifier] ?? Data()
        guard previous.count <= AutomaticReceiverTranscriptClient.maximumResponseBytes - data.count else {
            rejected[dataTask.taskIdentifier] = .response; dataTask.cancel(); return
        }
        bodies[dataTask.taskIdentifier] = previous + data
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let body = bodies.removeValue(forKey: task.taskIdentifier) ?? Data()
        var failure = rejected.removeValue(forKey: task.taskIdentifier)
        if rejectedSessionTLS { failure = .tls }
        // One attempt owns this session at a time. A rejected connection must
        // not taint every later, independently challenged request forever.
        rejectedSessionTLS = false
        if failure == nil, let error { failure = (error as? URLError)?.code == .cancelled ? .cancelled : .network }
        if failure == nil {
            guard let response = task.response as? HTTPURLResponse, response.statusCode == 200,
                  response.mimeType == "application/json",
                  AutomaticReceiverResponseURLPolicy.matches(expected: endpoint, response: response.url) else {
                emit(task, body: nil, failure: .response, errorCode: .classify(error)); return
            }
        }
        emit(task, body: failure == nil ? body : nil, failure: failure, errorCode: .classify(error))
    }
    private func emit(_ task: URLSessionTask, body: Data?, failure: ReceiverTranscriptNativeFailure?,
                      errorCode: ReceiverTranscriptNativeErrorCode) {
        guard let text = task.taskDescription, let nonce = UUID(uuidString: text) else { return }
        let result = ReceiverTranscriptNativeResult(taskID: task.taskIdentifier, nonce: nonce, body: body, failure: failure, errorCode: errorCode)
        let callback = complete
        events.append { await callback(result) }
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let event = tracker.capture(identifier), callback = finished
        events.append { await callback(event) }
    }
}

/// One durable native attempt per immutable grant. Full query identity and the
/// request digest are committed before resume. A completed response remains
/// replayable across a crash until the current authorization commits it.
@MainActor
final class ReceiverTranscriptBackgroundQueue {
    struct DeferredAttempt {
        let nonce: UUID
        let queries: [AutomaticReceiverTranscriptQuery]
        let due: Date
    }
    private enum InvalidationReason: String {
        case pause, retire, ambiguousDrain = "ambiguous_drain", taskBinding = "task_binding"
        case missingTask = "missing_task", persistence, registration, supersededFuture = "superseded_future"

        var countsAsInterruption: Bool {
            switch self {
            case .pause, .retire, .supersededFuture: return false
            default: return true
            }
        }
    }
    private enum FailurePhase: String { case completion, replay, persistence }
    private struct Attempt: Codable {
        let nonce: UUID
        let queries: [AutomaticReceiverTranscriptQuery]
        let bodySHA256: String
        let bodyBytes: Int
        let due: Date
        let created: Date
        var taskID: Int?
        var responseSHA256: String?
        var responseBytes: Int?
    }
    private struct State: Codable {
        let schemaVersion: Int
        let scope: AutomaticDeliveryScope
        var failures: Int
        var retryAt: Date?
        var attempt: Attempt?
    }
    private let credentials: AutomaticReceiverCredentials
    private let directory: URL
    private let gate: BackgroundSessionRestorationGate
    private let factory: ReceiverTranscriptNativeFactory
    private let consume: ([AutomaticReceiverTranscriptQuery], Data) throws -> Int?
    private let changed: () -> Void
    private let beforeFinish: () async -> Void
    private let diagnostic: @Sendable (String, String) -> Void
    private let retry: (Date) -> Void
    private let now: () -> Date
    private var state: State
    private var client: (any ReceiverTranscriptNativeTransport)?
    private var recovering = false
    private var revision: UInt64 = 0
    private var enabled: Bool
    private var retired = false
    private var handoff: Task<Void, Never>?
    private var epoch = UUID()
    private let diagnosticRun = String(UUID().uuidString.prefix(8)).lowercased()
    private var diagnosticQueries: [UUID: Int] = [:]
    private var diagnosticSequence = 0
    let identifier: String

    init(credentials: AutomaticReceiverCredentials, directory: URL, gate: BackgroundSessionRestorationGate,
         enabled: Bool, factory: @escaping ReceiverTranscriptNativeFactory,
         now: @escaping () -> Date = Date.init,
         diagnostic: @escaping @Sendable (String, String) -> Void, retry: @escaping (Date) -> Void,
         consume: @escaping ([AutomaticReceiverTranscriptQuery], Data) throws -> Int?,
         changed: @escaping () -> Void, beforeFinish: @escaping () async -> Void = {}) throws {
        self.credentials = credentials; self.directory = directory; self.gate = gate; self.enabled = enabled
        self.factory = factory; self.now = now; self.diagnostic = diagnostic; self.retry = retry
        self.consume = consume; self.changed = changed; self.beforeFinish = beforeFinish
        identifier = ReceiverTranscriptNativeClient.identifier(for: credentials.scope)
        state = State(schemaVersion: 1, scope: credentials.scope, failures: 0)
        let url = directory.appendingPathComponent("native-query-state.json")
        if try ReceiverTranscriptPrivateFiles.exists(url) {
            state = try TransportCodec.decode(State.self, from: Self.read(url, limit: 128 * 1_024))
            guard state.schemaVersion == 1, state.scope == credentials.scope, (0...30).contains(state.failures),
                  state.retryAt?.timeIntervalSince1970.isFinite != false else { throw AutomaticReceiverTranscriptError.invalidResponse }
            if let attempt = state.attempt {
                let body = try AutomaticReceiverTranscriptClient.requestBody(attempt.queries, scope: credentials.scope)
                guard attempt.bodySHA256 == Self.hash(body), attempt.bodyBytes == body.count,
                      attempt.taskID.map({ $0 > 0 }) != false,
                      attempt.due.timeIntervalSince1970.isFinite, attempt.created.timeIntervalSince1970.isFinite,
                      (attempt.responseSHA256 == nil) == (attempt.responseBytes == nil),
                      attempt.responseSHA256.map(AutomaticReceiverPairingPayload.isDigest) != false,
                      attempt.responseBytes.map({ (0...AutomaticReceiverTranscriptClient.maximumResponseBytes).contains($0) }) != false else {
                    throw AutomaticReceiverTranscriptError.invalidResponse
                }
                guard try Self.read(requestURL(attempt.nonce), limit: 32 * 1_024) == body else { throw AutomaticReceiverTranscriptError.invalidResponse }
            }
        }
        gate.registerRestore(identifier) { [weak self] in self?.restore() }
    }
    var canRegister: Bool { enabled && !retired && client != nil && !recovering && handoff == nil && state.attempt == nil }
    var retryAt: Date? { state.retryAt }
    var hasAttempt: Bool { state.attempt != nil }
    var isRecovering: Bool { recovering }
    var deferredAttempt: DeferredAttempt? {
        guard enabled, !retired, handoff == nil, let attempt = state.attempt,
              attempt.responseSHA256 == nil, attempt.due > now() else { return nil }
        return .init(nonce: attempt.nonce, queries: attempt.queries, due: attempt.due)
    }

    /// The caller proves that every old item is exact no-speech and that a new
    /// or already due authorized source lacks local text. Keep this tied to the
    /// current immutable scope, nonce and complete request bytes. No new owner
    /// may be created until native invalidation and ordered callbacks drain.
    @discardableResult
    func supersedeDeferredAttempt(_ expected: DeferredAttempt) -> Bool {
        guard enabled, !retired, !recovering, handoff == nil, let attempt = state.attempt,
              attempt.nonce == expected.nonce, attempt.due == expected.due,
              attempt.due > now(), attempt.responseSHA256 == nil,
              let body = try? AutomaticReceiverTranscriptClient.requestBody(expected.queries, scope: credentials.scope),
              Self.hash(body) == attempt.bodySHA256 else { return false }
        invalidate(reason: .supersededFuture)
        return true
    }

    func setEnabled(_ value: Bool) {
        guard !retired else { return }
        enabled = value
        if value { restore(); replay() }
        else { invalidate(reason: .pause) }
    }
    func retire() { enabled = false; retired = true; invalidate(reason: .retire) }
    func restore(executionLease: (any AutomaticDeliveryExecutionLease)? = nil) {
        guard handoff == nil, !retired || gate.hasPendingCompletion(identifier),
              gate.canRestore(identifier) || executionLease?.hasTimeRemaining == true else { return }
        if client == nil {
            guard state.attempt != nil || gate.hasPendingCompletion(identifier) || enabled else { return }
            do {
                let currentEpoch = UUID(); epoch = currentEpoch
                client = try factory(credentials, gate.eventTracker, { [weak self] result in
                    await self?.receive(result, epoch: currentEpoch)
                }, { [weak self] event in await self?.finish(event, epoch: currentEpoch) })
            } catch {
                diagnostic("phone.transcript_native_restore_failed", "category=transport")
                if gate.hasPendingCompletion(identifier) { gate.cancelUnrestorable(identifier) }
                return
            }
        }
        if !enabled || gate.requiresInvalidation(identifier) {
            invalidate(reason: retired ? .retire : enabled ? .ambiguousDrain : .pause); return
        }
        guard !recovering, let client else { return }
        recovering = true
        let version = revision, currentEpoch = epoch, attempt = state.attempt
        Task { [weak self] in
            let tasks = await client.tasks()
            guard let self, self.epoch == currentEpoch, self.revision == version, self.handoff == nil else { return }
            self.recovering = false
            // Enumeration is asynchronous. A finite WC/foreground opportunity
            // may have expired while the OS was returning its task snapshot.
            guard self.gate.canRestore(self.identifier) || executionLease?.hasTimeRemaining == true else { return }
            if !tasks.isEmpty {
                guard tasks.count == 1, let task = tasks.first, let attempt,
                      task.nonce == attempt.nonce, task.bodySHA256 == attempt.bodySHA256,
                      task.bodyBytes == Int64(attempt.bodyBytes), task.method == "POST",
                      let base = AutomaticReceiverPairingPayload.endpointURL(self.credentials.scope.endpoint),
                      AutomaticReceiverResponseURLPolicy.matches(expected: base.appendingPathComponent("v1/transcripts/query"), response: task.requestURL),
                      (attempt.taskID == nil ? task.suspended : task.taskID == attempt.taskID) else {
                    self.invalidate(reason: .taskBinding); return
                }
                if attempt.taskID == nil {
                    self.state.attempt?.taskID = task.taskID
                    do { try self.persist() }
                    catch { self.enabled = false; self.invalidate(reason: .persistence); return }
                }
                if task.suspended, self.gate.canRestore(self.identifier) || executionLease?.hasTimeRemaining == true {
                    client.resume(task.taskID)
                }
            }
            if let attempt, attempt.responseSHA256 == nil, tasks.isEmpty {
                // Task completion may still be queued behind enumeration. Keep
                // exact ownership until the resource deadline plus a short grace.
                let deadline = max(attempt.created, attempt.due).addingTimeInterval(180)
                if self.now() >= deadline { self.invalidate(reason: .missingTask); return }
                self.retry(deadline)
            }
            self.replay(); self.changed()
        }
    }
    func register(_ queries: [AutomaticReceiverTranscriptQuery], due: Date,
                  executionLease: (any AutomaticDeliveryExecutionLease)? = nil) throws {
        guard canRegister, let client, due.timeIntervalSince1970.isFinite,
              executionLease?.hasTimeRemaining != false else { return }
        let bytes = try AutomaticReceiverTranscriptClient.requestBody(queries, scope: credentials.scope)
        let nonce = UUID(), date = max(due, state.retryAt ?? .distantPast)
        try write(bytes, to: requestURL(nonce))
        let previous = state
        state.attempt = Attempt(nonce: nonce, queries: queries, bodySHA256: Self.hash(bytes), bodyBytes: bytes.count,
            due: date, created: now())
        do { try persist() }
        catch {
            state = previous
            try? ReceiverTranscriptPrivateFiles.remove(requestURL(nonce))
            throw error
        }
        do {
            let taskID = try client.create(nonce: nonce, file: requestURL(nonce), due: date)
            state.attempt?.taskID = taskID
            try persist() // task remains suspended until this exact ID is durable
            revision &+= 1
            guard executionLease?.hasTimeRemaining != false else { throw CancellationError() }
            client.resume(taskID)
            emit("registered", "batch=\(queries.count) delay_seconds=\(max(0, Int(date.timeIntervalSince(now()))))", nonce: nonce)
        } catch {
            // A suspended task may already exist. Invalidate before allowing any
            // replacement, even when persisting its native task ID failed.
            invalidate(reason: .registration)
            throw error
        }
    }
    func replay() {
        guard enabled, !retired, handoff == nil, let attempt = state.attempt,
              let hash = attempt.responseSHA256, let size = attempt.responseBytes else { return }
        do {
            let data = try Self.read(responseURL(attempt.nonce), limit: AutomaticReceiverTranscriptClient.maximumResponseBytes)
            guard data.count == size, Self.hash(data) == hash else { throw AutomaticReceiverTranscriptError.invalidResponse }
            guard let savedCount = try consume(attempt.queries, data) else { return }
            emit("response_accepted", "batch=\(attempt.queries.count)", nonce: attempt.nonce)
            if savedCount > 0 { emit("strict_saved", "count=\(savedCount)", nonce: attempt.nonce) }
            let previous = state
            state.attempt = nil; state.failures = 0; state.retryAt = nil
            do { try persist() } catch { state = previous; enabled = false; throw error }
            removeFiles(attempt); changed()
        } catch { fail(.response, phase: .replay) }
    }
    private func receive(_ result: ReceiverTranscriptNativeResult, epoch: UUID) {
        guard self.epoch == epoch, let attempt = state.attempt, result.nonce == attempt.nonce,
              result.taskID == attempt.taskID else { return }
        revision &+= 1; recovering = false
        guard enabled, !retired, handoff == nil else { return }
        if let failure = result.failure { fail(failure, errorCode: result.errorCode, phase: .completion); return }
        do {
            guard let body = result.body, body.count <= AutomaticReceiverTranscriptClient.maximumResponseBytes else {
                throw AutomaticReceiverTranscriptError.invalidResponse
            }
            try write(body, to: responseURL(attempt.nonce))
            let previous = state
            state.attempt?.responseSHA256 = Self.hash(body); state.attempt?.responseBytes = body.count
            do { try persist() }
            catch { state = previous; throw error } // Uncommitted response metadata is never replay authority.
            emit("response_stored", "bounded=true", nonce: attempt.nonce)
            replay()
        } catch { fail(.response, phase: .persistence) }
    }
    private func fail(_ failure: ReceiverTranscriptNativeFailure, errorCode: ReceiverTranscriptNativeErrorCode = .none,
                      phase: FailurePhase) {
        let previous = state
        state.attempt = nil; state.failures = min(30, state.failures + 1)
        state.retryAt = now().addingTimeInterval(min(3_600, 60 * pow(2, Double(min(6, state.failures - 1)))))
        do { try persist(); if let attempt = previous.attempt { removeFiles(attempt) } }
        catch { state = previous; enabled = false }
        if let attempt = previous.attempt {
            emit("failed", "category=\(failure.rawValue) error_code=\(errorCode.rawValue) phase=\(phase.rawValue)"
                + " elapsed_seconds=\(Self.diagnosticSeconds(now().timeIntervalSince(attempt.created)))"
                + " due_in_seconds=\(Self.diagnosticSeconds(attempt.due.timeIntervalSince(now())))", nonce: attempt.nonce)
        } else { diagnostic("phone.transcript_native_failed", "category=\(failure.rawValue) error_code=\(errorCode.rawValue) phase=\(phase.rawValue)") }
        if let date = state.retryAt { retry(date) }
        changed()
    }
    private func invalidate(reason: InvalidationReason) {
        guard handoff == nil else { return }
        if client == nil {
            guard state.attempt != nil || gate.hasPendingCompletion(identifier) else {
                if retired { gate.unregisterRestore(identifier) }; return
            }
            // Restore only this grant to cancel its retained native task.
            do {
                let currentEpoch = UUID(); epoch = currentEpoch
                client = try factory(credentials, gate.eventTracker, { [weak self] result in
                    await self?.receive(result, epoch: currentEpoch)
                }, { [weak self] event in await self?.finish(event, epoch: currentEpoch) })
            } catch { gate.cancelUnrestorable(identifier); return }
        }
        let token = gate.beginHandoff(identifier), current = client
        let hadAttempt = state.attempt != nil
        if let attempt = state.attempt {
            emit("invalidation_started", "reason=\(reason.rawValue) has_attempt=true", nonce: attempt.nonce)
        } else { diagnostic("phone.transcript_native_invalidation_started", "reason=\(reason.rawValue) has_attempt=false") }
        revision &+= 1; recovering = false
        handoff = Task { [self] in
            await current?.invalidateAndDrain()
            client = nil
            let previous = state
            state.attempt = nil
            if enabled && !retired && hadAttempt && reason.countsAsInterruption {
                state.failures = min(30, state.failures + 1)
                state.retryAt = now().addingTimeInterval(min(3_600, 60 * pow(2, Double(min(6, state.failures - 1)))))
            }
            do { try persist(); if let attempt = previous.attempt { removeFiles(attempt) } }
            catch { state = previous; enabled = false }
            gate.completeHandoff(identifier, token: token)
            handoff = nil
            if retired { gate.unregisterRestore(identifier) }
            else if enabled { restore(); changed() }
        }
    }
    private func finish(_ event: BackgroundSessionEvent, epoch: UUID) async {
        guard self.epoch == epoch else { return }
        // Result callbacks precede this event in the transport's serial drain;
        // replay has already committed, deferred or rejected their private data.
        await beforeFinish()
        guard self.epoch == epoch else { return }
        gate.finish(event.identifier, token: event.token)
    }
    private func removeFiles(_ attempt: Attempt) {
        try? ReceiverTranscriptPrivateFiles.remove(requestURL(attempt.nonce))
        try? ReceiverTranscriptPrivateFiles.remove(responseURL(attempt.nonce))
    }
    private func emit(_ kind: String, _ detail: String, nonce: UUID) {
        if diagnosticQueries[nonce] == nil { diagnosticSequence += 1; diagnosticQueries[nonce] = diagnosticSequence }
        diagnostic("phone.transcript_native_" + kind,
            "run=\(diagnosticRun) query_seq=\(diagnosticQueries[nonce] ?? 0) " + detail)
        if diagnosticQueries.count > 32 { diagnosticQueries = [nonce: diagnosticQueries[nonce] ?? 0] }
    }
    private func requestURL(_ nonce: UUID) -> URL { directory.appendingPathComponent(nonce.uuidString.lowercased() + ".request.json") }
    private func responseURL(_ nonce: UUID) -> URL { directory.appendingPathComponent(nonce.uuidString.lowercased() + ".response.json") }
    private func persist() throws {
        let bytes = try TransportCodec.encode(state)
        guard bytes.count <= 128 * 1_024 else { throw AutomaticReceiverTranscriptError.invalidResponse }
        try write(bytes, to: directory.appendingPathComponent("native-query-state.json"))
    }
    private func write(_ bytes: Data, to url: URL) throws {
        try ReceiverTranscriptPrivateFiles.write(bytes, to: url)
    }
    private static func read(_ url: URL, limit: Int) throws -> Data {
        try ReceiverTranscriptPrivateFiles.read(url, limit: limit)
    }
    private static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private static func diagnosticSeconds(_ interval: TimeInterval) -> Int {
        guard interval.isFinite else { return 0 }
        return Int(max(0, min(604_800, interval)))
    }
}

/// The native authority is durable before resume: private exclusive temporary,
/// descriptor-bound single-link reads, file sync, atomic rename, directory sync.
enum ReceiverTranscriptPrivateFiles {
    static func remove(_ file: URL) throws {
        let parent = Darwin.open(file.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw AutomaticReceiverTranscriptError.invalidResponse }
        defer { Darwin.close(parent) }
        var info = stat()
        if Darwin.fstatat(parent, file.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            guard errno == ENOENT else { throw AutomaticReceiverTranscriptError.invalidResponse }; return
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              Darwin.unlinkat(parent, file.lastPathComponent, 0) == 0,
              Darwin.fsync(parent) == 0 else { throw AutomaticReceiverTranscriptError.invalidResponse }
    }
    static func exists(_ file: URL) throws -> Bool {
        var info = stat()
        if Darwin.lstat(file.path, &info) == 0 { return true }
        guard errno == ENOENT else { throw AutomaticReceiverTranscriptError.invalidResponse }; return false
    }
    static func read(_ file: URL, limit: Int) throws -> Data {
        let parent = Darwin.open(file.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw AutomaticReceiverTranscriptError.invalidResponse }
        defer { Darwin.close(parent) }
        let fd = Darwin.openat(parent, file.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw AutomaticReceiverTranscriptError.invalidResponse }
        defer { Darwin.close(fd) }
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_size > 0, info.st_size <= limit else { throw AutomaticReceiverTranscriptError.invalidResponse }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let bytes = try handle.read(upToCount: limit + 1), bytes.count == info.st_size,
              bytes.count <= limit else { throw AutomaticReceiverTranscriptError.invalidResponse }
        return bytes
    }
    static func write(_ bytes: Data, to file: URL) throws {
        guard !bytes.isEmpty, bytes.count <= AutomaticReceiverTranscriptClient.maximumResponseBytes else {
            throw AutomaticReceiverTranscriptError.invalidResponse
        }
        let directory = file.deletingLastPathComponent(), fm = FileManager.default
        if try !exists(directory) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let parent = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw AutomaticReceiverTranscriptError.invalidResponse }
        defer { Darwin.close(parent) }
        guard Darwin.fchmod(parent, 0o700) == 0 else { throw AutomaticReceiverTranscriptError.invalidResponse }
        var old = stat()
        if Darwin.fstatat(parent, file.lastPathComponent, &old, AT_SYMLINK_NOFOLLOW) == 0 {
            guard old.st_mode & S_IFMT == S_IFREG, old.st_nlink == 1 else { throw AutomaticReceiverTranscriptError.invalidResponse }
        } else if errno != ENOENT { throw AutomaticReceiverTranscriptError.invalidResponse }
        let temporary = ".query-" + UUID().uuidString.lowercased()
        let fd = Darwin.openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AutomaticReceiverTranscriptError.invalidResponse }
        defer { Darwin.close(fd); Darwin.unlinkat(parent, temporary, 0) }
        #if os(iOS)
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.appendingPathComponent(temporary).path)
        #endif
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.write(contentsOf: bytes); try handle.synchronize()
        guard Darwin.renameat(parent, temporary, parent, file.lastPathComponent) == 0,
              Darwin.fsync(parent) == 0 else { throw AutomaticReceiverTranscriptError.invalidResponse }
    }
}
