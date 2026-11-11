import Foundation

/// Only known invalid/missing data may be skipped. Storage and unknown failures
/// retain the request for another opportunity. Codes never contain file paths
/// or arbitrary decoder/error descriptions.
public enum ReceiptVerificationFailure: String, Sendable {
    case invalidMetadata = "invalid_metadata"
    case identityMismatch = "identity_mismatch"
    case contentMismatch = "content_mismatch"
    case missingData = "missing_data"
    case storageFailure = "storage_failure"

    public var failsMaintenance: Bool { self == .storageFailure }

    public static func classify(_ error: Error) -> Self {
        if let error = error as? RepositoryError {
            switch error {
            case .invalidManifest: return .invalidMetadata
            case .receiptMismatch, .conflictingSegment: return .identityMismatch
            case .checksumMismatch: return .contentMismatch
            case .missingAudio: return .missingData
            case .invalidStagingPath, .persistenceFailure: return .storageFailure
            }
        }
        if error is DecodingError || error is TargetedReceiptRequest.ValidationError {
            return .invalidMetadata
        }
        let value = error as NSError
        if value.domain == NSCocoaErrorDomain && value.code == CocoaError.fileReadNoSuchFile.rawValue {
            return .missingData
        }
        return .storageFailure
    }
}

/// The owner serializes access and only asks for attempts while the companion is
/// reachable. An attempt is not evidence that Watch persisted the receipt.
public struct ReceiptReplayPolicy: Sendable {
    /// Resume a bounded background sweep after its last attempted ID. Corrupt
    /// receipts still advance the cursor so they cannot starve healthy copies.
    public static func orderedIDs(_ ids: [UUID], after cursor: UUID?) -> [UUID] {
        let ordered = Array(Set(ids)).sorted { $0.uuidString < $1.uuidString }
        guard let cursor else { return ordered }
        let following = ordered.filter { $0.uuidString > cursor.uuidString }
        let earlier = ordered.filter { $0.uuidString <= cursor.uuidString }
        return following + earlier
    }

    public let batchLimit: Int
    public let receiptCooldown: TimeInterval
    public let batchInterval: TimeInterval

    private struct Attempt: Sendable {
        let receipt: SegmentReceipt
        let date: Date
    }

    private var attempts: [UUID: Attempt] = [:]
    private var lastBatchAt: Date?

    public init(batchLimit: Int = 12, receiptCooldown: TimeInterval = 15,
                batchInterval: TimeInterval = 2) {
        precondition(batchLimit > 0 && receiptCooldown >= 0 && batchInterval > 0)
        self.batchLimit = batchLimit
        self.receiptCooldown = receiptCooldown
        self.batchInterval = batchInterval
    }

    public func delayUntilNextBatch(at now: Date = Date()) -> TimeInterval {
        guard let lastBatchAt, now >= lastBatchAt else { return 0 }
        return max(0, batchInterval - now.timeIntervalSince(lastBatchAt))
    }

    public func canAttempt(_ receipt: SegmentReceipt, at now: Date = Date()) -> Bool {
        delayUntilAttempt(receipt, at: now) == 0
    }

    public func delayUntilAttempt(_ receipt: SegmentReceipt, at now: Date = Date()) -> TimeInterval {
        guard let attempt = attempts[receipt.segmentID], attempt.receipt == receipt else { return 0 }
        // A wall-clock correction must not suppress durable receipts indefinitely.
        guard now >= attempt.date else { return 0 }
        return max(0, receiptCooldown - now.timeIntervalSince(attempt.date))
    }

    /// New arrivals bypass batch debounce, but duplicate arrivals retain their
    /// individual cooldown. Call before sending; failure does not undo an attempt.
    public mutating func beginImmediateAttempt(_ receipt: SegmentReceipt,
                                              at now: Date = Date()) -> Bool {
        guard canAttempt(receipt, at: now) else { return false }
        attempts[receipt.segmentID] = Attempt(receipt: receipt, date: now)
        return true
    }

    public mutating func nextBatch(from receipts: [SegmentReceipt],
                                   at now: Date = Date()) -> [SegmentReceipt] {
        guard delayUntilNextBatch(at: now) == 0 else { return [] }
        var seen = Set<UUID>()
        let candidates = receipts.filter {
            seen.insert($0.segmentID).inserted && canAttempt($0, at: now)
        }.sorted { lhs, rhs in
            let left = matchingAttempt(for: lhs)
            let right = matchingAttempt(for: rhs)
            if let left, let right, left.date != right.date { return left.date < right.date }
            if (left == nil) != (right == nil) { return left == nil }
            if lhs.receivedAt != rhs.receivedAt { return lhs.receivedAt > rhs.receivedAt }
            return lhs.segmentID.uuidString < rhs.segmentID.uuidString
        }
        let selected = Array(candidates.prefix(batchLimit))
        guard !selected.isEmpty else { return [] }
        lastBatchAt = now
        for receipt in selected {
            attempts[receipt.segmentID] = Attempt(receipt: receipt, date: now)
        }
        return selected
    }

    private func matchingAttempt(for receipt: SegmentReceipt) -> Attempt? {
        guard let attempt = attempts[receipt.segmentID], attempt.receipt == receipt else { return nil }
        return attempt
    }
}

/// Historical Watch ACK replay. A failed send keeps the head and cursor.
/// A receipt that cannot be verified still advances so one bad file cannot
/// block the tail. Another request's success is not an input here.
public enum HistoricalReceiptReplay {
    public enum Handoff: Equatable, Sendable {
        case queued, alreadyQueued, unavailable
    }
    public struct Progress: Equatable, Sendable {
        public var pending: [UUID]
        public var cursor: UUID?
        public var committed: Bool
        public init(pending: [UUID], cursor: UUID?, committed: Bool) {
            self.pending = pending; self.cursor = cursor; self.committed = committed
        }
    }

    public static func step(pending: [UUID], cursor: UUID?, verified: Bool, handoff: Handoff?) -> Progress {
        guard let head = pending.first else {
            return Progress(pending: pending, cursor: cursor, committed: false)
        }
        if !verified {
            return Progress(pending: Array(pending.dropFirst()), cursor: head, committed: true)
        }
        switch handoff {
        case .queued, .alreadyQueued:
            return Progress(pending: Array(pending.dropFirst()), cursor: head, committed: true)
        case .unavailable, nil:
            return Progress(pending: pending, cursor: cursor, committed: false)
        }
    }
}

/// One exact Watch receipt request. An unavailable companion keeps the head.
/// A request that cannot be verified still leaves, so it cannot block the tail.
public enum TargetedReceiptHandoff {
    public struct Progress: Equatable, Sendable {
        public var pending: [TargetedReceiptRequest]
        public var committed: Bool
        public init(pending: [TargetedReceiptRequest], committed: Bool) {
            self.pending = pending
            self.committed = committed
        }
    }

    public static func step(pending: [TargetedReceiptRequest], verified: Bool,
                            handoff: HistoricalReceiptReplay.Handoff?) -> Progress {
        guard pending.first != nil else {
            return Progress(pending: pending, committed: false)
        }
        if !verified {
            return Progress(pending: Array(pending.dropFirst()), committed: true)
        }
        switch handoff {
        case .queued, .alreadyQueued:
            return Progress(pending: Array(pending.dropFirst()), committed: true)
        case .unavailable, nil:
            return Progress(pending: pending, committed: false)
        }
    }
}
