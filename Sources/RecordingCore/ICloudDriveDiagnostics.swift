import Foundation

/// The latest bounded metadata result for one expected file. No URL, provider
/// error text or recording content belongs in this value. Only `uploaded` can
/// contribute to confirmation, after the caller also checks the export grant.
public enum ICloudDriveProviderObservationStatus: String, Codable, CaseIterable, Sendable {
    case uploaded
    case notUploaded = "not_uploaded"
    case missingKey = "missing_key"
    case resourceError = "resource_error"
    case notUbiquitous = "not_ubiquitous"
    case invalidFile = "invalid_file"
    case identityMismatch = "identity_mismatch"
    case fileChangedDuringCheck = "file_changed_during_check"
    case fileUnavailable = "file_unavailable"
    /// Older Bool observations did not distinguish false from failed sampling.
    case legacyUnknown = "legacy_unknown"

    public static func metadata(regular: Bool?, symbolicLink: Bool?,
                                ubiquitous: Bool?, uploaded: Bool?) -> Self {
        if regular == false || symbolicLink == true { return .invalidFile }
        guard regular == true, symbolicLink == false else { return .missingKey }
        if ubiquitous == false { return .notUbiquitous }
        guard ubiquitous == true, let uploaded else { return .missingKey }
        return uploaded ? .uploaded : .notUploaded
    }

    /// A provider flag cannot override an unavailable, replaced or unstable
    /// target. A missing export identity still needs a validated marker/commit.
    public func applyingIdentity(fileAvailable: Bool, identityMatches: Bool?,
                                 contentValidated: Bool, stampStable: Bool) -> Self {
        guard fileAvailable else { return .fileUnavailable }
        guard identityMatches ?? contentValidated else { return .identityMismatch }
        guard stampStable else { return .fileChangedDuringCheck }
        return self
    }

    /// Optional typed fields permit schema-1 caches to load without inventing
    /// precision they never recorded. In particular an old positive must never
    /// mask a newer typed negative, or a recorded identity failure.
    public static func restored(_ typed: Self?, legacyUploaded: Bool,
                                legacyFailureCode: String?) -> Self {
        if let typed { return typed }
        switch legacyFailureCode {
        case "file_unavailable": return .fileUnavailable
        case "export_identity_changed": return .identityMismatch
        case "file_changed_during_check": return .fileChangedDuringCheck
        case nil: return legacyUploaded ? .uploaded : .legacyUnknown
        default: return .legacyUnknown
        }
    }
}

/// Read-only counters for the current foreground signal source. They describe
/// query opportunities and never assert that a file was uploaded.
public struct ICloudDriveProviderMonitorDiagnostic: Encodable, Equatable, Sendable {
    public let startAttemptCount: Int
    public let startSuccessCount: Int
    public let startFailureCount: Int
    public let notificationCount: Int
    public let firstGatherAt: Date?
    public let latestNotificationAt: Date?

    public init(startAttemptCount: Int = 0, startSuccessCount: Int = 0,
                startFailureCount: Int = 0, notificationCount: Int = 0,
                firstGatherAt: Date? = nil, latestNotificationAt: Date? = nil) {
        func bounded(_ value: Int) -> Int { min(1_000_000_000, max(0, value)) }
        self.startAttemptCount = bounded(startAttemptCount)
        self.startSuccessCount = bounded(startSuccessCount)
        self.startFailureCount = bounded(startFailureCount)
        self.notificationCount = bounded(notificationCount)
        self.firstGatherAt = firstGatherAt.flatMap { $0.timeIntervalSince1970.isFinite ? $0 : nil }
        self.latestNotificationAt = latestNotificationAt.flatMap { $0.timeIntervalSince1970.isFinite ? $0 : nil }
    }
}

/// Bounded facts copied from a completed local worker state. There is no field
/// for a recording identity, path, bookmark, credential or free-form error.
public struct ICloudDriveDiagnosticObservation: Equatable, Sendable {
    public enum Failure: String, Encodable, Sendable {
        case providerUnavailable = "provider_unavailable"
        case ledgerUnavailable = "ledger_unavailable"
        case evidenceUnavailable = "evidence_unavailable"
        case operationFailed = "operation_failed"
    }
    public enum CacheResetReason: Int, Encodable, Sendable {
        case none, missing, invalid, folderChanged, authorizationUnavailable, disconnected, paused
        case unknown
    }
    public enum Phase: Int, Encodable, Sendable {
        case idle, loading, target, discovery, export, provider, unknown
    }
    public struct Counts: Encodable, Equatable, Sendable {
        public let authorizedSources: Int
        public let locallyWrittenAudio: Int
        public let locallyWrittenTranscripts: Int
        public let providerConfirmedFiles: Int
        public let pendingProviderFiles: Int
        public let needsIdentityRevalidationSources: Int
        public let identityMismatchFiles: Int
        public let unavailableFiles: Int
        public let providerReportedPendingFiles: Int
        public let providerMissingKeyFiles: Int
        public let providerResourceErrorFiles: Int
        public let providerNotUbiquitousFiles: Int
        public let providerInvalidFileFiles: Int
        public let providerLegacyUnknownFiles: Int
        public let retainedHistoricalPositiveFiles: Int
        public let sourceDiscoveryCovered: Int
        public let metadataCheckedLastRound: Int
        public let cacheResetCount: Int
        public let phaseExpiryCount: Int

        public init(authorizedSources: Int = 0, locallyWrittenAudio: Int = 0,
                    locallyWrittenTranscripts: Int = 0, providerConfirmedFiles: Int = 0,
                    pendingProviderFiles: Int = 0, needsIdentityRevalidationSources: Int = 0,
                    identityMismatchFiles: Int = 0, unavailableFiles: Int = 0,
                    providerReportedPendingFiles: Int = 0, retainedHistoricalPositiveFiles: Int = 0,
                    sourceDiscoveryCovered: Int = 0, metadataCheckedLastRound: Int = 0,
                    cacheResetCount: Int = 0, phaseExpiryCount: Int = 0,
                    providerMissingKeyFiles: Int = 0, providerResourceErrorFiles: Int = 0,
                    providerNotUbiquitousFiles: Int = 0, providerInvalidFileFiles: Int = 0,
                    providerLegacyUnknownFiles: Int = 0) {
            // Fixed-size scalar counters also keep malformed/extreme local
            // values from growing a report or becoming negative evidence.
            func bounded(_ value: Int) -> Int { min(1_000_000_000, max(0, value)) }
            self.authorizedSources = bounded(authorizedSources)
            self.locallyWrittenAudio = bounded(locallyWrittenAudio)
            self.locallyWrittenTranscripts = bounded(locallyWrittenTranscripts)
            self.providerConfirmedFiles = bounded(providerConfirmedFiles)
            self.pendingProviderFiles = bounded(pendingProviderFiles)
            self.needsIdentityRevalidationSources = bounded(needsIdentityRevalidationSources)
            self.identityMismatchFiles = bounded(identityMismatchFiles)
            self.unavailableFiles = bounded(unavailableFiles)
            self.providerReportedPendingFiles = bounded(providerReportedPendingFiles)
            self.providerMissingKeyFiles = bounded(providerMissingKeyFiles)
            self.providerResourceErrorFiles = bounded(providerResourceErrorFiles)
            self.providerNotUbiquitousFiles = bounded(providerNotUbiquitousFiles)
            self.providerInvalidFileFiles = bounded(providerInvalidFileFiles)
            self.providerLegacyUnknownFiles = bounded(providerLegacyUnknownFiles)
            self.retainedHistoricalPositiveFiles = bounded(retainedHistoricalPositiveFiles)
            self.sourceDiscoveryCovered = bounded(sourceDiscoveryCovered)
            self.metadataCheckedLastRound = bounded(metadataCheckedLastRound)
            self.cacheResetCount = bounded(cacheResetCount)
            self.phaseExpiryCount = bounded(phaseExpiryCount)
        }
    }

    public let observedAt: Date
    public let latestProviderObservationAt: Date?
    public let firstProviderConfirmationAt: Date?
    public let latestProviderConfirmationAt: Date?
    public let failure: Failure?
    public let sourceDiscoveryComplete: Bool
    public let cacheResetReason: CacheResetReason
    public let expiredPhase: Phase
    public let counts: Counts

    public init(observedAt: Date, latestProviderObservationAt: Date? = nil,
                failure: Failure? = nil, sourceDiscoveryComplete: Bool = false,
                cacheResetReason: CacheResetReason = .none, expiredPhase: Phase = .idle,
                counts: Counts = .init(), firstProviderConfirmationAt: Date? = nil,
                latestProviderConfirmationAt: Date? = nil) {
        self.observedAt = observedAt; self.latestProviderObservationAt = latestProviderObservationAt
        self.firstProviderConfirmationAt = firstProviderConfirmationAt
        self.latestProviderConfirmationAt = latestProviderConfirmationAt
        self.failure = failure; self.sourceDiscoveryComplete = sourceDiscoveryComplete
        self.cacheResetReason = cacheResetReason; self.expiredPhase = expiredPhase; self.counts = counts
    }
}

/// This export is an as-of memory observation, even when recently collected.
/// Creating it never reads the worker, repository or file provider.
public struct ICloudDriveDiagnosticSnapshot: Encodable, Equatable, Sendable {
    public enum Availability: String, Encodable, Sendable {
        case cached, stale, unavailable, notObserved = "not_observed", invalidTimestamp = "invalid_timestamp"
    }
    public enum Status: String, Encodable, Sendable {
        case unknown, unavailable, disconnected, paused
        case needsIdentityRevalidation = "needs_identity_revalidation"
        case providerPending = "provider_pending"
        case observed
    }
    public static let maximumObservationAge: TimeInterval = 3_600
    public let schemaVersion = 1
    public let capturedAt: Date
    public let observedAt: Date?
    public let latestProviderObservationAt: Date?
    public let firstProviderConfirmationAt: Date?
    public let latestProviderConfirmationAt: Date?
    public let providerMonitor: ICloudDriveProviderMonitorDiagnostic?
    public let ageSeconds: Double?
    public let availability: Availability
    public let status: Status
    public let failure: ICloudDriveDiagnosticObservation.Failure?
    public let connected: Bool
    public let enabled: Bool
    public let sourceDiscoveryComplete: Bool?
    public let counts: ICloudDriveDiagnosticObservation.Counts?
    public let cacheResetReason: ICloudDriveDiagnosticObservation.CacheResetReason?
    public let expiredPhase: ICloudDriveDiagnosticObservation.Phase?
    public let includesAudio = false
    public let includesTranscripts = false
    public let includesRecordingIdentities = false
    public let providerAccessedForExport = false
    public let workerStartedForExport = false
    public let audioContentVerified = false
    public let currentRemoteReadabilityProven = false
    public let allCountersShareOneObservationTime = false

    public init(observation: ICloudDriveDiagnosticObservation?, at now: Date = Date(),
                connected: Bool = false, enabled: Bool = false, operationFailed: Bool = false,
                providerMonitor: ICloudDriveProviderMonitorDiagnostic? = nil) {
        capturedAt = now; self.connected = connected; self.enabled = enabled
        func validEventTime(_ time: Date?) -> Date? {
            time.flatMap { $0.timeIntervalSince1970.isFinite && $0 <= now.addingTimeInterval(5) ? $0 : nil }
        }
        self.providerMonitor = providerMonitor.map { monitor in
            .init(startAttemptCount: monitor.startAttemptCount, startSuccessCount: monitor.startSuccessCount,
                  startFailureCount: monitor.startFailureCount, notificationCount: monitor.notificationCount,
                  firstGatherAt: validEventTime(monitor.firstGatherAt),
                  latestNotificationAt: validEventTime(monitor.latestNotificationAt))
        }
        failure = operationFailed ? .operationFailed : observation?.failure
        guard let observation else {
            observedAt = nil; latestProviderObservationAt = nil; ageSeconds = nil
            firstProviderConfirmationAt = nil; latestProviderConfirmationAt = nil
            availability = operationFailed ? .unavailable : .notObserved
            status = operationFailed ? .unavailable : .unknown
            sourceDiscoveryComplete = nil; counts = nil; cacheResetReason = nil; expiredPhase = nil
            return
        }
        let age = now.timeIntervalSince(observation.observedAt)
        let validTime = now.timeIntervalSince1970.isFinite && observation.observedAt.timeIntervalSince1970.isFinite
            && age.isFinite && age >= -5
        observedAt = validTime ? observation.observedAt : nil
        latestProviderObservationAt = validEventTime(observation.latestProviderObservationAt)
        firstProviderConfirmationAt = validEventTime(observation.firstProviderConfirmationAt)
        latestProviderConfirmationAt = validEventTime(observation.latestProviderConfirmationAt)
        ageSeconds = validTime ? max(0, age) : nil
        counts = observation.counts; sourceDiscoveryComplete = observation.sourceDiscoveryComplete
        cacheResetReason = observation.cacheResetReason; expiredPhase = observation.expiredPhase
        if failure != nil { availability = .unavailable; status = .unavailable }
        else if !validTime { availability = .invalidTimestamp; status = .unknown }
        else if age > Self.maximumObservationAge { availability = .stale; status = .unknown }
        else {
            availability = .cached
            if !connected { status = .disconnected }
            else if !enabled { status = .paused }
            else if observation.counts.needsIdentityRevalidationSources > 0 { status = .needsIdentityRevalidation }
            else if observation.counts.pendingProviderFiles > 0 { status = .providerPending }
            else if observation.counts.providerConfirmedFiles > 0 { status = .observed }
            else { status = .unknown }
        }
    }

    public var summary: String {
        switch availability {
        case .notObserved: return "iCloud 状态尚未观察，未为导出启动检查。"
        case .stale: return "iCloud 缓存状态已过时，未当作当前上传状态。"
        case .invalidTimestamp: return "iCloud 缓存时间无效，当前状态未知。"
        case .unavailable: return "iCloud 本轮状态不可用，历史计数不代表当前确认。"
        case .cached:
            switch status {
            case .needsIdentityRevalidation: return "部分 iCloud 文件身份待确认，暂不计入已上传。录音文件仍保留。"
            case .providerPending: return "iCloud 文件上传待系统确认，附已有缓存计数。"
            case .paused: return "iCloud 已暂停后续写入，附已有缓存计数。"
            case .disconnected: return "iCloud 已断开，附已有缓存计数。"
            case .observed: return "附 iCloud 已有上传观察；不是当前远端可读性证明。"
            default: return "iCloud 当前状态未知，未为导出启动检查。"
            }
        }
    }
}
