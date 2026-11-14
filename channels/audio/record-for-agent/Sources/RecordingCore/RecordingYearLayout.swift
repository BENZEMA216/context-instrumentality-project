import Foundation

/// Annual marks use the user's calendar, including leap years and DST.
public struct RecordingYearLayout: Sendable {
    public let dates: [Date]
    public init(year: Int, calendar: Calendar = .current) {
        guard let start = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let interval = calendar.dateInterval(of: .year, for: start) else { dates = []; return }
        var result: [Date] = []
        var cursor = interval.start
        while cursor < interval.end && result.count < 400 {
            result.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        dates = result
    }
}

/// No queue count, local file, computer receipt, or elapsed day can substitute
/// for these independent proofs. Unknown evidence is always false at the adapter.
public enum RecordingDayMark: String, Sendable {
    case future, notReceived, pending, archived
    public static func resolve(isFuture: Bool, hasReceivedAudio: Bool,
                               watchRangeClosed: Bool = false, allExpectedSegmentsReceived: Bool = false,
                               cloudConfirmed: Bool = false, agentDiscoverable: Bool = false) -> Self {
        if isFuture { return .future }
        guard hasReceivedAudio else { return .notReceived }
        return watchRangeClosed && allExpectedSegmentsReceived && cloudConfirmed && agentDiscoverable ? .archived : .pending
    }
}
