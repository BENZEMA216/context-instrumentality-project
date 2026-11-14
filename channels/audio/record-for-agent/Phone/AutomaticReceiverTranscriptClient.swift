import CryptoKit
import Foundation
import RecordingCore
import Security

/// Read-only ASR return from one already paired receiver. The full durable
/// receipt is the capability; the echoed scope is only a client-side fence.
struct AutomaticReceiverTranscriptScope: Codable, Equatable, Sendable {
    let receiverID: UUID
    let pairingID: UUID
    let grantEpoch: UUID
    let sourceInstallationID: UUID

    init(_ scope: AutomaticDeliveryScope) {
        receiverID = scope.receiverID; pairingID = scope.pairingID
        grantEpoch = scope.grantEpoch; sourceInstallationID = scope.sourceInstallationID
    }
}

struct AutomaticReceiverTranscriptSource: Codable, Equatable, Hashable, Sendable {
    let segmentID: UUID
    let sessionID: UUID
    let sequence: Int
    let audioSHA256: String

    init(_ manifest: SegmentManifest) {
        segmentID = manifest.id; sessionID = manifest.sessionID
        sequence = manifest.sequence; audioSHA256 = manifest.sha256
    }
}

struct AutomaticReceiverTranscriptQuery: Codable, Sendable {
    let receipt: AutomaticDeliveryReceipt
    let manifest: SegmentManifest
    var source: AutomaticReceiverTranscriptSource { .init(manifest) }
}

enum AutomaticReceiverTranscriptStatus: String, Codable, Sendable {
    case ready, pending, retry, noSpeech = "no_speech", unavailable
}

struct AutomaticReceiverTranscriptResult: Sendable {
    let query: AutomaticReceiverTranscriptQuery
    let status: AutomaticReceiverTranscriptStatus
    let transcript: SegmentTranscript?
}

enum AutomaticReceiverTranscriptError: LocalizedError {
    case invalidResponse, http(Int)
    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "电脑转写结果未通过核对，原录音与已有文字仍保留。"
        case .http(let code): return "电脑转写暂未取回（HTTP \(code)），稍后会重试。"
        }
    }
}

protocol AutomaticReceiverTranscriptTransport: AnyObject, Sendable {
    func query(_ items: [AutomaticReceiverTranscriptQuery], timeout: TimeInterval) async throws -> [AutomaticReceiverTranscriptResult]
}

typealias AutomaticReceiverTranscriptClientFactory = (AutomaticReceiverCredentials) throws -> any AutomaticReceiverTranscriptTransport

final class AutomaticReceiverTranscriptClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable, AutomaticReceiverTranscriptTransport {
    static let maximumResponseBytes = 4 * 1_024 * 1_024
    private let credentials: AutomaticReceiverCredentials
    private let endpoint: URL
    private let configuration: URLSessionConfiguration

    struct Item: Codable, Equatable, Sendable {
        let receipt: AutomaticDeliveryReceipt
        let source: AutomaticReceiverTranscriptSource
    }
    struct Request: Codable, Sendable {
        let schemaVersion: Int
        let scope: AutomaticReceiverTranscriptScope
        let items: [Item]
    }
    struct ResponseItem: Codable, Sendable {
        let receipt: AutomaticDeliveryReceipt
        let source: AutomaticReceiverTranscriptSource
        let status: AutomaticReceiverTranscriptStatus
        let transcriptJSON: String?
        let transcriptSHA256: String?
        let transcriptByteCount: Int?
    }
    struct Response: Codable, Sendable {
        let schemaVersion: Int
        let scope: AutomaticReceiverTranscriptScope
        let items: [ResponseItem]
    }

    init(credentials: AutomaticReceiverCredentials, configuration: URLSessionConfiguration = .ephemeral) throws {
        guard let endpoint = AutomaticReceiverPairingPayload.endpointURL(credentials.scope.endpoint),
              AutomaticReceiverPairingPayload.isDigest(credentials.scope.certificateSHA256),
              AutomaticReceiverPairingPayload.validToken(credentials.token) else { throw AutomaticReceiverError.invalidPairing }
        self.credentials = credentials; self.endpoint = endpoint.appendingPathComponent("v1/transcripts/query")
        self.configuration = configuration
        super.init()
    }

    func query(_ items: [AutomaticReceiverTranscriptQuery], timeout: TimeInterval) async throws -> [AutomaticReceiverTranscriptResult] {
        try Task.checkCancellation()
        guard timeout.isFinite, timeout > 0 else { throw AutomaticReceiverTranscriptError.invalidResponse }
        let body = try Self.requestBody(items, scope: credentials.scope)
        let scope = AutomaticReceiverTranscriptScope(credentials.scope)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"; request.httpBody = body
        request.timeoutInterval = min(15, timeout)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer " + credentials.token, forHTTPHeaderField: "Authorization")
        let config = configuration.copy() as! URLSessionConfiguration
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil; config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.allowsCellularAccess = false; config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = min(15, timeout); config.timeoutIntervalForResource = min(15, timeout)
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let data: Data
        do {
            data = try await withTaskCancellationHandler {
                let (bytes, response) = try await session.bytes(for: request)
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse,
                      AutomaticReceiverResponseURLPolicy.matches(expected: endpoint, response: response.url),
                      response.expectedContentLength <= Int64(Self.maximumResponseBytes) else {
                    throw AutomaticReceiverTranscriptError.invalidResponse
                }
                guard response.statusCode == 200 else { throw AutomaticReceiverTranscriptError.http(response.statusCode) }
                guard response.mimeType == "application/json" else { throw AutomaticReceiverTranscriptError.invalidResponse }
                var data = Data()
                for try await byte in bytes {
                    guard data.count < Self.maximumResponseBytes else { throw AutomaticReceiverTranscriptError.invalidResponse }
                    data.append(byte)
                }
                try Task.checkCancellation()
                return data
            } onCancel: { session.invalidateAndCancel() }
        } catch {
            try Task.checkCancellation()
            throw error
        }
        return try Self.validate(data, for: items, scope: scope)
    }

    /// Both foreground reads and file-backed native queries use the exact same
    /// bounded capability encoding. Neither path can request ASR or add sources.
    static func requestBody(_ items: [AutomaticReceiverTranscriptQuery], scope: AutomaticDeliveryScope) throws -> Data {
        guard !items.isEmpty, items.count <= 4,
              Set(items.map { $0.receipt.deliveryID }).count == items.count,
              Set(items.map { $0.manifest.id }).count == items.count,
              items.allSatisfy({ $0.receipt.schemaVersion == 1 && $0.receipt.receiverID == scope.receiverID
                  && $0.receipt.recordingIDs == [$0.manifest.id] && $0.manifest.schemaVersion == 1
                  && $0.manifest.sequence >= 0 && AutomaticReceiverPairingPayload.isDigest($0.manifest.sha256)
                  && AutomaticReceiverPairingPayload.isDigest($0.receipt.archiveSHA256) }) else {
            throw AutomaticReceiverTranscriptError.invalidResponse
        }
        let wireItems = items.map { Item(receipt: $0.receipt, source: $0.source) }
        let body = try TransportCodec.encode(Request(schemaVersion: 1, scope: .init(scope), items: wireItems))
        guard body.count <= 32 * 1_024 else { throw AutomaticReceiverTranscriptError.invalidResponse }
        return body
    }

    static func validate(_ data: Data, for queries: [AutomaticReceiverTranscriptQuery],
                         scope: AutomaticReceiverTranscriptScope) throws -> [AutomaticReceiverTranscriptResult] {
        guard data.count <= maximumResponseBytes else { throw AutomaticReceiverTranscriptError.invalidResponse }
        let value = try TransportCodec.decode(Response.self, from: data)
        guard value.schemaVersion == 1, value.scope == scope, value.items.count == queries.count else {
            throw AutomaticReceiverTranscriptError.invalidResponse
        }
        var results: [AutomaticReceiverTranscriptResult] = []
        for (item, query) in zip(value.items, queries) {
            guard item.receipt == query.receipt, item.source == query.source else {
                throw AutomaticReceiverTranscriptError.invalidResponse
            }
            var transcript: SegmentTranscript?
            if item.status == .ready {
                guard let text = item.transcriptJSON, let hash = item.transcriptSHA256,
                      let count = item.transcriptByteCount, AutomaticReceiverPairingPayload.isDigest(hash) else {
                    throw AutomaticReceiverTranscriptError.invalidResponse
                }
                let bytes = Data(text.utf8)
                guard bytes.count == count, bytes.count <= TranscriptRepository.maximumFileBytes,
                      SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == hash else {
                    throw AutomaticReceiverTranscriptError.invalidResponse
                }
                let decoded = try TransportCodec.decode(SegmentTranscript.self, from: bytes)
                try decoded.validate(against: query.manifest)
                transcript = decoded
            } else {
                guard item.transcriptJSON == nil, item.transcriptSHA256 == nil, item.transcriptByteCount == nil else {
                    throw AutomaticReceiverTranscriptError.invalidResponse
                }
            }
            results.append(.init(query: query, status: item.status, transcript: transcript))
        }
        return results
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        respond(to: challenge, completionHandler: completionHandler)
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        respond(to: challenge, completionHandler: completionHandler)
    }
    private func respond(to challenge: URLAuthenticationChallenge,
                         completionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host.caseInsensitiveCompare(endpoint.host ?? "") == .orderedSame,
              let trust = challenge.protectionSpace.serverTrust,
              AutomaticReceiverPinnedTLS.accepts(trust, host: challenge.protectionSpace.host,
                certificateSHA256: credentials.scope.certificateSHA256) else {
            completionHandler(.cancelAuthenticationChallenge, nil); return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
