import XCTest
@testable import RecordingCore

final class RecordingCalendarLayoutTests: XCTestCase {
    private func calendar(_ zone: String = "Asia/Shanghai") -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        return value
    }

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text.contains("T") ? text : "\(text)T00:00:00+08:00")!
    }

    // Metadata-only fixtures: no audio files are opened, created, or hashed.
    private func segment(start: String, end: String? = nil, audioSeconds: Int = 60) -> SegmentManifest {
        let id = UUID()
        let startedAt = date(start)
        return SegmentManifest(id: id, sessionID: UUID(), sequence: 0,
            startedAt: startedAt, endedAt: end.map(date) ?? startedAt.addingTimeInterval(60),
            sampleRate: 16_000, frameCount: Int64(audioSeconds) * 16_000,
            fileName: "\(id).caf", byteCount: 1_024, sha256: String(repeating: "a", count: 64))
    }

    private func assertPosition(_ layout: RecordingCalendarLayout, _ value: Date,
                                column: Int, row: Int, file: StaticString = #filePath, line: UInt = #line) {
        let position = layout.position(for: value)
        XCTAssertEqual(position?.column, column, file: file, line: line)
        XCTAssertEqual(position?.row, row, file: file, line: line)
    }

    func testNovemberFirstSundayKeepsOctoberLabelOverAnOctoberMonday() {
        let layout = RecordingCalendarLayout(now: date("2026-11-01T12:00:00+08:00"), calendar: calendar())

        XCTAssertEqual(layout.weekCount, 9)
        XCTAssertEqual(layout.startDate, date("2026-08-31"))
        XCTAssertEqual(layout.today, date("2026-11-01"))
        XCTAssertEqual(layout.endDate, date("2026-11-02"))
        assertPosition(layout, date("2026-11-01"), column: 8, row: 6)
        XCTAssertEqual(layout.monthLabels.map(\.date), [date("2026-08-01"), date("2026-09-01"), date("2026-10-01")])
        XCTAssertEqual(layout.monthLabels.map(\.column), [0, 1, 5])
        XCTAssertEqual(layout.date(column: 5, row: 0), date("2026-10-05"))
        XCTAssertEqual(layout.date(column: 8, row: 0), date("2026-10-26"))
        XCTAssertEqual(layout.trailingMonthLabel?.date, date("2026-11-01"))
        XCTAssertEqual(layout.trailingMonthLabel?.column, 8)
        let boundary = layout.monthBoundaries.first { $0.date == date("2026-11-01") }
        XCTAssertEqual(boundary?.column, 8)
        XCTAssertEqual(boundary?.row, 6)
    }

    func testSeptemberDatesInTheOctoberBoundaryWeekKeepTheirActualMonth() {
        let layout = RecordingCalendarLayout(now: date("2026-11-01"), calendar: calendar())

        for (row, value) in ["2026-09-28", "2026-09-29", "2026-09-30"].enumerated() {
            XCTAssertEqual(layout.date(column: 4, row: row), date(value))
            assertPosition(layout, date(value), column: 4, row: row)
            XCTAssertEqual(calendar().component(.month, from: layout.date(column: 4, row: row)!), 9)
        }
        let october = layout.monthBoundaries.first { $0.date == date("2026-10-01") }
        XCTAssertEqual(october?.column, 4)
        XCTAssertEqual(october?.row, 3)
        XCTAssertEqual(layout.monthLabels.first { $0.date == date("2026-10-01") }?.column, 5)
    }

    func testMidMonthShowsOnlyTheCurrentWeeksRemainingDaysAsEmpty() {
        let layout = RecordingCalendarLayout(now: date("2026-11-18T12:00:00+08:00"), calendar: calendar())

        XCTAssertEqual(layout.startDate, date("2026-09-21"))
        assertPosition(layout, date("2026-11-18"), column: 8, row: 2)
        XCTAssertEqual(layout.monthLabels.map(\.date), [date("2026-09-01"), date("2026-10-01"), date("2026-11-01")])
        XCTAssertEqual(layout.monthLabels.map(\.column), [0, 2, 6])
        XCTAssertNil(layout.trailingMonthLabel)
        for column in 0..<8 {
            for row in 0..<7 {
                XCTAssertNotNil(layout.date(column: column, row: row))
            }
        }
        for row in 0..<7 {
            XCTAssertEqual(layout.date(column: 8, row: row) == nil, row > 2)
        }
    }

    func testJanuaryFirstAcrossYearsDoesNotLabelDecemberDaysAsJanuary() {
        let layout = RecordingCalendarLayout(now: date("2027-01-01T12:00:00+08:00"), calendar: calendar())

        XCTAssertEqual(layout.startDate, date("2026-11-02"))
        XCTAssertEqual(layout.monthLabels.map(\.date), [date("2026-11-01"), date("2026-12-01")])
        XCTAssertEqual(layout.monthLabels.map(\.column), [0, 5])
        assertPosition(layout, date("2026-12-31"), column: 8, row: 3)
        assertPosition(layout, date("2027-01-01"), column: 8, row: 4)
        XCTAssertEqual(layout.trailingMonthLabel?.date, date("2027-01-01"))
        XCTAssertEqual(layout.trailingMonthLabel?.column, 8)
        XCTAssertEqual(layout.monthBoundaries.last?.date, date("2027-01-01"))
        XCTAssertEqual(layout.monthBoundaries.last?.column, 8)
        XCTAssertEqual(layout.monthBoundaries.last?.row, 4)
        XCTAssertNil(layout.date(column: 8, row: 5))
    }

    func testMondayMonthStartUsesItsOwnColumnAndLeavesAtMostSixFutureCells() {
        let layout = RecordingCalendarLayout(now: date("2027-02-01T12:00:00+08:00"), calendar: calendar())

        XCTAssertEqual(layout.startDate, date("2026-12-07"))
        XCTAssertEqual(layout.monthLabels.last?.date, date("2027-02-01"))
        XCTAssertEqual(layout.monthLabels.last?.column, 8)
        XCTAssertEqual(layout.monthBoundaries.last?.date, date("2027-02-01"))
        XCTAssertEqual(layout.monthBoundaries.last?.column, 8)
        XCTAssertEqual(layout.monthBoundaries.last?.row, 0)
        XCTAssertNil(layout.trailingMonthLabel)
        XCTAssertEqual(layout.date(column: 8, row: 0), date("2027-02-01"))
        let emptyCells = (0..<9).flatMap { column in
            (0..<7).filter { layout.date(column: column, row: $0) == nil }
                .map { (column: column, row: $0) }
        }
        XCTAssertEqual(emptyCells.count, 6)
        XCTAssertTrue(emptyCells.allSatisfy { $0.column == 8 && $0.row > 0 })
    }

    func testLeapFebruaryIncludesTheTwentyNinthBeforeMarchBoundary() {
        let leapDay = RecordingCalendarLayout(now: date("2024-02-29T12:00:00+08:00"), calendar: calendar())

        XCTAssertEqual(leapDay.startDate, date("2024-01-01"))
        XCTAssertEqual(leapDay.endDate, date("2024-03-01"))
        XCTAssertEqual(leapDay.monthLabels.map(\.date), [date("2024-01-01"), date("2024-02-01")])
        XCTAssertEqual(leapDay.monthLabels.map(\.column), [0, 5])
        XCTAssertEqual(leapDay.monthBoundaries.first?.date, date("2024-01-01"))
        XCTAssertEqual(leapDay.monthBoundaries.first?.column, 0)
        XCTAssertEqual(leapDay.monthBoundaries.first?.row, 0)
        XCTAssertEqual(leapDay.monthBoundaries.last?.column, 4)
        XCTAssertEqual(leapDay.monthBoundaries.last?.row, 3)
        assertPosition(leapDay, date("2024-02-29"), column: 8, row: 3)
        XCTAssertEqual(leapDay.date(column: 8, row: 3), date("2024-02-29"))
        XCTAssertNil(leapDay.date(column: 8, row: 4))

        let march = RecordingCalendarLayout(now: date("2024-03-01T12:00:00+08:00"), calendar: calendar())
        XCTAssertEqual(march.date(column: 8, row: 3), date("2024-02-29"))
        XCTAssertEqual(march.monthBoundaries.last?.date, date("2024-03-01"))
        XCTAssertEqual(march.monthBoundaries.last?.column, 8)
        XCTAssertEqual(march.monthBoundaries.last?.row, 4)
    }

    func testPositionUsesLocalCalendarDayAndRejectsDatesOutsideTheVisibleWindow() {
        let layout = RecordingCalendarLayout(now: date("2026-11-18T12:00:00+08:00"), calendar: calendar())

        assertPosition(layout, date("2026-09-21T23:59:59+08:00"), column: 0, row: 0)
        assertPosition(layout, date("2026-11-18T23:59:59+08:00"), column: 8, row: 2)
        XCTAssertNil(layout.position(for: date("2026-09-20T23:59:59+08:00")))
        XCTAssertNil(layout.position(for: date("2026-11-19")))
        XCTAssertNil(layout.position(for: layout.endDate))
        XCTAssertNil(layout.date(column: -1, row: 0))
        XCTAssertNil(layout.date(column: 9, row: 0))
        XCTAssertNil(layout.date(column: 0, row: -1))
        XCTAssertNil(layout.date(column: 0, row: 7))
    }

    func testMondayRowsAreIndependentOfLocaleWeekSettings() {
        for firstWeekday in [1, 2, 7] {
            var localeCalendar = calendar()
            localeCalendar.firstWeekday = firstWeekday
            localeCalendar.minimumDaysInFirstWeek = firstWeekday == 1 ? 1 : 4
            let layout = RecordingCalendarLayout(now: date("2027-01-01"), calendar: localeCalendar)

            XCTAssertEqual(layout.startDate, date("2026-11-02"))
            XCTAssertEqual(layout.date(column: 8, row: 0), date("2026-12-28"))
            assertPosition(layout, date("2027-01-01"), column: 8, row: 4)
        }
    }

    func testRequestedWeekCountKeepsTodayInTheLastColumn() {
        for weeks in [1, 9, 13] {
            let layout = RecordingCalendarLayout(now: date("2026-11-18"), weekCount: weeks, calendar: calendar())

            XCTAssertEqual(layout.weekCount, weeks)
            assertPosition(layout, date("2026-11-18"), column: weeks - 1, row: 2)
            XCTAssertEqual(layout.date(column: weeks - 1, row: 0), date("2026-11-16"))
            XCTAssertEqual(calendar().dateComponents([.day], from: layout.startDate, to: layout.today).day,
                           (weeks - 1) * 7 + 2)
            XCTAssertNil(layout.date(column: weeks, row: 0))
        }
    }

    func testDaylightSavingTransitionsRetainEveryLocalDayAndRoundTripPositions() {
        let newYork = calendar("America/New_York")
        let cases: [(today: String, tomorrow: String, hours: Double)] = [
            ("2024-03-10T05:00:00Z", "2024-03-11T04:00:00Z", 23),
            ("2024-11-03T04:00:00Z", "2024-11-04T05:00:00Z", 25)
        ]
        for value in cases {
            let layout = RecordingCalendarLayout(now: date(value.today).addingTimeInterval(12 * 3_600), calendar: newYork)

            XCTAssertEqual(layout.today, date(value.today))
            XCTAssertEqual(layout.endDate, date(value.tomorrow))
            XCTAssertEqual(layout.endDate.timeIntervalSince(layout.today), value.hours * 3_600)
            var visibleDates = Set<Date>()
            for column in 0..<9 {
                for row in 0..<7 {
                    guard let day = layout.date(column: column, row: row) else {
                        XCTFail("All 63 days must be visible on Sunday")
                        continue
                    }
                    XCTAssertEqual(day, newYork.startOfDay(for: day))
                    assertPosition(layout, day, column: column, row: row)
                    visibleDates.insert(day)
                }
            }
            XCTAssertEqual(visibleDates.count, 63)
        }
    }

    func testDecemberWindowCountExcludesOlderAndFutureDaysAndDeduplicatesManifests() {
        let layout = RecordingCalendarLayout(now: date("2026-12-01T12:00:00+08:00"), calendar: calendar())
        let beforeWindow = segment(start: "2026-10-04")
        let firstDay = segment(start: "2026-10-05")
        let middle = segment(start: "2026-11-01")
        let today = segment(start: "2026-12-01")
        let tomorrow = segment(start: "2026-12-02")
        let empty = segment(start: "2026-11-15", audioSeconds: 0)
        // Advancing the activity snapshot proves the layout's upper bound also
        // excludes future days when a caller supplies a newer activity value.
        let activity = RecordingActivity(manifests: [beforeWindow, firstDay, middle, today, tomorrow, empty, firstDay],
            calendar: calendar(), now: date("2026-12-03"))

        XCTAssertEqual(layout.startDate, date("2026-10-05"))
        XCTAssertEqual(activity.recordingDayCount, 5)
        XCTAssertEqual(activity.recordingDayCount(in: layout), 3)
        XCTAssertNil(layout.position(for: beforeWindow.startedAt))
        XCTAssertNotNil(layout.position(for: firstDay.startedAt))
        XCTAssertNotNil(layout.position(for: today.startedAt))
        XCTAssertNil(layout.position(for: tomorrow.startedAt))
    }

    func testWindowCountIncludesOnlyVisibleDaysOfCrossMidnightSegments() {
        let layout = RecordingCalendarLayout(now: date("2026-12-01T12:00:00+08:00"), calendar: calendar())
        let firstBoundary = segment(start: "2026-10-04T23:59:00+08:00",
                                    end: "2026-10-05T00:01:00+08:00")
        let lastBoundary = segment(start: "2026-12-01T23:59:00+08:00",
                                   end: "2026-12-02T00:01:00+08:00")
        let activity = RecordingActivity(manifests: [firstBoundary, firstBoundary, lastBoundary],
            calendar: calendar(), now: date("2026-12-02T12:00:00+08:00"))

        XCTAssertEqual(activity.recordingDayCount, 4)
        XCTAssertEqual(activity.recordingDayCount(in: layout), 2)
        XCTAssertEqual(activity.day(on: layout.startDate).recordedDuration, 30, accuracy: 0.001)
        XCTAssertEqual(activity.day(on: layout.today).recordedDuration, 30, accuracy: 0.001)
    }
}
