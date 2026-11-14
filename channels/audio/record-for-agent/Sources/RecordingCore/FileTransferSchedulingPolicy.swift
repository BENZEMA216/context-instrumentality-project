import Foundation

/// Gives recent recordings one turn, then historical recordings two turns.
/// Keep the same instance across queue refills, including single-slot refills.
/// Persist it after successful enqueues to retain the rotation across restarts.
/// This only selects eligible work; it neither creates transfers nor acknowledges files.
public struct FileTransferSchedulingPolicy: Codable, Equatable, Sendable {
    public static let recentCaptureWindow: TimeInterval = 5 * 60
    private var nextTurn = 0
    private var recentSegmentID: UUID?
    private var recentSegmentEndedAt: Date?

    /// Starting with history is a conservative fallback for unreadable saved state.
    public init(startingWithOldest: Bool = false) {
        nextTurn = startingWithOldest ? 1 : 0
    }

    private enum CodingKeys: String, CodingKey { case nextTurn, recentSegmentID, recentSegmentEndedAt }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let turn = try container.decode(Int.self, forKey: .nextTurn)
        guard (0...2).contains(turn) else {
            throw DecodingError.dataCorruptedError(forKey: .nextTurn, in: container,
                debugDescription: "File transfer scheduling turn must be in 0...2.")
        }
        nextTurn = turn
        recentSegmentID = try container.decodeIfPresent(UUID.self, forKey: .recentSegmentID)
        recentSegmentEndedAt = try container.decodeIfPresent(Date.self, forKey: .recentSegmentEndedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(nextTurn, forKey: .nextTurn)
        try container.encodeIfPresent(recentSegmentID, forKey: .recentSegmentID)
        try container.encodeIfPresent(recentSegmentEndedAt, forKey: .recentSegmentEndedAt)
    }

    /// The caller excludes queued, retry-ineligible, and missing-file candidates.
    /// Selection does not consume a turn: encoding or enqueue preparation can fail.
    /// After success, remove every candidate with that ID before selecting again.
    public func nextCandidate(from eligible: [SegmentManifest]) -> SegmentManifest? {
        if nextTurn == 0 {
            return eligible.max(by: Self.isEarlier)
        }
        return eligible.min(by: Self.isEarlier)
    }

    /// Call exactly once after a real transfer has been enqueued, never merely
    /// after selection, an empty result, or an unsuccessful enqueue attempt.
    public mutating func noteEnqueued() {
        nextTurn = (nextTurn + 1) % 3
    }

    /// Reserve one of the owner's three slots for the latest eligible recording.
    /// While that task is still outstanding, natural vacancies advance history.
    /// Without a recently sealed candidate, leave the third slot empty so a
    /// future recording need not wait behind three historical tasks. A full
    /// legacy queue is untouched until a task naturally leaves it.
    public func nextCandidate(from eligible: [SegmentManifest],
                              outstandingIDs: Set<UUID>, outstandingCount: Int,
                              at now: Date = Date()) -> SegmentManifest? {
        guard outstandingCount < 3 else { return nil }
        if hasRecentOutstanding(outstandingIDs, at: now) {
            return eligible.min(by: Self.isEarlier)
        }
        if let recent = eligible.filter({ Self.isRecent($0, at: now) }).max(by: Self.isEarlier) {
            return recent
        }
        guard outstandingCount < 2 else { return nil }
        return eligible.min(by: Self.isEarlier)
    }

    /// Pass the queue before adding this successful enqueue to it.
    public mutating func noteEnqueued(_ manifest: SegmentManifest, outstandingIDs: Set<UUID>,
                                     at now: Date = Date()) {
        if !hasRecentOutstanding(outstandingIDs, at: now) && Self.isRecent(manifest, at: now) {
            recentSegmentID = manifest.id
            recentSegmentEndedAt = manifest.endedAt
        }
        noteEnqueued()
    }

    private static func isRecent(_ manifest: SegmentManifest, at now: Date) -> Bool {
        manifest.endedAt <= now && manifest.endedAt >= now.addingTimeInterval(-recentCaptureWindow)
    }

    private func hasRecentOutstanding(_ outstandingIDs: Set<UUID>, at now: Date) -> Bool {
        guard let recentSegmentID, let recentSegmentEndedAt else { return false }
        return outstandingIDs.contains(recentSegmentID) && recentSegmentEndedAt <= now
            && recentSegmentEndedAt >= now.addingTimeInterval(-Self.recentCaptureWindow)
    }

    /// UUID order makes equal capture times deterministic across input ordering.
    private static func isEarlier(_ lhs: SegmentManifest, _ rhs: SegmentManifest) -> Bool {
        if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
