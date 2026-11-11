import Darwin
import Foundation
import OSLog
import RecordingCore

/// Derived discovery/error state only. This never changes a Drive grant, token,
/// upload ID, artifact or durable receipt. The ledger remains the authority for
/// bytes saved; discovery must also finish before we can claim completion.
struct GoogleDriveSyncProgress: Sendable {
    struct Snapshot: Sendable {
        let revision: UInt64
        let priorityIDs: Set<UUID>
    }
    /// Source admission is a metadata-only boundary, separate from transcript
    /// scanning and prepared-request/network retries. The caller must durably
    /// persist this ledger before accepting its discovery coverage.
    struct SourceSnapshot: Sendable {
        let ledger: GoogleDriveLibraryLedger
        let previousIDs: Set<UUID>
        let request: Snapshot
        let transcriptHints: Set<UUID>
        var addedCount: Int { ledger.jobs.filter { !previousIDs.contains($0.id) }.count }

        init(ledger: GoogleDriveLibraryLedger, manifests: [SegmentManifest], receivedIDs: Set<UUID>,
             request: Snapshot, transcriptHints: Set<UUID> = []) throws {
            previousIDs = Set(ledger.jobs.map(\.id)); self.request = request
            self.transcriptHints = transcriptHints
            var candidate = ledger
            try candidate.discover(manifests: manifests, receivedIDs: receivedIDs)
            self.ledger = candidate
        }
    }
    struct TranscriptInspection: Sendable {
        let transcript: SegmentTranscript?
        let issue: String?
    }
    struct UploadChoice: Equatable, Sendable {
        let segmentID: UUID
        let artifactKey: String
        let isPrioritySmall: Bool
    }
    enum Phase: Equatable { case discovering, uploading, transcriptIssues(Int), complete }

    private(set) var revision: UInt64 = 0
    private(set) var snapshotRevision: UInt64?
    private(set) var remaining: [SegmentManifest] = []
    private(set) var needsDiscovery = true
    private(set) var transcriptIssues: [UUID: String] = [:]
    private(set) var issueRetryAt: Date?
    private(set) var operationError: String?
    private(set) var operationErrorIsNetwork = false
    private(set) var operationErrorNeedsCredential = false
    private(set) var lastFailureAt: Date?
    private(set) var smallVerifiedSinceAudio = 0
    private var priorityIDs = Set<UUID>()
    private var observedHintIDs = Set<UUID>()
    private var pendingHintIDs = Set<UUID>()
    private var creditedReceipts = Set<String>()
    private var knownManifests: [SegmentManifest] = []

    var snapshot: Snapshot { .init(revision: revision, priorityIDs: priorityIDs) }
    var needsSnapshot: Bool { snapshotRevision != revision }
    var hasIssues: Bool { !transcriptIssues.isEmpty }
    var hasWork: Bool { needsDiscovery || hasIssues }
    var errorMessage: String? {
        var messages = operationError.map { [$0] } ?? []
        if hasIssues {
            messages.append("有 \(transcriptIssues.count) 段已有转写未通过核对，尚未保存到 Drive。原音频会继续同步；修复后会自动重查。")
        }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    /// Rehydrating an unknown in-memory cache is not an external work event.
    /// The real receipt, authorization and transcript callbacks already retain
    /// their own wake generation; a changed warm snapshot must still retain it.
    static func sourceChangeNeedsWake(previousManifests: [SegmentManifest]?, previousReceivedIDs: Set<UUID>?,
                                      manifests: [SegmentManifest], receivedIDs: Set<UUID>) -> Bool {
        guard let previousManifests, let previousReceivedIDs else { return false }
        return previousManifests != manifests || previousReceivedIDs != receivedIDs
    }

    mutating func requestDiscovery(prioritizing id: UUID? = nil) {
        revision &+= 1; needsDiscovery = true
        if let id { priorityIDs.insert(id) }
    }
    mutating func acceptSourceSnapshot(_ source: SourceSnapshot) {
        acceptSnapshot(source.ledger.jobs.map(\.manifest), previousIDs: source.previousIDs,
            request: source.request, transcriptHints: source.transcriptHints)
    }
    mutating func acceptSnapshot(_ manifests: [SegmentManifest], previousIDs: Set<UUID>, request: Snapshot,
                                 transcriptHints: Set<UUID> = []) {
        knownManifests = manifests.sorted { $0.startedAt > $1.startedAt }
        let authorized = Set(knownManifests.map(\.id)), hints = transcriptHints.intersection(authorized)
        pendingHintIDs.formUnion(hints.subtracting(observedHintIDs))
        pendingHintIDs.formIntersection(hints)
        observedHintIDs = hints
        let explicit = knownManifests.filter { request.priorityIDs.contains($0.id) }
        let hinted = knownManifests.filter { pendingHintIDs.contains($0.id) }
        let added = knownManifests.filter { !previousIDs.contains($0.id) }
        var seen = Set<UUID>()
        remaining = (explicit + hinted + added + remaining + knownManifests)
            .filter { authorized.contains($0.id) && seen.insert($0.id).inserted }
        priorityIDs.subtract(request.priorityIDs)
        snapshotRevision = request.revision
        // A new event arriving during detached IO must retain its own revision.
        needsDiscovery = revision != request.revision || !remaining.isEmpty
    }
    mutating func finishRecord(_ id: UUID, issue: String?) throws {
        guard remaining.first?.id == id else { throw GoogleDriveLibraryError.invalidState }
        transcriptIssues[id] = issue
        pendingHintIDs.remove(id)
        remaining.removeFirst()
    }
    mutating func finishSlice(observedRevision: UInt64, at date: Date = Date()) {
        // A source event can arrive while the caller awaits its metadata
        // snapshot, before it takes a transcript-slice revision. An unaccepted
        // snapshot remains work even if that older scan has reached its end.
        needsDiscovery = needsSnapshot || revision != observedRevision || !remaining.isEmpty
        if !hasIssues { issueRetryAt = nil }
        else if !needsDiscovery, issueRetryAt == nil { issueRetryAt = date.addingTimeInterval(60) }
    }
    /// Recheck only failed derived records. Normal recordings with no transcript
    /// do not create an endless historical scan or delay original-audio uploads.
    mutating func retryIssuesIfDue(at date: Date = Date()) {
        guard !needsDiscovery, hasIssues, let due = issueRetryAt, due <= date else { return }
        remaining = knownManifests.filter { transcriptIssues[$0.id] != nil }
        needsDiscovery = !remaining.isEmpty
        issueRetryAt = nil
    }
    mutating func recordOperationFailure(_ message: String, isNetwork: Bool = false, needsCredential: Bool = false) {
        operationError = message
        operationErrorIsNetwork = isNetwork
        operationErrorNeedsCredential = needsCredential; lastFailureAt = Date()
    }
    mutating func clearOperationError() {
        operationError = nil
        operationErrorIsNetwork = false; operationErrorNeedsCredential = false
    }
    /// Filenames are discovery hints, never proof that text is valid or that a
    /// recording belongs to the Drive grant. Snapshot acceptance intersects them
    /// with the ledger's authorized jobs before they can affect ordering.
    static func transcriptHints(fileNames: [String]) -> Set<UUID> {
        Set(fileNames.compactMap { name in
            guard name.count == 41, name.hasSuffix(".json"),
                  let id = UUID(uuidString: String(name.dropLast(5))),
                  name == id.uuidString.lowercased() + ".json" else { return nil }
            return id
        })
    }
    /// Only jobs with already validated, pending derived artifacts get a small
    /// file turn. Ordinary manifests do not jump ahead of their original audio.
    func nextUpload(in jobs: [GoogleDriveLibraryJob], excluding: Set<String> = [],
                    preferred: UploadChoice? = nil,
                    reservations: [UploadChoice] = [], reservationJobs: [GoogleDriveLibraryJob]? = nil,
                    mayReserve: (Int64) -> Bool = { _ in true }) -> UploadChoice? {
        func eligible(_ job: GoogleDriveLibraryJob, _ artifact: GoogleDriveArtifact) -> Bool {
            artifact.verifiedAt == nil && !excluding.contains(job.id.uuidString.lowercased() + "/" + artifact.key)
                && mayReserve(artifact.byteCount)
        }
        // Queue reservations affect selection only; receipt credit remains
        // exclusively in didVerify after the real ledger commit. Candidate
        // filtering must not hide another source's real audio reservation.
        var reservedSmallTurns = smallVerifiedSinceAudio
        for selected in reservations {
            if (reservationJobs ?? jobs).first(where: { $0.id == selected.segmentID })?.artifacts.first(where: { $0.key == selected.artifactKey })?.kind == .audio {
                reservedSmallTurns = 0
            } else if selected.isPrioritySmall { reservedSmallTurns = min(3, reservedSmallTurns + 1) }
        }
        let ordered = jobs.sorted {
            $0.manifest.startedAt == $1.manifest.startedAt
                ? $0.id.uuidString < $1.id.uuidString : $0.manifest.startedAt > $1.manifest.startedAt
        }
        func choice(_ job: GoogleDriveLibraryJob, _ artifact: GoogleDriveArtifact, priority: Bool = false) -> UploadChoice {
            .init(segmentID: job.id, artifactKey: artifact.key, isPrioritySmall: priority)
        }
        let audio = ordered.compactMap { job -> (GoogleDriveLibraryJob, GoogleDriveArtifact)? in
            guard let artifact = job.artifacts.first(where: { $0.kind == .audio && eligible(job, $0) }) else { return nil }
            return (job, artifact)
        }
        let preparedIndex = GoogleDriveAudioTurn.preparedSessionIndex(audio.map { $0.1.uploadURL != nil })
        let audioTurn = preparedIndex.map { audio[$0] }
            ?? audio.first(where: { $0.0.artifacts.contains { $0.kind == .transcriptJSON || $0.kind == .transcriptText } })
            ?? audio.first
        if reservedSmallTurns >= 3, let (job, artifact) = audioTurn {
            // A prepared audio is itself the owed audio turn. New arrivals must
            // not restart its preparation; a small preference can never enter.
            if let preferred, let preparedJob = ordered.first(where: { $0.id == preferred.segmentID }),
               let prepared = preparedJob.artifacts.first(where: { $0.key == preferred.artifactKey
                   && $0.kind == .audio && eligible(preparedJob, $0) }) {
                return choice(preparedJob, prepared)
            }
            return choice(job, artifact)
        }
        if let preferred, let job = ordered.first(where: { $0.id == preferred.segmentID }),
           let artifact = job.artifacts.first(where: { $0.key == preferred.artifactKey && eligible(job, $0) }) {
            return choice(job, artifact, priority: preferred.isPrioritySmall)
        }
        for job in ordered where job.artifacts.contains(where: {
            ($0.kind == .transcriptJSON || $0.kind == .transcriptText) && $0.verifiedAt == nil
        }) {
            for kind in [GoogleDriveArtifact.Kind.manifest, .transcriptJSON, .transcriptText] {
                if let artifact = job.artifacts.first(where: { $0.kind == kind && eligible(job, $0) }) {
                    return choice(job, artifact, priority: true)
                }
            }
        }
        for job in ordered {
            if let artifact = job.artifacts.first(where: { eligible(job, $0) }) {
                if artifact.kind == .audio, let (audioJob, audioArtifact) = audioTurn { return choice(audioJob, audioArtifact) }
                return choice(job, artifact)
            }
        }
        return nil
    }
    /// Called only after the original ledger receipt has been durably recorded.
    /// Failed/cancelled attempts do not spend a turn or reset the audio debt.
    mutating func didVerify(_ selected: UploadChoice, in jobs: [GoogleDriveLibraryJob]) throws {
        guard let artifact = jobs.first(where: { $0.id == selected.segmentID })?.artifacts
            .first(where: { $0.key == selected.artifactKey }), artifact.verifiedAt != nil else {
            throw GoogleDriveLibraryError.invalidState
        }
        let receiptKey = selected.segmentID.uuidString + "/" + selected.artifactKey
        guard creditedReceipts.insert(receiptKey).inserted else { return }
        // A newly verified remote receipt supersedes an earlier transport
        // failure. Replaying an old receipt cannot hide a subsequent failure;
        // local operation errors and independent transcript issues stay visible.
        if operationErrorIsNetwork { clearOperationError() }
        if artifact.kind == .audio { smallVerifiedSinceAudio = 0 }
        else if selected.isPrioritySmall { smallVerifiedSinceAudio = min(3, smallVerifiedSinceAudio + 1) }
    }
    func phase(hasPendingFiles: Bool) -> Phase {
        if needsDiscovery { return .discovering }
        if hasPendingFiles { return .uploading }
        if hasIssues { return .transcriptIssues(transcriptIssues.count) }
        return .complete
    }
    /// Clear any remaining old operation error after a successful full discovery
    /// pass with no pending artifacts. A transport error may clear earlier after
    /// a newly verified remote receipt; derived-file issues remain independent.
    mutating func finishSuccessfulRound(hasPendingFiles: Bool) -> Phase {
        if !needsDiscovery && !hasPendingFiles { clearOperationError() }
        return phase(hasPendingFiles: hasPendingFiles)
    }
    static func inspectTranscript(repository: TranscriptRepository, manifest: SegmentManifest) -> TranscriptInspection {
        let result = repository.availableTranscripts(for: [manifest])
        return .init(transcript: result.transcripts[manifest.id], issue: result.issues[manifest.id])
    }
}


/// Fixed diagnostic phases only: never URLs, recording IDs or server content.
enum GoogleDrivePreflightPhase: String, Codable, Sendable {
    // Keep the broad legacy account label for historical evidence; the current
    // client emits token_access and account_get around their separate awaits.
    case idle, recovery, snapshot, transcriptScan = "transcript_scan", account
    case tokenAccess = "token_access", accountGet = "account_get"
    case allocate, fingerprint, folder, fileLookup = "file_lookup"
    case sessionQuery = "session_query", sessionCreate = "session_create"
    case nativeStage = "native_stage", strictVerify = "strict_verify"
}

/// Fixed, bounded control-plane observations. This is not an upload receipt:
/// no credential, account, URL, source identity, file name or content fits here.
struct GoogleDriveWorkerReport: Codable, Sendable {
    enum Event: String, Codable, Sendable {
        case initialized, scheduleRequested = "schedule_requested"
        case notConfigured = "not_configured", ledgerUnavailable = "ledger_unavailable"
        case disabled, credentialUnavailable = "credential_unavailable", handoffPending = "handoff_pending"
        case queueUnavailable = "queue_unavailable", waitingNative = "waiting_native"
        case waitingSelection = "waiting_selection", waitingWorker = "waiting_worker", waitingRetry = "waiting_retry"
        case roundStarted = "round_started", roundFinished = "round_finished", leaseExpired = "lease_expired"
        case sourceAdmitted = "source_metadata_admitted", networkDeferred = "network_deferred"
        case phaseChanged = "phase_changed", callback, cancelled, interrupted, roundFailed = "round_failed"
        case remoteVerified = "remote_verified", nativeRegistered = "native_registered", queueRecovered = "queue_recovered"
        case requestObserved = "request_observed", requestCompleted = "request_completed"
    }
    struct Failure: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case network, http, needsSignIn = "needs_sign_in", credentials, localState = "local_state", other }
        let kind: Kind
        let code: Int?
        var apiReason: GoogleDriveAPIReason? = nil
        init(_ error: Error) {
            if (error as NSError).domain == NSURLErrorDomain {
                kind = .network; code = (error as NSError).code
            } else if let value = error as? GoogleDriveError {
                switch value {
                case .http(let status): kind = .http; code = status
                case .apiFailure(let status, let reason): kind = .http; code = status; apiReason = reason
                case .needsSignIn: kind = .needsSignIn; code = nil
                case .credentials: kind = .credentials; code = nil
                default: kind = .other; code = nil
                }
            } else { kind = error is GoogleDriveLibraryError ? .localState : .other; code = nil }
        }
    }
    struct Observation: Codable, Sendable {
        let atMS: Int64
        let event: Event
        let phase: GoogleDrivePreflightPhase
        let roundSequence: UInt64
        let foreground: Bool
        let roundActive: Bool
        let remainingMS: Int
        let pendingCount: Int
        let nativeCount: Int
        let readbackCount: Int
        // Absent in legacy schema-1 reports. Never infer these from a nearby
        // failure, the current round, or the report's final systemGranted flag.
        var execution: Execution? = nil
        var cancellationReason: CancellationReason? = nil
        // Exact request facts are supplied by transport callbacks, never inferred
        // from the worker's current selection when the callback arrives.
        var uploadCorrelation: GoogleDriveUploadCorrelation? = nil
        var requestID: UUID? = nil
        var origin: GoogleDriveTransportDiagnostic.Origin? = nil
        var transportPhase: GoogleDriveTransportDiagnostic.Phase? = nil
        var endpoint: GoogleDriveTransportDiagnostic.Endpoint? = nil
        var method: GoogleDriveTransportDiagnostic.Method? = nil
        var httpStatus: Int? = nil
        var errorCode: Int? = nil
        var completionOutcome: GoogleDriveRequestCompletion.Outcome? = nil
    }
    enum CancellationReason: String, Codable, Sendable {
        case unknown, stopRequested = "stop_requested", taskCancellationObserved = "task_cancellation_observed"
        case parentCancellationObserved = "parent_cancellation_observed", generationChanged = "generation_changed"
        case libraryDisabled = "library_disabled", ledgerUnavailable = "ledger_unavailable", leaseUnavailable = "lease_unavailable"
        case leaseCheckFailed = "lease_check_failed", deadlineReached = "deadline_reached"
        case leaseExpirationObserved = "lease_expiration_observed"
    }
    struct Execution: Codable, Equatable, Sendable {
        enum LeaseState: String, Codable, Sendable { case active, checkFailed = "check_failed", absent, finished }
        enum Kind: String, Codable, Sendable { case normal, metadataRecovery = "metadata_recovery" }
        let id: UUID
        let roundSequence: UInt64
        let systemGranted: Bool
        let parentDeadlineUptimeMS: Int64?
        var leaseDeadlineUptimeMS: Int64
        var leaseState: LeaseState
        // Missing in older reports; never infer the kind of historical rounds.
        var kind: Kind? = nil
        // P-60: absent means legacy/unknown, never an inferred zero.
        var progressedItems: Int? = nil
        var firstProgressPhase: GoogleDrivePreflightPhase? = nil
        var startedAtMS: Int64? = nil
        var finishedAtMS: Int64? = nil
    }
    struct FailureContext: Codable, Equatable, Sendable {
        let atMS: Int64
        let reportSequence: UInt64
        let phase: GoogleDrivePreflightPhase
        let executionID: UUID?
        let roundSequence: UInt64?
        // No requestID: this coordinator does not have an exact HTTP binding.
    }
    let schemaVersion: Int
    let processRunID: UUID
    let build: String
    let generatedAtMS: Int64
    let sequence: UInt64
    let enabled: Bool
    let ledgerAvailable: Bool
    let sourceSnapshotPending: Bool
    let discoveryComplete: Bool
    let discoveryRemaining: Int
    let authorizedSourceCount: Int
    let savedAudioCount: Int
    let pendingArtifactCount: Int
    let nativeCount: Int
    let readbackCount: Int
    let itemRetryCount: Int
    let retryAfterMS: Int64?
    let failureCount: Int
    let systemGranted: Bool
    let lastFailure: Failure?
    let lastFailurePhase: GoogleDrivePreflightPhase?
    let observations: [Observation]
    var diagnosticsRevision: Int? = nil
    var execution: Execution? = nil
    var lastFailureContext: FailureContext? = nil

    static let maximumBytes = 16_384
    static let maximumObservations = 8
    func encoded() throws -> Data {
        let bytes = try TransportCodec.encode(self)
        guard [1, 2].contains(schemaVersion), build.utf8.count <= 32, observations.count <= Self.maximumObservations,
              observations.allSatisfy({ $0.uploadCorrelation?.isValid != false }),
              !observations.isEmpty, bytes.count <= Self.maximumBytes else { throw GoogleDriveLibraryError.invalidState }
        return bytes
    }
}

/// Attribution only. No scheduling, cancellation, credentials or receipts are
/// changed here. A retained failure stays bound to its original execution even
/// after the bounded observation ring has moved on to a later round.
struct GoogleDriveWorkerDiagnosticState: Sendable {
    private var generation: UInt64?
    private(set) var execution: GoogleDriveWorkerReport.Execution?
    private(set) var lastFailure: GoogleDriveWorkerReport.Failure?
    private(set) var lastFailurePhase: GoogleDrivePreflightPhase?
    private(set) var lastFailureContext: GoogleDriveWorkerReport.FailureContext?
    private(set) var cancellationReason: GoogleDriveWorkerReport.CancellationReason?

    mutating func begin(id: UUID, roundSequence: UInt64, systemGranted: Bool,
                        parentDeadline: TimeInterval?, leaseDeadline: TimeInterval, generation: UInt64? = nil,
                        kind: GoogleDriveWorkerReport.Execution.Kind = .normal) {
        self.generation = generation
        execution = .init(id: id, roundSequence: roundSequence, systemGranted: systemGranted,
            parentDeadlineUptimeMS: parentDeadline.map(Self.uptimeMS), leaseDeadlineUptimeMS: Self.uptimeMS(leaseDeadline), leaseState: .active, kind: kind, progressedItems: 0,
            startedAtMS: Int64((Date().timeIntervalSince1970 * 1_000).rounded(.towardZero)))
        cancellationReason = nil
    }
    mutating func didProgress(phase: GoogleDrivePreflightPhase) {
        guard var value = execution, phase == .strictVerify else { return }
        value.progressedItems = (value.progressedItems ?? 0) + 1
        if value.firstProgressPhase == nil { value.firstProgressPhase = phase }
        execution = value
    }
    func matches(_ id: UUID) -> Bool { execution?.id == id }
    mutating func updateLeaseDeadline(_ deadline: TimeInterval) { execution?.leaseDeadlineUptimeMS = Self.uptimeMS(deadline) }
    mutating func noteCancellation(_ reason: GoogleDriveWorkerReport.CancellationReason, generation: UInt64? = nil) {
        guard execution != nil, generation == nil || self.generation == generation else { return }
        // A later catch or delayed expiry callback must not erase the stronger,
        // actually observed lease-expiration/deadline signal.
        if cancellationReason == .leaseExpirationObserved { return }
        if reason == .leaseExpirationObserved || cancellationReason == nil || cancellationReason == .unknown {
            cancellationReason = reason
        }
    }
    mutating func failed(_ error: Error, phase: GoogleDrivePreflightPhase, atMS: Int64, reportSequence: UInt64) {
        lastFailure = .init(error); lastFailurePhase = phase
        lastFailureContext = .init(atMS: atMS, reportSequence: reportSequence, phase: phase,
            executionID: execution?.id, roundSequence: execution?.roundSequence)
    }
    mutating func clearFailure() { lastFailure = nil; lastFailurePhase = nil; lastFailureContext = nil }
    func snapshot(leasePresent: Bool, leaseCheckSucceeded: Bool, finished: Bool = false, atMS: Int64? = nil) -> GoogleDriveWorkerReport.Execution? {
        guard var value = execution else { return nil }
        value.leaseState = finished ? .finished : (!leasePresent ? .absent : (leaseCheckSucceeded ? .active : .checkFailed))
        if finished { value.finishedAtMS = atMS ?? Int64((Date().timeIntervalSince1970 * 1_000).rounded(.towardZero)) }
        return value
    }
    mutating func finish(id: UUID) {
        guard matches(id) else { return }
        execution = nil; cancellationReason = nil; generation = nil
    }
    static func uptimeMS(_ seconds: TimeInterval) -> Int64 {
        // Uptime is observed locally; never convert it to a wall-clock event.
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int64.max) / 1_000 else { return 0 }
        return Int64((seconds * 1_000).rounded(.towardZero))
    }
}

/// Independent diagnostic publication health, never an upload receipt. This
/// process-local record cannot promise freshness when the process is suspended
/// or all filesystem writes fail; the fixed OSLog event is an independent path.
struct GoogleDriveWorkerWriterHealth: Codable, Sendable {
    struct Failure: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case metadata, cocoa, posix, encoding, syncEvidence = "sync_evidence", other }
        let kind: Kind
        let code: Int?
        init(_ error: Error) {
            if let value = error as? GoogleDriveMetadataIOError { kind = .metadata; code = Int(value.code) }
            else if let value = error as? SyncEvidenceArchive.Failure {
                kind = .syncEvidence
                // Stable diagnostic codes, independent of Swift's Error bridge.
                switch value { case .invalid: code = 1; case .capacity: code = 2; case .unavailable: code = 3 }
            }
            else if error is EncodingError { kind = .encoding; code = nil }
            else {
                let value = error as NSError
                kind = value.domain == NSCocoaErrorDomain ? .cocoa : (value.domain == NSPOSIXErrorDomain ? .posix : .other)
                code = kind == .other || Int64(value.code) < Int64(Int32.min) || Int64(value.code) > Int64(Int32.max) ? nil : value.code
            }
        }
    }
    /// One fixed-size record per additional diagnostic destination. Retaining
    /// both failure and publication observations makes later recovery visible.
    struct WriteHealth: Codable, Sendable {
        var attemptCount: UInt64 = 0
        var publishedCount: UInt64 = 0
        var failureCount: UInt64 = 0
        var lastAttemptAtMS: Int64?
        var lastAttemptSequence: UInt64?
        var lastPublishedAtMS: Int64?
        var lastPublishedSequence: UInt64?
        var lastFailureAtMS: Int64?
        var lastFailureSequence: UInt64?
        var lastFailure: Failure?

        mutating func record(sequence: UInt64, atMS: Int64, failure: Failure?) {
            GoogleDriveWorkerWriterHealth.increment(&attemptCount)
            lastAttemptAtMS = atMS; lastAttemptSequence = sequence
            if let failure {
                GoogleDriveWorkerWriterHealth.increment(&failureCount)
                lastFailureAtMS = atMS; lastFailureSequence = sequence; lastFailure = failure
            } else {
                GoogleDriveWorkerWriterHealth.increment(&publishedCount)
                lastPublishedAtMS = atMS; lastPublishedSequence = sequence
            }
        }
    }
    let schemaVersion: Int
    let diagnosticsRevision: Int
    let processRunID: UUID
    let build: String
    var generatedAtMS: Int64
    var attemptCount: UInt64 = 0
    var publishedCount: UInt64 = 0
    var failureCount: UInt64 = 0
    var healthWriteFailureCount: UInt64 = 0
    var coalescedCount: UInt64 = 0
    var lastAttemptAtMS: Int64?
    var lastAttemptSequence: UInt64?
    var lastPublishedAtMS: Int64?
    var lastPublishedSequence: UInt64?
    var lastFailureAtMS: Int64?
    var lastFailureSequence: UInt64?
    var lastFailure: Failure?
    var lastHealthFailureAtMS: Int64?
    var lastHealthFailureSequence: UInt64?
    var lastHealthFailure: Failure?
    // Optional for old schema-1 health files. There is no unbounded key space.
    var transportHistoryWrites: WriteHealth? = nil
    var syncEvidenceWrites: WriteHealth? = nil
    static let maximumBytes = 4_096
    static func increment(_ value: inout UInt64) { if value < .max { value += 1 } }
    func encoded() throws -> Data {
        let bytes = try TransportCodec.encode(self)
        guard bytes.count <= Self.maximumBytes else { throw GoogleDriveLibraryError.invalidState }
        return bytes
    }
}

/// Pure validation of the complete bounded worker/status-health pair. This
/// reads only the two diagnostic JSON leaves and never repairs either source.
enum GoogleDriveWorkerVerifiedObservation {
    static func source(file: URL, expectedProcessRunID: UUID, expectedBuild: String,
                       expectedHealthBytes: Data? = nil,
                       nowMS: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)) throws -> VerifiedObservationSource {
        let healthFile = file.deletingLastPathComponent().appendingPathComponent("worker-health.json")
        let reportBytes = try GoogleDriveMetadataIO.read(file, maximum: GoogleDriveWorkerReport.maximumBytes)
        let healthBytes = try GoogleDriveMetadataIO.read(healthFile, maximum: GoogleDriveWorkerWriterHealth.maximumBytes)
        let report = try TransportCodec.decode(GoogleDriveWorkerReport.self, from: reportBytes)
        let health = try TransportCodec.decode(GoogleDriveWorkerWriterHealth.self, from: healthBytes)
        try validate(report: report, health: health, nowMS: nowMS)
        guard report.processRunID == expectedProcessRunID, report.build == expectedBuild,
              expectedHealthBytes.map({ $0 == healthBytes }) ?? true,
              try GoogleDriveMetadataIO.read(file, maximum: GoogleDriveWorkerReport.maximumBytes) == reportBytes,
              try GoogleDriveMetadataIO.read(healthFile, maximum: GoogleDriveWorkerWriterHealth.maximumBytes) == healthBytes
        else { throw GoogleDriveLibraryError.invalidState }
        return .init(sourceGeneratedAtMS: max(report.generatedAtMS, health.generatedAtMS),
            identity: ["processRunID": report.processRunID.uuidString.lowercased(), "sequence": String(report.sequence),
                       "lastPublishedSequence": String(health.lastPublishedSequence!)],
            files: [.init(name: "worker-status.json", bytes: reportBytes), .init(name: "worker-health.json", bytes: healthBytes)],
            snapshotFiles: ["worker-status.json": reportBytes, "worker-health.json": healthBytes])
    }

    static func validate(report r: GoogleDriveWorkerReport, health h: GoogleDriveWorkerWriterHealth, nowMS: Int64) throws {
        func require(_ condition: Bool) throws { if !condition { throw GoogleDriveLibraryError.invalidState } }
        func time(_ value: Int64) -> Bool { value > 0 && value <= nowMS }
        func count(_ value: Int) -> Bool { value >= 0 && value <= 1_000_000 }
        func code(_ value: Int?) -> Bool { value.map { $0 >= Int(Int32.min) && $0 <= Int(Int32.max) } ?? true }
        func failure(_ value: GoogleDriveWorkerReport.Failure) -> Bool {
            switch value.kind {
            case .http: return value.code.map { (100...599).contains($0) } == true
            case .network: return value.code != nil && code(value.code)
            case .needsSignIn, .credentials, .localState, .other: return value.code == nil
            }
        }
        func execution(_ e: GoogleDriveWorkerReport.Execution, at: Int64) -> Bool {
            guard e.roundSequence > 0, e.leaseDeadlineUptimeMS >= 0,
                  e.parentDeadlineUptimeMS.map({ $0 >= 0 }) ?? true,
                  e.startedAtMS.map({ time($0) && $0 <= at }) ?? true,
                  e.finishedAtMS.map({ time($0) && $0 <= at && e.leaseState == .finished }) ?? true,
                  e.progressedItems.map(count) ?? true else { return false }
            if let start = e.startedAtMS, let finish = e.finishedAtMS, finish < start { return false }
            if let progress = e.progressedItems {
                guard progress == 0 ? e.firstProgressPhase == nil : e.firstProgressPhase == .strictVerify else { return false }
            } else if e.firstProgressPhase != nil { return false }
            return true
        }
        try require([1, 2].contains(r.schemaVersion) && r.sequence > 0 && time(r.generatedAtMS))
        try require(!r.build.isEmpty && r.build.utf8.count <= 32 && r.build.utf8.allSatisfy { (48...57).contains($0) })
        let supportedPair = (r.schemaVersion == 1 && r.diagnosticsRevision == 2 && h.schemaVersion == 1 && h.diagnosticsRevision == 2)
            || (r.schemaVersion == 1 && r.diagnosticsRevision == 3 && h.schemaVersion == 1 && h.diagnosticsRevision == 3)
            || (r.schemaVersion == 2 && [4, 5].contains(r.diagnosticsRevision ?? 0) && h.schemaVersion == 1 && h.diagnosticsRevision == 3)
        try require(supportedPair)
        try require([r.discoveryRemaining, r.authorizedSourceCount, r.savedAudioCount, r.pendingArtifactCount,
            r.nativeCount, r.readbackCount, r.itemRetryCount, r.failureCount].allSatisfy(count))
        try require(r.savedAudioCount <= r.authorizedSourceCount && (r.retryAfterMS.map { $0 > 0 } ?? true))
        try require(!r.discoveryComplete || (r.ledgerAvailable && !r.sourceSnapshotPending && r.discoveryRemaining == 0))
        try require(!r.observations.isEmpty && r.observations.count <= GoogleDriveWorkerReport.maximumObservations
            && UInt64(r.observations.count) <= r.sequence)
        try require((r.lastFailure == nil) == (r.lastFailurePhase == nil))
        if let value = r.lastFailure { try require(failure(value)) }
        if let context = r.lastFailureContext {
            try require(r.lastFailure != nil && context.phase == r.lastFailurePhase && time(context.atMS)
                && context.atMS <= r.generatedAtMS && context.reportSequence > 0 && context.reportSequence <= r.sequence
                && ((context.executionID == nil) == (context.roundSequence == nil))
                && (context.roundSequence.map { $0 > 0 } ?? true))
        } else if (r.diagnosticsRevision ?? 0) >= 2 { try require(r.lastFailure == nil) }
        var previousAt: Int64 = 0
        var retainedExecutions: [UUID: GoogleDriveWorkerReport.Execution] = [:]
        for o in r.observations {
            try require(time(o.atMS) && o.atMS >= previousAt && o.atMS <= r.generatedAtMS)
            previousAt = o.atMS
            try require((0...120_000).contains(o.remainingMS) && [o.pendingCount, o.nativeCount, o.readbackCount].allSatisfy(count))
            try require(o.roundActive || o.remainingMS == 0)
            if let e = o.execution {
                try require(execution(e, at: o.atMS) && e.roundSequence == o.roundSequence)
                if (r.diagnosticsRevision ?? 0) >= 5 {
                    try require(e.progressedItems != nil && e.startedAtMS != nil)
                    if let old = retainedExecutions[e.id] {
                        try require(old.roundSequence == e.roundSequence && old.systemGranted == e.systemGranted
                            && old.startedAtMS == e.startedAtMS && old.progressedItems! <= e.progressedItems!
                            && (old.firstProgressPhase == nil || old.firstProgressPhase == e.firstProgressPhase))
                    }
                    retainedExecutions[e.id] = e
                }
            }
            try require(o.uploadCorrelation?.isValid != false && code(o.errorCode)
                && (o.httpStatus.map { (100...599).contains($0) } ?? true))
            if o.transportPhase != nil || o.endpoint != nil || o.method != nil || o.httpStatus != nil || o.errorCode != nil {
                try require(o.event == .requestObserved && o.transportPhase != nil && o.endpoint != nil && o.method != nil)
            }
            if o.event == .requestCompleted || o.completionOutcome != nil {
                try require(o.event == .requestCompleted && o.completionOutcome != nil && o.requestID != nil && o.origin != nil)
            }
            if o.requestID != nil { try require(o.event == .requestObserved || o.event == .requestCompleted) }
            if o.cancellationReason != nil { try require([.cancelled, .roundFinished, .leaseExpired].contains(o.event)) }
        }
        let last = r.observations.last!
        try require(last.atMS == r.generatedAtMS && last.pendingCount == r.pendingArtifactCount
            && last.nativeCount == r.nativeCount && last.readbackCount == r.readbackCount
            && last.execution == r.execution && r.systemGranted == (r.execution?.systemGranted ?? false))
        if let e = r.execution { try require(execution(e, at: r.generatedAtMS)) }

        func writerFailure(_ value: GoogleDriveWorkerWriterHealth.Failure) -> Bool {
            guard code(value.code) else { return false }
            switch value.kind {
            case .syncEvidence: return value.code.map { (1...3).contains($0) } == true
            case .metadata, .cocoa, .posix: return value.code != nil
            case .encoding, .other: return value.code == nil
            }
        }
        func pair(_ at: Int64?, _ sequence: UInt64?, present: Bool, limitAt: Int64, limitSequence: UInt64?) -> Bool {
            guard (at != nil) == present, (sequence != nil) == present else { return false }
            guard let at, let sequence else { return true }
            return time(at) && at <= limitAt && (limitSequence.map { sequence <= $0 } ?? true)
        }
        func writes(_ w: GoogleDriveWorkerWriterHealth.WriteHealth) -> Bool {
            let (sum, overflow) = w.publishedCount.addingReportingOverflow(w.failureCount)
            guard w.attemptCount == (overflow ? .max : sum),
                  pair(w.lastAttemptAtMS, w.lastAttemptSequence, present: w.attemptCount > 0, limitAt: h.generatedAtMS, limitSequence: nil),
                  pair(w.lastPublishedAtMS, w.lastPublishedSequence, present: w.publishedCount > 0,
                       limitAt: h.generatedAtMS, limitSequence: w.lastAttemptSequence),
                  pair(w.lastFailureAtMS, w.lastFailureSequence, present: w.failureCount > 0,
                       limitAt: h.generatedAtMS, limitSequence: w.lastAttemptSequence),
                  (w.lastFailure != nil) == (w.failureCount > 0), w.lastFailure.map(writerFailure) ?? true else { return false }
            return true
        }
        try require(h.schemaVersion == 1 && (1...3).contains(h.diagnosticsRevision)
            && h.processRunID == r.processRunID && h.build == r.build && time(h.generatedAtMS) && h.generatedAtMS >= r.generatedAtMS)
        var reportWrites = GoogleDriveWorkerWriterHealth.WriteHealth()
        reportWrites.attemptCount = h.attemptCount; reportWrites.publishedCount = h.publishedCount; reportWrites.failureCount = h.failureCount
        reportWrites.lastAttemptAtMS = h.lastAttemptAtMS; reportWrites.lastAttemptSequence = h.lastAttemptSequence
        reportWrites.lastPublishedAtMS = h.lastPublishedAtMS; reportWrites.lastPublishedSequence = h.lastPublishedSequence
        reportWrites.lastFailureAtMS = h.lastFailureAtMS; reportWrites.lastFailureSequence = h.lastFailureSequence; reportWrites.lastFailure = h.lastFailure
        try require(writes(reportWrites) && h.lastPublishedSequence == r.sequence
            && h.lastPublishedAtMS.map { $0 >= r.generatedAtMS } == true)
        if let failed = h.lastFailureSequence {
            try require(failed <= r.sequence && (failed != r.sequence || h.lastFailureAtMS! <= h.lastPublishedAtMS!))
        }
        if let failed = h.lastHealthFailureSequence { try require(failed <= r.sequence) }
        if let w = h.transportHistoryWrites { try require(writes(w)) }
        if let w = h.syncEvidenceWrites { try require(writes(w)) }
        let largestSequence = max(h.lastAttemptSequence ?? 0, max(h.transportHistoryWrites?.lastAttemptSequence ?? 0,
            h.syncEvidenceWrites?.lastAttemptSequence ?? 0))
        try require(pair(h.lastHealthFailureAtMS, h.lastHealthFailureSequence, present: h.healthWriteFailureCount > 0,
                         limitAt: h.generatedAtMS, limitSequence: largestSequence)
            && (h.lastHealthFailure != nil) == (h.healthWriteFailureCount > 0)
            && (h.lastHealthFailure.map(writerFailure) ?? true))
    }
}

/// Coalesced serial diagnostic IO. Business work never waits for this queue.
/// Failed health writes are logged once per attempt and are not recursively
/// retried; the next report or write outcome can persist the cumulative failure.
final class GoogleDriveWorkerDiagnosticsWriter: @unchecked Sendable {
    enum Destination: String, Sendable {
        case report, health, transportHistory = "transport_history", syncEvidence = "sync_evidence"
    }
    enum ExternalDestination: String, Sendable {
        case transportHistory = "transport_history", syncEvidence = "sync_evidence"
        var logDestination: Destination {
            switch self { case .transportHistory: return .transportHistory; case .syncEvidence: return .syncEvidence }
        }
    }
    typealias Write = @Sendable (Data, URL) throws -> Void
    typealias FailureLog = @Sendable (Destination, UInt64, GoogleDriveWorkerWriterHealth.Failure) -> Void
    private static let logger = Logger(subsystem: "record-for-agent", category: "drive-worker-diagnostics")
    private let file: URL
    private let healthFile: URL
    private let queue: DispatchQueue
    private let write: Write
    private let failureLog: FailureLog
    private let observation: VerifiedObservationPublisher
    private let processRunID: UUID
    private let build: String
    private let lock = NSLock()
    private var pending: GoogleDriveWorkerReport?
    private var running = false
    private var healthPending = false
    private var observationPending = false
    private var invalidationPending = false
    private var observationThrottleFeedback: (@Sendable (Int) -> Void)?
    private var observationSourceChanged = false
    // Protected by lock, including while the IO queue writes an older snapshot.
    // External writes can update this bounded value without waiting for disk IO.
    private var health: GoogleDriveWorkerWriterHealth

    init(file: URL, processRunID: UUID, build: String,
         queue: DispatchQueue = DispatchQueue(label: "record-for-agent.drive-worker-status", qos: .utility),
         write: @escaping Write, failureLog: @escaping FailureLog = { GoogleDriveWorkerDiagnosticsWriter.logFailure($0, $1, $2) }) {
        self.file = file; healthFile = file.deletingLastPathComponent().appendingPathComponent("worker-health.json")
        self.queue = queue; self.write = write; self.failureLog = failureLog
        self.processRunID = processRunID; self.build = String(build.prefix(32))
        observation = VerifiedObservationPublisher(directory: file.deletingLastPathComponent(),
            reportKind: "google_drive_worker", build: String(build.prefix(32)), processRunID: processRunID)
        health = .init(schemaVersion: 1, diagnosticsRevision: 3,
            processRunID: processRunID, build: String(build.prefix(32)), generatedAtMS: Self.nowMS())
    }
    /// No source publication, business wake or health accounting is caused here.
    func observeVerifiedMetadata(onThrottle: (@Sendable (Int) -> Void)? = nil) {
        lock.lock(); observationPending = true
        if let onThrottle { observationThrottleFeedback = onThrottle }
        let shouldStart = !running; running = true; lock.unlock()
        if shouldStart { queue.async { [self] in drain() } }
    }
    func submit(_ report: GoogleDriveWorkerReport) {
        lock.lock()
        if pending != nil { GoogleDriveWorkerWriterHealth.increment(&health.coalescedCount) }
        pending = report
        guard !running else { lock.unlock(); return }
        running = true; lock.unlock()
        queue.async { [self] in drain() }
    }
    /// Preserve the caller's best-effort persistence behavior, but never discard
    /// its outcome. Sequence references a worker observation, not an HTTP request.
    /// Only the original write runs here; health IO remains coalesced and async.
    @discardableResult
    func recordWrite(_ destination: ExternalDestination, sequence: UInt64, _ operation: () throws -> Void) -> Bool {
        let failure: GoogleDriveWorkerWriterHealth.Failure?
        do { try operation(); failure = nil }
        catch { failure = .init(error) }
        let atMS = Self.nowMS()
        lock.lock()
        switch destination {
        case .transportHistory:
            var value = health.transportHistoryWrites ?? .init()
            value.record(sequence: sequence, atMS: atMS, failure: failure); health.transportHistoryWrites = value
        case .syncEvidence:
            var value = health.syncEvidenceWrites ?? .init()
            value.record(sequence: sequence, atMS: atMS, failure: failure); health.syncEvidenceWrites = value
        }
        healthPending = true
        if failure != nil, (UInt64(build) ?? 0) >= 87 { invalidationPending = true }
        let shouldStart = !running
        running = true; lock.unlock()
        if let failure { failureLog(destination.logDestination, sequence, failure) }
        if shouldStart { queue.async { [self] in drain() } }
        return failure == nil
    }
    private func drain() {
        while true {
            lock.lock()
            // External failures only set a flag under the short state lock.
            // Persist it on this IO queue before any subsequent observation.
            if invalidationPending {
                invalidationPending = false; lock.unlock()
                observation.invalidate()
                continue
            }
            guard pending != nil || healthPending else {
                guard observationPending else { running = false; lock.unlock(); return }
                observationPending = false
                let sourceDidChange = observationSourceChanged; observationSourceChanged = false
                let onThrottle = observationThrottleFeedback; observationThrottleFeedback = nil
                let expectedHealth = health
                lock.unlock()
                _ = observation.observe(sourceDidChange: sourceDidChange, onThrottle: onThrottle) {
                    try GoogleDriveWorkerVerifiedObservation.source(file: file,
                        expectedProcessRunID: processRunID, expectedBuild: build,
                        expectedHealthBytes: expectedHealth.encoded())
                }
                // A failure received while publishing must be fenced even when
                // there is no further source work to wake this writer.
                continue
            }
            let report = pending
            pending = nil; healthPending = false; lock.unlock()
            if let report {
                lock.lock()
                GoogleDriveWorkerWriterHealth.increment(&health.attemptCount)
                health.lastAttemptAtMS = Self.nowMS(); health.lastAttemptSequence = report.sequence
                lock.unlock()
                let failure: GoogleDriveWorkerWriterHealth.Failure?
                do { try write(report.encoded(), file); failure = nil }
                catch { failure = .init(error) }
                lock.lock()
                if let failure {
                    GoogleDriveWorkerWriterHealth.increment(&health.failureCount)
                    health.lastFailureAtMS = Self.nowMS(); health.lastFailureSequence = report.sequence; health.lastFailure = failure
                } else {
                    GoogleDriveWorkerWriterHealth.increment(&health.publishedCount)
                    health.lastPublishedAtMS = Self.nowMS(); health.lastPublishedSequence = report.sequence
                }
                lock.unlock()
                if let failure {
                    if (UInt64(build) ?? 0) >= 87 { observation.invalidate() }
                    failureLog(.report, report.sequence, failure)
                }
            }
            lock.lock()
            health.generatedAtMS = Self.nowMS()
            let value = health
            // This snapshot already includes every external result observed
            // during the report write; only a newer result needs another pass.
            healthPending = false
            lock.unlock()
            // Health-only publication uses the greatest retained observation
            // reference. It does not invent a report publication.
            let sequence = report?.sequence ?? max(value.transportHistoryWrites?.lastAttemptSequence ?? 0,
                value.syncEvidenceWrites?.lastAttemptSequence ?? 0)
            do {
                try write(value.encoded(), healthFile)
                lock.lock(); observationPending = true; observationSourceChanged = true; lock.unlock()
            }
            catch {
                let failure = GoogleDriveWorkerWriterHealth.Failure(error)
                lock.lock()
                GoogleDriveWorkerWriterHealth.increment(&health.healthWriteFailureCount)
                health.lastHealthFailureAtMS = Self.nowMS(); health.lastHealthFailureSequence = sequence; health.lastHealthFailure = failure
                observationPending = true; observationSourceChanged = true
                lock.unlock()
                if (UInt64(build) ?? 0) >= 87 { observation.invalidate() }
                failureLog(.health, sequence, failure)
            }
        }
    }
    private static func nowMS() -> Int64 { Int64((Date().timeIntervalSince1970 * 1_000).rounded(.towardZero)) }
    private static func logFailure(_ destination: Destination, _ sequence: UInt64, _ failure: GoogleDriveWorkerWriterHealth.Failure) {
        // Fixed enums/numeric codes only, never localized descriptions or URLs.
        logger.error("diagnostic_write_failed destination=\(destination.rawValue, privacy: .public) sequence=\(sequence, privacy: .public) kind=\(failure.kind.rawValue, privacy: .public) code=\(failure.code ?? 0, privacy: .public)")
    }
}

/// A local scheduling choice, not a cache of remote authorization evidence.
/// Only nil-to-current allocation progress can be adopted from the authoritative
/// ledger. A previously non-nil file/session identity is never replaced here.
struct GoogleDrivePreflightPin: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let libraryID: UUID
    let accountID: String
    let folderID: String
    let authorizedAt: Date
    let recordingScope: GoogleDriveRecordingScope
    let manifest: SegmentManifest
    var artifact: GoogleDriveArtifact
    let isPrioritySmall: Bool

    init(ledger: GoogleDriveLibraryLedger, selected: GoogleDriveSyncProgress.UploadChoice) throws {
        try ledger.validate()
        guard ledger.enabled, !ledger.revokedLocally, let accountID = ledger.accountID,
              let folderID = ledger.folderID, let authorizedAt = ledger.authorizedAt,
              let scope = ledger.recordingScope,
              let job = ledger.jobs.first(where: { $0.id == selected.segmentID }),
              let artifact = job.artifacts.first(where: { $0.key == selected.artifactKey && $0.verifiedAt == nil })
        else { throw GoogleDriveLibraryError.notAuthorized }
        schemaVersion = 1; libraryID = ledger.libraryID; self.accountID = accountID
        self.folderID = folderID; self.authorizedAt = authorizedAt; recordingScope = scope
        manifest = job.manifest; self.artifact = artifact; isPrioritySmall = selected.isPrioritySmall
        try validate()
    }
    var choice: GoogleDriveSyncProgress.UploadChoice {
        .init(segmentID: manifest.id, artifactKey: artifact.key, isPrioritySmall: isPrioritySmall)
    }
    func validate() throws {
        guard schemaVersion == 1, !accountID.isEmpty, accountID.utf8.count <= 256,
              GoogleDriveLibraryLedger.validFileID(folderID), authorizedAt.timeIntervalSince1970.isFinite,
              artifact.verifiedAt == nil, artifact.byteCount > 0, artifact.byteCount <= 130 * 1_024 * 1_024,
              artifact.sha256.utf8.count == 64,
              artifact.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              artifact.fileID.map(GoogleDriveLibraryLedger.validFileID) ?? true,
              artifact.uploadURL.map(GoogleDriveLibraryLedger.validUploadURL) ?? true,
              artifact.uploadURL == nil || artifact.fileID != nil,
              !isPrioritySmall || artifact.kind != .audio else { throw GoogleDriveLibraryError.invalidState }
        // Reuse production manifest validation; this touches no media or DB.
        var validator = GoogleDriveLibraryLedger()
        try validator.bind(accountID: accountID, label: "Local preparation validation")
        try validator.authorize(.existingAndFuture, knownIDs: [], at: authorizedAt)
        try validator.discover(manifests: [manifest], receivedIDs: [manifest.id])
    }
    func reconciled(in ledger: GoogleDriveLibraryLedger) throws -> Self? {
        try validate(); try ledger.validate()
        guard ledger.enabled, !ledger.revokedLocally, ledger.libraryID == libraryID,
              ledger.accountID == accountID, ledger.folderID == folderID,
              ledger.authorizedAt == authorizedAt, ledger.recordingScope == recordingScope,
              let job = ledger.jobs.first(where: { $0.manifest == manifest }),
              let current = job.artifacts.first(where: { $0.key == artifact.key && $0.kind == artifact.kind
                  && $0.sha256 == artifact.sha256 && $0.byteCount == artifact.byteCount && $0.verifiedAt == nil }),
              artifact.fileID == nil || artifact.fileID == current.fileID,
              artifact.uploadURL == nil || artifact.uploadURL == current.uploadURL
        else { return nil }
        var updated = self; updated.artifact = current; try updated.validate(); return updated
    }
    /// Narrow display/authorization metadata check. This never issues an ACK,
    /// deletes a source, hashes audio, or treats an old receipt as durability.
    func sourceIsCurrent(in repository: RecordingRepository) throws -> Bool {
        let current: SegmentManifest
        do { current = try repository.manifest(id: manifest.id) }
        catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain,
               [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(failure.code) { return false }
            throw error
        }
        guard current == manifest else { return false }
        let file = repository.root.appendingPathComponent("receipts", isDirectory: true)
            .appendingPathComponent(manifest.id.uuidString.lowercased() + ".json")
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return false }
            throw GoogleDriveLibraryError.invalidState
        }
        defer { Darwin.close(fd) }
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_size > 0, info.st_size <= 16 * 1_024 else { return false }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let bytes = try handle.read(upToCount: 16 * 1_024 + 1), bytes.count <= 16 * 1_024,
              let receipt = try? TransportCodec.decode(SegmentReceipt.self, from: bytes) else { return false }
        return receipt.segmentID == manifest.id && receipt.sha256 == manifest.sha256
            && receipt.byteCount == manifest.byteCount && receipt.receivedAt.timeIntervalSince1970.isFinite
    }
    func matchesCurrentTranscript(_ transcript: SegmentTranscript?, in ledger: GoogleDriveLibraryLedger) throws -> Bool {
        guard artifact.kind == .transcriptJSON || artifact.kind == .transcriptText else { return true }
        guard let transcript else { return false }
        try transcript.validate(against: manifest)
        guard try reconciled(in: ledger) != nil else { return false }
        let bytes = artifact.kind == .transcriptJSON ? try TransportCodec.encode(transcript)
            : GoogleDriveLibraryLedger.readableTranscript(transcript, manifest: manifest)
        return GoogleDriveLibraryLedger.digest(bytes) == artifact.sha256 && bytes.count == artifact.byteCount
    }
    /// Run both before network readback and again immediately before committing
    /// its receipt. A source/receipt/text notification can arrive during HTTP
    /// without changing the library's authorization generation. No audio opens.
    func completedSourceIsCurrent(in repository: RecordingRepository, transcripts: TranscriptRepository,
                                  ledger: GoogleDriveLibraryLedger) throws -> Bool {
        guard try reconciled(in: ledger) != nil, try sourceIsCurrent(in: repository) else { return false }
        if artifact.kind == .transcriptJSON || artifact.kind == .transcriptText {
            return try matchesCurrentTranscript(GoogleDriveSyncProgress.inspectTranscript(
                repository: transcripts, manifest: manifest).transcript, in: ledger)
        }
        return true
    }
    func matches(_ segmentID: UUID, _ key: String) -> Bool { manifest.id == segmentID && artifact.key == key }
}

/// At most one 64KiB private control file. Ledger and pin are distinct atomic
/// files; a crash between them may withdraw the choice, never invent a receipt
/// or rewrite the ledger's original fileID/session. Corruption throws closed.
final class GoogleDrivePreflightPinStore {
    static let maximumBytes = 64 * 1_024
    private let directory: URL
    private let file: URL
    private(set) var pin: GoogleDrivePreflightPin?
    init(directory: URL) throws {
        self.directory = directory; file = directory.appendingPathComponent("preflight-pin.json")
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        guard try fm.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory else { throw GoogleDriveLibraryError.invalidState }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        #if os(iOS)
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        #endif
        var info = stat()
        if Darwin.lstat(file.path, &info) != 0 {
            guard errno == ENOENT else { throw GoogleDriveLibraryError.invalidState }; return
        }
        let fd = Darwin.open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw GoogleDriveLibraryError.invalidState }
        defer { Darwin.close(fd) }
        guard Darwin.fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_size > 0, info.st_size <= Self.maximumBytes else { throw GoogleDriveLibraryError.invalidState }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        guard let data = try handle.read(upToCount: Self.maximumBytes + 1), data.count <= Self.maximumBytes else { throw GoogleDriveLibraryError.invalidState }
        let value = try TransportCodec.decode(GoogleDrivePreflightPin.self, from: data)
        try value.validate(); pin = value
    }
    func capture(ledger: GoogleDriveLibraryLedger, selected: GoogleDriveSyncProgress.UploadChoice) throws {
        try reconcile(in: ledger)
        let candidate = try GoogleDrivePreflightPin(ledger: ledger, selected: selected)
        if let pin {
            // The selector may owe an audio turn while a small preparation is
            // held, or choose a source at least as recent as the preparation.
            // Equal timestamps follow the selector's deterministic source order.
            // Transfer only the local choice; the old item's authoritative
            // fileID/session remain in the ledger for its later fair turn.
            let newerSource = candidate.manifest.id != pin.manifest.id
                && candidate.manifest.startedAt >= pin.manifest.startedAt
            let owedAudio = candidate.artifact.kind == .audio && pin.artifact.kind != .audio
            guard newerSource || owedAudio else { return }
        }
        try save(candidate)
    }
    func reconcile(in ledger: GoogleDriveLibraryLedger) throws {
        guard let pin else { return }
        let updated = try pin.reconciled(in: ledger)
        if updated != pin { try save(updated) }
    }
    func reconcileSources(in ledger: GoogleDriveLibraryLedger, manifests: [SegmentManifest]?, receivedIDs: Set<UUID>?) throws {
        try reconcile(in: ledger)
        guard let pin else { return }
        if let manifests, !manifests.contains(pin.manifest) { try save(nil); return }
        if let receivedIDs, !receivedIDs.contains(pin.manifest.id) { try save(nil) }
    }
    /// This is a scheduling decision only. The caller must still read the exact
    /// local manifest, fingerprint bytes, and freshly verify remote permissions.
    func canDeferDiscovery(selected: GoogleDriveSyncProgress.UploadChoice?, completedReadback: Bool) -> Bool {
        guard let pin, let selected else { return false }
        return pin.matches(selected.segmentID, selected.artifactKey) || completedReadback
    }
    @discardableResult func transcriptDidChange(for segmentID: UUID) throws -> Bool {
        guard pin?.manifest.id == segmentID else { return false }
        try save(nil); return true
    }
    func clear(matching segmentID: UUID, key: String) throws {
        guard pin?.matches(segmentID, key) == true else { return }; try save(nil)
    }
    private func save(_ value: GoogleDrivePreflightPin?) throws {
        if let value {
            try value.validate()
            let data = try TransportCodec.encode(value)
            guard data.count <= Self.maximumBytes else { throw GoogleDriveLibraryError.invalidState }
            let temporary = directory.appendingPathComponent(".preflight-" + UUID().uuidString.lowercased())
            let fd = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw GoogleDriveLibraryError.invalidState }
            defer { Darwin.close(fd); try? FileManager.default.removeItem(at: temporary) }
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: temporary.path)
            #endif
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            try handle.write(contentsOf: data); try handle.synchronize()
            try validateExistingFileIfPresent()
            guard Darwin.rename(temporary.path, file.path) == 0 else { throw GoogleDriveLibraryError.invalidState }
        } else {
            try validateExistingFileIfPresent()
            if Darwin.unlink(file.path) != 0, errno != ENOENT { throw GoogleDriveLibraryError.invalidState }
        }
        let parent = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw GoogleDriveLibraryError.invalidState }
        defer { Darwin.close(parent) }
        guard Darwin.fsync(parent) == 0 else { throw GoogleDriveLibraryError.invalidState }
        pin = value
    }
    private func validateExistingFileIfPresent() throws {
        var info = stat()
        if Darwin.lstat(file.path, &info) != 0 {
            guard errno == ENOENT else { throw GoogleDriveLibraryError.invalidState }; return
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size > 0, info.st_size <= Self.maximumBytes else { throw GoogleDriveLibraryError.invalidState }
    }
}

/// Shared production ordering boundary, also exercised with a finite synthetic
/// clock. No stage can renew the caller's absolute deadline.
enum GoogleDriveProgressFirstRound {
    @MainActor static func run(background: Bool, check: () throws -> Void,
                               advance: () async throws -> Void,
                               discover: () async throws -> Void) async throws {
        try check()
        if background {
            try await advance(); try check(); try await discover()
        } else {
            try await discover(); try check(); try await advance()
        }
    }
}

/// Metadata-only, grant-bound durable source enumeration. The cursor never
/// contains audio or transcript bytes and never authorizes a job itself.
struct GoogleDriveSourceSnapshotCursor: Codable, Sendable {
    let schemaVersion: Int
    let libraryID: UUID
    let authorizedAt: Date?
    let accountID: String?
    let recordingScope: GoogleDriveRecordingScope?
    private(set) var ids: [UUID]
    let previousIDs: Set<UUID>
    private(set) var awaitingReceiptIDs: Set<UUID> = []
    private(set) var position: Int
    var nextID: UUID? { position < ids.count ? ids[position] : nil }
    static let maximumBytes = 2 * 1_024 * 1_024

    static func loadOrCreate(file: URL, repository: RecordingRepository, ledger: GoogleDriveLibraryLedger,
                             write: (Data) throws -> Void) throws -> Self {
        let manifests = repository.root.appendingPathComponent("manifests", isDirectory: true)
        try GoogleDriveMetadataIO.validateDirectory(manifests)
        let names = try FileManager.default.contentsOfDirectory(atPath: manifests.path)
        let known = Set(ledger.jobs.map(\.id))
        let ids = GoogleDriveSyncProgress.transcriptHints(fileNames: names).sorted {
            if known.contains($0) != known.contains($1) { return !known.contains($0) }
            return $0.uuidString < $1.uuidString
        }
        guard ids.count <= 10_000 else { throw GoogleDriveLibraryError.invalidState }
        var info = stat()
        if Darwin.lstat(file.path, &info) == 0 {
            var value = try TransportCodec.decode(Self.self, from: GoogleDriveMetadataIO.read(file, maximum: maximumBytes))
            guard value.schemaVersion == 1, value.ids.count <= 10_000,
                  Set(value.ids).count == value.ids.count, value.previousIDs.count <= 10_000,
                  (0...value.ids.count).contains(value.position),
                  value.awaitingReceiptIDs.isSubset(of: Set(value.ids.prefix(value.position)))
            else { throw GoogleDriveLibraryError.invalidState }
            if value.libraryID == ledger.libraryID, value.authorizedAt == ledger.authorizedAt,
               value.accountID == ledger.accountID, value.recordingScope == ledger.recordingScope {
                // A source may be deleted while this cursor is suspended. Only
                // a successful directory enumeration establishes absence; IO,
                // permission and alias failures must never prune work silently.
                let currentIDs = Set(ids)
                let visited = value.ids.prefix(value.position).filter { currentIDs.contains($0) }
                let retained = value.ids.filter { currentIDs.contains($0) }
                let pruned = retained.count != value.ids.count
                value.ids = retained
                value.position = visited.count
                value.awaitingReceiptIDs.formIntersection(Set(visited))
                let readyReceipts = value.awaitingReceiptIDs.filter { id in
                    FileManager.default.fileExists(atPath: repository.root.appendingPathComponent("receipts")
                        .appendingPathComponent(id.uuidString.lowercased() + ".json").path)
                }
                if !readyReceipts.isEmpty {
                    // A receipt can arrive while this process was suspended.
                    // Keep completed admissions, revisit only previously absent
                    // receipts and validate their bytes before ledger admission.
                    value.ids.removeAll { readyReceipts.contains($0) }
                    value.position -= readyReceipts.count
                    value.ids.insert(contentsOf: readyReceipts.sorted { $0.uuidString < $1.uuidString }, at: value.position)
                    value.awaitingReceiptIDs.subtract(readyReceipts)
                }
                let prior = Set(value.ids)
                let added = ids.filter { !prior.contains($0) }
                if !added.isEmpty {
                    guard value.ids.count + added.count <= 10_000 else { throw GoogleDriveLibraryError.invalidState }
                    value.ids.insert(contentsOf: added, at: value.position)
                }
                if pruned || !added.isEmpty || !readyReceipts.isEmpty { try write(value.encoded()) }
                return value
            }
        } else if errno != ENOENT { throw GoogleDriveMetadataIO.syscallFailure() }
        let value = Self(schemaVersion: 1, libraryID: ledger.libraryID, authorizedAt: ledger.authorizedAt,
            accountID: ledger.accountID, recordingScope: ledger.recordingScope, ids: ids, previousIDs: known, position: 0)
        try write(value.encoded()); return value
    }
    mutating func advance(after id: UUID, awaitingReceipt: Bool = false, write: (Data) throws -> Void) throws {
        guard nextID == id else { throw GoogleDriveLibraryError.invalidState }
        var next = self; next.position += 1
        if awaitingReceipt { next.awaitingReceiptIDs.insert(id) }
        try write(next.encoded()); self = next
    }
    private func encoded() throws -> Data {
        let bytes = try TransportCodec.encode(self)
        guard bytes.count <= Self.maximumBytes else { throw GoogleDriveLibraryError.invalidState }
        return bytes
    }
    static func readSource(_ id: UUID, repository: RecordingRepository) throws -> SegmentManifest? {
        let manifest = try repository.transferEvidenceManifest(id: id)
        let receiptFile = repository.root.appendingPathComponent("receipts").appendingPathComponent(id.uuidString.lowercased() + ".json")
        let bytes: Data
        do { bytes = try GoogleDriveMetadataIO.read(receiptFile, maximum: 16 * 1_024) }
        catch let error as GoogleDriveMetadataIOError where error.code == ENOENT { return nil }
        let receipt = try TransportCodec.decode(SegmentReceipt.self, from: bytes)
        guard receipt.segmentID == id, receipt.sha256 == manifest.sha256,
              receipt.byteCount == manifest.byteCount, receipt.receivedAt.timeIntervalSince1970.isFinite
        else { throw GoogleDriveLibraryError.changedManifest }
        return manifest
    }
    static func remove(file: URL) throws {
        if Darwin.unlink(file.path) != 0, errno != ENOENT { throw GoogleDriveMetadataIO.syscallFailure() }
        let parent = Darwin.open(file.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw GoogleDriveMetadataIO.syscallFailure() }
        defer { Darwin.close(parent) }
        guard Darwin.fsync(parent) == 0 else { throw GoogleDriveMetadataIO.syscallFailure() }
    }
}
