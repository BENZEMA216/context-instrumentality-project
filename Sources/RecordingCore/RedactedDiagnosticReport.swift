import Foundation

/// Export-only types. Recording identities, paths, locations, content digests,
/// free-form errors and event details deliberately have no representable field.
public struct RedactedDiagnosticEvent: Encodable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case automaticResumeAttempt = "automatic_resume_attempt"
        case automaticResumeScheduled = "automatic_resume_scheduled"
        case automaticResumeExhausted = "automatic_resume_exhausted"
        case captureAttemptStarted = "capture_attempt_started"
        case captureEngineStarted = "capture_engine_started"
        case captureAttemptError = "capture_attempt_error"
        case captureAttemptAudioConfirmed = "capture_attempt_audio_confirmed"
        case captureAttemptsCancelled = "capture_attempts_cancelled"
        case userPaused = "user_paused", userEnded = "user_ended"
        case audioGap = "audio_gap", gapClosed = "gap_closed", other
        public static func classify(_ value: String) -> Self { Self(rawValue: value) ?? .other }
    }
    public enum Category: String, Codable, Sendable {
        case capture, captureGap = "capture_gap", captureFailure = "capture_failure"
        case transferQueued = "transfer_queued", transferReceived = "transfer_received"
        case transferFailure = "transfer_failure", receipt, receiptFailure = "receipt_failure"
        case connection, background, driveFailure = "drive_failure", other

        public static func classify(_ kind: String) -> Self {
            switch kind {
            case "audio_started", "capture_start_requested", "segment_opened", "segment_sealed",
                 "audio_format_changed", "capture_telemetry", "capture_storage_telemetry": return .capture
            case "automatic_resume_attempt", "automatic_resume_scheduled", "automatic_resume_exhausted",
                 "capture_attempt_started", "capture_engine_started", "capture_attempt_audio_confirmed",
                 "capture_attempts_cancelled", "user_paused", "user_ended": return .capture
            case "capture_attempt_error": return .captureFailure
            case "audio_gap", "gap_closed", "recovered_unknown_interval": return .captureGap
            case "capture_interrupted", "microphone_permission_denied", "resume_requires_user": return .captureFailure
            case "file_transfer_enqueued", "file_transfer_queue", "phone.incoming_staged": return .transferQueued
            case "phone.received", "file_delivered_waiting_ack": return .transferReceived
            case "phone.ack_attempt", "phone.ack_background_completed", "phone_durable_ack",
                 "phone_receipt_request_enqueued", "phone_receipt_request_immediate_reply",
                 "phone.targeted_receipt_verified", "phone.targeted_receipt_deferred": return .receipt
            case "phone.ack_failed", "phone_ack_rejected", "phone_receipt_request_failed",
                 "phone_receipt_request_immediate_failed", "file_transfer_ack_check_failed",
                 "phone.targeted_receipt_rejected", "phone.targeted_receipt_unavailable": return .receiptFailure
            case "phone.connection_state", "watch_activation_failed": return .connection
            case "phone.background_lease", "phone.background_sync_started", "phone.background_sync_finished",
                 "watch.background_connectivity_started", "watch.background_connectivity_finished",
                 "watch.background_connectivity_expired", "watch.background_refresh_requested",
                 "watch.background_refresh_schedule_result", "watch.background_transfer_decision": return .background
            case "phone.drive_background_request_failed": return .driveFailure
            case "phone.error", "phone.old_sync_request_failed", "phone.watch_backlog_evidence_failed",
                 "event_transfer_failed", "file_sync_failed", "file_transfer_failed",
                 "file_transfer_callback_lookup_failed", "file_retry_state_load_failed",
                 "file_retry_state_save_failed", "file_scheduling_state_load_failed",
                 "file_scheduling_state_save_failed", "watch.background_refresh_state_failed": return .transferFailure
            default: return .other
            }
        }
    }
    public let timestamp: Date
    public let category: Category
    public let kind: Kind
    public let correlation = "not_available"
    public init(timestamp: Date, category: Category, kind: Kind = .other) {
        self.timestamp = timestamp; self.category = category; self.kind = kind
    }
    public init(_ event: RecordingEvent) {
        self.init(timestamp: event.timestamp, category: .classify(event.kind), kind: .classify(event.kind))
    }
}

public struct RedactedDiagnosticEventBatch: Encodable, Sendable {
    public enum Scope: String, Codable, Sendable { case recent, fullHistory = "full_history" }
    public enum Availability: String, Encodable, Sendable { case observed, unavailable }
    public enum Failure: String, Encodable, Sendable { case libraryUnavailable = "library_unavailable" }
    public let availability: Availability
    public let unavailableReason: Failure?
    public let scope: Scope
    public let events: [RedactedDiagnosticEvent]
    public let requestedStartAt: Date?
    public let requestedEndAt: Date
    public let bytesRead: Int
    public let decodedFileCount: Int
    public let totalEventFileCount: Int?
    public let truncated: Bool
    public let completeHistoryObserved: Bool
    public let directoryStable: Bool
    public let enumerationLimitReached: Bool
    public let candidateLimitReached: Bool
    public let byteLimitReached: Bool
    public let maximumEventCount: Int
    public let maximumSourceBytes: Int

    public static func recent(_ snapshot: RecordingDiagnosticEventSnapshot, at now: Date) -> Self {
        let selection = snapshot.eventSelection
        return .init(availability: .observed, unavailableReason: nil,
            scope: .recent, events: snapshot.events.map(RedactedDiagnosticEvent.init),
            requestedStartAt: selection.requestedStartAt, requestedEndAt: now,
            bytesRead: selection.eventBytesRead ?? 0, decodedFileCount: selection.decodedFileCount,
            totalEventFileCount: selection.totalEventFileCount, truncated: selection.truncated,
            completeHistoryObserved: false, directoryStable: selection.candidateMetadataStable,
            enumerationLimitReached: selection.metadataEnumerationLimitReached,
            candidateLimitReached: selection.candidateLimitReached, byteLimitReached: selection.byteLimitReached,
            maximumEventCount: 500, maximumSourceBytes: selection.maximumEventBytes)
    }
    public static func unavailable(includeFullHistory: Bool, at now: Date) -> Self {
        .init(availability: .unavailable, unavailableReason: .libraryUnavailable,
            scope: includeFullHistory ? .fullHistory : .recent, events: [], requestedStartAt: nil, requestedEndAt: now,
            bytesRead: 0, decodedFileCount: 0, totalEventFileCount: nil, truncated: false,
            completeHistoryObserved: false, directoryStable: false, enumerationLimitReached: false,
            candidateLimitReached: false, byteLimitReached: false,
            maximumEventCount: includeFullHistory ? DiagnosticHistoryReader.maximumEvents : 500,
            maximumSourceBytes: includeFullHistory ? DiagnosticHistoryReader.maximumBytes : 2_097_152)
    }
}

public struct RedactedDiagnosticMemory: Encodable, Sendable {
    public let source = "phone_store_cached_snapshot"
    public let contentReverifiedForExport = false
    public let capturedAt: Date
    public let librarySnapshotObservedAt: Date?
    public let librarySnapshotAvailable: Bool
    public let segmentCount: Int
    public let receiptCount: Int
    public let visibleEventCount: Int
    public let storageFailureObserved: Bool
    public init(capturedAt: Date, librarySnapshotObservedAt: Date?, librarySnapshotAvailable: Bool,
                segmentCount: Int, receiptCount: Int, visibleEventCount: Int, storageFailureObserved: Bool) {
        self.capturedAt = capturedAt; self.librarySnapshotObservedAt = librarySnapshotObservedAt
        self.librarySnapshotAvailable = librarySnapshotAvailable
        self.segmentCount = max(0, segmentCount); self.receiptCount = max(0, receiptCount)
        self.visibleEventCount = max(0, visibleEventCount); self.storageFailureObserved = storageFailureObserved
    }
}

public struct RedactedDiagnosticWatch: Encodable, Sendable {
    public enum Availability: String, Codable, Sendable { case missing, cached, stale, invalidTimestamp = "invalid_timestamp" }
    public let source = "cached_watch_status_only"
    public let statusRequestedForExport = false
    public let availability: Availability
    public let reachableAtCapture: Bool
    public let capturedAt: Date
    public let observedAt: Date?
    public let ageSeconds: Double?
    public let state: CaptureState?
    public init(snapshot: RecorderSnapshot?, reachable: Bool, at now: Date) {
        capturedAt = now; reachableAtCapture = reachable
        guard let snapshot else { availability = .missing; observedAt = nil; ageSeconds = nil; state = nil; return }
        let age = now.timeIntervalSince(snapshot.observedAt)
        guard age.isFinite, age >= -5 else {
            availability = .invalidTimestamp; observedAt = nil; ageSeconds = nil; state = nil; return
        }
        observedAt = snapshot.observedAt; ageSeconds = max(0, age); state = snapshot.state
        availability = age > 60 ? .stale : .cached
    }
}

public struct RedactedDiagnosticReport: Encodable, Sendable {
    public let schemaVersion = 1
    public let privacyPolicyVersion = 1
    public let issueID: UUID
    public let processRunID: UUID
    public let platform = "iOS"
    public let build: String
    public let operatingSystem: OperatingSystem
    public let includesAudio = false
    public let includesTranscripts = false
    public let includesRecordingIdentities = false
    public let audioContentVerified = false
    public let watchContactedForExport = false
    public let watchProcessingHistory = "not_observed"
    public let macASRObservation = "not_observed"
    public let agentObservation = "not_observed"
    public let collectionStartedAt: Date
    public let collectionFinishedAt: Date
    public let collectionElapsedMS: Double
    public let memory: RedactedDiagnosticMemory
    public let watch: RedactedDiagnosticWatch
    public let eventHistory: RedactedDiagnosticEventBatch
    public let maximumExportBytes = DiagnosticReportStorage.maximumReportBytes

    public struct OperatingSystem: Encodable, Sendable {
        public let family = "iOS"
        public let major: Int
        public let minor: Int
        public let patch: Int
        public init(_ version: OperatingSystemVersion) {
            major = version.majorVersion; minor = version.minorVersion; patch = version.patchVersion
        }
    }
    public init(issueID: UUID, processRunID: UUID, build: String, operatingSystem: OperatingSystemVersion,
                collectionStartedAt: Date, collectionFinishedAt: Date, collectionElapsedMS: Double,
                memory: RedactedDiagnosticMemory, watch: RedactedDiagnosticWatch,
                eventHistory: RedactedDiagnosticEventBatch) {
        self.issueID = issueID; self.processRunID = processRunID
        // Bundle versions are developer metadata, but a malformed bundle must
        // not smuggle arbitrary strings into a report.
        self.build = Self.safeBuild(build)
        self.operatingSystem = .init(operatingSystem)
        self.collectionStartedAt = collectionStartedAt; self.collectionFinishedAt = collectionFinishedAt
        self.collectionElapsedMS = max(0, collectionElapsedMS)
        self.memory = memory; self.watch = watch; self.eventHistory = eventHistory
    }
    public static func safeBuild(_ value: String) -> String {
        guard !value.isEmpty, value.utf8.count <= 32,
              value.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) else { return "unknown" }
        return value
    }
}

/// The file is immutable once ready. Later UI observations are a separate,
/// bounded local receipt, never presented as proof that a recipient got a file.
public struct DiagnosticShareLifecycle: Encodable, Sendable {
    public let schemaVersion = 1
    public let issueID: UUID
    public let requestedAt: Date
    public let fileReadyAt: Date
    public let fileReadyElapsedMS: Double
    public var panelPresentedAt: Date?
    public var panelPresentedElapsedMS: Double?
    public var activityFinishedAt: Date?
    public var activityFinishedElapsedMS: Double?
    public var systemActivityCompleted: Bool?
    public let recipientDeliveryObserved = false
    public init(issueID: UUID, requestedAt: Date, fileReadyAt: Date, fileReadyElapsedMS: Double) {
        self.issueID = issueID; self.requestedAt = requestedAt; self.fileReadyAt = fileReadyAt
        self.fileReadyElapsedMS = max(0, fileReadyElapsedMS)
    }
}
