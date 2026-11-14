import Foundation
import Darwin
import XCTest
@testable import RecordingCore

final class VerifiedObservationTests: XCTestCase {
    private func source() -> VerifiedObservationSource {
        .init(sourceGeneratedAtMS: 1_000, identity: ["generationID": "frozen"],
              files: [.init(name: "metadata-capture.json", bytes: Data("old business bytes".utf8))])
    }
    func testIdleSameBuildAndNewProcessObserveWithoutChangingSourceTime() throws {
        var files: [String: Data] = [:]
        var now: Int64 = 600_000
        let process = UUID()
        let publisher = VerifiedObservationPublisher(reportKind: "phone_receipts", build: "86", processRunID: process,
            clock: { (now, now) }, writer: { files[$1] = $0 })
        XCTAssertTrue(publisher.observe { self.source() })
        let first = try JSONDecoder().decode(VerifiedObservationPublisher.Receipt.self,
            from: XCTUnwrap(files[VerifiedObservationPublisher.fileName]))
        XCTAssertEqual(first.sourceGeneratedAtMS, 1_000)
        XCTAssertEqual(first.observedAtMS, now)
        XCTAssertEqual(first.observerProcessRunID, process)
        var validations = 0
        XCTAssertFalse(publisher.observe { validations += 1; return self.source() })
        XCTAssertEqual(validations, 0)
        now += 30_000
        XCTAssertTrue(publisher.observe { self.source() })
        let second = try JSONDecoder().decode(VerifiedObservationPublisher.Receipt.self,
            from: XCTUnwrap(files[VerifiedObservationPublisher.fileName]))
        XCTAssertEqual(second.sequence, 2)
        XCTAssertEqual(first.files, second.files)
        XCTAssertEqual(first.identity, second.identity)
        let restarted = UUID()
        let fresh = VerifiedObservationPublisher(reportKind: "phone_receipts", build: "86", processRunID: restarted,
            clock: { (now, now) }, writer: { files[$1] = $0 })
        XCTAssertTrue(fresh.observe { self.source() })
        let third = try JSONDecoder().decode(VerifiedObservationPublisher.Receipt.self,
            from: XCTUnwrap(files[VerifiedObservationPublisher.fileName]))
        XCTAssertEqual(third.observerProcessRunID, restarted)
        XCTAssertEqual(third.sequence, 1)
        XCTAssertEqual(third.files, first.files)
    }
    func testFailedRevalidationPreservesReceiptAndInvalidatesPriorSuccess() throws {
        var files: [String: Data] = [:]
        var now: Int64 = 600_000
        var failures: [String] = []
        let publisher = VerifiedObservationPublisher(reportKind: "google_drive", build: "86", processRunID: UUID(),
            clock: { (now, now) }, writer: { files[$1] = $0 }, failureSink: { failures.append($0) })
        XCTAssertTrue(publisher.observe { self.source() })
        let old = files[VerifiedObservationPublisher.fileName]
        now += 30_000
        XCTAssertFalse(publisher.observe { throw VerifiedObservationPublisher.Failure.invalidSource })
        XCTAssertEqual(old, files[VerifiedObservationPublisher.fileName])
        let status = try JSONDecoder().decode(VerifiedObservationPublisher.Status.self,
            from: XCTUnwrap(files[VerifiedObservationPublisher.statusName]))
        XCTAssertFalse(status.available)
        XCTAssertEqual(status.sequence, 2)
        XCTAssertNil(status.observationSHA256)
        XCTAssertEqual(failures, ["validation_or_write_failed"])
    }
    func testThrottleReportsRoundedRemainingSecondsWithoutValidatingOrWriting() {
        var now: Int64 = 600_000, writes = 0, remaining: [Int] = []
        let publisher = VerifiedObservationPublisher(reportKind: "phone_receipts", build: "86", processRunID: UUID(),
            clock: { (now, now) }, writer: { _, _ in writes += 1 })
        XCTAssertTrue(publisher.observe { self.source() })
        let originalWrites = writes
        now += 1_001
        XCTAssertFalse(publisher.observe(onThrottle: { remaining.append($0) }) {
            XCTFail("A throttled request must not read source metadata"); return self.source()
        })
        XCTAssertEqual(remaining, [29]); XCTAssertEqual(writes, originalWrites)
        now += 28_999
        XCTAssertTrue(publisher.observe(onThrottle: { remaining.append($0) }) { self.source() })
        XCTAssertEqual(remaining, [29])
    }
    func testReceiptWriteFailureRetainsOldBytesAndIndependentError() throws {
        var files: [String: Data] = [:]
        var now: Int64 = 600_000
        var rejectReceipt = false
        let publisher = VerifiedObservationPublisher(reportKind: "google_drive", build: "86", processRunID: UUID(),
            clock: { (now, now) }, writer: { bytes, name in
                if rejectReceipt && name == VerifiedObservationPublisher.fileName { throw POSIXError(.ENOSPC) }
                files[name] = bytes
            }, failureSink: { _ in })
        XCTAssertTrue(publisher.observe { self.source() })
        let old = files[VerifiedObservationPublisher.fileName]
        now += 30_000; rejectReceipt = true
        XCTAssertFalse(publisher.observe { self.source() })
        XCTAssertEqual(old, files[VerifiedObservationPublisher.fileName])
        let status = try JSONDecoder().decode(VerifiedObservationPublisher.Status.self,
            from: XCTUnwrap(files[VerifiedObservationPublisher.statusName]))
        XCTAssertFalse(status.available)
    }
    func testPendingStatusFailureDoesNotValidateOrPublishAndLogs() throws {
        var validations = 0
        var failures: [String] = []
        let publisher = VerifiedObservationPublisher(reportKind: "google_drive", build: "86", processRunID: UUID(),
            clock: { (600_000, 600_000) }, writer: { _, _ in throw POSIXError(.EACCES) }, failureSink: { failures.append($0) })
        XCTAssertFalse(publisher.observe { validations += 1; return self.source() })
        XCTAssertEqual(validations, 0)
        XCTAssertEqual(failures, ["failure_status_write_failed", "validation_or_write_failed"])
    }
    func testClockRollbackAndForwardJumpCannotProduceFreshReceipt() {
        for step in [(wall: Int64(-10), continuous: Int64(30_000)), (wall: Int64(90_000), continuous: Int64(30_000)),
                     (wall: Int64(30_000), continuous: Int64(-10))] {
            var now: (wall: Int64, continuous: Int64) = (600_000, 600_000)
            var files: [String: Data] = [:]
            let publisher = VerifiedObservationPublisher(reportKind: "google_drive", build: "86", processRunID: UUID(),
                clock: { now }, writer: { files[$1] = $0 }, failureSink: { _ in })
            XCTAssertTrue(publisher.observe { self.source() })
            let old = files[VerifiedObservationPublisher.fileName]
            now = (now.wall + step.wall, now.continuous + step.continuous)
            XCTAssertFalse(publisher.observe { self.source() })
            XCTAssertEqual(files[VerifiedObservationPublisher.fileName], old)
        }
    }
    func testSleepInclusiveClockAllowsFirstForegroundAfterIdleAndOvernight() throws {
        for sleptMS: Int64 in [600_000, 8 * 60 * 60 * 1_000] {
            var now: (wall: Int64, continuous: Int64) = (10_000_000, 1_000_000)
            var awakeUptime: Int64 = 50_000
            var files: [String: Data] = [:], failures: [String] = []
            let publisher = VerifiedObservationPublisher(reportKind: "google_drive", build: "86", processRunID: UUID(),
                clock: { now }, writer: { files[$1] = $0 }, failureSink: { failures.append($0) })
            XCTAssertTrue(publisher.observe { self.source() })
            let first = try JSONDecoder().decode(VerifiedObservationPublisher.Receipt.self,
                from: XCTUnwrap(files[VerifiedObservationPublisher.fileName]))
            let awakeBefore = awakeUptime
            now.wall += sleptMS + 1_000; now.continuous += sleptMS + 1_000
            awakeUptime += 1_000 // The old uptime pauses throughout simulated sleep.
            XCTAssertGreaterThan((now.wall - first.observedAtMS) - (awakeUptime - awakeBefore), 2_000)
            XCTAssertLessThan(awakeUptime - awakeBefore, 30_000, "The old clock would also incorrectly throttle the wake")
            XCTAssertTrue(publisher.observe { self.source() }, "First real foreground after sleep must succeed")
            let second = try JSONDecoder().decode(VerifiedObservationPublisher.Receipt.self,
                from: XCTUnwrap(files[VerifiedObservationPublisher.fileName]))
            let status = try JSONDecoder().decode(VerifiedObservationPublisher.Status.self,
                from: XCTUnwrap(files[VerifiedObservationPublisher.statusName]))
            XCTAssertEqual(second.schemaVersion, 2); XCTAssertEqual(second.clockName, "CLOCK_MONOTONIC")
            XCTAssertEqual(second.continuousTimeMS - first.continuousTimeMS, second.observedAtMS - first.observedAtMS)
            XCTAssertEqual(second.sourceGeneratedAtMS, first.sourceGeneratedAtMS)
            XCTAssertEqual(second.identity, first.identity); XCTAssertEqual(second.files, first.files)
            XCTAssertTrue(status.available); XCTAssertEqual(status.clockName, second.clockName)
            XCTAssertEqual(status.continuousTimeMS, second.continuousTimeMS)
            XCTAssertTrue(failures.isEmpty)
        }
    }
    func testProductionClockUsesDarwinSleepInclusiveMonotonicSource() {
        let before = Int64(clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1_000_000)
        let actual = VerifiedObservationPublisher.continuousMilliseconds()
        let after = Int64(clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1_000_000)
        XCTAssertGreaterThanOrEqual(actual, before); XCTAssertLessThanOrEqual(actual, after)
    }
    func testUnavailableProductionClockCannotValidateOrPublishReceipt() throws {
        var files: [String: Data] = [:], validations = 0
        let publisher = VerifiedObservationPublisher(reportKind: "google_drive", build: "86", processRunID: UUID(),
            clock: { (600_000, VerifiedObservationPublisher.continuousMilliseconds(readNanoseconds: { 0 })) },
            writer: { files[$1] = $0 }, failureSink: { _ in })
        XCTAssertFalse(publisher.observe { validations += 1; return self.source() })
        XCTAssertEqual(validations, 0); XCTAssertNil(files[VerifiedObservationPublisher.fileName])
        let status = try JSONDecoder().decode(VerifiedObservationPublisher.Status.self,
            from: XCTUnwrap(files[VerifiedObservationPublisher.statusName]))
        XCTAssertFalse(status.available); XCTAssertEqual(status.continuousTimeMS, -1)
    }
    func testRealClockJumpInsideThrottleStillInvalidatesReceipt() throws {
        var now: (wall: Int64, continuous: Int64) = (600_000, 600_000)
        var files: [String: Data] = [:]
        let publisher = VerifiedObservationPublisher(reportKind: "google_drive", build: "86", processRunID: UUID(),
            clock: { now }, writer: { files[$1] = $0 }, failureSink: { _ in })
        XCTAssertTrue(publisher.observe { self.source() })
        let old = files[VerifiedObservationPublisher.fileName]
        now.wall += 600_000; now.continuous += 1_000
        XCTAssertFalse(publisher.observe { self.source() })
        XCTAssertEqual(old, files[VerifiedObservationPublisher.fileName])
        let status = try JSONDecoder().decode(VerifiedObservationPublisher.Status.self,
            from: XCTUnwrap(files[VerifiedObservationPublisher.statusName]))
        XCTAssertFalse(status.available); XCTAssertEqual(status.failureCode, "clock_discontinuity")
    }
    func testFailedErrorStatusStaysBlockedUntilRetriedAndThenRevalidated() throws {
        var now: Int64 = 600_000
        var files: [String: Data] = [:], failures: [String] = []
        var rejectStatus = false, validations = 0
        let publisher = VerifiedObservationPublisher(reportKind: "google_drive", build: "86", processRunID: UUID(),
            clock: { (now, now) }, writer: { bytes, name in
                if rejectStatus && name == VerifiedObservationPublisher.statusName { throw POSIXError(.EACCES) }
                files[name] = bytes
            }, failureSink: { failures.append($0) })
        XCTAssertTrue(publisher.observe { self.source() })
        let old = files[VerifiedObservationPublisher.fileName]
        now += 30_000
        XCTAssertFalse(publisher.observe {
            validations += 1; rejectStatus = true
            throw VerifiedObservationPublisher.Failure.invalidSource
        })
        XCTAssertEqual(failures, ["failure_status_write_failed", "validation_or_write_failed"])
        XCTAssertEqual(old, files[VerifiedObservationPublisher.fileName])
        now += 30_000
        XCTAssertFalse(publisher.observe { validations += 1; return self.source() })
        XCTAssertEqual(validations, 1, "Failed invalidation must block fresh validation even after the throttle expires")
        XCTAssertEqual(failures.last, "failure_status_write_failed")
        rejectStatus = false
        XCTAssertTrue(publisher.observe { validations += 1; return self.source() })
        XCTAssertEqual(validations, 2)
        let status = try JSONDecoder().decode(VerifiedObservationPublisher.Status.self,
            from: XCTUnwrap(files[VerifiedObservationPublisher.statusName]))
        XCTAssertTrue(status.available); XCTAssertEqual(status.sequence, 3)
    }
    func testValidationCannotAttestFutureTimestampOrUnsafeMetadataPath() {
        for candidate in [VerifiedObservationSource(sourceGeneratedAtMS: 700_000, identity: ["id": "frozen"], files: source().files),
                          VerifiedObservationSource(sourceGeneratedAtMS: 1_000, identity: ["id": "frozen"],
                            files: [.init(name: "../audio.m4a", bytes: Data([1]))])] {
            var wroteReceipt = false
            let publisher = VerifiedObservationPublisher(reportKind: "google_drive", build: "86", processRunID: UUID(),
                clock: { (600_000, 600_000) }, writer: { _, name in wroteReceipt = name == VerifiedObservationPublisher.fileName || wroteReceipt },
                failureSink: { _ in })
            XCTAssertFalse(publisher.observe { candidate }); XCTAssertFalse(wroteReceipt)
        }
    }
}
