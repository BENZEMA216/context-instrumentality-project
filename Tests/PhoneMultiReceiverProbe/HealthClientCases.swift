import Foundation
import RecordingCore

private final class HealthProtocolState: @unchecked Sendable {
    enum Reply: Sendable {
        case response(Int, Data, URL?, Int?)
        case failure(Int)
        case hold
    }
    private let lock = NSLock()
    private var reply: Reply = .hold
    private var recorded: [URLRequest] = []
    func install(_ reply: Reply) { lock.lock(); self.reply = reply; recorded = []; lock.unlock() }
    func accept(_ request: URLRequest) -> Reply {
        lock.lock(); defer { lock.unlock() }; recorded.append(request); return reply
    }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
}

/// URLProtocol consumes every request locally. No DNS, TLS socket, private file,
/// upload or actual receiver is involved in these transport regressions.
private final class HealthProbeURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = HealthProtocolState()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        switch Self.state.accept(request) {
        case let .response(status, data, url, contentLength):
            var headers = ["Content-Type": "application/json"]
            if let contentLength { headers["Content-Length"] = String(contentLength) }
            if (300...399).contains(status) { headers["Location"] = "https://other.invalid/v1/status" }
            let response = HTTPURLResponse(url: url ?? request.url!, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(code):
            client?.urlProtocol(self, didFailWithError: NSError(domain: NSURLErrorDomain, code: code,
                userInfo: [NSLocalizedDescriptionKey: "synthetic-private-host.invalid/synthetic-path"]))
        case .hold: break
        }
    }
    override func stopLoading() {}
}

@MainActor
extension Probe {
    private func healthCredentials() -> AutomaticReceiverCredentials {
        let payload = payload("health-native")
        return .init(scope: .init(receiverID: payload.receiverID, pairingID: UUID(), grantEpoch: UUID(),
            sourceInstallationID: UUID(), endpoint: payload.endpoint, certificateSHA256: payload.certificateSHA256),
            token: payload.token)
    }
    private func healthReady(_ id: UUID) -> Data {
        Data("{\"schemaVersion\":1,\"receiverID\":\"\(id.uuidString)\",\"status\":\"ready\"}".utf8)
    }
    private func healthCheck(_ credentials: AutomaticReceiverCredentials, timeout: TimeInterval = 1) async -> AutomaticReceiverProbeResult {
        await AutomaticReceiverHealthClient.check(credentials, protocolClasses: [HealthProbeURLProtocol.self], timeout: timeout)
    }

    func executeHealthClientCases() async {
        await run("receiver_health_client_ready_is_authenticated_read_only_get") { _ in
            let credentials = self.healthCredentials()
            HealthProbeURLProtocol.state.install(.response(200, self.healthReady(credentials.scope.receiverID), nil, nil))
            let result = await self.healthCheck(credentials)
            try self.check(result == .reachable, "Only validated ready status establishes reachability")
            let requests = HealthProbeURLProtocol.state.requests
            try self.check(requests.count == 1, "One natural health check emits one request")
            guard let request = requests.first else { throw ProbeFailure.failed("No synthetic health request") }
            try self.check(request.url?.absoluteString == credentials.scope.endpoint + "/v1/status", "Health GET stays on exact paired status URL")
            try self.check(request.httpMethod == "GET" && request.httpBody == nil && request.httpBodyStream == nil,
                "Status check must neither upload nor read an archive")
            try self.check(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + credentials.token,
                "Status endpoint requires the paired bearer credential")
            try self.check(request.cachePolicy == .reloadIgnoringLocalCacheData, "Cached status cannot establish current reachability")
            try self.check(request.timeoutInterval <= AutomaticReceiverHealthClient.timeout, "Request timeout remains bounded")
        }
        await run("receiver_health_client_http_200_requires_paired_identity_and_schema") { _ in
            let credentials = self.healthCredentials()
            for body in [self.healthReady(UUID()), Data("OK".utf8), Data("{}".utf8),
                         Data("{\"schemaVersion\":1,\"receiverID\":\"\(credentials.scope.receiverID)\",\"status\":\"starting\"}".utf8)] {
                HealthProbeURLProtocol.state.install(.response(200, body, nil, nil))
                let result = await self.healthCheck(credentials)
                try self.check(result == .failed(.invalidResponse), "HTTP 200 without the exact ready identity must fail")
            }
        }
        await run("receiver_health_client_http_errors_and_redirects_are_not_reachable") { _ in
            let credentials = self.healthCredentials()
            let cases: [(Int, AutomaticReceiverFailureCategory)] = [(401, .unauthorized), (403, .unauthorized),
                (503, .server), (302, .invalidResponse), (204, .invalidResponse)]
            for (status, category) in cases {
                HealthProbeURLProtocol.state.install(.response(status, self.healthReady(credentials.scope.receiverID), nil, nil))
                let result = await self.healthCheck(credentials)
                try self.check(result == .failed(category), "HTTP failure keeps its fixed category")
                try self.check(HealthProbeURLProtocol.state.requests.count == 1, "No redirect or retry may disclose credentials to a second target")
            }
        }
        await run("receiver_health_client_legacy_status_endpoint_is_neutral") { _ in
            let credentials = self.healthCredentials()
            for status in [404, 405, 501] {
                HealthProbeURLProtocol.state.install(.response(status, Data("legacy response".utf8), nil, nil))
                let result = await self.healthCheck(credentials)
                try self.check(result == .unsupportedProbe, "A legacy status endpoint provides a neutral upgrade result")
                try self.check(result != .reachable && result != .failed(.unsupportedProbe),
                    "Unsupported status establishes neither ready identity nor an unreachable failure")
                try self.check(HealthProbeURLProtocol.state.requests.count == 1, "Legacy status does not trigger retry or fallback upload")
            }
            HealthProbeURLProtocol.state.install(.response(405, Data(), URL(string: "https://other.invalid/v1/status"), nil))
            let changedOrigin = await self.healthCheck(credentials)
            try self.check(changedOrigin == .failed(.invalidResponse), "A response from a changed origin cannot become a neutral upgrade result")
        }
        await run("receiver_health_transfer_repair_requirement_overrides_weaker_categories") { _ in
            let scope = self.healthCredentials().scope
            let deliveryID = UUID()
            let categories: [AutomaticReceiverFailureCategory?] = [nil, .invalidResponse, .certificate,
                .unauthorized, .unsupportedProbe, .timeout, .localState]
            for category in categories {
                let result = AutomaticReceiverTransferResult(scope: scope, deliveryID: deliveryID, receipt: nil,
                    statusCode: 200, message: "synthetic-private-error", requiresRepair: true,
                    attemptCount: 2, failureCategory: category)
                try self.check(result.failureCategory == .pairingRepairRequired,
                    "A durable repair requirement must expose re-pair recovery regardless of HTTP or lower-level cause")
                try self.check(result.requiresRepair && result.deliveryID == deliveryID && result.attemptCount == 2,
                    "Category normalization preserves the retry identity and repair gate")
            }
            let retryable = AutomaticReceiverTransferResult(scope: scope, deliveryID: deliveryID, receipt: nil,
                statusCode: nil, message: nil, requiresRepair: false, failureCategory: .timeout)
            try self.check(retryable.failureCategory == .timeout && !retryable.requiresRepair,
                "A retryable network failure must not acquire a re-pair gate")
        }
        await run("receiver_health_client_changed_origin_and_oversized_response_fail") { _ in
            let credentials = self.healthCredentials()
            let replies: [HealthProtocolState.Reply] = [
                .response(200, self.healthReady(credentials.scope.receiverID), URL(string: "https://other.invalid/v1/status"), nil),
                .response(200, self.healthReady(credentials.scope.receiverID), nil, 100_000),
                .response(200, Data(repeating: 32, count: AutomaticReceiverProbeResult.maximumResponseBytes + 1), nil, nil)
            ]
            for reply in replies {
                HealthProbeURLProtocol.state.install(reply)
                let result = await self.healthCheck(credentials)
                try self.check(result == .failed(.invalidResponse), "Wrong origin and unbounded bodies cannot become healthy")
            }
        }
        await run("receiver_health_client_transport_failures_keep_safe_categories") { _ in
            let credentials = self.healthCredentials()
            let cases: [(Int, AutomaticReceiverFailureCategory)] = [(NSURLErrorCannotFindHost, .dns),
                (NSURLErrorCannotConnectToHost, .cannotConnect), (NSURLErrorTimedOut, .timeout),
                (NSURLErrorNotConnectedToInternet, .offline), (NSURLErrorDataNotAllowed, .networkRestricted),
                (NSURLErrorAppTransportSecurityRequiresSecureConnection, .atsBlocked),
                (NSURLErrorServerCertificateUntrusted, .certificate)]
            for (code, category) in cases {
                HealthProbeURLProtocol.state.install(.failure(code))
                let result = await self.healthCheck(credentials)
                try self.check(result == .failed(category), "Native URLSession errors must survive as fixed categories")
            }
        }
        await run("receiver_health_client_deadline_completes_stalled_request_without_polling") { _ in
            let credentials = self.healthCredentials()
            HealthProbeURLProtocol.state.install(.hold)
            let started = ProcessInfo.processInfo.systemUptime
            let result = await self.healthCheck(credentials, timeout: 0.1)
            try self.check(result == .failed(.timeout), "A stalled transport must resolve to timeout")
            try self.check(ProcessInfo.processInfo.systemUptime - started < 2, "One-shot deadline must resolve even without a transport callback")
            try await self.settle()
            try self.check(HealthProbeURLProtocol.state.requests.count == 1, "Deadline cannot schedule periodic probes or retries")
        }
        await run("receiver_health_client_cancellation_completes_stalled_request") { _ in
            let credentials = self.healthCredentials()
            HealthProbeURLProtocol.state.install(.hold)
            let task = Task { await self.healthCheck(credentials) }
            try await self.eventually("synthetic request starts") { HealthProbeURLProtocol.state.requests.count == 1 }
            task.cancel()
            let result = await task.value
            try self.check(result == .failed(.cancelled), "Cancellation resolves once and preserves its category")
            try self.check(HealthProbeURLProtocol.state.requests.count == 1, "Cancelled request must not retry")
        }
    }
}
