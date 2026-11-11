import Foundation

/// Delivery by WatchConnectivity is not a durable receipt from the phone.
/// Keep this state across launches, and clear it only after a validated receipt
/// or when the corresponding manifest is no longer pending in the repository.
public struct FileTransferRetryPolicy: Codable, Equatable, Sendable {
    /// The system may remove a task before dispatching its completion callback.
    /// Apply this only once per attempt, even across process restarts.
    public static let disappearanceGrace: TimeInterval = 60

    private enum Phase: String, Codable, Sendable {
        case enqueued
        case waitingForAcknowledgement
        case failed

        var maximumDelay: TimeInterval {
            switch self {
            case .waitingForAcknowledgement: return 30 * 60
            case .enqueued, .failed: return 5 * 60
            }
        }
    }

    private struct Attempt: Codable, Equatable, Sendable {
        let manifest: SegmentManifest
        var deliveries: Int = 0
        var failures: Int = 0
        var phase: Phase
        var retryAt: Date
        var attemptID: String?
        var attemptEnqueuedAt: Date?
        var disappearanceRetryAt: Date?
        var unclassifiedCompletionRetryAt: Date?
    }

    // An array keeps the encoded format independent of JSON's UUID key handling.
    // Full manifest equality prevents a reused ID from inheriting another file's
    // delivery history or cooldown.
    private var attempts: [Attempt] = []
    private var lastUpdatedAt: Date?

    public init() {}

    @discardableResult
    public mutating func recordDelivery(of manifest: SegmentManifest, attemptID: String? = nil,
                                       enqueuedAt: Date? = nil, at now: Date = Date()) -> Bool {
        guard acceptsCallback(for: manifest, attemptID: attemptID) else { return false }
        normalizeClock(at: now)
        var attempt = existingAttempt(for: manifest)
            ?? Attempt(manifest: manifest, phase: .waitingForAcknowledgement, retryAt: now)
        attempt.deliveries = Self.increment(attempt.deliveries)
        attempt.attemptID = attemptID
        if attempt.attemptEnqueuedAt == nil { attempt.attemptEnqueuedAt = enqueuedAt }
        attempt.failures = 0
        attempt.phase = .waitingForAcknowledgement
        attempt.retryAt = now.addingTimeInterval(Self.delay(base: 5 * 60, maximum: 30 * 60,
                                                         count: attempt.deliveries))
        replace(attempt, at: now)
        return true
    }

    @discardableResult
    public mutating func recordFailure(of manifest: SegmentManifest, attemptID: String? = nil,
                                      enqueuedAt: Date? = nil, at now: Date = Date()) -> Bool {
        guard acceptsCallback(for: manifest, attemptID: attemptID) else { return false }
        normalizeClock(at: now)
        var attempt = existingAttempt(for: manifest)
            ?? Attempt(manifest: manifest, phase: .failed, retryAt: now)
        attempt.failures = Self.increment(attempt.failures)
        attempt.attemptID = attemptID
        if attempt.attemptEnqueuedAt == nil { attempt.attemptEnqueuedAt = enqueuedAt }
        let failureRetryAt = now.addingTimeInterval(Self.delay(base: 30, maximum: 5 * 60,
                                                              count: attempt.failures))
        if attempt.phase == .waitingForAcknowledgement, attempt.retryAt > now {
            // An obsolete duplicate can fail after another copy was delivered.
            // That failure must not shorten the wait for the durable receipt.
            attempt.retryAt = max(attempt.retryAt, failureRetryAt)
        } else {
            attempt.phase = .failed
            attempt.retryAt = failureRetryAt
        }
        replace(attempt, at: now)
        return true
    }

    /// Optional cancellation observations may be temporarily unreadable. An
    /// error callback then cannot safely distinguish a transport failure from
    /// a delayed cancellation. Keep its exact attempt and existing ACK backoff,
    /// and wait conservatively without inventing delivery, failure, or a receipt.
    @discardableResult
    public mutating func deferUnclassifiedCompletion(of manifest: SegmentManifest, attemptID: String? = nil,
                                                     enqueuedAt: Date? = nil, at now: Date = Date()) -> Bool {
        guard acceptsCallback(for: manifest, attemptID: attemptID) else { return false }
        normalizeClock(at: now)
        var attempt = existingAttempt(for: manifest)
            ?? Attempt(manifest: manifest, phase: .enqueued, retryAt: now)
        if attempt.attemptID == nil { attempt.attemptID = attemptID }
        if attempt.attemptEnqueuedAt == nil { attempt.attemptEnqueuedAt = enqueuedAt }
        // Native callbacks may be repeated or replayed after a restart. Only
        // the first unclassified completion of this exact attempt starts wait.
        let deadline = attempt.unclassifiedCompletionRetryAt ?? now.addingTimeInterval(5 * 60)
        attempt.unclassifiedCompletionRetryAt = deadline
        attempt.retryAt = max(attempt.retryAt, deadline)
        replace(attempt, at: now)
        return true
    }

    /// Optional bookkeeping when the owner enqueues a transfer. The system's
    /// outstanding queue must still exclude the ID from eligibility checks.
    /// If that task disappears without a callback, this bounded deadline allows
    /// recovery while retaining the previous delivery/failure attempt counts.
    public mutating func noteEnqueued(_ manifest: SegmentManifest, attemptID: String? = nil,
                                     at now: Date = Date()) {
        normalizeClock(at: now)
        var attempt = existingAttempt(for: manifest)
            ?? Attempt(manifest: manifest, phase: .enqueued, retryAt: now)
        attempt.phase = .enqueued
        attempt.retryAt = now.addingTimeInterval(5 * 60)
        attempt.attemptID = attemptID
        attempt.attemptEnqueuedAt = now
        attempt.disappearanceRetryAt = nil
        attempt.unclassifiedCompletionRetryAt = nil
        replace(attempt, at: now)
    }

    /// Bind pre-upgrade state to the newest actual system task. The owner must
    /// select that task deterministically when duplicate IDs are outstanding.
    /// Existing deadlines stay unchanged. A provably newer enqueue also repairs
    /// a crash between handing a task to the system and saving its identity.
    /// Missing or reversed wall-clock evidence cannot prove a newer attempt;
    /// retain the known identity and use receipts or bounded retries to recover.
    public mutating func adoptOutstanding(_ manifest: SegmentManifest, attemptID: String?,
                                         enqueuedAt: Date?, at now: Date = Date()) {
        normalizeClock(at: now)
        guard let attemptID else { return }
        guard var attempt = existingAttempt(for: manifest) else {
            let enqueued = min(enqueuedAt ?? now, now)
            replace(Attempt(manifest: manifest, phase: .enqueued,
                            retryAt: enqueued.addingTimeInterval(5 * 60),
                            attemptID: attemptID, attemptEnqueuedAt: enqueuedAt), at: now)
            return
        }
        if let currentID = attempt.attemptID {
            if currentID == attemptID {
                guard attempt.attemptEnqueuedAt == nil, let enqueuedAt else { return }
                attempt.attemptEnqueuedAt = enqueuedAt
            } else {
                guard let enqueuedAt, let previous = attempt.attemptEnqueuedAt,
                      enqueuedAt > previous else { return }
                attempt.attemptID = attemptID
                attempt.attemptEnqueuedAt = enqueuedAt
                attempt.phase = .enqueued
                attempt.disappearanceRetryAt = nil
                attempt.unclassifiedCompletionRetryAt = nil
            }
        } else {
            attempt.attemptID = attemptID
            attempt.attemptEnqueuedAt = enqueuedAt
        }
        replace(attempt, at: now)
    }

    /// Observe after reading the real outstanding queue and before eligibility.
    /// A reappearing task does not reset this marker; only a new enqueue does.
    @discardableResult
    public mutating func recordDisappearedTransfers(outstandingIDs: Set<UUID>,
                                                    at now: Date = Date()) -> [UUID] {
        normalizeClock(at: now)
        var disappeared: [UUID] = []
        for index in attempts.indices where attempts[index].phase == .enqueued
            && !outstandingIDs.contains(attempts[index].manifest.id)
            && attempts[index].disappearanceRetryAt == nil {
            let deadline = now.addingTimeInterval(Self.disappearanceGrace)
            attempts[index].disappearanceRetryAt = deadline
            attempts[index].retryAt = max(attempts[index].retryAt, deadline)
            disappeared.append(attempts[index].manifest.id)
        }
        if !disappeared.isEmpty { lastUpdatedAt = now }
        return disappeared
    }

    private func acceptsCallback(for manifest: SegmentManifest, attemptID: String?) -> Bool {
        guard let currentID = existingAttempt(for: manifest)?.attemptID else { return true }
        return currentID == attemptID
    }

    /// Call only after the repository has validated and persisted the receipt.
    /// This policy never deletes or acknowledges audio itself.
    public mutating func acknowledge(id: UUID) {
        attempts.removeAll { $0.manifest.id == id }
        if attempts.isEmpty { lastUpdatedAt = nil }
    }

    public mutating func retainPending(manifests: [SegmentManifest]) {
        let pendingByID = Dictionary(grouping: manifests, by: \.id)
        attempts.removeAll { attempt in
            !(pendingByID[attempt.manifest.id]?.contains(attempt.manifest) ?? false)
        }
        if attempts.isEmpty { lastUpdatedAt = nil }
    }

    public mutating func isEligible(_ manifest: SegmentManifest, at now: Date = Date()) -> Bool {
        normalizeClock(at: now)
        return existingAttempt(for: manifest).map { $0.retryAt <= now } ?? true
    }

    /// Call after attempting to fill available queue slots. Already eligible
    /// files must not return an elapsed deadline and create a busy retry timer.
    /// Completion callbacks or a later sync handle those files when a slot opens.
    public mutating func nextRetryDate(pending: [SegmentManifest], excludingIDs: Set<UUID> = [],
                                       at now: Date = Date()) -> Date? {
        normalizeClock(at: now)
        return pending.compactMap { manifest -> Date? in
            guard !excludingIDs.contains(manifest.id),
                  let attempt = existingAttempt(for: manifest), attempt.retryAt > now else { return nil }
            return attempt.retryAt
        }.min()
    }

    private func existingAttempt(for manifest: SegmentManifest) -> Attempt? {
        attempts.first { $0.manifest == manifest }
    }

    private mutating func replace(_ attempt: Attempt, at now: Date) {
        if let index = attempts.firstIndex(where: { $0.manifest.id == attempt.manifest.id }) {
            attempts[index] = attempt
        } else {
            attempts.append(attempt)
        }
        lastUpdatedAt = now
    }

    private mutating func normalizeClock(at now: Date) {
        guard let previous = lastUpdatedAt, now < previous else { return }
        // Wall-clock changes must not impose hours or days of accidental delay.
        // Re-anchor once, preserving only the bounded remaining wait; subsequent
        // queries leave the deadline unchanged instead of sliding it forward.
        for index in attempts.indices {
            let remaining = min(attempts[index].phase.maximumDelay,
                                max(0, attempts[index].retryAt.timeIntervalSince(previous)))
            attempts[index].retryAt = now.addingTimeInterval(remaining)
            if let deadline = attempts[index].disappearanceRetryAt {
                let graceRemaining = min(Self.disappearanceGrace,
                                         max(0, deadline.timeIntervalSince(previous)))
                attempts[index].disappearanceRetryAt = now.addingTimeInterval(graceRemaining)
            }
            if let deadline = attempts[index].unclassifiedCompletionRetryAt {
                let remaining = min(5 * 60, max(0, deadline.timeIntervalSince(previous)))
                attempts[index].unclassifiedCompletionRetryAt = now.addingTimeInterval(remaining)
            }
        }
        lastUpdatedAt = now
    }

    private static func increment(_ value: Int) -> Int {
        min(max(0, value), 30) + 1
    }

    private static func delay(base: TimeInterval, maximum: TimeInterval, count: Int) -> TimeInterval {
        min(maximum, base * pow(2, Double(min(max(1, count) - 1, 16))))
    }
}
