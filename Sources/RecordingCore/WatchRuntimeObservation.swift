import Foundation

/// Latest source observations, never receipt authority or proof of radio progress.
/// Missing queue/time fields remain unknown. No recording identifiers or free text.
public struct WatchRuntimeObservation: Codable, Equatable, Sendable {
    public static let maximumBytes = 4_096
    public var schemaVersion = 1
    public var build: String
    public var processRunID: UUID
    public var observerEpochID: UUID
    public var sequence: UInt64
    public var observedAtMS: Int64
    public var foreground: Bool?
    public var liveCapture: Bool?
    public var maintenanceOwnerAllowed = false
    public var nativeQueueCount: Int?
    public var nativeQueueObservedAtMS: Int64?
    public var lastEnqueuedAtMS: Int64?
    public var lastACKCommittedAtMS: Int64?
    public var lastACKReplayedAtMS: Int64?
    public var enqueuedCount = 0
    public var ackCommittedCount = 0
    public var ackReplayedCount = 0
    public var ackUncommittedCount = 0
    public var connectivityTasksStarted = 0
    public var applicationRefreshTasksStarted = 0
    public var tasksCompleted = 0
    public var tasksExpired = 0
    public var liveTaskCount = 0
    // Optional additions preserve 106 packets. Progress is native units, not
    // audio bytes; compare only samples with the same unique non-nil attempt ID.
    public var queueSamples: [QueueSample]?
    public var lastACKFailure: ACKFailure?
    public var refresh: Refresh?
    public var admission: Admission?

    public struct QueueSample: Codable, Equatable, Sendable {
        public var attemptID: UUID?
        public var isTransferring: Bool
        public var completedUnits: Int64?
        public var totalUnits: Int64?
        public init(attemptID: UUID?, isTransferring: Bool, completedUnits: Int64?, totalUnits: Int64?) {
            self.attemptID = attemptID; self.isTransferring = isTransferring
            self.completedUnits = completedUnits; self.totalUnits = totalUnits
        }
    }

    public struct ACKFailure: Codable, Equatable, Sendable {
        public enum Stage: String, Codable, Sendable { case decode, commit }
        public enum Reason: String, Codable, Sendable {
            case decodeFailed = "decode_failed", receiptMismatch = "receipt_mismatch"
            case invalidManifest = "invalid_manifest", conflictingSegment = "conflicting_segment"
            case checksumMismatch = "checksum_mismatch", missingAudio = "missing_audio"
            case invalidStagingPath = "invalid_staging_path", persistenceFailure = "persistence_failure"
            case storedMetadataDecodeFailed = "stored_metadata_decode_failed"
            case cocoaIO = "cocoa_io", posixIO = "posix_io", other
        }
        public var observedAtMS: Int64
        public var stage: Stage
        public var reason: Reason
        public var systemCode: Int?
        public var operation: AcknowledgementOperation?
        public init(observedAtMS: Int64, stage: Stage, reason: Reason, systemCode: Int?,
                    operation: AcknowledgementOperation? = nil) {
            self.observedAtMS = observedAtMS; self.stage = stage; self.reason = reason; self.systemCode = systemCode
            self.operation = operation
        }
    }

    public struct Refresh: Codable, Equatable, Sendable {
        public enum ErrorKind: String, Codable, Sendable { case cocoa, posix, watchkit, other }
        public var requestedCount: Int
        public var acceptedCount: Int
        public var failedCount: Int
        public var requestedAtMS: Int64?
        public var preferredAtMS: Int64?
        public var completedAtMS: Int64?
        public var accepted: Bool?
        public var errorKind: ErrorKind?
        public var errorCode: Int?
        public init(requestedCount: Int, acceptedCount: Int, failedCount: Int,
                    requestedAtMS: Int64?, preferredAtMS: Int64?, completedAtMS: Int64?,
                    accepted: Bool?, errorKind: ErrorKind?, errorCode: Int?) {
            self.requestedCount = requestedCount; self.acceptedCount = acceptedCount; self.failedCount = failedCount
            self.requestedAtMS = requestedAtMS; self.preferredAtMS = preferredAtMS; self.completedAtMS = completedAtMS
            self.accepted = accepted; self.errorKind = errorKind; self.errorCode = errorCode
        }
    }

    public struct Admission: Codable, Equatable, Sendable {
        public enum Reason: String, Codable, Sendable {
            case notEvaluated = "not_evaluated", awaitingActivation = "awaiting_activation"
            case nativeOccupied = "native_occupied", foreignNative = "foreign_native"
            case candidateBudget = "candidate_budget", enqueueBudget = "enqueue_budget"
            case retryBackoff = "retry_backoff", noAdmission = "no_admission"
            case openTail = "open_tail", candidateReadFailed = "candidate_read_failed"
            case freshReadFailed = "fresh_read_failed", enqueued
        }
        public var observedAtMS: Int64
        public var reason: Reason
        public var handoffReason: String?
        public var handoffObservedAtMS: Int64?
        public init(observedAtMS: Int64, reason: Reason) { self.observedAtMS = observedAtMS; self.reason = reason }
    }

    public init(build: String, processRunID: UUID, observerEpochID: UUID,
                sequence: UInt64, observedAtMS: Int64) {
        self.build = build; self.processRunID = processRunID; self.observerEpochID = observerEpochID
        self.sequence = sequence; self.observedAtMS = observedAtMS
    }

    public var isValid: Bool {
        let safeBuild = build == "unknown" || (!build.isEmpty && build.utf8.count <= 20
            && build.utf8.allSatisfy { (48...57).contains($0) })
        let times = [observedAtMS, nativeQueueObservedAtMS, lastEnqueuedAtMS,
                     lastACKCommittedAtMS, lastACKReplayedAtMS].compactMap { $0 }
        let counts = [nativeQueueCount, enqueuedCount, ackCommittedCount, ackReplayedCount,
                      ackUncommittedCount, connectivityTasksStarted, applicationRefreshTasksStarted,
                      tasksCompleted, tasksExpired, liveTaskCount].compactMap { $0 }
        let validTime: (Int64) -> Bool = { $0 >= 0 && $0 <= 253_402_300_799_000 }
        let validCode: (Int?) -> Bool = { $0 == nil || Int32(exactly: $0!) != nil }
        if let samples = queueSamples {
            guard let count = nativeQueueCount, samples.count <= min(3, count),
                  samples.allSatisfy({ [$0.completedUnits, $0.totalUnits].compactMap { $0 }.allSatisfy { $0 >= 0 } }) else { return false }
        }
        if let failure = lastACKFailure {
            guard validTime(failure.observedAtMS), validCode(failure.systemCode),
                  (failure.stage == .decode) == (failure.reason == .decodeFailed),
                  failure.operation == nil || failure.stage == .commit,
                  failure.systemCode == nil || failure.reason == .cocoaIO || failure.reason == .posixIO else { return false }
        }
        if let refresh {
            guard [refresh.requestedCount, refresh.acceptedCount, refresh.failedCount].allSatisfy({ $0 >= 0 }),
                  [refresh.requestedAtMS, refresh.preferredAtMS, refresh.completedAtMS].compactMap({ $0 }).allSatisfy(validTime),
                  validCode(refresh.errorCode),
                  refresh.accepted == false || (refresh.errorKind == nil && refresh.errorCode == nil) else { return false }
        }
        if let admission {
            guard validTime(admission.observedAtMS),
                  (admission.handoffReason == nil) == (admission.handoffObservedAtMS == nil) else { return false }
            if let reason = admission.handoffReason {
                guard reason == "source_metadata_unavailable" || reason == "power_or_owner_changed"
                    || WatchTransferHandoffPolicy.Decision(rawValue: reason) != nil,
                      admission.handoffObservedAtMS.map(validTime) == true else { return false }
            }
        }
        return schemaVersion == 1 && safeBuild && sequence > 0 && observedAtMS > 0
            && times.allSatisfy { $0 >= 0 && $0 <= 253_402_300_799_000 }
            && counts.allSatisfy { $0 >= 0 }
            && ((nativeQueueCount == nil) == (nativeQueueObservedAtMS == nil))
    }

    public func supersedes(_ prior: Self) -> Bool {
        if processRunID == prior.processRunID && observerEpochID == prior.observerEpochID {
            return build == prior.build && sequence > prior.sequence
        }
        return observedAtMS > prior.observedAtMS
    }

    /// Sampling the same queue again is not new transfer progress. A caller can
    /// refresh that observation on a later real wake without sending every sample.
    public func hasSameProgress(as prior: Self) -> Bool {
        var comparable = self
        comparable.sequence = prior.sequence
        comparable.observedAtMS = prior.observedAtMS
        comparable.nativeQueueObservedAtMS = prior.nativeQueueObservedAtMS
        // Re-sampling an unchanged admission reason is not new progress.
        if var admission = comparable.admission, let previous = prior.admission,
           admission.reason == previous.reason {
            admission.observedAtMS = previous.observedAtMS
            if admission.handoffReason == previous.handoffReason {
                admission.handoffObservedAtMS = previous.handoffObservedAtMS
            }
            comparable.admission = admission
        }
        return comparable == prior
    }

    public static func decode(_ data: Data) -> Self? {
        guard !data.isEmpty, data.count <= maximumBytes,
              let value = try? TransportCodec.decode(Self.self, from: data), value.isValid else { return nil }
        return value
    }
}
