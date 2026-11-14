import Foundation
import XCTest
@testable import RecordingCore

final class AutomaticReceiverHealthTests: XCTestCase {
    func testNetworkFailuresHaveFixedActionableCategories() {
        let cases: [(Int, AutomaticReceiverFailureCategory)] = [
            (NSURLErrorCannotFindHost, .dns), (NSURLErrorDNSLookupFailed, .dns),
            (NSURLErrorTimedOut, .timeout), (NSURLErrorCannotConnectToHost, .cannotConnect),
            (NSURLErrorNotConnectedToInternet, .offline), (NSURLErrorNetworkConnectionLost, .offline),
            (NSURLErrorDataNotAllowed, .networkRestricted), (NSURLErrorInternationalRoamingOff, .networkRestricted),
            (NSURLErrorAppTransportSecurityRequiresSecureConnection, .atsBlocked),
            (NSURLErrorServerCertificateUntrusted, .certificate), (NSURLErrorSecureConnectionFailed, .certificate),
            (NSURLErrorUserAuthenticationRequired, .unauthorized), (NSURLErrorCancelled, .cancelled),
            (NSURLErrorHTTPTooManyRedirects, .invalidResponse)
        ]
        for (code, expected) in cases {
            XCTAssertEqual(AutomaticReceiverFailureCategory.classify(error: NSError(domain: NSURLErrorDomain, code: code)), expected)
        }
        XCTAssertEqual(AutomaticReceiverFailureCategory.classify(error: CancellationError()), .cancelled)
        XCTAssertTrue(AutomaticReceiverFailureCategory.networkRestricted.hint.contains("不能单独证明"))
    }

    func testHTTPFailureAndUnsupportedLegacyServerRemainDistinct() {
        for code in [401, 403] { XCTAssertEqual(AutomaticReceiverFailureCategory.classify(error: nil, statusCode: code), .unauthorized) }
        for code in [404, 405, 501] { XCTAssertEqual(AutomaticReceiverFailureCategory.classify(error: nil, statusCode: code), .unsupportedProbe) }
        for code in [429, 500, 502, 503] { XCTAssertEqual(AutomaticReceiverFailureCategory.classify(error: nil, statusCode: code), .server) }
        XCTAssertEqual(AutomaticReceiverFailureCategory.classify(error: nil, statusCode: 408), .timeout)
        for code in [200, 204, 301, 400] { XCTAssertEqual(AutomaticReceiverFailureCategory.classify(error: nil, statusCode: code), .invalidResponse) }
    }

    func testUnsupportedStatusEndpointIsNeutralRatherThanUnreachableOrReceipt() {
        for code in [404, 405, 501] {
            let result = AutomaticReceiverProbeResult.httpFailure(statusCode: code)
            XCTAssertEqual(result, .unsupportedProbe)
            XCTAssertNotEqual(result, .failed(.unsupportedProbe))
            XCTAssertNotEqual(result, .reachable)
        }
        XCTAssertEqual(AutomaticReceiverProbeResult.httpFailure(statusCode: 401), .failed(.unauthorized))
        XCTAssertEqual(AutomaticReceiverProbeResult.httpFailure(statusCode: 503), .failed(.server))
        XCTAssertEqual(AutomaticReceiverProbeResult.httpFailure(statusCode: 302), .failed(.invalidResponse))
        XCTAssertEqual(AutomaticReceiverFailureCategory.unsupportedProbe.title, "已连接 · 建议升级电脑接收程序")
        XCTAssertTrue(AutomaticReceiverFailureCategory.unsupportedProbe.hint.contains("配对证书"))
        XCTAssertTrue(AutomaticReceiverFailureCategory.unsupportedProbe.hint.contains("不代表录音已交付"))
    }

    func testLocalFailuresDoNotMasqueradeAsNetworkFailures() {
        let privateText = "private-host.invalid/private-recording-path"
        for error in [NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError),
                      NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError),
                      NSError(domain: "SyntheticPreparation", code: NSURLErrorTimedOut,
                        userInfo: [NSLocalizedDescriptionKey: privateText])] {
            XCTAssertNil(AutomaticReceiverFailureCategory.networkFailure(error: error))
        }
        let network = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
            userInfo: [NSLocalizedDescriptionKey: privateText])
        XCTAssertEqual(AutomaticReceiverFailureCategory.networkFailure(error: network), .timeout)
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: 1, userInfo: [NSUnderlyingErrorKey: network])
        XCTAssertEqual(AutomaticReceiverFailureCategory.networkFailure(error: wrapped), .timeout)
        XCTAssertEqual(AutomaticReceiverFailureCategory.networkFailure(error: NSError(domain: NSURLErrorDomain, code: -9_999)), .unknown)
        XCTAssertEqual(AutomaticReceiverFailureCategory.networkFailure(error: CancellationError()), .cancelled)
        XCTAssertEqual(AutomaticReceiverFailureCategory.pairingRepairRequired.title, "需重新配对")
        XCTAssertTrue(AutomaticReceiverFailureCategory.pairingRepairRequired.hint.contains("重试不会解除"))
        XCTAssertTrue(AutomaticReceiverFailureCategory.localState.title.contains("本地"))
    }

    func testRawErrorsAndNestedPrivateContextNeverEscapeClassifier() throws {
        let privateText = "https://private-computer.local:8766/private-audio-path?token=private-token"
        let underlying = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost,
            userInfo: [NSLocalizedDescriptionKey: privateText, NSURLErrorFailingURLStringErrorKey: privateText])
        let wrapped = NSError(domain: "SyntheticWrapper", code: 1, userInfo: [NSUnderlyingErrorKey: underlying])
        let category = AutomaticReceiverFailureCategory.classify(error: wrapped)
        XCTAssertEqual(category, .dns)
        for value in AutomaticReceiverFailureCategory.allCases {
            let encoded = try JSONEncoder().encode(value)
            XCTAssertEqual(try JSONDecoder().decode(AutomaticReceiverFailureCategory.self, from: encoded), value)
            XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(privateText))
            XCTAssertFalse(value.title.contains("private-"))
            XCTAssertFalse(value.hint.contains("private-"))
            XCTAssertFalse(value.title.isEmpty)
            XCTAssertFalse(value.hint.isEmpty)
        }
        XCTAssertEqual(AutomaticReceiverFailureCategory.classify(error: NSError(domain: "Unknown", code: -1003,
            userInfo: [NSLocalizedDescriptionKey: privateText])), .unknown)
    }

    func testURLSessionFileFailuresRetainLocalRecoveryEvenWhenWrapped() {
        let codes = [NSURLErrorFileDoesNotExist, NSURLErrorFileIsDirectory,
                     NSURLErrorNoPermissionsToReadFile, NSURLErrorCannotCreateFile,
                     NSURLErrorCannotOpenFile, NSURLErrorCannotCloseFile,
                     NSURLErrorCannotWriteToFile, NSURLErrorCannotRemoveFile,
                     NSURLErrorCannotMoveFile]
        for code in codes {
            let local = NSError(domain: NSURLErrorDomain, code: code,
                userInfo: [NSLocalizedDescriptionKey: "synthetic-private-file-path"])
            XCTAssertNil(AutomaticReceiverFailureCategory.networkFailure(error: local))
            let wrapped = NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown,
                userInfo: [NSUnderlyingErrorKey: local])
            XCTAssertNil(AutomaticReceiverFailureCategory.networkFailure(error: wrapped))
        }
    }

    func testUnknownWrapperRetainsNestedNetworkCategoryWithoutUsingItsDescription() {
        let network = NSError(domain: NSURLErrorDomain, code: NSURLErrorDNSLookupFailed)
        let wrapped = NSError(domain: NSURLErrorDomain, code: NSURLErrorUnknown,
            userInfo: [NSUnderlyingErrorKey: network, NSLocalizedDescriptionKey: "local preparation failed"])
        XCTAssertEqual(AutomaticReceiverFailureCategory.networkFailure(error: wrapped), .dns)
        let unrelated = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError,
            userInfo: [NSLocalizedDescriptionKey: "network timed out at private-host.invalid"])
        XCTAssertNil(AutomaticReceiverFailureCategory.networkFailure(error: unrelated))
    }

    func testOnlyCurrentReceiverReadyResponseEstablishesReachability() throws {
        let id = UUID()
        func payload(_ overrides: [String: Any] = [:]) throws -> Data {
            var object: [String: Any] = ["schemaVersion": 1, "receiverID": id.uuidString, "status": "ready"]
            overrides.forEach { object[$0.key] = $0.value }
            return try JSONSerialization.data(withJSONObject: object)
        }
        XCTAssertEqual(AutomaticReceiverProbeResult.decodeStatus(try payload(), receiverID: id), .reachable)
        for value in [try payload(["receiverID": UUID().uuidString]), try payload(["schemaVersion": 2]),
                      try payload(["status": "starting"]), try payload(["unexpected": "secret"]),
                      Data("{}".utf8), Data("OK".utf8), Data(repeating: 32, count: 4_097)] {
            XCTAssertEqual(AutomaticReceiverProbeResult.decodeStatus(value, receiverID: id), .failed(.invalidResponse))
        }
    }
}
