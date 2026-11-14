import Darwin
import Foundation
import RecordingCore

/// Real HTTP/OAuth code, intercepted before every network request. All token
/// strings, errors and JSON are generated here; no login or Keychain is used.
enum GoogleDriveHTTPRecoveryCases {
    @MainActor private final class UploadTokens: GoogleDriveTokenProvider {
        func accessToken(for accountID: String) async throws -> String { "SYNTHETIC_PRIVATE_ACCESS_TOKEN" }
    }
    private enum Reply {
        case failure(NSError, delay: TimeInterval = 0)
        case failureAfterConfiguredIdleTimeout(NSError)
        case response(Int, Data, headers: [String: String] = [:])
    }
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private let replies: [Reply]
        private var requests: [URLRequest] = []
        private var bodies: [Data?] = []
        private var diagnostics: [GoogleDriveTransportDiagnostic] = []
        private var completions: [GoogleDriveRequestCompletion] = []
        init(_ replies: [Reply]) { self.replies = replies }
        func take(_ request: URLRequest) -> Reply {
            let body = Self.syntheticBody(request)
            lock.lock(); defer { lock.unlock() }
            requests.append(request); bodies.append(body)
            return requests.count <= replies.count ? replies[requests.count - 1]
                : .failure(NSError(domain: "SyntheticUnexpectedRetry", code: requests.count))
        }
        func record(_ value: GoogleDriveTransportDiagnostic) { lock.lock(); diagnostics.append(value); lock.unlock() }
        func finish(_ value: GoogleDriveRequestCompletion) { lock.lock(); completions.append(value); lock.unlock() }
        var captured: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
        var capturedBodies: [Data?] { lock.lock(); defer { lock.unlock() }; return bodies }
        var observed: [GoogleDriveTransportDiagnostic] { lock.lock(); defer { lock.unlock() }; return diagnostics }
        var finished: [GoogleDriveRequestCompletion] { lock.lock(); defer { lock.unlock() }; return completions }
        private static func syntheticBody(_ request: URLRequest) -> Data? {
            if let body = request.httpBody { return body }
            guard let stream = request.httpBodyStream else { return nil }
            // URLSession may expose an in-memory generated form as a stream.
            // This fixture reads only the synthetic bytes it owns.
            stream.open(); defer { stream.close() }
            var body = Data(), buffer = [UInt8](repeating: 0, count: 1_024)
            while body.count <= 65_536 {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count == 0 { return body }
                guard count > 0 else { return nil }
                body.append(contentsOf: buffer.prefix(count))
            }
            return nil
        }
    }
    private final class OfflineProtocol: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var state: State?
        private let stoppedLock = NSLock()
        private var stopped = false
        static func install(_ value: State) { lock.lock(); state = value; lock.unlock() }
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            Self.lock.lock(); let state = Self.state; Self.lock.unlock()
            guard let state else {
                client?.urlProtocol(self, didFailWithError: ProbeFailure(message: "No synthetic HTTP route")); return
            }
            let reply = state.take(request)
            if case .failure(_, let delay) = reply, delay > 0 { Thread.sleep(forTimeInterval: delay) }
            if case .failureAfterConfiguredIdleTimeout = reply {
                // No bytes arrive in this synthetic attempt. URLSession may
                // produce its own idle timeout before this delayed fixture.
                Thread.sleep(forTimeInterval: request.timeoutInterval + 0.025)
            }
            stoppedLock.lock(); let stopped = self.stopped; stoppedLock.unlock()
            guard !stopped else { return }
            switch reply {
            case .failure(let error, _), .failureAfterConfiguredIdleTimeout(let error):
                client?.urlProtocol(self, didFailWithError: error)
            case .response(let status, let data, let headers):
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"].merging(headers) { _, replacement in replacement })!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            }
        }
        override func stopLoading() { stoppedLock.lock(); stopped = true; stoppedLock.unlock() }
    }
    private static let formType = "application/x-www-form-urlencoded"
    private static let invalidGrant = Data(#"{"error":"invalid_grant"}"#.utf8)
    private static let tokenResponse = Data(#"{"access_token":"SYNTHETIC_NEW_ACCESS","expires_in":3600,"token_type":"Bearer"}"#.utf8)
    private static var timeoutError: NSError {
        NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [
            "SyntheticTimeoutMarker": "original-one-shot-timeout",
            NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT),
                userInfo: ["SyntheticUnderlyingMarker": "preserve-cause"])
        ])
    }
    private static func request(_ body: String = "grant_type=refresh_token&refresh_token=SYNTHETIC_ONLY",
                                contentType: String? = formType) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        return request
    }
    private static func transport(_ state: State) -> GoogleDriveHTTP {
        OfflineProtocol.install(state)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineProtocol.self]
        let http = GoogleDriveHTTP(configuration: configuration)
        http.setTransportDiagnosticHandler { state.record($0) }
        http.setRequestCompletionHandler { state.finish($0) }
        return http
    }
    private static func requireOriginalTimeout(_ error: Error) throws {
        let value = error as NSError
        let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError
        try require(value.domain == NSURLErrorDomain && value.code == NSURLErrorTimedOut
            && value.userInfo["SyntheticTimeoutMarker"] as? String == "original-one-shot-timeout"
            && underlying?.domain == NSPOSIXErrorDomain && underlying?.code == Int(ETIMEDOUT)
            && underlying?.userInfo["SyntheticUnderlyingMarker"] as? String == "preserve-cause",
            "Original timeout or its full NSError cause was replaced")
    }
    private static func requireSingleAttempt(_ state: State, outcome: GoogleDriveRequestCompletion.Outcome) throws {
        try require(state.captured.count == 1 && state.observed.count == 1
            && state.observed[0].phase == .apiRequest && state.observed[0].httpStatus == nil,
            "Ineligible/expired request consumed its queued second response")
        try require(state.finished.count == 1 && state.finished[0].attemptCount == 1
            && state.finished[0].outcome == outcome && state.finished[0].origin == .natural
            && state.finished[0].requestID == state.observed[0].requestID,
            "Single request completion lost its original identity or terminal reason")
    }

    @MainActor static func run(test: @MainActor (_ name: String, _ body: @MainActor () async throws -> Void) async -> Void) async {
        await test("REC-46 Google 403 retains only allowlisted reason and keeps queue across restart") {
            let body = Data(#"{"error":{"code":403,"message":"SYNTHETIC_PRIVATE_MESSAGE","errors":[{"reason":"storageQuotaExceeded","location":"SYNTHETIC_PRIVATE_LOCATION"}]}}"#.utf8)
            let state = State([.response(200, Data(#"{"user":{"permissionId":"synthetic-owner"}}"#.utf8)), .response(403, body)])
            let client = GoogleDriveClient(http: transport(state), oauth: UploadTokens(), accountID: "synthetic-owner", check: {})
            do { _ = try await client.generateID(); throw ProbeFailure(message: "403 accepted") }
            catch let error as GoogleDriveError {
                try require(error == .apiFailure(403, .storageQuotaExceeded), "403 reason lost")
                try require(error.localizedDescription.contains("空间不足"), "no actionable capacity message")
                let failure = GoogleDriveWorkerReport.Failure(error)
                try require(failure.apiReason == .storageQuotaExceeded && failure.code == 403, "worker reason lost")
            }
            try require(state.captured.count == 2 && state.observed.last?.apiReason == .storageQuotaExceeded, "unsafe immediate replay or diagnostic reason lost")
            let encoded = String(decoding: try TransportCodec.encode(state.observed), as: UTF8.self)
            try require(!encoded.contains("SYNTHETIC_PRIVATE"), "server text leaked")
            var ledger = GoogleDriveLibraryLedger()
            try ledger.bind(accountID: "synthetic-owner", label: "Synthetic")
            try ledger.authorize(.existingAndFuture, knownIDs: [])
            let id = UUID(), start = Date(timeIntervalSince1970: 1_800_000_000)
            let source = SegmentManifest(id: id, sessionID: UUID(), sequence: 3, startedAt: start,
                endedAt: start.addingTimeInterval(1), sampleRate: 16_000, frameCount: 16_000,
                fileName: id.uuidString.lowercased() + ".caf", byteCount: 32_000, sha256: String(repeating: "3", count: 64))
            try ledger.discover(manifests: [source], receivedIDs: [id])
            let key = ledger.jobs[0].artifacts[0].key
            try ledger.allocateFile(segmentID: id, key: key, fileID: "synthetic-retained-file")
            let before = ledger
            ledger.recordFailure(apiReason: .storageQuotaExceeded)
            let restored = try TransportCodec.decode(GoogleDriveLibraryLedger.self, from: TransportCodec.encode(ledger))
            try restored.validate()
            try require(restored.apiFailureReason == .storageQuotaExceeded && restored.enabled == before.enabled
                && restored.jobs == before.jobs && restored.recordingScope == before.recordingScope, "capacity error changed grant or queue")
            ledger.clearRetry()
            try require(ledger.apiFailureReason == nil, "capacity error survives successful recovery")
        }
        await test("REC-46 Google reason parser rejects unknown private malformed and mismatched bodies") {
            for body in [#"{"error":{"code":403,"message":"storageQuotaExceeded"}}"#,
                         #"{"error":{"code":403,"errors":[{"reason":"SYNTHETIC_PRIVATE_REASON"}]}}"#,
                         #"{"error":{"code":400,"errors":[{"reason":"storageQuotaExceeded"}]}}"#, "not JSON"] {
                try require(GoogleDriveError.response(status: 403, data: Data(body.utf8)) == .http(403), "untrusted reason accepted")
            }
            try require(GoogleDriveAPIReason.parse(status: 200, data: Data(#"{"error":{"code":200,"errors":[{"reason":"storageQuotaExceeded"}]}}"#.utf8)) == nil, "success classified as failure")
            let body = Data(#"{"error":{"code":403,"errors":[{"reason":"userRateLimitExceeded"},{"reason":"storageQuotaExceeded"}]}}"#.utf8)
            try require(GoogleDriveAPIReason.parse(status: 403, data: body) == .storageQuotaExceeded, "rate limit hides capacity")
            let rate = Data(#"{"error":{"code":403,"errors":[{"reason":"userRateLimitExceeded"}]}}"#.utf8)
            try require(GoogleDriveAPIReason.parse(status: 403, data: rate)?.isRateLimit == true, "rate limit loses automatic backoff")
            try require(GoogleDriveAPIReason.parse(status: 403, data: Data(repeating: 32, count: 65_537)) == nil, "oversized body parsed")
        }
        await test("P-59 resumable query create chunk and metadata readback retain one job correlation") {
            let start = Date(timeIntervalSince1970: 1_700_000_000), id = UUID()
            let manifest = SegmentManifest(id: id, sessionID: UUID(), sequence: 1, startedAt: start,
                endedAt: start.addingTimeInterval(30), sampleRate: 16_000, frameCount: 480_000,
                fileName: id.uuidString.lowercased() + ".caf", byteCount: 8, sha256: String(repeating: "3", count: 64))
            var ledger = GoogleDriveLibraryLedger()
            let owner = "SYNTHETIC_ROUTE_ACCOUNT", folder = "synthetic-route-folder"
            try ledger.bind(accountID: owner, label: "Synthetic route account")
            try ledger.authorize(.existingAndFuture, knownIDs: [], at: start)
            try ledger.discover(manifests: [manifest], receivedIDs: [id]); try ledger.allocateFolder(folder)
            let key = ledger.jobs[0].artifacts.first { $0.kind == .manifest }!.key
            try ledger.allocateFile(segmentID: id, key: key, fileID: "synthetic-route-manifest")
            let oldSession = "https://www.googleapis.com/upload/drive/v3/files?upload_id=SYNTHETIC_OLD_SESSION"
            let newSession = "https://www.googleapis.com/upload/drive/v3/files?upload_id=SYNTHETIC_NEW_SESSION"
            try ledger.recordSession(segmentID: id, key: key, url: oldSession)
            let artifact = ledger.jobs[0].artifacts.first { $0.kind == .manifest }!
            let correlation = GoogleDriveUploadCorrelation(segmentID: id, kind: .manifest, manifestSHA256: manifest.sha256)
            let remote = GoogleDriveRemoteFile(id: artifact.fileID!, size: String(artifact.byteCount), sha256Checksum: artifact.sha256,
                parents: [folder], ownedByMe: true, shared: false, trashed: false,
                appProperties: ["rfaSchema": "1", "rfaLibraryID": ledger.libraryID.uuidString.lowercased(),
                    "rfaSegmentID": id.uuidString.lowercased(), "rfaKind": artifact.kind.rawValue,
                    "rfaAudioSHA256": manifest.sha256, "rfaContentSHA256": artifact.sha256],
                permissions: [.init(id: owner, type: "user", role: "owner")])
            let about = try JSONSerialization.data(withJSONObject: ["user": ["permissionId": owner]])
            let state = State([.response(200, about), .response(404, Data()), .response(410, Data()),
                .response(200, Data(), headers: ["Location": newSession]), .response(200, Data()),
                .response(200, try TransportCodec.encode(remote))])
            let client = GoogleDriveClient(http: transport(state), oauth: UploadTokens(), accountID: owner, check: {})
            // Only generated JSON is opened by the real chunk uploader.
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-upload-route-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: directory) }
            let file = directory.appendingPathComponent("manifest.json")
            let bytes = try TransportCodec.encode(GoogleDriveLibraryLedger.exportManifest(manifest))
            try bytes.write(to: file)
            var sessions: [String?] = []
            let result = try await client.upload(file: file, artifact: artifact, manifest: manifest, folderID: folder,
                libraryID: ledger.libraryID, saveSession: { value in
                    sessions.append(value); try ledger.recordSession(segmentID: id, key: key, url: value)
                })
            try require(sessions == [nil, newSession] && state.captured.count == 6
                && state.captured.map(\.httpMethod) == ["GET", "GET", "PUT", "POST", "PUT", "GET"]
                && state.capturedBodies[4] == bytes,
                "Synthetic expired-session recovery did not traverse session query/create, real JSON chunk and readback")
            try require(state.observed.count == 6 && state.finished.count == 6
                && state.observed.allSatisfy { $0.uploadCorrelation == correlation }
                && state.finished.allSatisfy { $0.uploadCorrelation == correlation }
                && state.observed.map(\.endpoint) == [.driveAbout, .driveFiles, .driveUpload, .driveUpload, .driveUpload, .driveFiles]
                && Set(state.finished.map(\.requestID)).count == 6,
                "One resumable path lost its job key, artifact kind or distinct request identity")
            try require(ledger.jobs[0].artifacts.first { $0.kind == .manifest }!.verifiedAt == nil,
                "Successful chunk or metadata HTTP response bypassed strict receipt verification")
            try ledger.recordVerified(segmentID: id, key: key, file: result, in: owner, at: start.addingTimeInterval(3))
            try require(ledger.jobs[0].artifacts.first { $0.kind == .manifest }!.verifiedUploadCorrelation == correlation,
                "Strict final metadata verification changed the resumable job correlation")
            let diagnostics = String(decoding: try TransportCodec.encode(state.observed), as: UTF8.self)
                + state.observed.map(\.logFields).joined(separator: " ")
            for sensitive in [owner, folder, oldSession, newSession, file.path, manifest.sha256,
                              id.uuidString.lowercased(), "SYNTHETIC_PRIVATE_ACCESS_TOKEN"] {
                try require(!diagnostics.contains(sensitive), "Resumable diagnostics leaked private request or source metadata")
            }
        }
        await test("P-59 natural timeout joins only the same job's next-opportunity remote_verified receipt") {
            let start = Date(timeIntervalSince1970: 1_700_000_000)
            let manifests = [1, 2].map { sequence in
                let id = UUID()
                return SegmentManifest(id: id, sessionID: UUID(), sequence: sequence, startedAt: start,
                    endedAt: start.addingTimeInterval(30), sampleRate: 16_000, frameCount: 480_000,
                    fileName: id.uuidString.lowercased() + ".caf", byteCount: 8,
                    sha256: String(repeating: String(sequence), count: 64))
            }
            var ledger = GoogleDriveLibraryLedger()
            let owner = "SYNTHETIC_PRIVATE_ACCOUNT", folder = "synthetic-upload-folder"
            try ledger.bind(accountID: owner, label: "Synthetic private account label")
            try ledger.authorize(.existingAndFuture, knownIDs: [], at: start)
            try ledger.discover(manifests: manifests, receivedIDs: Set(manifests.map(\.id)))
            try ledger.allocateFolder(folder)
            for index in manifests.indices {
                let artifact = ledger.jobs[index].artifacts[0]
                try ledger.allocateFile(segmentID: manifests[index].id, key: artifact.key, fileID: "synthetic-upload-\(index)")
            }
            let artifacts = ledger.jobs.map { $0.artifacts[0] }
            let correlations = manifests.indices.map {
                GoogleDriveUploadCorrelation(segmentID: manifests[$0].id, kind: artifacts[$0].kind, manifestSHA256: manifests[$0].sha256)
            }
            func remote(_ index: Int) -> GoogleDriveRemoteFile {
                let artifact = artifacts[index], manifest = manifests[index]
                return .init(id: artifact.fileID!, size: String(artifact.byteCount), sha256Checksum: artifact.sha256,
                    parents: [folder], ownedByMe: true, shared: false, trashed: false,
                    appProperties: ["rfaSchema": "1", "rfaLibraryID": ledger.libraryID.uuidString.lowercased(),
                        "rfaSegmentID": manifest.id.uuidString.lowercased(), "rfaKind": artifact.kind.rawValue,
                        "rfaAudioSHA256": manifest.sha256, "rfaContentSHA256": artifact.sha256],
                    permissions: [.init(id: owner, type: "user", role: "owner")])
            }
            let about = try JSONSerialization.data(withJSONObject: ["user": ["permissionId": owner]])
            let state = State([.response(200, about), .failure(timeoutError), .failure(timeoutError),
                .response(200, try TransportCodec.encode(remote(1))), .response(200, try TransportCodec.encode(remote(0)))])
            let client = GoogleDriveClient(http: transport(state), oauth: UploadTokens(), accountID: owner, check: {})
            // The timeout occurs in metadata before any local file can be opened.
            let unopened = URL(fileURLWithPath: "/SYNTHETIC_PRIVATE_PATH/must-not-exist.caf")
            do {
                _ = try await client.upload(file: unopened, artifact: artifacts[0], manifest: manifests[0],
                    folderID: folder, libraryID: ledger.libraryID, saveSession: { _ in
                        throw ProbeFailure(message: "Metadata timeout unexpectedly reached session persistence")
                    })
                throw ProbeFailure(message: "Original upload timeout unexpectedly succeeded")
            } catch let failure as ProbeFailure { throw failure }
            catch { try requireOriginalTimeout(error) }
            let failures = state.observed.filter { $0.errors.contains { $0.domain == NSURLErrorDomain && $0.code == NSURLErrorTimedOut } }
            try require(failures.count == 2 && failures.allSatisfy { $0.origin == .natural && $0.uploadCorrelation == correlations[0] }
                && failures[0].requestID == failures[1].requestID,
                "The natural timeout attempts lost their request and upload-job identity")
            let failureAtMS: Int64 = 1_700_000_001_000
            func receipt(_ index: Int) -> SyncEvidenceArtifact {
                let saved = ledger.jobs[index].artifacts[0]
                return .init(kind: saved.kind.rawValue, sha256: saved.sha256, byteCount: saved.byteCount,
                    state: saved.verifiedAt == nil ? "pending" : "remote_verified",
                    recordedAtMS: saved.verifiedAt.map { Int64($0.timeIntervalSince1970 * 1_000) }, origin: "synthetic",
                    uploadCorrelation: saved.verifiedUploadCorrelation)
            }
            let other = try await client.upload(file: unopened, artifact: artifacts[1], manifest: manifests[1],
                folderID: folder, libraryID: ledger.libraryID, saveSession: { _ in })
            try ledger.recordVerified(segmentID: manifests[1].id, key: artifacts[1].key, file: other,
                in: owner, at: start.addingTimeInterval(2))
            try require(GoogleDriveUploadRecoveryEvidence.evaluate(failureCorrelation: failures[0].uploadCorrelation,
                naturalTimeout: true, failureAtMS: failureAtMS, receipt: receipt(1)) == .insufficientEvidence,
                "Another job's valid receipt was counted as recovery for the failed job")
            // A new opportunity starts a new request, but the durable job key survives.
            let readBack = try await client.readBackCompletedUpload(artifact: artifacts[0], manifest: manifests[0])
            guard case .remote(let original) = readBack else { throw ProbeFailure(message: "Next opportunity lacked remote metadata") }
            try require(ledger.jobs[0].artifacts[0].verifiedAt == nil, "HTTP 200 alone created a cloud receipt")
            try ledger.recordVerified(segmentID: manifests[0].id, key: artifacts[0].key, file: original,
                in: owner, at: start.addingTimeInterval(3))
            let roundTrip = try TransportCodec.decode(GoogleDriveLibraryLedger.self, from: TransportCodec.encode(ledger))
            try require(roundTrip.jobs[0].artifacts[0].verifiedUploadCorrelation == correlations[0]
                && GoogleDriveUploadRecoveryEvidence.evaluate(failureCorrelation: failures[0].uploadCorrelation,
                    naturalTimeout: true, failureAtMS: failureAtMS, receipt: receipt(0)) == .pass,
                "Same-job strict remote verification did not preserve the failure correlation in its durable receipt")
            try require(state.finished.count == 4 && state.finished[1].uploadCorrelation == correlations[0]
                && state.finished[2].uploadCorrelation == correlations[1] && state.finished[3].uploadCorrelation == correlations[0]
                && state.finished[1].requestID != state.finished[3].requestID,
                "Independent opportunities lost their distinct request IDs or stable job attribution")
            let encoded = try TransportCodec.encode(state.observed)
            let diagnostics = String(decoding: encoded, as: UTF8.self) + state.observed.map(\.logFields).joined(separator: " ")
            for sensitive in [owner, "SYNTHETIC_PRIVATE_ACCESS_TOKEN", "SYNTHETIC_PRIVATE_PATH", folder,
                              manifests[0].id.uuidString.lowercased(), manifests[0].sha256, artifacts[0].fileID!] {
                try require(!diagnostics.contains(sensitive), "Transport evidence leaked a sensitive source field")
            }
            try require(GoogleDriveUploadTrace.current == nil, "Upload job scope escaped into unrelated caller work")
        }
        await test("P-55 authorization_code timeout preserves original error without invalid_grant replay") {
            for timeout in [nil, 30, 7.25] as [TimeInterval?] {
                let state = State([.failure(timeoutError), .response(400, invalidGrant)])
                do {
                    _ = try await GoogleDriveOAuthExchange.exchange(http: transport(state), clientID: "SYNTHETIC_CLIENT",
                        values: ["grant_type": "authorization_code", "code": "SYNTHETIC_ONE_USE_CODE"], previous: nil,
                        timeout: timeout)
                    throw ProbeFailure(message: "Authorization-code timeout unexpectedly succeeded")
                } catch let failure as ProbeFailure { throw failure }
                catch { try requireOriginalTimeout(error) }
                try requireSingleAttempt(state, outcome: .notEligible)
                try require(state.captured[0].timeoutInterval == (timeout ?? 30),
                    "One-use authorization-code exchange lost the full first-attempt timeout")
                try require(!state.finished.contains { $0.outcome == .httpFailure },
                    "The preserved timeout became an invalid_grant HTTP failure")
            }
        }
        await test("P-55 a genuine authorization_code invalid_grant still requires sign-in") {
            let state = State([.response(400, invalidGrant)])
            do {
                _ = try await GoogleDriveOAuthExchange.exchange(http: transport(state), clientID: "SYNTHETIC_CLIENT",
                    values: ["grant_type": "authorization_code", "code": "SYNTHETIC_REJECTED_CODE"], previous: nil)
                throw ProbeFailure(message: "Actual invalid_grant unexpectedly succeeded")
            } catch GoogleDriveError.needsSignIn { }
            catch { throw error }
            try require(state.captured.count == 1 && state.finished.count == 1
                && state.finished[0].outcome == .httpFailure, "Genuine OAuth HTTP failure lost its meaning")
        }
        await test("P-55 other token grants preserve an explicitly configured original request timeout") {
            var original = request("grant_type=authorization_code&code=SYNTHETIC_ONLY")
            original.timeoutInterval = 37
            let state = State([.failure(timeoutError), .response(400, invalidGrant)])
            do {
                _ = try await transport(state).send(original)
                throw ProbeFailure(message: "Other token grant unexpectedly recovered")
            } catch let failure as ProbeFailure { throw failure }
            catch { try requireOriginalTimeout(error) }
            try requireSingleAttempt(state, outcome: .notEligible)
            try require(state.captured[0].timeoutInterval == 37,
                "An ineligible request with no timeout override lost its original timeout")
        }
        await test("P-55 refresh_token early timeout recovers once with the same requestID") {
            let state = State([.failure(timeoutError), .response(200, tokenResponse)])
            let previous = GoogleDriveCredential(clientID: "SYNTHETIC_CLIENT", accessToken: "SYNTHETIC_OLD_ACCESS",
                refreshToken: "SYNTHETIC_REFRESH", expiresAt: .distantPast, accountID: "synthetic-owner")
            let value = try await GoogleDriveOAuthExchange.exchange(http: transport(state), clientID: previous.clientID,
                values: ["grant_type": "refresh_token", "refresh_token": previous.refreshToken], previous: previous, timeout: 30)
            try require(value.accessToken == "SYNTHETIC_NEW_ACCESS" && value.refreshToken == previous.refreshToken,
                "The real OAuth exchange failed after a successful synthetic refresh recovery")
            try require(state.captured.count == 2 && state.captured[0].timeoutInterval == 22
                && state.captured[1].timeoutInterval > 0 && state.captured[1].timeoutInterval <= 8,
                "Refresh recovery lost the reserved retry room or exceeded the retry cap")
            let requests = state.captured, bodies = state.capturedBodies
            try require(requests[0].url == requests[1].url && requests[0].httpMethod == requests[1].httpMethod
                && requests[0].allHTTPHeaderFields == requests[1].allHTTPHeaderFields
                && bodies.count == 2 && bodies[0] != nil && bodies[0] == bodies[1],
                "Refresh recovery changed the URL, method, headers or synthetic form body")
            let observed = state.observed, finished = state.finished
            try require(observed.count == 2 && observed.map(\.phase) == [.apiRequest, .apiRecovery]
                && observed[0].requestID != nil && observed[0].requestID == observed[1].requestID
                && observed.allSatisfy { $0.origin == .natural && $0.endpoint == .oauthToken },
                "Natural refresh recovery did not preserve requestID and origin")
            try require(finished.count == 1 && finished[0].attemptCount == 2 && finished[0].outcome == .recovered
                && finished[0].requestID == observed[0].requestID,
                "Recovered refresh omitted its same-request terminal receipt")
        }
        await test("P-55 strict form parser accepts valid refresh encoding and MIME") {
            let bodies = ["grant_type=refresh_token", "%67rant_type=%72efresh_token",
                "client_id=synthetic+client&grant_type=refresh_token&extra=%E4%B8%AD%E6%96%87",
                "extra=a=b&grant_type=refresh_token&extra=second"]
            let types = [formType, "Application/X-WWW-Form-Urlencoded", formType + "; charset=UTF-8",
                " " + formType + "; charset=\"utf-8\" "]
            for body in bodies { for type in types {
                let value = request(body, contentType: type)
                try require(GoogleDriveHTTP.recoveryPath(for: value) == .tokenPOST
                    && GoogleDriveHTTP.recoveryTimeout(for: value, error: timeoutError, remaining: 8) == 8,
                    "Valid refresh form or supported MIME was excluded")
            } }
        }
        await test("P-55 strict form parser rejects wrong content types and ambiguous grants") {
            let invalidTypes: [String?] = [nil, "application/json", "text/plain", formType + "-extra",
                formType + ", application/json", formType + "; charset=iso-8859-1", formType + "; unknown=x"]
            for type in invalidTypes {
                try require(GoogleDriveHTTP.recoveryPath(for: request(contentType: type)) == .other,
                    "Non-form or unsupported MIME became a retryable token POST")
            }
            let bodies = ["", "refresh_token=SYNTHETIC_ONLY", "grant_type=", "grant_type=authorization_code",
                "grant_type=client_credentials", "grant_type=REFRESH_TOKEN", "grant_type=refresh+token",
                "grant_type=refresh_token&grant_type=refresh_token",
                "grant_type=refresh_token&%67rant_type=authorization_code",
                "%67rant_type=refresh_token&grant_type=refresh_token",
                "grant_type=refresh_token&unrelated=%", "grant_type=refresh_token&unrelated=%0",
                "grant_type=refresh_token&unrelated=%GG", "grant_type=refresh_token&unrelated=%FF",
                "grant_type=refresh_token&unrelated=%C0%AF", "grant_type=refresh_token&unrelated=%ED%A0%80",
                "grant_type=refresh_token&bad%FF=value", "grant_type=refresh_token&unrelated=%00",
                "grant_type=refresh_token&unrelated=%0A", "grant_type=refresh_token&bare",
                "grant_type=refresh_token&=empty-name", "grant_type=refresh_token&", "&grant_type=refresh_token"]
            for body in bodies {
                let value = request(body)
                try require(GoogleDriveHTTP.recoveryPath(for: value) == .other
                    && GoogleDriveHTTP.recoveryTimeout(for: value, error: timeoutError, remaining: 8) == nil,
                    "Malformed or ambiguous form became retryable: " + body)
            }
            var invalidUTF8 = request(); invalidUTF8.httpBody = Data("grant_type=refresh_token&x=".utf8) + Data([0xFF])
            var stream = request(); stream.httpBody = nil
            stream.httpBodyStream = InputStream(data: Data("grant_type=refresh_token".utf8))
            var oversized = request(); oversized.httpBody = Data(("grant_type=refresh_token&x=" + String(repeating: "x", count: 65_536)).utf8)
            for value in [invalidUTF8, stream, oversized] {
                try require(GoogleDriveHTTP.recoveryPath(for: value) == .other,
                    "Uninspectable or invalid body became retryable")
            }
        }
        await test("P-55 malformed token form timeout keeps one attempt and its original budget") {
            for body in ["grant_type=refresh_token&%67rant_type=authorization_code", "grant_type=refresh_token&x=%FF"] {
                let state = State([.failure(timeoutError), .response(400, invalidGrant)])
                do {
                    _ = try await transport(state).send(request(body), timeout: 30)
                    throw ProbeFailure(message: "Malformed token form unexpectedly recovered")
                } catch let failure as ProbeFailure { throw failure }
                catch { try requireOriginalTimeout(error) }
                try requireSingleAttempt(state, outcome: .notEligible)
                try require(state.captured[0].timeoutInterval == 30, "Rejected form lost its first-attempt budget")
            }
        }
        await test("P-55 first-attempt and retry budget boundaries") {
            for path in [GoogleDriveRecoveryDecision.Path.tokenPOST, .aboutGET, .fileMetadataGET, .other] {
                let examples: [(TimeInterval, TimeInterval, TimeInterval)] = [
                    (0.5, 0.5, 0.5), (1, 1, 1), (1.5, 1.5, 1.5), (1.999, 1.999, 1.999),
                    (2, 1, 2), (3, 1.5, 3), (4, 2, 4), (8, 4, 8),
                    (15.998, 7.999, 15.998), (16, 8, 16), (18, 10, 18),
                    (22, 14, 22), (30, 22, 30), (60, 22, 30)]
                for (budget, reserved, full) in examples {
                    let expected = path == .other ? full : reserved
                    try require(GoogleDriveRecoveryDecision.firstAttemptTimeout(budget: budget, path: path) == expected,
                        "First-attempt idle timeout lost the reservation threshold, cap or ineligible full timeout")
                }
                for invalid in [0.0, -1.0, .infinity, -.infinity, .nan] {
                    try require(GoogleDriveRecoveryDecision.firstAttemptTimeout(budget: invalid, path: path) == 0,
                        "Invalid first-attempt budget was accepted")
                }
            }
            for (remaining, expected) in [(1.0, 1.0), (1.001, 1.001), (8.0, 8.0), (30.0, 8.0)] {
                try require(GoogleDriveHTTP.recoveryTimeout(for: request(), error: timeoutError, remaining: remaining) == expected,
                    "Retry threshold/cap drifted at an exact boundary")
            }
            for remaining in [0.0, 0.999, -1.0, .infinity, -.infinity, .nan] {
                try require(GoogleDriveHTTP.recoveryTimeout(for: request(), error: timeoutError, remaining: remaining) == nil,
                    "Subsecond or nonfinite remaining budget permitted a retry")
            }
        }
        await test("P-55 retry subtracts elapsed first-attempt time from one original budget") {
            let state = State([.failure(timeoutError, delay: 0.03), .response(200, Data("{}".utf8))])
            _ = try await transport(state).send(request(), timeout: 3)
            try require(state.captured.count == 2 && state.captured[0].timeoutInterval == 1.5
                && state.captured[1].timeoutInterval >= 1 && state.captured[1].timeoutInterval < 2.99,
                "Retry renewed the original timeout after time spent on its first attempt")
        }
        await test("P-55 configured first idle timeout leaves room for same-request recovery") {
            let state = State([.failureAfterConfiguredIdleTimeout(timeoutError), .response(200, Data("{}".utf8))])
            let started = ProcessInfo.processInfo.systemUptime
            _ = try await transport(state).send(request(), timeout: 4)
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            try require(state.captured.count == 2 && state.captured[0].timeoutInterval == 2
                && state.captured[1].timeoutInterval >= 1 && state.captured[1].timeoutInterval <= 2.05
                && elapsed >= 1.95,
                "A complete configured idle interval consumed all retry room or renewed the original budget")
            try require(state.observed.count == 2 && state.observed[0].requestID != nil
                && state.observed[0].requestID == state.observed[1].requestID
                && state.finished.count == 1 && state.finished[0].outcome == .recovered
                && state.finished[0].requestID == state.observed[0].requestID,
                "Delayed synthetic timeout did not recover the same request")
        }
        await test("P-55 spent and subsecond original budgets never start recovery") {
            for budget in [1.0, 0.5, 0.01] {
                let state = State([.failure(timeoutError, delay: 0.03), .response(200, Data("{}".utf8))])
                do {
                    _ = try await transport(state).send(request(), timeout: budget)
                    throw ProbeFailure(message: "Expired/subsecond request budget recovered")
                } catch let failure as ProbeFailure { throw failure }
                catch {
                    // At 10 ms URLSession can time out before the delayed
                    // synthetic reply. Either timeout must remain a timeout.
                    let value = error as NSError
                    try require(value.domain == NSURLErrorDomain && value.code == NSURLErrorTimedOut,
                        "Spent budget replaced its transport timeout")
                }
                try requireSingleAttempt(state, outcome: .budgetExpired)
                try require(state.captured[0].timeoutInterval == budget, "Short budget changed before its first attempt")
            }
        }
        await test("P-55 invalid caller budgets never start a first attempt") {
            for budget in [0.0, -1.0, .infinity, -.infinity, .nan] {
                let state = State([.response(200, Data("{}".utf8))])
                do {
                    _ = try await transport(state).send(request(), timeout: budget)
                    throw ProbeFailure(message: "Invalid caller budget performed a request")
                } catch is CancellationError { }
                try require(state.captured.isEmpty && state.finished.count == 1
                    && state.finished[0].attemptCount == 0 && state.finished[0].outcome == .budgetExpired,
                    "Invalid budget consumed transport or lacked terminal budget attribution")
            }
        }
        await test("P-55 shortened current lease caps recovery without renewing the first request") {
            let state = State([.failure(timeoutError), .response(200, Data("{}".utf8))])
            var checks = 0
            _ = try await transport(state).send(request(), timeout: 30, recoveryBudget: { checks += 1; return 2 })
            try require(checks == 1 && state.captured.count == 2 && state.captured[0].timeoutInterval == 22
                && state.captured[1].timeoutInterval >= 1 && state.captured[1].timeoutInterval <= 2,
                "Recovery ignored a shorter current background lease")
        }
        await test("P-55 subsecond and expired current leases reject recovery") {
            for remaining in [0.5, 0.0] {
                let state = State([.failure(timeoutError), .response(200, Data("{}".utf8))])
                var checks = 0
                do {
                    _ = try await transport(state).send(request(), timeout: 30,
                        recoveryBudget: { checks += 1; return remaining })
                    throw ProbeFailure(message: "Expired/subsecond lease launched recovery")
                } catch let failure as ProbeFailure { throw failure }
                catch { if remaining > 0 { try requireOriginalTimeout(error) } else { try require(error is CancellationError, "Expired lease did not cancel") } }
                try require(checks == 1, "Current lease was not checked exactly once")
                try requireSingleAttempt(state, outcome: .budgetExpired)
            }
            let state = State([.failure(timeoutError), .response(200, Data("{}".utf8))])
            do {
                _ = try await transport(state).send(request(), timeout: 30, recoveryBudget: { throw CancellationError() })
                throw ProbeFailure(message: "Rejected current lease launched recovery")
            } catch is CancellationError { }
            try requireSingleAttempt(state, outcome: .callerBudgetRejected)
        }
        await test("P-55 a second timeout ends recovery without a third token POST") {
            let state = State([.failure(timeoutError), .failure(timeoutError), .response(200, tokenResponse)])
            do {
                _ = try await transport(state).send(request(), timeout: 30)
                throw ProbeFailure(message: "Second timeout caused an unexpected third attempt")
            } catch let failure as ProbeFailure { throw failure }
            catch { try requireOriginalTimeout(error) }
            try require(state.captured.count == 2 && state.finished.count == 1 && state.finished[0].attemptCount == 2
                && state.finished[0].outcome == .recoveryFailed, "Retry was unbounded or mislabeled recovered")
        }
    }
}
