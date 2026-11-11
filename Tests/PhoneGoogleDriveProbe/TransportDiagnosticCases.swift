import Foundation
import RecordingCore

/// Synthetic-only privacy and numeric-cause checks for the real production
/// diagnostic encoder. No requests, media, credentials or device access.
enum GoogleDriveTransportDiagnosticCases {
    private struct Failure: Error { let message: String }
    private final class LinkedError: NSError, @unchecked Sendable {
        weak var next: NSError?
        override var userInfo: [String: Any] { next.map { [NSUnderlyingErrorKey: $0] } ?? [:] }
        init(code: Int) { super.init(domain: NSURLErrorDomain, code: code, userInfo: nil) }
        required init?(coder: NSCoder) { fatalError("Not a fixture archive") }
    }

    static func run() throws -> Int {
        var count = 0
        func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try value() else { throw Failure(message: message) }
            count += 1
        }
        func encoded(_ value: GoogleDriveTransportDiagnostic) throws -> String {
            String(decoding: try JSONEncoder().encode(value), as: UTF8.self) + value.logFields
        }

        let privateMarker = "SYNTHETIC_PRIVATE_DO_NOT_LOG"
        let segmentID = UUID()
        let correlation = GoogleDriveUploadCorrelation(segmentID: segmentID, kind: .audio, manifestSHA256: privateMarker)
        var upload = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files/" + privateMarker + "?upload_id=" + privateMarker)!)
        upload.httpMethod = "PUT"
        upload.httpBody = Data(privateMarker.utf8)
        upload.setValue("Bearer " + privateMarker, forHTTPHeaderField: "Authorization")
        let ssl = NSError(domain: "kCFErrorDomainCFNetwork", code: -1200, userInfo: [
            "_kCFStreamErrorDomainKey": 3, "_kCFStreamErrorCodeKey": -9806,
            NSURLErrorFailingURLErrorKey: upload.url!, NSLocalizedDescriptionKey: privateMarker
        ])
        let cause = NSError(domain: NSURLErrorDomain, code: -1200, userInfo: [
            NSUnderlyingErrorKey: ssl, NSLocalizedDescriptionKey: privateMarker,
            "NSErrorFailingURLStringKey": upload.url!.absoluteString
        ])
        let observed = GoogleDriveTransportDiagnostic.capture(error: cause, request: upload, phase: .nativeUpload,
                                                               uploadCorrelation: correlation)
        try require(observed.endpoint == .driveUpload && observed.method == .PUT && observed.phase == .nativeUpload,
                    "The native upload lost its fixed endpoint/method/phase")
        try require(observed.errors == [.init(domain: NSURLErrorDomain, code: -1200),
                                        .init(domain: "kCFErrorDomainCFNetwork", code: -1200)],
                    "The numeric NSError chain was lost")
        try require(observed.streamErrorDomain == 3 && observed.streamErrorCode == -9806,
                    "Underlying SSL stream integers were lost")
        try require(!(try encoded(observed)).contains(privateMarker), "A private request or localized error escaped")
        try require(observed.uploadCorrelation == correlation && observed.logFields.contains("upload_job_key=" + correlation.jobKey!)
            && observed.logFields.contains("upload_kind=audio") && !(try encoded(observed)).contains(segmentID.uuidString.lowercased()),
            "Upload correlation was dropped or exposed the unhashed source identity")
        let attributed = GoogleDriveTransportDiagnostic.capture(error: cause, request: upload, phase: .nativeUpload)
            .withUploadCorrelation(correlation)
        try require(attributed == observed, "Native callback attribution changed bounded transport facts")
        try require(observed.httpStatus == nil && observed.metrics == nil, "Missing observations were invented")

        let token = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        let successful = GoogleDriveTransportDiagnostic.capture(error: nil, request: token, phase: .apiRequest, httpStatus: 200)
        try require(successful.endpoint == .oauthToken && successful.errors.isEmpty && successful.httpStatus == 200,
                    "Success was classified as a transport failure")
        try require(GoogleDriveTransportDiagnostic.capture(error: nil, request: token, phase: .apiRequest, httpStatus: 99).httpStatus == nil,
                    "An invalid HTTP status was retained")
        let fixedEndpoints: [(String, GoogleDriveTransportDiagnostic.Endpoint)] = [
            ("https://oauth2.googleapis.com/revoke", .oauthRevoke),
            ("https://www.googleapis.com/drive/v3/about?fields=" + privateMarker, .driveAbout),
            ("https://www.googleapis.com/drive/v3/files/generateIds", .driveIDs),
            ("https://www.googleapis.com/drive/v3/files?q=" + privateMarker, .driveFiles),
            ("https://www.googleapis.com/drive/v3/files/" + privateMarker, .driveFiles)
        ]
        for (url, expected) in fixedEndpoints {
            let value = GoogleDriveTransportDiagnostic.capture(error: nil, request: URLRequest(url: URL(string: url)!), phase: .apiRequest)
            try require(value.endpoint == expected && !(try encoded(value)).contains(privateMarker), "Endpoint classification exposed a path/query")
        }
        for url in ["https://" + privateMarker + ".example/token", "http://www.googleapis.com/drive/v3/files",
                    "https://oauth2.googleapis.com/token?secret=" + privateMarker,
                    "https://www.googleapis.com:443/drive/v3/files", "https://www.googleapis.com/drive/v3/files#" + privateMarker] {
            let value = GoogleDriveTransportDiagnostic.capture(error: nil, request: URLRequest(url: URL(string: url)!), phase: .apiRequest)
            try require(value.endpoint == .unknown && !(try encoded(value)).contains(privateMarker), "An unsupported endpoint leaked raw input")
        }
        var unusual = upload; unusual.httpMethod = privateMarker
        let unknown = GoogleDriveTransportDiagnostic.capture(error: NSError(domain: privateMarker, code: 42,
            userInfo: ["_kCFStreamErrorCodeKey": privateMarker]), request: unusual, phase: .apiRequest)
        try require(unknown.method == .unknown && unknown.errors == [.init(domain: "other", code: 42)]
                    && unknown.streamErrorCode == nil && !(try encoded(unknown)).contains(privateMarker),
                    "An arbitrary method/domain/noninteger stream field escaped")

        let first = LinkedError(code: 1), second = LinkedError(code: 2)
        first.next = second; second.next = first
        let cycle = GoogleDriveTransportDiagnostic.capture(error: first, request: nil, phase: .apiRequest)
        try require(cycle.errors.map(\.code) == [1, 2], "A cyclic error chain was not bounded by identity")
        let chain = (0..<8).map { LinkedError(code: $0) }
        for index in 0..<7 { chain[index].next = chain[index + 1] }
        try require(GoogleDriveTransportDiagnostic.capture(error: chain[0], request: nil, phase: .apiRequest).errors.map(\.code) == [0, 1, 2, 3],
                    "Error chain exceeded four causes")

        let metrics = GoogleDriveTransportMetrics(networkProtocol: .h2, reusedConnection: false,
            proxyConnection: true, cellular: false, dnsMS: 2, connectMS: 8, tlsMS: nil,
            tlsStarted: true, tlsFinished: false, requestStarted: false, responseStarted: false,
            tlsProtocolVersion: nil)
        let measured = GoogleDriveTransportDiagnostic.capture(error: cause, request: upload, phase: .nativeUpload, metrics: metrics)
        let roundTrip = try JSONDecoder().decode(GoogleDriveTransportDiagnostic.self, from: JSONEncoder().encode(measured))
        try require(roundTrip == measured && roundTrip.metrics == metrics, "Safe metrics did not survive the small report")
        try require(!(try encoded(measured)).contains(privateMarker) && measured.logFields.contains("proxy_connection=true")
                    && measured.logFields.contains("tls_finished=false"), "Safe metric logging leaked input or hid handshake state")
        return count
    }
}
