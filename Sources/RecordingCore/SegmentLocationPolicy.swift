import Foundation

/// A bounded, in-memory set of location fixes for one active recording run.
/// The writer owns serialization; this policy never reads location services or rewrites a sealed segment.
public struct SegmentLocationPolicy: Sendable {
    public static let maximumRetainedFixes = 64
    private var acceptedFrom: Date?
    private var sealedThrough: Date?
    private var fixes: [SegmentLocation] = []
    var retainedFixCount: Int { fixes.count }

    public init() {}

    /// Called on every prepare, including resume within the same session.
    public mutating func beginRecording(at time: Date) {
        endRecording()
        guard (try? AgentRecordingMetadata.validateTimestamp(time)) != nil else { return }
        acceptedFrom = Self.milliseconds(time)
    }

    public mutating func endRecording() {
        acceptedFrom = nil
        sealedThrough = nil
        fixes.removeAll(keepingCapacity: true)
    }

    /// receivedAt is captured before enqueueing so a delayed queue cannot legitimize a future fix.
    /// A nil update also excludes fixes captured before the clear, including delayed callbacks.
    public mutating func update(_ location: SegmentLocation?, receivedAt: Date) {
        guard let acceptedFrom, (try? AgentRecordingMetadata.validateTimestamp(receivedAt)) != nil else { return }
        let receivedAt = Self.milliseconds(receivedAt)
        guard let location else {
            fixes.removeAll(keepingCapacity: true)
            self.acceptedFrom = max(acceptedFrom, receivedAt)
            return
        }
        guard (try? location.validate()) != nil,
              location.capturedAt >= acceptedFrom, location.capturedAt <= receivedAt,
              sealedThrough == nil || location.capturedAt > sealedThrough! else { return }
        if let index = fixes.firstIndex(where: { $0.capturedAt == location.capturedAt }) {
            // For equal timestamps prefer better accuracy; an equal-accuracy first fix stays stable.
            if location.horizontalAccuracy < fixes[index].horizontalAccuracy { fixes[index] = location }
        } else {
            fixes.append(location)
            fixes.sort { $0.capturedAt < $1.capturedAt }
            if fixes.count > Self.maximumRetainedFixes {
                fixes.removeFirst(fixes.count - Self.maximumRetainedFixes)
            }
        }
    }

    /// Select the latest retained fix inside the segment's persisted millisecond boundaries.
    /// Every fix at or before this end is then retired, including a shared boundary fix.
    public mutating func sealSegment(startedAt: Date, endedAt: Date) -> SegmentLocation? {
        guard acceptedFrom != nil,
              (try? AgentRecordingMetadata.validateTimestamp(startedAt)) != nil,
              (try? AgentRecordingMetadata.validateTimestamp(endedAt)) != nil else { return nil }
        let start = Self.milliseconds(startedAt), end = Self.milliseconds(endedAt)
        guard start <= end else { return nil }
        let selected = fixes.last { $0.capturedAt >= start && $0.capturedAt <= end }
        let closed = max(sealedThrough ?? end, end)
        sealedThrough = closed
        fixes.removeAll { $0.capturedAt <= closed }
        return selected
    }

    private static func milliseconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1_000).rounded() / 1_000)
    }
}
