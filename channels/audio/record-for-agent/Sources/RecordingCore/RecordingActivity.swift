import Foundation

/// Calendar summaries of sealed audio already known to this device. This never
/// extends a recording using a running clock or interprets a phone ACK as an
/// Agent receipt. Pass the delivered IDs for exactly one receiver.
public struct RecordingActivity: Equatable, Sendable {
    public struct Day: Equatable, Identifiable, Sendable {
        public var id: Date { date }
        public let date: Date
        public let recordedDuration: TimeInterval
        public let receivedDuration: TimeInterval
        /// First to last known recording time within this calendar day. Gaps
        /// remain gaps; use recordedDuration for actual audio time.
        public let recordedInterval: DateInterval?
    }

    public let days: [Day]
    public let totalRecordedDuration: TimeInterval
    public let totalReceivedDuration: TimeInterval
    public let recordingDayCount: Int
    /// Consecutive recorded days ending today, or yesterday while today is empty.
    public let currentStreak: Int
    private let calendar: Calendar

    public init(manifests: [SegmentManifest], deliveredSegmentIDs: Set<UUID> = [],
                calendar: Calendar = .current, now: Date = Date()) {
        self.calendar = calendar
        var totals: [Date: (recorded: TimeInterval, received: TimeInterval)] = [:]
        var intervals: [Date: DateInterval] = [:]
        func includeInterval(on day: Date, from start: Date, to end: Date) {
            if let previous = intervals[day] {
                intervals[day] = DateInterval(start: min(previous.start, start), end: max(previous.end, end))
            } else {
                intervals[day] = DateInterval(start: start, end: end)
            }
        }
        var seen: Set<UUID> = []
        // Sealed IDs are immutable. Sorting makes duplicate handling independent
        // of a caller's listing order, including malformed conflicting copies.
        let ordered = manifests.sorted {
            if $0.id != $1.id { return $0.id.uuidString < $1.id.uuidString }
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            if $0.endedAt != $1.endedAt { return $0.endedAt < $1.endedAt }
            if $0.frameCount != $1.frameCount { return $0.frameCount < $1.frameCount }
            return $0.sampleRate < $1.sampleRate
        }
        for manifest in ordered {
            let duration = manifest.duration
            let elapsed = manifest.endedAt.timeIntervalSince(manifest.startedAt)
            guard manifest.sampleRate.isFinite, manifest.sampleRate > 0,
                  manifest.frameCount > 0, duration.isFinite, duration > 0,
                  elapsed.isFinite, elapsed >= 0,
                  manifest.startedAt < now,
                  seen.insert(manifest.id).inserted else { continue }
            if elapsed == 0 {
                let day = calendar.startOfDay(for: manifest.startedAt)
                var value = totals[day] ?? (0, 0)
                value.recorded += duration
                if deliveredSegmentIDs.contains(manifest.id) { value.received += duration }
                totals[day] = value
                includeInterval(on: day, from: manifest.startedAt, to: manifest.endedAt)
                continue
            }
            let end = min(manifest.endedAt, now)
            var cursor = manifest.startedAt
            while cursor < end {
                guard let interval = calendar.dateInterval(of: .day, for: cursor),
                      interval.end > cursor else { break }
                let boundary = min(interval.end, end)
                // Frames are the duration source. Wall time only determines how
                // that duration is apportioned when the segment spans midnight.
                let portion = duration * boundary.timeIntervalSince(cursor) / elapsed
                var value = totals[interval.start] ?? (0, 0)
                value.recorded += portion
                if deliveredSegmentIDs.contains(manifest.id) { value.received += portion }
                totals[interval.start] = value
                includeInterval(on: interval.start, from: cursor, to: boundary)
                cursor = boundary
            }
        }
        days = totals.map { Day(date: $0.key, recordedDuration: $0.value.recorded,
                                receivedDuration: $0.value.received, recordedInterval: intervals[$0.key]) }
            .sorted { $0.date < $1.date }
        totalRecordedDuration = days.reduce(0) { $0 + $1.recordedDuration }
        totalReceivedDuration = days.reduce(0) { $0 + $1.receivedDuration }
        recordingDayCount = days.count
        var cursor = calendar.startOfDay(for: now)
        if totals[cursor] == nil, let previous = calendar.date(byAdding: .day, value: -1, to: cursor) {
            cursor = previous
        }
        var streak = 0
        while totals[cursor] != nil {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor),
                  previous < cursor else { break }
            cursor = previous
        }
        currentStreak = streak
    }

    public func day(on date: Date) -> Day {
        let start = calendar.startOfDay(for: date)
        return days.first { $0.date == start }
            ?? Day(date: start, recordedDuration: 0, receivedDuration: 0, recordedInterval: nil)
    }

    /// Recorded days in the same visible window as the calendar. Normalize the
    /// boundaries with this activity's calendar, which also allocated its days.
    public func recordingDayCount(in layout: RecordingCalendarLayout) -> Int {
        let start = calendar.startOfDay(for: layout.startDate)
        let lastDay = calendar.startOfDay(for: layout.today)
        let end = calendar.date(byAdding: .day, value: 1, to: lastDay)!
        return days.filter { $0.date >= start && $0.date < end && $0.recordedDuration > 0 }.count
    }
}

/// A fixed number of Monday-first weeks ending with today's week. Dates after
/// today have no cell; all calculations use calendar days, including DST days.
public struct RecordingCalendarLayout: Equatable, Sendable {
    public static let defaultWeekCount = 9

    public struct Position: Equatable, Sendable {
        public let column: Int
        public let row: Int

        public init(column: Int, row: Int) {
            self.column = column
            self.row = row
        }
    }

    public struct MonthLabel: Equatable, Sendable {
        /// Calendar month start, even when the visible window starts mid-month.
        public let date: Date
        public let column: Int

        public init(date: Date, column: Int) {
            self.date = date
            self.column = column
        }
    }

    public struct MonthBoundary: Equatable, Sendable {
        public let date: Date
        public let column: Int
        public let row: Int

        public init(date: Date, column: Int, row: Int) {
            self.date = date
            self.column = column
            self.row = row
        }
    }

    public let weekCount: Int
    public let startDate: Date
    public let today: Date
    /// The next local midnight, excluded from the visible date range.
    public let endDate: Date
    /// The first column, followed by columns whose Monday belongs to a new month.
    public let monthLabels: [MonthLabel]
    public let monthBoundaries: [MonthBoundary]
    /// A month that has started but has no visible Monday yet belongs below its
    /// partial column, rather than above the previous month's six other days.
    public let trailingMonthLabel: MonthLabel?
    private let calendar: Calendar

    public init(now: Date, weekCount: Int = RecordingCalendarLayout.defaultWeekCount,
                calendar: Calendar = .current) {
        precondition(weekCount > 0, "The recording calendar must contain at least one week")
        self.calendar = calendar
        self.weekCount = weekCount
        let today = calendar.startOfDay(for: now)
        let weekdayOffset = (calendar.component(.weekday, from: today) + 5) % 7
        let start = calendar.date(byAdding: .day,
                                  value: -weekdayOffset - (weekCount - 1) * 7, to: today)!
        self.today = today
        startDate = start
        endDate = calendar.date(byAdding: .day, value: 1, to: today)!

        var labels: [MonthLabel] = []
        for column in 0..<weekCount {
            let monday = calendar.date(byAdding: .day, value: column * 7, to: start)!
            let month = calendar.dateInterval(of: .month, for: monday)!.start
            if labels.last?.date != month {
                labels.append(MonthLabel(date: month, column: column))
            }
        }
        monthLabels = labels

        var boundaries: [MonthBoundary] = []
        var month = calendar.dateInterval(of: .month, for: start)!.start
        if month < start {
            month = calendar.date(byAdding: .month, value: 1, to: month)!
        }
        while month <= today {
            let offset = calendar.dateComponents([.day], from: start, to: month).day!
            boundaries.append(MonthBoundary(date: month, column: offset / 7, row: offset % 7))
            month = calendar.date(byAdding: .month, value: 1, to: month)!
        }
        monthBoundaries = boundaries

        let currentMonth = calendar.dateInterval(of: .month, for: today)!.start
        if !labels.contains(where: { $0.date == currentMonth }),
           let boundary = boundaries.last, boundary.date == currentMonth {
            trailingMonthLabel = MonthLabel(date: currentMonth, column: boundary.column)
        } else {
            trailingMonthLabel = nil
        }
    }

    public func position(for date: Date) -> Position? {
        let day = calendar.startOfDay(for: date)
        guard day >= startDate, day < endDate,
              let offset = calendar.dateComponents([.day], from: startDate, to: day).day else { return nil }
        return Position(column: offset / 7, row: offset % 7)
    }

    public func date(column: Int, row: Int) -> Date? {
        guard (0..<weekCount).contains(column), (0..<7).contains(row),
              let date = calendar.date(byAdding: .day, value: column * 7 + row, to: startDate),
              date < endDate else { return nil }
        return date
    }
}
