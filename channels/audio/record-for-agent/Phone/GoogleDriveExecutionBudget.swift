import Foundation

/// A single round has a fixed upper bound. Only a real BGProcessing parent
/// grants a longer background round; ordinary lifecycle changes never renew it.
struct GoogleDriveExecutionBudget: Sendable {
    private(set) var deadline: TimeInterval
    private(set) var isExpired = false
    private let systemGranted: Bool

    init(isForeground: Bool, systemGranted: Bool = false, now: TimeInterval, maximumDeadline: TimeInterval? = nil) {
        self.systemGranted = systemGranted
        let limit = now + (systemGranted || isForeground ? 120 : 19)
        deadline = min(limit, maximumDeadline ?? limit)
    }

    mutating func enterBackground(at now: TimeInterval) {
        guard !systemGranted else { return }
        deadline = min(deadline, now + 19)
    }

    mutating func expire() { isExpired = true }

    func remaining(at now: TimeInterval) -> TimeInterval {
        isExpired ? 0 : max(0, deadline - now)
    }

    func check(at now: TimeInterval) throws {
        guard remaining(at: now) > 0 else { throw CancellationError() }
    }

    func requestTimeout(at now: TimeInterval) throws -> TimeInterval {
        try check(at: now)
        return min(30, remaining(at: now))
    }

    /// Created only while handling an actual BGProcessing parent. Waiting for an
    /// ordinary round consumes this same fixed budget, rather than renewing it.
    struct ParentGrant: Sendable {
        enum ExistingWork { case none, ordinarySync, systemSync, identityOperation }
        let deadline: TimeInterval
        private var mayStartRound: Bool

        init(now: TimeInterval, existingWork: ExistingWork, systemGranted: Bool = true) {
            deadline = now + (systemGranted ? 120 : 19)
            mayStartRound = existingWork == .none || existingWork == .ordinarySync
        }

        mutating func takeRound(at now: TimeInterval, isCancelled: Bool) -> TimeInterval? {
            guard mayStartRound, !isCancelled, now < deadline else { return nil }
            mayStartRound = false
            return deadline
        }
    }
}
