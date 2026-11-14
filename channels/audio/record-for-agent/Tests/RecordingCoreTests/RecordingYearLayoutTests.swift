import XCTest
@testable import RecordingCore

final class RecordingYearLayoutTests: XCTestCase {
    func testLeapYearAndDSTUseCalendarDays() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let leap = RecordingYearLayout(year: 2024, calendar: calendar).dates
        XCTAssertEqual(leap.count, 366)
        XCTAssertEqual(Set(leap).count, 366)
        XCTAssertEqual(calendar.component(.month, from: leap.last!), 12)
        XCTAssertEqual(calendar.component(.day, from: leap.last!), 31)
        XCTAssertEqual(RecordingYearLayout(year: 2026, calendar: calendar).dates.count, 365)
        XCTAssertTrue(leap.allSatisfy { calendar.startOfDay(for: $0) == $0 })
    }
    func testArchiveNeedsAllFourProofsAndReceivedAudio() {
        for mask in 0..<32 {
            let hasAudio = mask & 1 != 0
            let closed = mask & 2 != 0
            let received = mask & 4 != 0
            let cloud = mask & 8 != 0
            let discoverable = mask & 16 != 0
            let mark = RecordingDayMark.resolve(isFuture: false, hasReceivedAudio: hasAudio,
                watchRangeClosed: closed, allExpectedSegmentsReceived: received,
                cloudConfirmed: cloud, agentDiscoverable: discoverable)
            XCTAssertEqual(mark, !hasAudio ? .notReceived : mask == 31 ? .archived : .pending)
        }
        XCTAssertEqual(RecordingDayMark.resolve(isFuture: false, hasReceivedAudio: true), .pending)
        XCTAssertEqual(RecordingDayMark.resolve(isFuture: true, hasReceivedAudio: false), .future)
    }
}
