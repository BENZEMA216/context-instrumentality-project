import Foundation

/// Strict metadata-only wire records. Unknown fields are rejected, including
/// fields Codable would otherwise silently ignore. No native error text leaves
/// the Watch through this channel.
public enum WatchTransferSourceCategory: String, Codable, Sendable { case normal, recovery, unknown }
public enum WatchTransferProtection: String, Codable, Sendable {
    case complete, untilFirstAuth = "until_first_auth", unlessOpen = "unless_open", none, unknown, unavailable
}
public struct WatchTransferAttemptDiagnostic: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case enqueue, progress, completion }
    public enum Outcome: String, Codable, Sendable { case enqueued, observed, succeeded, failed }
    public let phase: Phase
    public let segmentID: UUID
    public let attemptID: UUID
    public let sourceCategory: WatchTransferSourceCategory
    public let protection: WatchTransferProtection
    public let observedAtMS: Int64
    public let processRunID: UUID?
    public let enqueuedAtMS: Int64?
    public let generation: UInt64?
    public let foreground: Bool?
    public let liveCapture: Bool?
    public let completed: Int64
    public let total: Int64
    public let outcome: Outcome
    public init(phase: Phase, segmentID: UUID, attemptID: UUID, sourceCategory: WatchTransferSourceCategory,
                protection: WatchTransferProtection, observedAtMS: Int64, enqueuedAtMS: Int64?, generation: UInt64?,
                foreground: Bool?, liveCapture: Bool?, completed: Int64, total: Int64, outcome: Outcome, processRunID: UUID? = nil) {
        self.phase = phase; self.segmentID = segmentID; self.attemptID = attemptID; self.sourceCategory = sourceCategory
        self.protection = protection; self.observedAtMS = observedAtMS; self.enqueuedAtMS = enqueuedAtMS
        self.generation = generation; self.foreground = foreground; self.liveCapture = liveCapture
        self.completed = completed; self.total = total; self.outcome = outcome; self.processRunID = processRunID
    }
    public static func decode(detail: String) -> Self? {
        guard let value: Self = strictDiagnosticDecode(detail, allowed: ["processRunID", "phase", "segmentID", "attemptID", "sourceCategory", "protection", "observedAtMS", "enqueuedAtMS", "generation", "foreground", "liveCapture", "completed", "total", "outcome"]),
              value.observedAtMS > 0, value.enqueuedAtMS.map({ $0 > 0 }) ?? true,
              value.completed >= 0, value.total >= 0,
              (value.phase == .enqueue && value.outcome == .enqueued)
                || (value.phase == .progress && value.outcome == .observed)
                || (value.phase == .completion && [.succeeded, .failed].contains(value.outcome)) else { return nil }
        return value
    }
    public func detail() -> String? { diagnosticDetail(self) }
}
public struct WatchTransferRefusalDiagnostic: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable {
        case nativeOccupied = "native_occupied", foreignNative = "foreign_native", cap
        case expiredGeneration = "expired_generation", noOwner = "no_owner"
        case candidateBudget = "candidate_budget", enqueueBudget = "enqueue_budget", retryBackoff = "retry_backoff"
        case noAdmission = "no_admission", awaitingActivation = "awaiting_activation", openTail = "open_tail"
        case metadataUnavailable = "metadata_unavailable", deadline, byteLimit = "byte_limit", capacityLimit = "capacity_limit"
    }
    public let reason: Reason
    public let observedAtMS: Int64
    public let processRunID: UUID?
    public let generation: UInt64?
    public let foreground: Bool?
    public let liveCapture: Bool?
    public let nativeCount: Int?
    public let observationCount: Int?
    public let lastObservedAtMS: Int64?
    public init(reason: Reason, observedAtMS: Int64, generation: UInt64?, foreground: Bool?, liveCapture: Bool?, nativeCount: Int?, processRunID: UUID? = nil, observationCount: Int? = nil, lastObservedAtMS: Int64? = nil) {
        self.reason = reason; self.observedAtMS = observedAtMS; self.generation = generation
        self.foreground = foreground; self.liveCapture = liveCapture; self.nativeCount = nativeCount; self.processRunID = processRunID
        self.observationCount = observationCount; self.lastObservedAtMS = lastObservedAtMS
    }
    public static func decode(detail: String) -> Self? {
        guard let value: Self = strictDiagnosticDecode(detail, allowed: ["processRunID", "reason", "observedAtMS", "generation", "foreground", "liveCapture", "nativeCount", "observationCount", "lastObservedAtMS"]),
              value.observedAtMS > 0, value.observationCount.map({ $0 > 0 }) ?? true,
              value.lastObservedAtMS.map({ $0 >= value.observedAtMS }) ?? true,
              value.nativeCount.map({ $0 >= 0 && $0 <= 10_000 }) ?? true else { return nil }
        return value
    }
    public func detail() -> String? { diagnosticDetail(self) }
}
public struct WatchTransferOpportunityDiagnostic: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case started, completed, expired }
    public let phase: Phase
    public let generation: UInt64
    public let observedAtMS: Int64
    public let processRunID: UUID?
    public let foreground: Bool?
    public let liveCapture: Bool?
    public init(phase: Phase, generation: UInt64, observedAtMS: Int64, foreground: Bool?, liveCapture: Bool?, processRunID: UUID? = nil) {
        self.phase = phase; self.generation = generation; self.observedAtMS = observedAtMS
        self.foreground = foreground; self.liveCapture = liveCapture; self.processRunID = processRunID
    }
    public static func decode(detail: String) -> Self? {
        guard let value: Self = strictDiagnosticDecode(detail, allowed: ["processRunID", "phase", "generation", "observedAtMS", "foreground", "liveCapture"]),
              value.observedAtMS > 0 else { return nil }
        return value
    }
    public func detail() -> String? { diagnosticDetail(self) }
}
public struct WatchTransferDiagnostic: Codable, Equatable, Sendable {
    public let kind: String
    public let attempt: WatchTransferAttemptDiagnostic?
    public let refusal: WatchTransferRefusalDiagnostic?
    public let opportunity: WatchTransferOpportunityDiagnostic?
    /// Source observation time, never the time a delayed packet reaches Phone.
    /// Coalesced waiting states retain their first time and a later last time.
    public var latestObservedAtMS: Int64 {
        if let refusal { return refusal.lastObservedAtMS ?? refusal.observedAtMS }
        return attempt?.observedAtMS ?? opportunity?.observedAtMS ?? 0
    }
    public static func parse(_ event: RecordingEvent) -> Self? {
        // A diagnostic packet never needs capture session or interval context.
        guard event.sessionID == nil, event.intervalStart == nil, event.intervalEnd == nil else { return nil }
        switch event.kind {
        case "watch.transfer_attempt":
            guard let value = WatchTransferAttemptDiagnostic.decode(detail: event.detail) else { return nil }
            return Self(kind: event.kind, attempt: value, refusal: nil, opportunity: nil)
        case "watch.transfer_refusal":
            guard let value = WatchTransferRefusalDiagnostic.decode(detail: event.detail) else { return nil }
            return Self(kind: event.kind, attempt: nil, refusal: value, opportunity: nil)
        case "watch.transfer_opportunity":
            guard let value = WatchTransferOpportunityDiagnostic.decode(detail: event.detail) else { return nil }
            return Self(kind: event.kind, attempt: nil, refusal: nil, opportunity: value)
        default: return nil
        }
    }
}
private func diagnosticDetail<T: Encodable>(_ value: T) -> String? {
    guard let data = try? JSONEncoder().encode(value), data.count <= 2_048 else { return nil }
    return String(data: data, encoding: .utf8)
}
private func strictDiagnosticDecode<T: Decodable>(_ detail: String, allowed: Set<String>) -> T? {
    guard let data = detail.data(using: .utf8), data.count <= 2_048,
          let dictionary = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          Set(dictionary.keys).isSubset(of: allowed) else { return nil }
    return try? JSONDecoder().decode(T.self, from: data)
}
