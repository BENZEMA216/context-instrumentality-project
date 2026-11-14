import XCTest
@testable import RecordingCore

final class RecordingActivityTests: XCTestCase {
    private func calendar(_ zone: String = "Asia/Shanghai") -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        return value
    }

    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    private func segment(id: UUID = UUID(), start: String, end: String,
                         audioSeconds: Int) -> SegmentManifest {
        SegmentManifest(id: id, sessionID: UUID(), sequence: 0,
            startedAt: date(start), endedAt: date(end), sampleRate: 16_000,
            frameCount: Int64(audioSeconds) * 16_000, fileName: "\(id).caf",
            byteCount: 1_024, sha256: String(repeating: "a", count: 64))
    }

    func testDeduplicatesIDsAndUsesOneReceiversDeliveredIDsOnly() {
        let first = segment(start: "2026-10-23T01:00:00Z", end: "2026-10-23T01:02:00Z", audioSeconds: 120)
        let second = segment(start: "2026-10-23T02:00:00Z", end: "2026-10-23T02:01:00Z", audioSeconds: 60)
        let summary = RecordingActivity(manifests: [first, second, first],
            deliveredSegmentIDs: [first.id, UUID()], calendar: calendar(), now: date("2026-10-23T03:00:00Z"))
        XCTAssertEqual(summary.totalRecordedDuration, 180, accuracy: 0.001)
        XCTAssertEqual(summary.totalReceivedDuration, 120, accuracy: 0.001)
        XCTAssertEqual(summary.day(on: first.startedAt).receivedDuration, 120, accuracy: 0.001)
        XCTAssertEqual(summary.recordingDayCount, 1)
    }

    func testSplitsActualFrameDurationAtLocalMidnightWithoutCountingPausedWallTime() {
        let audio = segment(start: "2026-10-22T15:59:00Z", end: "2026-10-22T16:01:00Z", audioSeconds: 60)
        let summary = RecordingActivity(manifests: [audio], deliveredSegmentIDs: [audio.id],
            calendar: calendar(), now: date("2026-10-23T01:00:00Z"))
        XCTAssertEqual(summary.days.count, 2)
        XCTAssertEqual(summary.day(on: date("2026-10-22T15:00:00Z")).recordedDuration, 30, accuracy: 0.001)
        XCTAssertEqual(summary.day(on: date("2026-10-22T17:00:00Z")).recordedDuration, 30, accuracy: 0.001)
        XCTAssertEqual(summary.totalRecordedDuration, 60, accuracy: 0.001)
        XCTAssertEqual(summary.totalReceivedDuration, 60, accuracy: 0.001)
        XCTAssertEqual(summary.day(on: date("2026-10-22T15:00:00Z")).recordedInterval,
            DateInterval(start: date("2026-10-22T15:59:00Z"), end: date("2026-10-22T16:00:00Z")))
        XCTAssertEqual(summary.day(on: date("2026-10-22T17:00:00Z")).recordedInterval,
            DateInterval(start: date("2026-10-22T16:00:00Z"), end: date("2026-10-22T16:01:00Z")))
    }

    func testCalendarTimezoneChangesDayAllocation() {
        let audio = segment(start: "2026-10-22T15:59:00Z", end: "2026-10-22T16:01:00Z", audioSeconds: 120)
        let summary = RecordingActivity(manifests: [audio], calendar: calendar("UTC"), now: date("2026-10-23T01:00:00Z"))
        XCTAssertEqual(summary.days.count, 1)
        XCTAssertEqual(summary.day(on: date("2026-10-22T23:00:00Z")).recordedDuration, 120, accuracy: 0.001)
        XCTAssertEqual(summary.day(on: date("2026-10-23T01:00:00Z")).recordedDuration, 0)
        XCTAssertEqual(summary.day(on: date("2026-10-22T23:00:00Z")).recordedInterval,
            DateInterval(start: audio.startedAt, end: audio.endedAt))
        XCTAssertNil(summary.day(on: date("2026-10-23T01:00:00Z")).recordedInterval)
    }

    func testDaylightSavingDayUsesCalendarBoundaries() {
        let audio = segment(start: "2024-11-03T04:00:00Z", end: "2024-11-04T05:00:00Z", audioSeconds: 90_000)
        let summary = RecordingActivity(manifests: [audio], calendar: calendar("America/New_York"),
            now: date("2024-11-04T12:00:00Z"))
        XCTAssertEqual(summary.days.count, 1)
        XCTAssertEqual(summary.totalRecordedDuration, 90_000, accuracy: 0.001)
        XCTAssertEqual(summary.days.first?.recordedInterval,
            DateInterval(start: audio.startedAt, end: audio.endedAt))
    }

    func testSelectedDayRangeDoesNotExtendToOtherDaysInTheSamePeriod() {
        let morning = segment(start: "2026-10-17T01:00:00Z", end: "2026-10-17T02:00:00Z", audioSeconds: 3_600)
        let afternoon = segment(start: "2026-10-17T06:00:00Z", end: "2026-10-17T07:00:00Z", audioSeconds: 3_600)
        let otherDay = segment(start: "2026-10-25T01:00:00Z", end: "2026-10-25T02:00:00Z", audioSeconds: 3_600)
        let summary = RecordingActivity(manifests: [otherDay, afternoon, morning], calendar: calendar(),
            now: date("2026-10-27T02:00:00Z"))
        let selected = summary.day(on: morning.startedAt)
        XCTAssertEqual(selected.recordedInterval, DateInterval(start: morning.startedAt, end: afternoon.endedAt))
        XCTAssertEqual(selected.recordedDuration, 7_200)
        // The displayed first/last range must not turn a paused gap into audio time.
        XCTAssertEqual(selected.recordedInterval?.duration, 21_600)
        XCTAssertEqual(summary.day(on: otherDay.startedAt).recordedInterval,
            DateInterval(start: otherDay.startedAt, end: otherDay.endedAt))
    }

    func testExactLocalMidnightEndDoesNotCreateAnIntervalOnTheFollowingDay() {
        let audio = segment(start: "2026-10-22T15:59:00Z", end: "2026-10-22T16:00:00Z", audioSeconds: 60)
        let summary = RecordingActivity(manifests: [audio], calendar: calendar(),
            now: date("2026-10-23T01:00:00Z"))
        XCTAssertEqual(summary.days.count, 1)
        XCTAssertEqual(summary.day(on: audio.startedAt).recordedInterval,
            DateInterval(start: audio.startedAt, end: audio.endedAt))
        XCTAssertNil(summary.day(on: audio.endedAt).recordedInterval)
    }

    func testSpringDayRangeFollowsThe23HourLocalDay() {
        let audio = segment(start: "2024-03-10T04:59:00Z", end: "2024-03-11T04:01:00Z", audioSeconds: 82_920)
        let summary = RecordingActivity(manifests: [audio], calendar: calendar("America/New_York"),
            now: date("2024-03-11T12:00:00Z"))
        let selected = summary.day(on: date("2024-03-10T16:00:00Z"))
        XCTAssertEqual(selected.recordedInterval,
            DateInterval(start: date("2024-03-10T05:00:00Z"), end: date("2024-03-11T04:00:00Z")))
        XCTAssertEqual(selected.recordedDuration, 82_800, accuracy: 0.001)
    }

    func testDayRangeStopsAtNowAndIgnoresFutureOrInvalidSegments() {
        let audio = segment(start: "2026-10-22T15:59:00Z", end: "2026-10-22T16:01:00Z", audioSeconds: 120)
        let future = segment(start: "2026-10-23T01:00:00Z", end: "2026-10-23T02:00:00Z", audioSeconds: 3_600)
        let invalid = segment(start: "2026-10-22T14:00:00Z", end: "2026-10-22T13:00:00Z", audioSeconds: 60)
        let now = date("2026-10-22T16:00:30Z")
        let summary = RecordingActivity(manifests: [audio, future, invalid], calendar: calendar(), now: now)
        XCTAssertEqual(summary.day(on: now).recordedInterval,
            DateInterval(start: date("2026-10-22T16:00:00Z"), end: now))
        XCTAssertEqual(summary.day(on: now).recordedDuration, 30, accuracy: 0.001)
        XCTAssertEqual(summary.day(on: audio.startedAt).recordedInterval,
            DateInterval(start: audio.startedAt, end: date("2026-10-22T16:00:00Z")))
    }

    func testStreakIncludesYesterdayUntilTodayHasAudioAndBreaksAcrossMissingDay() {
        let values = [20, 21, 22].map { day in
            segment(start: "2026-10-\(day)T01:00:00Z", end: "2026-10-\(day)T01:01:00Z", audioSeconds: 60)
        }
        let today = date("2026-10-23T02:00:00Z")
        XCTAssertEqual(RecordingActivity(manifests: values, calendar: calendar(), now: today).currentStreak, 3)
        XCTAssertEqual(RecordingActivity(manifests: values, calendar: calendar(), now: date("2026-10-24T02:00:00Z")).currentStreak, 0)
        let afterGap = segment(start: "2026-10-24T01:00:00Z", end: "2026-10-24T01:01:00Z", audioSeconds: 60)
        let summary = RecordingActivity(manifests: values + [afterGap], calendar: calendar(), now: date("2026-10-24T02:00:00Z"))
        XCTAssertEqual(summary.currentStreak, 1)
        XCTAssertEqual(summary.recordingDayCount, 4)
    }

    func testSealedAudioDoesNotGrowAsNowAdvancesAndFutureAudioIsNotCounted() {
        let audio = segment(start: "2026-10-23T01:00:00Z", end: "2026-10-23T01:01:00Z", audioSeconds: 45)
        let future = segment(start: "2026-10-24T01:00:00Z", end: "2026-10-24T01:01:00Z", audioSeconds: 60)
        let early = RecordingActivity(manifests: [audio, future], calendar: calendar(), now: date("2026-10-23T02:00:00Z"))
        let later = RecordingActivity(manifests: [audio, future], calendar: calendar(), now: date("2026-10-23T03:00:00Z"))
        XCTAssertEqual(early.totalRecordedDuration, 45, accuracy: 0.001)
        XCTAssertEqual(early.totalRecordedDuration, later.totalRecordedDuration)
    }

    func testValidFramesArePreservedWhenClockBoundariesAreEqual() {
        let audio = segment(start: "2026-10-23T01:00:00Z", end: "2026-10-23T01:00:00Z", audioSeconds: 2)
        let summary = RecordingActivity(manifests: [audio], deliveredSegmentIDs: [audio.id],
            calendar: calendar(), now: date("2026-10-23T02:00:00Z"))
        XCTAssertEqual(summary.totalRecordedDuration, 2)
        XCTAssertEqual(summary.totalReceivedDuration, 2)
        XCTAssertEqual(summary.recordingDayCount, 1)
        XCTAssertEqual(summary.days.first?.recordedInterval,
            DateInterval(start: audio.startedAt, end: audio.endedAt))
    }
}
