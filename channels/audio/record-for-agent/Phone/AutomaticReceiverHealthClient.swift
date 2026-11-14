import Foundation
import RecordingCore

typealias AutomaticReceiverHealthCheck = @Sendable (AutomaticReceiverCredentials) async -> AutomaticReceiverProbeResult

/// One foreground, metadata-only check. Each invocation has an independent
/// eight-second deadline; it neither uploads recordings nor schedules polling.
final class AutomaticReceiverHealthClient: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let timeout: TimeInterval = 8
    private let credentials: AutomaticReceiverCredentials
    private let url: URL
    private let protocolClasses: [AnyClass]
    private let requestTimeout: TimeInterval
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AutomaticReceiverProbeResult, Never>?
    private var completedResult: AutomaticReceiverProbeResult?
    private var session: URLSession?
    private var deadline: DispatchSourceTimer?
    // Only accessed by the serial URLSession delegate queue.
    private var data = Data()
    private var rejectedTrust = false

    private init(credentials: AutomaticReceiverCredentials, endpoint: URL,
                 protocolClasses: [AnyClass], timeout: TimeInterval) {
        self.credentials = credentials
        url = endpoint.appendingPathComponent("v1/status")
        self.protocolClasses = protocolClasses
        requestTimeout = timeout.isFinite ? min(Self.timeout, max(0.01, timeout)) : Self.timeout
        super.init()
    }

    static func check(_ credentials: AutomaticReceiverCredentials) async -> AutomaticReceiverProbeResult {
        await check(credentials, protocolClasses: [], timeout: Self.timeout)
    }

    /// Isolated probes can replace URL loading without sockets; this cannot
    /// lengthen the production deadline or bypass response/pinning checks.
    static func check(_ credentials: AutomaticReceiverCredentials, protocolClasses: [AnyClass],
                      timeout: TimeInterval) async -> AutomaticReceiverProbeResult {
        guard let endpoint = AutomaticReceiverPairingPayload.endpointURL(credentials.scope.endpoint),
              AutomaticReceiverPairingPayload.isDigest(credentials.scope.certificateSHA256),
              AutomaticReceiverPairingPayload.validToken(credentials.token) else { return .failed(.invalidResponse) }
        let client = AutomaticReceiverHealthClient(credentials: credentials, endpoint: endpoint,
            protocolClasses: protocolClasses, timeout: timeout)
        return await withTaskCancellationHandler(operation: {
            await client.run()
        }, onCancel: {
            client.finish(.failed(.cancelled))
        })
    }

    private func run() async -> AutomaticReceiverProbeResult {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let completedResult {
                lock.unlock()
                continuation.resume(returning: completedResult)
                return
            }
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = false
            configuration.allowsCellularAccess = false
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCredentialStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = requestTimeout
            configuration.timeoutIntervalForResource = requestTimeout
            if !protocolClasses.isEmpty { configuration.protocolClasses = protocolClasses }
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            queue.name = "RecordForAgent.receiver-health"
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
            self.session = session
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
            request.httpMethod = "GET"
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("Bearer " + credentials.token, forHTTPHeaderField: "Authorization")
            let task = session.dataTask(with: request)
            // Resource timeout alone can be delayed by URLSession. The one-shot
            // deadline also resolves the caller and cancels this entire session.
            let deadline = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            deadline.schedule(deadline: .now() + requestTimeout)
            deadline.setEventHandler { [weak self] in self?.finish(.failed(.timeout)) }
            self.deadline = deadline
            deadline.resume()
            task.resume()
            lock.unlock()
        }
    }

    private func finish(_ result: AutomaticReceiverProbeResult) {
        lock.lock()
        guard completedResult == nil else { lock.unlock(); return }
        completedResult = result
        let continuation = self.continuation
        let session = self.session
        let deadline = self.deadline
        self.continuation = nil
        self.session = nil
        self.deadline = nil
        lock.unlock()
        deadline?.cancel()
        session?.invalidateAndCancel()
        continuation?.resume(returning: result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler: completionHandler)
    }

    private func handle(_ challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host.caseInsensitiveCompare(url.host ?? "") == .orderedSame,
              let trust = challenge.protectionSpace.serverTrust,
              AutomaticReceiverPinnedTLS.accepts(trust, host: challenge.protectionSpace.host,
                certificateSHA256: credentials.scope.certificateSHA256) else {
            rejectedTrust = true
            completionHandler(.cancelAuthenticationChallenge, nil)
            finish(.failed(.certificate))
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse,
              AutomaticReceiverResponseURLPolicy.matches(expected: url, response: response.url) else {
            completionHandler(.cancel)
            finish(.failed(.invalidResponse))
            return
        }
        guard response.statusCode == 200 else {
            completionHandler(.cancel)
            finish(.httpFailure(statusCode: response.statusCode))
            return
        }
        guard response.expectedContentLength <= Int64(AutomaticReceiverProbeResult.maximumResponseBytes) else {
            completionHandler(.cancel)
            finish(.failed(.invalidResponse))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard self.data.count + data.count <= AutomaticReceiverProbeResult.maximumResponseBytes else {
            finish(.failed(.invalidResponse))
            return
        }
        self.data.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if rejectedTrust { finish(.failed(.certificate)); return }
        if let error { finish(.failed(.classify(error: error))); return }
        guard let response = task.response as? HTTPURLResponse, response.statusCode == 200,
              AutomaticReceiverResponseURLPolicy.matches(expected: url, response: response.url) else {
            finish(.failed(.invalidResponse))
            return
        }
        finish(.decodeStatus(data, receiverID: credentials.scope.receiverID))
    }
}
