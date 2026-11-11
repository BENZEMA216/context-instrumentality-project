import XCTest
@testable import RecordingCore

final class AudioRecoveryPolicyTests: XCTestCase {
    private func retry(_ decision: AudioRecoveryPolicy.FailureDecision,
                       file: StaticString = #filePath, line: UInt = #line) throws
        -> AudioRecoveryPolicy.RetryPermit {
        guard case .retry(let permit) = decision else {
            XCTFail("Expected a retry permit, got \(decision)", file: file, line: line)
            throw MissingRetry()
        }
        return permit
    }

    func testAutomaticRecoveryStopsAfterThreeDelayedRetries() throws {
        var policy = AudioRecoveryPolicy()
        var attempt = try XCTUnwrap(policy.begin(.automaticRecovery))
        for (index, delay) in [1.0, 3.0, 6.0].enumerated() {
            let permit = try retry(policy.failed(attempt))
            XCTAssertEqual(permit.delay, delay)
            XCTAssertEqual(policy.retryCount, index + 1)
            XCTAssertTrue(policy.isActive)
            XCTAssertFalse(policy.isCurrent(attempt))
            attempt = try XCTUnwrap(policy.consume(permit))
            XCTAssertTrue(policy.isCurrent(attempt))
        }
        XCTAssertEqual(policy.failed(attempt), .stop)
        XCTAssertFalse(policy.isActive)
        XCTAssertEqual(policy.retryCount, 3)
        XCTAssertEqual(policy.failed(attempt), .ignored)
    }

    func testManualFailureNeverSchedulesRetry() throws {
        var policy = AudioRecoveryPolicy()
        let attempt = try XCTUnwrap(policy.begin(.manual))
        XCTAssertEqual(policy.failed(attempt), .stop)
        XCTAssertFalse(policy.isActive)
        XCTAssertEqual(policy.retryCount, 0)
        XCTAssertEqual(policy.failed(attempt), .ignored)
    }

    func testActualAudioSuccessResetsBudgetForNextRecovery() throws {
        var policy = AudioRecoveryPolicy()
        let first = try XCTUnwrap(policy.begin(.automaticRecovery))
        let permit = try retry(policy.failed(first))
        let second = try XCTUnwrap(policy.consume(permit))
        XCTAssertTrue(policy.succeeded(second))
        XCTAssertFalse(policy.isActive)
        XCTAssertEqual(policy.retryCount, 0)
        XCTAssertFalse(policy.succeeded(second))
        XCTAssertEqual(policy.failed(second), .ignored)
        XCTAssertNil(policy.consume(permit))

        let fresh = try XCTUnwrap(policy.begin(.automaticRecovery))
        XCTAssertNotEqual(fresh, first)
        XCTAssertEqual(try retry(policy.failed(fresh)).delay, 1)
        XCTAssertEqual(policy.retryCount, 1)
    }

    func testCancellationInvalidatesWaitingPermitAndAttempt() throws {
        var policy = AudioRecoveryPolicy()
        let first = try XCTUnwrap(policy.begin(.automaticRecovery))
        let permit = try retry(policy.failed(first))
        policy.cancel()
        policy.cancel() // Pause/end/interruption cancellation is idempotent.
        XCTAssertFalse(policy.isActive)
        XCTAssertEqual(policy.retryCount, 0)
        XCTAssertNil(policy.consume(permit))
        XCTAssertEqual(policy.failed(first), .ignored)
        XCTAssertFalse(policy.succeeded(first))

        let fresh = try XCTUnwrap(policy.begin(.automaticRecovery))
        XCTAssertTrue(policy.isCurrent(fresh))
        XCTAssertNil(policy.consume(permit))
        XCTAssertEqual(try retry(policy.failed(fresh)).delay, 1)
    }

    func testCancellationInvalidatesInFlightActivation() throws {
        var policy = AudioRecoveryPolicy()
        let attempt = try XCTUnwrap(policy.begin(.automaticRecovery))
        policy.cancel()
        XCTAssertFalse(policy.isCurrent(attempt))
        XCTAssertEqual(policy.failed(attempt), .ignored)
        XCTAssertFalse(policy.succeeded(attempt))
        XCTAssertFalse(policy.isActive)
    }

    func testDuplicateFailureAndPermitConsumptionDoNotSpendExtraBudget() throws {
        var policy = AudioRecoveryPolicy()
        let first = try XCTUnwrap(policy.begin(.automaticRecovery))
        let permit = try retry(policy.failed(first))
        XCTAssertEqual(policy.failed(first), .ignored)
        XCTAssertEqual(policy.retryCount, 1)
        let second = try XCTUnwrap(policy.consume(permit))
        XCTAssertNil(policy.consume(permit))
        XCTAssertEqual(policy.failed(first), .ignored)
        XCTAssertFalse(policy.succeeded(first))
        XCTAssertTrue(policy.isCurrent(second))
        XCTAssertEqual(try retry(policy.failed(second)).delay, 3)
        XCTAssertEqual(policy.retryCount, 2)
    }

    func testManualStartSupersedesWaitingAutomaticRetry() throws {
        var policy = AudioRecoveryPolicy()
        let automatic = try XCTUnwrap(policy.begin(.automaticRecovery))
        let permit = try retry(policy.failed(automatic))
        let manual = try XCTUnwrap(policy.begin(.manual))
        XCTAssertEqual(policy.retryCount, 0)
        XCTAssertNil(policy.consume(permit))
        XCTAssertEqual(policy.failed(automatic), .ignored)
        XCTAssertFalse(policy.succeeded(automatic))
        XCTAssertTrue(policy.isCurrent(manual))
        XCTAssertEqual(policy.failed(manual), .stop)
    }

    func testNewManualAttemptMakesOldActivationCallbacksStale() throws {
        var policy = AudioRecoveryPolicy()
        let old = try XCTUnwrap(policy.begin(.manual))
        let current = try XCTUnwrap(policy.begin(.manual))
        XCTAssertNotEqual(current, old)
        XCTAssertFalse(policy.succeeded(old))
        XCTAssertEqual(policy.failed(old), .ignored)
        XCTAssertTrue(policy.isCurrent(current))
        XCTAssertTrue(policy.succeeded(current))
    }

    func testAutomaticReentryDoesNotReplaceAttemptOrResetBudget() throws {
        var policy = AudioRecoveryPolicy()
        let first = try XCTUnwrap(policy.begin(.automaticRecovery))
        XCTAssertNil(policy.begin(.automaticRecovery))
        XCTAssertTrue(policy.isCurrent(first))
        let firstPermit = try retry(policy.failed(first))
        XCTAssertNil(policy.begin(.automaticRecovery))
        XCTAssertEqual(policy.retryCount, 1)
        let second = try XCTUnwrap(policy.consume(firstPermit))
        XCTAssertNil(policy.begin(.automaticRecovery))
        XCTAssertEqual(try retry(policy.failed(second)).delay, 3)
        XCTAssertEqual(policy.retryCount, 2)
    }

    func testAutomaticNotificationCannotSupersedeManualActivation() throws {
        var policy = AudioRecoveryPolicy()
        let manual = try XCTUnwrap(policy.begin(.manual))
        XCTAssertNil(policy.begin(.automaticRecovery))
        XCTAssertTrue(policy.isCurrent(manual))
        XCTAssertEqual(policy.failed(manual), .stop)
    }

    func testStalePermitCannotConsumeNewCyclesWaitingRetry() throws {
        var policy = AudioRecoveryPolicy()
        let oldAttempt = try XCTUnwrap(policy.begin(.automaticRecovery))
        let oldPermit = try retry(policy.failed(oldAttempt))
        policy.cancel()
        let currentAttempt = try XCTUnwrap(policy.begin(.automaticRecovery))
        let currentPermit = try retry(policy.failed(currentAttempt))
        XCTAssertEqual(oldPermit.delay, currentPermit.delay)
        XCTAssertNotEqual(oldPermit, currentPermit)
        XCTAssertNil(policy.consume(oldPermit))
        XCTAssertFalse(policy.succeeded(oldAttempt))
        XCTAssertEqual(policy.retryCount, 1)
        XCTAssertNotNil(policy.consume(currentPermit))
    }

    func testTokenFromDifferentPolicyCannotAffectCurrentAttempt() throws {
        var policy = AudioRecoveryPolicy()
        var other = AudioRecoveryPolicy()
        let current = try XCTUnwrap(policy.begin(.automaticRecovery))
        let foreign = try XCTUnwrap(other.begin(.automaticRecovery))
        let foreignPermit = try retry(other.failed(foreign))
        XCTAssertEqual(policy.failed(foreign), .ignored)
        XCTAssertFalse(policy.succeeded(foreign))
        XCTAssertNil(policy.consume(foreignPermit))
        XCTAssertTrue(policy.isCurrent(current))
        XCTAssertEqual(policy.retryCount, 0)
    }

    private struct MissingRetry: Error {}
}
