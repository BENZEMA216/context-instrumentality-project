import Foundation

/// Connectivity can activate before the recorder finishes loading its session.
/// An absent snapshot must stay absent; only the writer can establish capture state.
public struct TransferSnapshotState: Sendable {
    public private(set) var latest: RecorderSnapshot?

    public init() {}

    public mutating func receive(_ snapshot: RecorderSnapshot) {
        latest = snapshot
    }

    public func applicationSnapshot(pendingCount: Int) -> RecorderSnapshot? {
        guard var snapshot = latest else { return nil }
        snapshot.pendingCount = pendingCount
        snapshot.pendingCountIsKnown = true
        // Updating transport bookkeeping must not refresh the audio observation time.
        return snapshot
    }
}

/// Limits queue diagnostics without making event delivery generate more events.
/// The owner serializes access and supplies a stable queue fingerprint, excluding
/// progress, time, and the diagnostic user-info queue itself.
public struct TransferDiagnosticsPolicy: Sendable {
    public enum Trigger: Sendable {
        case automatic
        case manual
        case eventDeliveryCompletion
    }

    private var lastFingerprint: String?
    private var lastLoggedAt: Date?

    public init() {}

    public mutating func shouldLogQueue(fingerprint: String, trigger: Trigger,
                                       at now: Date = Date()) -> Bool {
        // Even after the interval elapses, completing a diagnostic transfer cannot
        // create its own successor. A recorder/connectivity update can log later.
        if case .eventDeliveryCompletion = trigger { return false }
        let forced: Bool
        if case .manual = trigger { forced = true } else { forced = false }
        guard forced || fingerprint != lastFingerprint
                || lastLoggedAt.map({ now.timeIntervalSince($0) >= 60 }) == true else { return false }
        lastFingerprint = fingerprint
        lastLoggedAt = now
        return true
    }
}
