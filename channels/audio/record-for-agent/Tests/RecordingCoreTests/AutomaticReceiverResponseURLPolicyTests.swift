import Foundation
import XCTest
@testable import RecordingCore

final class AutomaticReceiverResponseURLPolicyTests: XCTestCase {
    private let expected = URL(string: "https://DONGZHEdeMacBook-Pro.local:8766/v1/imports")!

    func testURLSessionLowercasedBonjourHostMatchesOriginalPairing() throws {
        let actual = try XCTUnwrap(URL(string: "https://dongzhedemacbook-pro.local:8766/v1/imports"))
        XCTAssertTrue(AutomaticReceiverResponseURLPolicy.matches(expected: expected, response: actual))
        XCTAssertTrue(AutomaticReceiverResponseURLPolicy.matches(expected: actual, response: expected))
        XCTAssertTrue(AutomaticReceiverResponseURLPolicy.matches(expected: expected, response: expected))
    }

    func testHTTPSchemeAndHostCaseMayNormalizeTogether() throws {
        let actual = try XCTUnwrap(URL(string: "HTTPS://DongzheDEMacbook-Pro.LOCAL:8766/v1/imports"))
        XCTAssertTrue(AutomaticReceiverResponseURLPolicy.matches(expected: expected, response: actual))
    }

    func testOriginChangesAndUnexpectedURLComponentsAreRejected() throws {
        let rejected = [
            "http://dongzhedemacbook-pro.local:8766/v1/imports",
            "https://other.local:8766/v1/imports",
            "https://dongzhedemacbook-pro.local.example:8766/v1/imports",
            "https://dongzhedemacbook-pro.local.:8766/v1/imports",
            "https://dongzhedemacbook-pro.local:8767/v1/imports",
            "https://dongzhedemacbook-pro.local/v1/imports",
            "https://dongzhedemacbook-pro.local:08766/v1/imports",
            "https://user@dongzhedemacbook-pro.local:8766/v1/imports",
            "https://user:password@dongzhedemacbook-pro.local:8766/v1/imports",
            "https://dongzhedemacbook-pro.local:8766/v1/imports?redirect=1",
            "https://dongzhedemacbook-pro.local:8766/v1/imports?",
            "https://dongzhedemacbook-pro.local:8766/v1/imports#fragment",
            "https://dongzhedemacbook-pro.local:8766/v1/imports#"
        ]
        for value in rejected {
            let actual = try XCTUnwrap(URL(string: value))
            XCTAssertFalse(AutomaticReceiverResponseURLPolicy.matches(expected: expected, response: actual), value)
        }
        XCTAssertFalse(AutomaticReceiverResponseURLPolicy.matches(expected: expected, response: nil))
    }

    func testPathSpellingMustRemainExact() throws {
        for path in ["/V1/imports", "/v1/Imports", "/v1/imports/", "/v1//imports",
                     "/v1/./imports", "/v1/%69mports", "/v1%2Fimports", "/v1/exports"] {
            let actual = try XCTUnwrap(URL(string: "https://dongzhedemacbook-pro.local:8766" + path))
            XCTAssertFalse(AutomaticReceiverResponseURLPolicy.matches(expected: expected, response: actual), path)
        }
    }

    func testDefaultPortIsNotSilentlyAddedOrRemoved() throws {
        let implicit = try XCTUnwrap(URL(string: "https://receiver.local/v1/imports"))
        let explicit = try XCTUnwrap(URL(string: "https://receiver.local:443/v1/imports"))
        XCTAssertFalse(AutomaticReceiverResponseURLPolicy.matches(expected: implicit, response: explicit))
        XCTAssertFalse(AutomaticReceiverResponseURLPolicy.matches(expected: explicit, response: implicit))
    }

    func testUnsafeExpectedURLDoesNotBecomeAnAllowedTarget() throws {
        for value in ["http://receiver.local/v1/imports", "https://user@receiver.local/v1/imports",
                      "https://receiver.local/v1/imports?x=1", "https://receiver.local/v1/imports#x",
                      "/v1/imports"] {
            let url = try XCTUnwrap(URL(string: value))
            XCTAssertFalse(AutomaticReceiverResponseURLPolicy.matches(expected: url, response: url), value)
        }
    }

    func testIPv6AddressCaseCanNormalizeButInterfaceZoneCannot() throws {
        let original = try XCTUnwrap(URL(string: "https://[FE80::ABCD%25en0]:8766/v1/imports"))
        let normalized = try XCTUnwrap(URL(string: "https://[fe80::abcd%25en0]:8766/v1/imports"))
        let changedZone = try XCTUnwrap(URL(string: "https://[fe80::abcd%25EN0]:8766/v1/imports"))
        XCTAssertTrue(AutomaticReceiverResponseURLPolicy.matches(expected: original, response: normalized))
        XCTAssertFalse(AutomaticReceiverResponseURLPolicy.matches(expected: original, response: changedZone))
    }
}
