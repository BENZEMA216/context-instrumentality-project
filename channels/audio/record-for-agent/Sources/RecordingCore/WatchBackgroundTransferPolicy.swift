import Foundation

/// Preparation limits for one real watchOS execution opportunity. External
/// power changes these limits; it never grants runtime or proves a receipt.
public struct WatchBackgroundTransferPolicy: Equatable, Sendable {
    public let isCharging: Bool
    public let sealedBacklog: Bool
    public static let refreshInterval: TimeInterval = 15 * 60
    public static let sealedBacklogRefreshInterval: TimeInterval = 60

    public init(isCharging: Bool = false, sealedBacklog: Bool = false) {
        self.isCharging = isCharging; self.sealedBacklog = sealedBacklog
    }
    public var expandedHandoff: Bool { isCharging || sealedBacklog }

    public var maximumCandidateChecks: Int { expandedHandoff ? 64 : 8 }
    public var maximumEnqueues: Int { expandedHandoff ? 12 : 3 }
    // These are system-owned queued files, not simultaneous radio transfers.
    public var maximumOutstandingFiles: Int { expandedHandoff ? 12 : 3 }

    /// Recompute from work already consumed, including after unplugging. A
    /// repeated power sample cannot replenish a task's preparation budget.
    public func remainingCandidateChecks(consumed: Int) -> Int {
        max(0, maximumCandidateChecks - max(0, consumed))
    }

    public func remainingEnqueues(consumed: Int) -> Int {
        max(0, maximumEnqueues - max(0, consumed))
    }

    /// Charging may inspect every outstanding file in one wake. A battery
    /// background wake still rotates three. Only a durable ACK may cancel.
    public func acknowledgedDuplicateInspectionCount(outstanding: Int, maintenanceAllowed: Bool) -> Int {
        guard outstanding > 0 else { return 0 }
        if maintenanceAllowed || isCharging { return outstanding }
        return min(3, outstanding)
    }

    /// A due refresh may have been ignored while the app was in the foreground.
    /// Call only on a real foreground-to-background edge, not background callbacks.
    public static func shouldRenewRefreshAfterForegroundExit(preferredDate: Date?, now: Date) -> Bool {
        guard let preferredDate, preferredDate.timeIntervalSince1970.isFinite else { return false }
        return preferredDate <= now
    }

    /// A future durable request keeps its date across callbacks and restarts.
    /// An overdue request is renewed once during an actual execution opportunity.
    public static func preferredRefreshDate(existing: Date?, confirmedDuringThisProcess: Bool = false,
                                            sealedBacklog: Bool = false,
                                            isCharging: Bool = false,
                                            now: Date) -> Date {
        // A live system request stays due until delivered; repeatedly replacing
        // an accepted overdue request could postpone its opportunity forever.
        if let existing, existing <= now, confirmedDuringThisProcess { return existing }
        // Callers have already observed pending work. Historical work on a
        // charger should not request a fifteen-minute gap between refills.
        // This requests runtime; it never grants it or changes battery budgets.
        let expedited = sealedBacklog || isCharging
        let interval = expedited ? sealedBacklogRefreshInterval : refreshInterval
        if let existing, existing > now {
            let earlier = Date(timeIntervalSince1970:
                (now.addingTimeInterval(interval).timeIntervalSince1970 * 1_000).rounded() / 1_000)
            return expedited ? min(existing, earlier) : existing
        }
        return Date(timeIntervalSince1970:
            (now.addingTimeInterval(interval).timeIntervalSince1970 * 1_000).rounded() / 1_000)
    }
}
