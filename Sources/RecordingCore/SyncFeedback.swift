import Foundation

/// Presentation evidence only. This type never acknowledges or deletes audio.
/// Counts from a repository observation must not be used to infer a new receipt:
/// recording can add a segment at the same time that another is acknowledged.
public struct SyncFeedback: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle, requested, waitingForConnection, queued, transferring
        case waitingForConfirmation, retryScheduled, completed, failed
    }

    public private(set) var phase: Phase = .idle
    public private(set) var pendingCount: Int?
    public private(set) var queuedCount = 0
    public private(set) var transferringCount = 0
    public private(set) var awaitingConfirmationCount = 0
    public private(set) var confirmedCount = 0
    public private(set) var lastConfirmedAt: Date?
    public private(set) var retryAt: Date?
    public private(set) var message: String?
    public private(set) var observedAt: Date?
    public private(set) var lastRequestedAt: Date?
    private var confirmedIDs = Set<UUID>()

    public init() {}

    /// Throttle only the request gesture, never the transfer or its retry deadline.
    /// A backwards wall-clock correction must not lock the button indefinitely.
    @discardableResult
    public mutating func beginRequest(at now: Date = Date()) -> Bool {
        if let previous = lastRequestedAt {
            let elapsed = now.timeIntervalSince(previous)
            if elapsed >= 0 && elapsed < 1.5 { return false }
        }
        lastRequestedAt = now
        phase = .requested
        message = nil
        return true
    }

    /// The caller must first validate AND durably persist this exact receipt.
    /// Duplicate delivery of the same receipt must not create progress or haptics.
    public mutating func recordVerifiedReceipt(id: UUID, at now: Date = Date()) {
        guard confirmedIDs.insert(id).inserted else { return }
        confirmedCount = confirmedIDs.count
        lastConfirmedAt = now
    }

    /// `allReceiptsVerified` is required even for an empty pending list. The
    /// caller must freshly inspect the repository and verify its stored receipts;
    /// enqueue, WC delivery, reachability and message replies do not satisfy it.
    public mutating func observe(pendingCount: Int, queuedCount: Int, transferringCount: Int,
                                awaitingConfirmationCount: Int = 0,
                                connectionReady: Bool, reachable: Bool,
                                hasSealedSegments: Bool, allReceiptsVerified: Bool = false,
                                retryAt: Date? = nil, failure: String? = nil,
                                at now: Date = Date()) {
        self.pendingCount = max(0, pendingCount)
        self.queuedCount = max(0, queuedCount)
        self.transferringCount = min(max(0, transferringCount), self.queuedCount)
        self.awaitingConfirmationCount = max(0, awaitingConfirmationCount)
        self.retryAt = retryAt
        observedAt = now
        message = failure
        if failure != nil {
            phase = .failed
        } else if pendingCount == 0 {
            if !hasSealedSegments { phase = .idle }
            else { phase = allReceiptsVerified ? .completed : .waitingForConfirmation }
        } else if !connectionReady {
            phase = .waitingForConnection
        } else if self.transferringCount > 0 {
            phase = .transferring
        } else if self.queuedCount > 0 {
            // Background file delivery does not require isReachable. A queued
            // file is not proof that the phone is disconnected or has saved it.
            phase = .queued
        } else if self.awaitingConfirmationCount > 0 {
            phase = .waitingForConfirmation
        } else if let retryAt, retryAt > now {
            phase = .retryScheduled
        } else if !reachable {
            phase = .waitingForConnection
        } else {
            phase = .queued
        }
    }

    /// Preserve a read/validation failure when no trustworthy observation exists.
    public mutating func recordFailure(_ message: String, at now: Date = Date()) {
        phase = .failed
        self.message = message
        observedAt = now
    }
}
