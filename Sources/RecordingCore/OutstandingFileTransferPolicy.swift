import Foundation

/// Bounded, persisted observations of individual native transfer attempts.
/// A candidate only authorizes an exact receipt query. The owner must still
/// wait for that query, verify the source and maintenance eligibility, and keep
/// a cancelled native task occupying its slot until the system removes it.
public struct OutstandingFileTransferPolicy: Codable, Equatable, Sendable {
    public static let minimumIdle: TimeInterval = 10 * 60
    public static let maximumObservationCount = 64
    /// Kept for callers reporting the policy: enqueue age grants no credit.
    public static let minimumAge: TimeInterval = 0

    private struct Observation: Codable, Equatable, Sendable {
        var lastProgressUptime: TimeInterval
        var lastObservedUptime: TimeInterval
        var lastObservedAt: Date
        var continuityID: String?
        var completed: Int64
        var total: Int64
        var isTransferring: Bool
        var receiptRequestedUptime: TimeInterval?
        var cancellationRequested = false
    }

    public private(set) var idleThreshold: TimeInterval
    private let observationLimit: Int
    private var observations: [String: Observation] = [:]
    // These are runtime bookkeeping, never evidence carried over from a launch.
    private var restoredKeys: Set<String> = []
    private var reanchorRequired: Set<String> = []
    private var outstandingKeys: Set<String> = []
    private var cancellationsThisProcess: Set<String> = []

    public var observationCount: Int { observations.count }

    public init(minimumIdle: TimeInterval = Self.minimumIdle,
                maximumObservationCount: Int = Self.maximumObservationCount) {
        idleThreshold = minimumIdle.isFinite && minimumIdle > 0 ? minimumIdle : Self.minimumIdle
        observationLimit = min(Self.maximumObservationCount, max(1, maximumObservationCount))
    }

    /// A restored test or future policy configuration starts fresh evidence when
    /// its threshold changes; a shorter threshold cannot reuse an old request.
    public mutating func reconfigure(minimumIdle: TimeInterval) {
        let threshold = minimumIdle.isFinite && minimumIdle > 0 ? minimumIdle : Self.minimumIdle
        guard threshold != idleThreshold else { return }
        idleThreshold = threshold
        for key in observations.keys {
            guard var item = observations[key] else { continue }
            item.lastProgressUptime = item.lastObservedUptime
            item.receiptRequestedUptime = nil
            item.continuityID = nil
            observations[key] = item
        }
        reanchorRequired.formUnion(observations.keys)
    }

    /// `key` must bind the native attempt and its complete source identity.
    /// A stable boot identity allows persisted monotonic observations to survive
    /// a process restart. Without one, the first restored observation starts a
    /// new idle window. Enqueue age never substitutes for observed no-progress.
    public mutating func observe(key: String, enqueuedAt: Date?, completed: Int64,
                                 total: Int64, isTransferring: Bool,
                                 now: Date, uptime: TimeInterval,
                                 continuityID: String? = nil) -> Bool {
        guard !key.isEmpty, key.utf8.count <= 1_024 else { return false }
        guard uptime.isFinite, uptime >= 0, now.timeIntervalSince1970.isFinite else {
            if var item = observations[key] {
                item.lastProgressUptime = item.lastObservedUptime
                item.receiptRequestedUptime = nil
                item.continuityID = nil
                observations[key] = item
                reanchorRequired.insert(key)
            }
            return false
        }
        // TransportCodec persists Date at rounded millisecond precision. Use
        // that same precision before comparing so decoding cannot manufacture
        // a sub-millisecond wall-clock rollback on a same-boot restart.
        let observedAt = Self.canonicalWallDate(now)
        if observations[key] == nil {
            guard makeRoom() else { return false }
            observations[key] = Observation(lastProgressUptime: uptime, lastObservedUptime: uptime,
                                            lastObservedAt: observedAt, continuityID: continuityID,
                                            completed: completed, total: total,
                                            isTransferring: isTransferring)
        }
        outstandingKeys.insert(key)
        guard var item = observations[key] else { return false }
        let wasRestored = restoredKeys.remove(key) != nil
        let mustReanchor = reanchorRequired.remove(key) != nil
        let restoredWithoutContinuity = wasRestored
            && (continuityID == nil || item.continuityID != continuityID)
        let discontinuity = uptime < item.lastObservedUptime || observedAt < Self.canonicalWallDate(item.lastObservedAt)
            || item.continuityID != continuityID || restoredWithoutContinuity
            || mustReanchor
        let changed = item.completed != completed || item.total != total
            || item.isTransferring != isTransferring
        if wasRestored && item.cancellationRequested {
            // A crash may occur after persisting cancellation intent but before
            // invoking native cancel. If it remains outstanding, a new exact
            // receipt query and source verification may safely retry cancel.
            item.receiptRequestedUptime = nil
        }
        if discontinuity || changed {
            // Progress resets, starts and pauses are activity. Clock changes or
            // an unproven boot cannot make an old receipt request reusable.
            item.lastProgressUptime = uptime
            item.receiptRequestedUptime = nil
        }
        item.completed = completed
        item.total = total
        item.isTransferring = isTransferring
        item.lastObservedUptime = uptime
        item.lastObservedAt = observedAt
        item.continuityID = continuityID
        observations[key] = item
        return isCandidate(item, key: key)
    }

    /// Call only after an exact request was sent or an identical native request
    /// is known to be queued. Repeated observations do not slide this deadline.
    public mutating func markReceiptRequested(key: String, uptime: TimeInterval) {
        guard uptime.isFinite, let item = observations[key], isCandidate(item, key: key),
              uptime >= item.lastObservedUptime, item.receiptRequestedUptime == nil else { return }
        observations[key]?.receiptRequestedUptime = uptime
    }

    /// Withdrawal/failure of the exact query invalidates only its grace, not
    /// the independent observation of native progress.
    public mutating func invalidateReceiptRequest(key: String) {
        observations[key]?.receiptRequestedUptime = nil
    }

    /// Native query objects and message callbacks cannot be restored from this
    /// ledger. A bridge restart must establish new live query evidence first.
    public mutating func invalidateReceiptRequests() {
        for key in observations.keys { observations[key]?.receiptRequestedUptime = nil }
    }

    /// The most recent observation must itself cover the receipt grace period;
    /// passing a later clock value alone cannot manufacture another observation.
    public func canRecover(key: String, uptime: TimeInterval, receiptGrace: TimeInterval = 60) -> Bool {
        guard uptime.isFinite, receiptGrace.isFinite, receiptGrace >= 0,
              let item = observations[key], isCandidate(item, key: key),
              let requested = item.receiptRequestedUptime,
              uptime >= item.lastObservedUptime, item.lastObservedUptime >= requested,
              item.lastObservedUptime - requested >= receiptGrace else { return false }
        return !restoredKeys.contains(key) && !reanchorRequired.contains(key)
    }

    public mutating func markCancellationRequested(key: String) {
        guard observations[key] != nil else { return }
        observations[key]?.cancellationRequested = true
        cancellationsThisProcess.insert(key)
    }

    public func cancellationRequested(key: String) -> Bool {
        observations[key]?.cancellationRequested == true
    }

    /// Failed source verification starts a new bounded observation window; it
    /// never acknowledges the source or repeatedly scans it on every callback.
    public mutating func deferRecovery(key: String, uptime: TimeInterval) {
        guard uptime.isFinite, uptime >= 0, var item = observations[key] else { return }
        item.lastProgressUptime = max(uptime, item.lastObservedUptime)
        item.receiptRequestedUptime = nil
        if uptime < item.lastObservedUptime {
            item.continuityID = nil
            reanchorRequired.insert(key)
        } else {
            // This is a new start of observation, not progress evidence. Keep
            // the stored monotonic timestamps ordered even when source checking
            // consumed time since the previous progress sample.
            item.lastObservedAt = Self.canonicalWallDate(
                item.lastObservedAt.addingTimeInterval(uptime - item.lastObservedUptime))
            item.lastObservedUptime = uptime
        }
        observations[key] = item
    }

    public mutating func retainOutstanding(keys: Set<String>) {
        outstandingKeys = keys
        // Keep bounded cancellation tombstones to reject delayed callbacks after
        // a restart. Only tombstones no longer outstanding may yield capacity.
        observations = observations.filter { keys.contains($0.key) || $0.value.cancellationRequested }
        restoredKeys.formIntersection(observations.keys)
        reanchorRequired.formIntersection(observations.keys)
        cancellationsThisProcess.formIntersection(observations.keys)
    }

    private func isCandidate(_ item: Observation, key: String) -> Bool {
        guard !cancellationsThisProcess.contains(key), item.completed >= 0, item.total >= 0,
              !(item.total > 0 && item.completed >= item.total) else { return false }
        return item.lastObservedUptime - item.lastProgressUptime >= idleThreshold
    }

    private static func canonicalWallDate(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded() / 1_000)
    }

    private mutating func makeRoom() -> Bool {
        guard observations.count >= observationLimit else { return true }
        let expiredTombstone = observations.filter {
            $0.value.cancellationRequested && !outstandingKeys.contains($0.key)
        }.min {
            if $0.value.lastObservedUptime != $1.value.lastObservedUptime {
                return $0.value.lastObservedUptime < $1.value.lastObservedUptime
            }
            return $0.key < $1.key
        }?.key
        guard let expiredTombstone else { return false }
        observations.removeValue(forKey: expiredTombstone)
        restoredKeys.remove(expiredTombstone)
        reanchorRequired.remove(expiredTombstone)
        cancellationsThisProcess.remove(expiredTombstone)
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, idleThreshold, observationLimit, observations
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .schemaVersion)
        guard version == 1 else {
            throw DecodingError.dataCorruptedError(forKey: .schemaVersion, in: values,
                                                   debugDescription: "Unsupported observation schema")
        }
        let threshold = try values.decode(TimeInterval.self, forKey: .idleThreshold)
        let limit = try values.decode(Int.self, forKey: .observationLimit)
        let saved = try values.decode([String: Observation].self, forKey: .observations)
        guard threshold.isFinite, threshold > 0, (1...Self.maximumObservationCount).contains(limit),
              saved.count <= limit,
              saved.allSatisfy({ key, item in
                  !key.isEmpty && key.utf8.count <= 1_024
                    && item.lastProgressUptime.isFinite && item.lastProgressUptime >= 0
                    && item.lastObservedUptime.isFinite && item.lastObservedUptime >= 0
                    && item.lastProgressUptime <= item.lastObservedUptime
                    && item.lastObservedAt.timeIntervalSince1970.isFinite
                    && (item.receiptRequestedUptime.map {
                        $0.isFinite && $0 >= item.lastProgressUptime
                    } ?? true)
              }) else {
            throw DecodingError.dataCorruptedError(forKey: .observations, in: values,
                                                   debugDescription: "Invalid bounded observations")
        }
        idleThreshold = threshold
        observationLimit = limit
        observations = saved
        restoredKeys = Set(saved.keys)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(1, forKey: .schemaVersion)
        try values.encode(idleThreshold, forKey: .idleThreshold)
        try values.encode(observationLimit, forKey: .observationLimit)
        try values.encode(observations, forKey: .observations)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.idleThreshold == rhs.idleThreshold && lhs.observationLimit == rhs.observationLimit
            && lhs.observations == rhs.observations
    }
}
