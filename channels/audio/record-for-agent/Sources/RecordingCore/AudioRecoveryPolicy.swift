import Foundation

/// A synchronous recovery budget. The owner schedules delays and serializes access
/// (for example, on MainActor); this policy never starts audio or creates a task.
public struct AudioRecoveryPolicy: Sendable {
    public enum Origin: Sendable {
        case manual
        case automaticRecovery
    }

    /// Permission for one activation attempt. Only this policy can issue tokens.
    public struct Attempt: Equatable, Sendable {
        fileprivate let generation: UUID
        fileprivate let sequence: Int
    }

    /// Permission to retry once after `delay`, provided it has not been cancelled.
    public struct RetryPermit: Equatable, Sendable {
        public let delay: TimeInterval
        fileprivate let generation: UUID
        fileprivate let sequence: Int
    }

    public enum FailureDecision: Equatable, Sendable {
        case ignored
        case stop
        case retry(RetryPermit)
    }

    private enum Phase: Sendable {
        case idle
        case attempting(Attempt)
        case waiting(RetryPermit)
    }

    private static let retryDelays: [TimeInterval] = [1, 3, 6]
    private var origin: Origin?
    private var phase: Phase = .idle

    /// Retries issued in this cycle. Exhaustion retains the count for diagnostics;
    /// beginning a new cycle, cancelling, or succeeding resets it to zero.
    public private(set) var retryCount = 0
    public var isActive: Bool { origin != nil }

    public init() {}

    /// Explicit manual starts supersede any older work. Repeated automatic
    /// notifications cannot replace an active attempt or reset its retry budget.
    @discardableResult
    public mutating func begin(_ origin: Origin) -> Attempt? {
        if case .automaticRecovery = origin, isActive { return nil }
        cancel()
        self.origin = origin
        let attempt = Attempt(generation: UUID(), sequence: 0)
        phase = .attempting(attempt)
        return attempt
    }

    public func isCurrent(_ attempt: Attempt) -> Bool {
        guard case .attempting(let current) = phase else { return false }
        return current == attempt
    }

    /// Consumes a failure at most once. The initial automatic attempt can grant
    /// three additional attempts, delayed by 1, 3, and 6 seconds respectively.
    public mutating func failed(_ attempt: Attempt) -> FailureDecision {
        guard isCurrent(attempt) else { return .ignored }
        guard case .automaticRecovery? = origin,
              retryCount < Self.retryDelays.count else {
            finishCycle(resetRetryCount: false)
            return .stop
        }
        let permit = RetryPermit(delay: Self.retryDelays[retryCount],
                                 generation: attempt.generation,
                                 sequence: attempt.sequence + 1)
        retryCount += 1
        phase = .waiting(permit)
        return .retry(permit)
    }

    /// Call after the owner's delay and cancellation checks. A permit cannot be
    /// used twice, after cancellation, or during a newer attempt or recovery cycle.
    public mutating func consume(_ permit: RetryPermit) -> Attempt? {
        guard case .automaticRecovery? = origin,
              case .waiting(let current) = phase,
              current == permit else { return nil }
        let attempt = Attempt(generation: permit.generation, sequence: permit.sequence)
        phase = .attempting(attempt)
        return attempt
    }

    /// The owner should report success only after receiving actual new audio.
    /// Stale success callbacks cannot clear a newer recovery budget.
    @discardableResult
    public mutating func succeeded(_ attempt: Attempt) -> Bool {
        guard isCurrent(attempt) else { return false }
        finishCycle(resetRetryCount: true)
        return true
    }

    /// Invalidates both an in-flight attempt and a scheduled retry. Use for user
    /// pause/end, a new system interruption, or another operation that stops audio.
    public mutating func cancel() {
        finishCycle(resetRetryCount: true)
    }

    private mutating func finishCycle(resetRetryCount: Bool) {
        origin = nil
        phase = .idle
        if resetRetryCount { retryCount = 0 }
    }
}
