import Foundation

/// Presentation of actual timer plans. These dates are scheduling intentions,
/// never proof that iOS will run a suspended process at that time.
public enum GoogleDriveRetrySchedule {
    public static func timerDate(requested: Date, at now: Date = Date()) -> Date {
        now.addingTimeInterval(max(2, min(3_600, requested.timeIntervalSince(now))))
    }

    public static func nextAttempt(at now: Date = Date(), isBusy: Bool, ordinary: Date?, recovery: Date?,
                                   library: Date?, item: Date?) -> Date? {
        func future(_ value: Date?) -> Date? {
            value.flatMap { $0.timeIntervalSince1970.isFinite && $0 > now ? $0 : nil }
        }
        // An active round has consumed its old deadline. Only a distinct,
        // retained recovery signal can already have another scheduled attempt.
        guard !isBusy else { return future(recovery) }
        let fallback = [future(library), future(item)].compactMap { $0 }.max()
        return [future(ordinary) ?? fallback, future(recovery)].compactMap { $0 }.min()
    }
}
