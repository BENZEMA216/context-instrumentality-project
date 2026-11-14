import Foundation
import RecordingCore

enum GoogleDriveTransportHistoryCases {
    private struct Failure: Error { let message: String }

    static func run() throws -> Int {
        var count = 0
        func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try value() else { throw Failure(message: message) }; count += 1
        }
        func bytes(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
        let at = Date(timeIntervalSince1970: 1_800_000_000), later = at.addingTimeInterval(300)
        let request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files")!)
        let failure = GoogleDriveTransportDiagnostic.capture(error: URLError(.secureConnectionFailed), request: request, phase: .apiRequest)
        let success = GoogleDriveTransportDiagnostic.capture(error: nil, request: request, phase: .apiRequest, httpStatus: 200)
        var original = GoogleDriveTransportHistory()
        try require(original.record(failure, at: at), "An initial TLS failure was not retained")
        let saved = original.encoded()!
        var restored = GoogleDriveTransportHistory.restored(from: saved, now: later)!
        try require(restored.record(success, at: at.addingTimeInterval(30)), "A post-restart success was not recorded")
        try require(restored.failures.count == 1 && restored.failures[0].diagnostic.errors[0].code == -1200,
                    "A restart followed by success erased the earlier TLS failure")
        let twice = GoogleDriveTransportHistory.restored(from: restored.encoded()!, now: later)!
        try require(twice.failures == restored.failures && twice.successes == restored.successes,
                    "History did not survive another roundtrip")
        try require(!restored.record(success, at: at.addingTimeInterval(31)), "Restored success sampling lost its ten-second bound")
        let recovered = GoogleDriveTransportDiagnostic.capture(error: nil, request: request, phase: .apiRecovery, httpStatus: 200)
        try require(restored.record(recovered, at: at.addingTimeInterval(31))
            && restored.successes.last?.diagnostic.phase == .apiRecovery,
                    "A concurrent ordinary success sampled away recovery evidence")

        for index in 0..<30 { _ = restored.record(failure, at: at.addingTimeInterval(Double(index + 40))) }
        for index in 0..<16 { _ = restored.record(success, at: at.addingTimeInterval(Double(100 + index * 10))) }
        try require(restored.failures.count == 16 && restored.successes.count == 8,
                    "Diagnostic history grew beyond its 16/8 bounds")
        var object = try JSONSerialization.jsonObject(with: restored.encoded()!) as! [String: Any]
        try require(object["schemaVersion"] as? Int == 2, "New transport history retained the legacy schema version")
        object["schemaVersion"] = 1
        let sampleFailure = (object["failures"] as! [[String: Any]])[0]
        let sampleSuccess = (object["successes"] as! [[String: Any]])[0]
        object["failures"] = Array(repeating: sampleFailure, count: 30)
        object["successes"] = Array(repeating: sampleSuccess, count: 14)
        let trimmed = GoogleDriveTransportHistory.restored(from: try bytes(object), now: later)
        try require(trimmed?.failures.count == 16 && trimmed?.successes.count == 8,
                    "A valid older schema-1 report was not bounded during readback")
        let privateMarker = "SYNTHETIC_PRIVATE_HISTORY_MUST_NOT_ESCAPE"
        object[privateMarker] = "https://private.example/" + privateMarker
        let unknownKey = GoogleDriveTransportHistory.restored(from: try bytes(object), now: later)
        try require(unknownKey != nil && !String(decoding: unknownKey!.encoded()!, as: UTF8.self).contains(privateMarker),
                    "An ignored JSON field became a later output channel")
        let correlation = GoogleDriveUploadCorrelation(segmentID: UUID(), kind: .audio,
            manifestSHA256: String(repeating: "f", count: 64))
        var correlated = GoogleDriveTransportHistory()
        try require(correlated.record(failure.withUploadCorrelation(correlation), at: at),
            "An upload-correlated failure was not retained")
        try require(GoogleDriveTransportHistory.restored(from: correlated.encoded()!, now: later)?.failures.first?.diagnostic.uploadCorrelation == correlation,
            "A restart lost the upload job correlation")
        let otherCorrelation = GoogleDriveUploadCorrelation(segmentID: UUID(), kind: .manifest,
            manifestSHA256: String(repeating: "e", count: 64))
        try require(correlated.record(success.withUploadCorrelation(correlation), at: at.addingTimeInterval(1))
            && correlated.record(success.withUploadCorrelation(otherCorrelation), at: at.addingTimeInterval(2))
            && correlated.record(success.withUploadCorrelation(correlation), at: at.addingTimeInterval(3))
            && correlated.successes.map(\.diagnostic.uploadCorrelation) == [correlation, otherCorrelation, correlation],
            "Global transport sampling dropped a keyed request or another upload job's first success")
        try require(unknownKey?.failures.allSatisfy { $0.diagnostic.uploadCorrelation == nil } == true,
            "Legacy history fabricated upload correlations")

        func rejectedDiagnosticMutation(_ key: String, _ value: Any) throws -> Bool {
            var invalid = object
            var observation = sampleFailure, diagnostic = observation["diagnostic"] as! [String: Any]
            diagnostic[key] = value; observation["diagnostic"] = diagnostic
            // Include the bad value in the discarded prefix too: validation must
            // cover every decoded observation, not only the retained suffix.
            invalid["failures"] = [observation] + Array(repeating: sampleFailure, count: 20)
            return GoogleDriveTransportHistory.restored(from: try bytes(invalid), now: later) == nil
        }
        try require(try rejectedDiagnosticMutation("errors", [["domain": privateMarker, "code": -1200]]),
                    "An arbitrary Codable NSError domain was accepted")
        for field in ["phase", "endpoint", "method"] {
            try require(try rejectedDiagnosticMutation(field, privateMarker), "An arbitrary typed vocabulary string was accepted")
        }
        try require(try rejectedDiagnosticMutation("errors", Array(repeating: ["domain": NSURLErrorDomain, "code": -1200], count: 5)),
                    "An overlong error chain was accepted")
        try require(try rejectedDiagnosticMutation("errors", []), "A success in the failure list was accepted")
        try require(try rejectedDiagnosticMutation("httpStatus", 999), "An invalid HTTP status was accepted")
        try require(try rejectedDiagnosticMutation("streamErrorCode", Int64(Int32.max) + 1), "An out-of-range stream code was accepted")
        try require(try rejectedDiagnosticMutation("metrics", ["networkProtocol": "h2", "reusedConnection": false,
            "proxyConnection": true, "cellular": false, "dnsMS": -1, "tlsStarted": true,
            "tlsFinished": false, "requestStarted": false, "responseStarted": false]), "Negative metric timing was accepted")
        try require(try rejectedDiagnosticMutation("uploadCorrelation", ["scope": "upload_job", "jobKey": privateMarker, "kind": "audio"]),
            "An arbitrary private upload correlation string was accepted")
        try require(try rejectedDiagnosticMutation("uploadCorrelation", ["scope": "shared", "jobKey": "0123456789abcdef", "kind": "audio"]),
            "A shared refresh carrying a contradictory job identity was accepted")
        object["schemaVersion"] = 3
        try require(GoogleDriveTransportHistory.restored(from: try bytes(object), now: later) == nil, "A different schema was accepted")
        try require(GoogleDriveTransportHistory.restored(from: Data("not json".utf8), now: later) == nil,
                    "Corrupt JSON was accepted")
        try require(GoogleDriveTransportHistory.restored(from: Data(repeating: 32, count: GoogleDriveTransportHistory.maximumFileBytes + 1), now: later) == nil,
                    "A report exceeding the fixed read limit was accepted")
        try require(!restored.record(failure, at: Date(timeIntervalSince1970: -1)), "An invalid timestamp entered history")
        return count
    }
}
