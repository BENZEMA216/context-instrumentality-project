import XCTest

final class AgentExportAvailabilityTests: XCTestCase {
    private func unavailableError() -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -10813)
        ])
    }

    func testOnlyKnownPreAccessorServiceFailureIsSkipped() throws {
        XCTAssertThrowsError(try AgentExportTestArchive.requireAvailable(
            error: unavailableError(), accessorEntered: false, requireNative: false)) { error in
                XCTAssertTrue(error is XCTSkip)
            }
        try AgentExportTestArchive.requireAvailable(error: nil, accessorEntered: true, requireNative: false)
    }

    func testStrictNativeRunDoesNotSkipUnavailableService() {
        assertFailureIsNotSkipped(unavailableError(), accessorEntered: false, requireNative: true)
    }

    func testOtherFailuresAndAccessorErrorsAreNotSkipped() {
        let errors = [
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError),
            NSError(domain: NSOSStatusErrorDomain, code: -10813),
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
                    userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -10813)]),
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                    userInfo: [NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: -10810)]),
            NSError(domain: NSCocoaErrorDomain, code: NSFileReadUnknownError,
                    userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: -10813)])
        ]
        for error in errors {
            assertFailureIsNotSkipped(error, accessorEntered: false, requireNative: false)
        }
        assertFailureIsNotSkipped(unavailableError(), accessorEntered: true, requireNative: false)
    }

    func testMissingAccessorWithoutAnErrorIsAFailure() {
        XCTAssertThrowsError(try AgentExportTestArchive.requireAvailable(
            error: nil, accessorEntered: false, requireNative: false)) { error in
                XCTAssertFalse(error is XCTSkip)
            }
    }

    private func assertFailureIsNotSkipped(_ expected: NSError, accessorEntered: Bool, requireNative: Bool,
                                          file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try AgentExportTestArchive.requireAvailable(
            error: expected, accessorEntered: accessorEntered, requireNative: requireNative), file: file, line: line) { error in
                XCTAssertFalse(error is XCTSkip, file: file, line: line)
                XCTAssertEqual((error as NSError).domain, expected.domain, file: file, line: line)
                XCTAssertEqual((error as NSError).code, expected.code, file: file, line: line)
            }
    }
}
