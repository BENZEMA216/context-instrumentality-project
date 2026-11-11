import Combine
import Foundation
import RecordingCore
import UIKit

@MainActor
final class PhoneStore: ObservableObject {
    /// Also initialized by AppDelegate on a background launch, before any view.
    static let shared = PhoneStore()
    @Published private(set) var observationPreparationMessage = "检查已有同步记录，供电脑端建立观察基线。"
    private var observationPreparationRequest = UUID()
    private var observationPreparationCooldownSeconds = 0
    @Published private(set) var manifests: [SegmentManifest] = []
    @Published private(set) var receivedSegmentIDs: Set<UUID> = []
    @Published private(set) var hasLibrarySnapshot = false
    @Published private(set) var events: [RecordingEvent] = []
    @Published private(set) var connection = PhoneConnectionState()
    @Published private(set) var storageError: String?
    @Published private(set) var exportURL: URL?
    @Published private(set) var isPreparingDiagnostics = false
    @Published private(set) var diagnosticPreparationIncludesFullHistory = false
    @Published private(set) var diagnosticExportSummary: String?
    @Published private(set) var diagnosticExportError: String?
    @Published private(set) var diagnosticIssueID: String?
    @Published private(set) var diagnosticBuild: String?
    @Published private(set) var diagnosticTimingSummary: String?
    @Published private(set) var eventHistorySummary = "尚未读取近期日志"
    @Published private(set) var syncFeedback: String?
    @Published private(set) var syncFeedbackIsError = false
    @Published private(set) var isRequestingSync = false
    @Published private(set) var isRequestingStatus = false
    @Published private(set) var statusFeedback: String?
    @Published private(set) var statusFeedbackIsError = false
    /// One view-owned user intent survives at most one connection recovery.
    @Published private(set) var statusQueryIntentID: UUID?
    @Published private(set) var statusRequestGeneration: UUID?
    @Published private(set) var isAwaitingStatusRecovery = false
    @Published private(set) var agentExportURL: URL?
    @Published private(set) var agentExportError: String?
    @Published private(set) var isPreparingAgentExport = false
    @Published private(set) var agentSelectedIDs: Set<UUID> = []
    @Published private(set) var personalLibrary: PersonalLibraryStore?
    @Published private(set) var automaticDelivery: PhoneAutomaticDeliveryStore?

    private let root: URL
    private let work = DispatchQueue(label: "WristRecord.phone.library", qos: .utility)
    private let exportWork = DispatchQueue(label: "WristRecord.phone.agent-export", qos: .utility)
    private let diagnosticWork = DispatchQueue(label: "WristRecord.phone.recent-diagnostics", qos: .userInitiated)
    private let fullDiagnosticWork = DispatchQueue(label: "WristRecord.phone.full-diagnostics", qos: .utility)
    private var repository: RecordingRepository?
    private var transcriptRepository: TranscriptRepository?
    private var connectivity: PhoneConnectivity?
    private var reloadInFlight = false
    private var reloadPending = false
    private var eventHistoryReadCancellation: PhoneBackgroundCancellation?
    private var syncRequestID: UUID?
    private var syncFeedbackTimeout: Task<Void, Never>?
    private var statusRequestID: UUID?
    private var statusFeedbackTimeout: Task<Void, Never>?
    private var statusRecoveryConnectionAvailable = false
    private var statusRecoveryRetried = false
    private var statusSuccessfulRequestGeneration: UUID?
    private var librarySnapshotObservedAt: Date?
    private let diagnosticProcessRunID = UUID()
    private var diagnosticLifecycle: DiagnosticShareLifecycle?
    private var diagnosticStartedUptime: TimeInterval?
    private var diagnosticLifecycleStorageFailed = false

    init() {
        defer { AutomaticDeliveryBackgroundEvents.shared.finishRegistration() }
        root = RecordingRepository.defaultRoot()
        do {
            let repository = try RecordingRepository(root: root)
            self.repository = repository
            let connectivity = try PhoneConnectivity(repository: repository, root: root)
            self.connectivity = connectivity
            // A background WC/BG launch need not pass through either lifecycle
            // transition. Record the state actually observed at initialization;
            // inactive is ambiguous and must remain unknown.
            switch UIApplication.shared.applicationState {
            case .active: connectivity.observeApplicationForeground(true)
            case .background: connectivity.observeApplicationForeground(false)
            case .inactive: break
            @unknown default: break
            }
            PhoneBackgroundSync.shared.setDiagnosticHandler { [weak connectivity] kind, detail in
                connectivity?.recordBackgroundDiagnostic(kind: kind, detail: detail)
            }
            AutomaticDeliveryBackgroundEvents.shared.setDiagnosticHandler { [weak connectivity] kind, detail in
                connectivity?.recordBackgroundDiagnostic(kind: kind, detail: detail)
            }
            connectivity.onUpdate = { [weak self] in
                Task { @MainActor in self?.reload() }
            }
            connectivity.onStatusReachabilityChanged = { [weak self] available in
                Task { @MainActor in self?.statusConnectionAvailabilityChanged(available) }
            }
            connectivity.onNeedsBackgroundMaintenance = {
                Task { @MainActor in PhoneBackgroundSync.shared.schedule() }
            }
            // Activate WC before optional cloud/transcript initialization. A cold
            // background delivery must not wait for credentials, cloud ledgers
            // or a derived-text store before its delegate can take ownership.
            connectivity.start()
            do {
                let transcriptRepository = try TranscriptRepository(root: root)
                self.transcriptRepository = transcriptRepository
                self.personalLibrary = PersonalLibraryStore(repository: repository, transcriptRepository: transcriptRepository)
            } catch {
                // Derived text must never prevent durable audio reception/ACKs.
                agentExportError = "转写存储暂不可用：\(error.localizedDescription)"
            }
            personalLibrary?.drive.setDiagnosticHandler { [weak connectivity] kind, detail in
                connectivity?.recordBackgroundDiagnostic(kind: kind, detail: detail)
            }
            automaticDelivery = PhoneAutomaticDeliveryStore(repository: repository,
                transcriptRepository: transcriptRepository,
                requestBackgroundRetry: { date in PhoneBackgroundSync.shared.schedule(earliestBeginDate: date) },
                diagnostic: { [weak connectivity] kind, detail in
                    connectivity?.recordBackgroundDiagnostic(kind: kind, detail: detail)
                }, onTranscriptDidSave: { [weak self] manifest in
                    self?.personalLibrary?.receiverTranscriptDidSave(for: manifest)
                })
            reload()
        } catch {
            // Never silently fall back to temporary storage.
            storageError = "无法打开本机录音存储：\(error.localizedDescription)"
        }
    }

    func didBecomeActive() {
        reload()
        connectivity?.appDidBecomeActive()
        automaticDelivery?.resume()
        personalLibrary?.drive.didBecomeActive()
        personalLibrary?.iCloudDrive.resume()
        connectivity?.observeVerifiedMetadata()
        personalLibrary?.drive.observeVerifiedMetadata()
        personalLibrary?.iCloudDrive.observeVerifiedMetadata()
    }

    /// Observation-only manual action. Existing metadata queues own validation;
    /// this does not resume workers, request source discovery, or read recordings.
    func prepareObservationSnapshots() {
        let request = UUID(); observationPreparationRequest = request
        observationPreparationCooldownSeconds = 0
        observationPreparationMessage = "已请求检查现有同步记录。是否可用于观察，以电脑端检查结果为准。"
        let onThrottle: @Sendable (Int) -> Void = { [weak self] seconds in
            Task { @MainActor in
                guard let self, self.observationPreparationRequest == request else { return }
                self.observationPreparationCooldownSeconds = max(self.observationPreparationCooldownSeconds, seconds)
                self.observationPreparationMessage = "刚刚已准备，\(self.observationPreparationCooldownSeconds) 秒后可再次准备。是否可用于观察，以电脑端检查结果为准。"
            }
        }
        connectivity?.observeVerifiedMetadata(onThrottle: onThrottle)
        personalLibrary?.drive.observeVerifiedMetadata(onThrottle: onThrottle)
        personalLibrary?.iCloudDrive.observeVerifiedMetadata(onThrottle: onThrottle)
    }

    func didEnterBackground() {
        personalLibrary?.iCloudDrive.suspendForBackground()
        eventHistoryReadCancellation?.cancel()
        automaticDelivery?.resume()
        connectivity?.appDidEnterBackground()
        PhoneBackgroundSync.shared.schedule()
    }

    func performBackgroundSync(cancellation: PhoneBackgroundCancellation,
                               completion: @escaping @Sendable (Bool, Bool) -> Void) {
        let processing = AutomaticDeliveryBackgroundEvents.shared.beginProcessing(isCancelled: { cancellation.isCancelled })
        let finish: @Sendable (Bool, Bool) -> Void = { success, needsMore in
            Task { @MainActor in
                AutomaticDeliveryBackgroundEvents.shared.endProcessing(processing)
                completion(success, needsMore)
            }
        }
        guard let connectivity else { finish(false, true); return }
        connectivity.performBackgroundMaintenance(cancellation: cancellation, resultCompletion: { [weak self] watch in
            Task { @MainActor in
                guard let self, !cancellation.isCancelled else { finish(false, true); return }
                // These grants have separate ledgers and staging directories.
                // Start both before waiting; receiver preparation and full source
                // enumeration must not hold their shared repository lock first.
                let drive = Task { @MainActor in
                    await self.personalLibrary?.drive.prepareBackgroundDelivery(isCancelled: {
                        cancellation.isCancelled
                    }, systemGranted: true) ?? true
                }
                let iCloud = Task { @MainActor in
                    await self.personalLibrary?.iCloudDrive.prepareBackgroundDelivery(isCancelled: {
                        cancellation.isCancelled
                    }, systemGranted: true) ?? true
                }
                let driveCompleted = await drive.value
                let iCloudCompleted = await iCloud.value
                // A full transfer snapshot holds the repository mutation lock.
                // Even a concurrent walk would block exact-source cloud checks;
                // only refresh it after both finite cloud turns have advanced.
                let discoveryCompleted: Bool
                do {
                    try await self.discoverBackgroundSources(cancellation: cancellation)
                    discoveryCompleted = true
                } catch {
                    connectivity.recordBackgroundDiagnostic(kind: "phone.cloud_source_discovery_failed",
                        detail: "metadata_unavailable=true cancelled=\(cancellation.isCancelled)")
                    discoveryCompleted = false
                }
                let deliveryCompleted = await self.automaticDelivery?.prepareBackgroundDelivery(isCancelled: {
                    cancellation.isCancelled
                }) ?? true
                let needsMore = watch.needsMore || self.automaticDelivery?.hasPendingDelivery == true
                    || self.personalLibrary?.drive.hasPendingWork == true
                    || self.personalLibrary?.iCloudDrive.hasPendingWork == true
                finish(watch.succeeded && discoveryCompleted && deliveryCompleted && driveCompleted && iCloudCompleted && !cancellation.isCancelled,
                    needsMore || !discoveryCompleted)
            }
        })
    }

    private func discoverBackgroundSources(cancellation: PhoneBackgroundCancellation) async throws {
        guard let repository, !cancellation.isCancelled else { throw CancellationError() }
        let snapshot: RecordingTransferEvidenceSnapshot = try await withCheckedThrowingContinuation { continuation in
            work.async {
                do {
                    guard !cancellation.isCancelled else { throw CancellationError() }
                    continuation.resume(returning: try repository.transferEvidenceSnapshot())
                } catch { continuation.resume(throwing: error) }
            }
        }
        guard !cancellation.isCancelled else { throw CancellationError() }
        let values = snapshot.manifests
        let received = Set(snapshot.receipts.map(\.segmentID))
        let ordered = values.sorted { $0.id.uuidString < $1.id.uuidString }
        if hasLibrarySnapshot && (manifests.sorted(by: { $0.id.uuidString < $1.id.uuidString }) != ordered
            || receivedSegmentIDs != received) {
            PhoneBackgroundSync.noteNewWork()
        }
        manifests = values.sorted { $0.startedAt > $1.startedAt }
        receivedSegmentIDs = received
        hasLibrarySnapshot = true
        librarySnapshotObservedAt = Date()
        personalLibrary?.drive.discover(manifests: values, receivedIDs: received)
        personalLibrary?.iCloudDrive.discover(manifests: values, receivedIDs: received)
        automaticDelivery?.discover(manifests: values, receivedSegmentIDs: received)
    }

    func expireBackgroundSync() {
        connectivity?.expireBackgroundMaintenance()
        automaticDelivery?.cancelPreparation()
        personalLibrary?.drive.expireBackgroundWork()
        personalLibrary?.iCloudDrive.expireBackgroundWork()
    }
    func requestSync() {
        guard !isRequestingSync else { return }
        guard let connectivity else {
            syncFeedback = "同步尚未准备好，请先检查本机存储状态。"
            syncFeedbackIsError = true
            return
        }
        let requestID = UUID()
        syncRequestID = requestID
        syncFeedbackTimeout?.cancel()
        isRequestingSync = true
        syncFeedbackIsError = false
        syncFeedback = "正在请求手表状态与补传…"
        // A background system request can take longer than the visible action.
        // Stop the spinner without pretending the recordings have completed.
        syncFeedbackTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 8_000_000_000) }
            catch { return }
            guard let self, self.syncRequestID == requestID else { return }
            self.isRequestingSync = false
            self.syncFeedback = "尚未收到手表回应。请在手表打开 App 核对当前状态；已保存的录音仍保留。"
        }
        connectivity.requestSync { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.syncRequestID == requestID else { return }
                self.syncFeedbackTimeout?.cancel()
                self.syncFeedbackTimeout = nil
                self.isRequestingSync = false
                self.syncFeedback = result.message
                self.syncFeedbackIsError = result.isError
                self.reload()
            }
        }
        reload()
    }

    /// The status sheet must not call requestSync/reload: those also discover
    /// delivery work and can verify/prepare audio. Only connection metadata is
    /// published by this action, including every failure and timeout branch.
    @discardableResult
    func requestStatus(completion: @escaping @MainActor (PhoneStatusRequestResult) -> Void = { _ in }) -> UUID? {
        guard !isRequestingStatus else { return nil }
        // A manual query replaces the previous terminal recovery intent. A busy
        // observer never takes ownership of somebody else's in-flight request.
        cancelStatusRequest()
        guard connectivity != nil else {
            let result = PhoneStatusRequestResult.failed
            statusFeedback = result.message
            statusFeedbackIsError = true
            completion(result)
            return nil
        }
        let intentID = UUID()
        statusQueryIntentID = intentID
        statusRecoveryRetried = false
        startStatusAttempt(intentID: intentID, isRecovery: false, completion: completion)
        return intentID
    }

    private func startStatusAttempt(intentID: UUID, isRecovery: Bool,
                                    completion: @escaping @MainActor (PhoneStatusRequestResult) -> Void = { _ in }) {
        guard statusQueryIntentID == intentID, !isRequestingStatus, let connectivity else { return }
        let requestID = UUID()
        statusRequestID = requestID
        statusRequestGeneration = requestID
        isAwaitingStatusRecovery = false
        isRequestingStatus = true
        // Keep the previous error until a bound current reply really succeeds.
        // While an attempt is running the UI presents the querying message.
        statusFeedback = isRecovery ? "连接已恢复，正在重新查询手表录音状态…" : "正在查询手表录音状态…"
        statusFeedbackTimeout?.cancel()
        statusFeedbackTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 8_000_000_000) }
            catch { return }
            guard let self, self.statusQueryIntentID == intentID, self.statusRequestID == requestID else { return }
            // Token revocation is synchronous, independent of a blocked worker.
            connectivity.cancelStatusRequest(diagnosticOutcome: .timeout)
            self.finishStatusAttempt(.timedOut, intentID: intentID, requestID: requestID,
                                     isRecovery: isRecovery, completion: completion)
        }
        connectivity.observeStatusAvailability()
        connectivity.requestStatus(intentID: intentID, attemptID: requestID, isRecoveryRetry: isRecovery) { [weak self] result in
            Task { @MainActor [weak self] in
                self?.finishStatusAttempt(result, intentID: intentID, requestID: requestID,
                                          isRecovery: isRecovery, completion: completion)
            }
        }
    }

    private func finishStatusAttempt(_ result: PhoneStatusRequestResult, intentID: UUID, requestID: UUID,
                                     isRecovery: Bool,
                                     completion: @escaping @MainActor (PhoneStatusRequestResult) -> Void) {
        guard statusQueryIntentID == intentID, statusRequestID == requestID else { return }
        statusFeedbackTimeout?.cancel()
        statusFeedbackTimeout = nil
        statusRequestID = nil
        isRequestingStatus = false
        statusFeedback = result.message
        statusFeedbackIsError = result.isError
        if case .received(let snapshot) = result {
            statusSuccessfulRequestGeneration = requestID
            isAwaitingStatusRecovery = false
            var updated = connection
            updated.activated = true
            updated.paired = true
            updated.watchAppInstalled = true
            updated.reachable = true
            updated.snapshot = snapshot
            updated.lastError = nil
            connection = updated
        } else if case .waitingForConnection = result, !isRecovery, !statusRecoveryRetried {
            // Only a confirmed unavailable connection arms recovery. Malformed,
            // old, missing or timed-out replies never manufacture that evidence.
            isAwaitingStatusRecovery = true
            // Recovery guidance belongs to the view; keep the status itself concise.
            statusFeedback = result.message
        }
        completion(result)
        guard statusQueryIntentID == intentID, isAwaitingStatusRecovery else { return }
        // A WC event can reach MainActor before this terminal result. Consume
        // the latest available observation, and independently observe current WC
        // flags once so the edge cannot be lost while the result was queued.
        retryStatusAfterConnectionRecovery()
        if isAwaitingStatusRecovery { connectivity?.observeStatusAvailability() }
    }

    /// Called directly from WC observations, without notify/reload or library work.
    func statusConnectionAvailabilityChanged(_ available: Bool) {
        statusRecoveryConnectionAvailable = available
        if available { retryStatusAfterConnectionRecovery() }
    }

    private func retryStatusAfterConnectionRecovery() {
        guard statusRecoveryConnectionAvailable, isAwaitingStatusRecovery,
              !statusRecoveryRetried, !isRequestingStatus, let intentID = statusQueryIntentID,
              connectivity?.statusConnectionIsAvailable() == true else { return }
        // Consume before starting: duplicate availability callbacks cannot queue
        // another attempt, even when the original connectivity worker is busy.
        statusRecoveryRetried = true
        isAwaitingStatusRecovery = false
        startStatusAttempt(intentID: intentID, isRecovery: true)
    }

    /// Wait only for an attempt already owned by this view. A later automatic
    /// attempt has a new generation and cannot be cancelled by this old waiter.
    func waitForStatusRequest(intentID: UUID) async {
        await waitForStatusAttempt(intentID: intentID, ownsRequest: true)
    }

    private func waitForStatusAttempt(intentID: UUID, ownsRequest: Bool) async {
        guard statusQueryIntentID == intentID, let observedRequestID = statusRequestID else { return }
        while statusQueryIntentID == intentID && statusRequestID == observedRequestID && isRequestingStatus {
            do { try await Task.sleep(nanoseconds: 50_000_000) }
            catch {
                if ownsRequest && statusQueryIntentID == intentID && statusRequestID == observedRequestID {
                    cancelStatusRequest(ifIntentID: intentID)
                }
                return
            }
        }
    }

    /// Busy observers wait for somebody else's query without owning cancellation.
    func requestStatusAndWait() async {
        guard !Task.isCancelled else { return }
        let ownsRequest = !isRequestingStatus
        if ownsRequest {
            guard let intentID = requestStatus() else { return }
            await waitForStatusAttempt(intentID: intentID, ownsRequest: true)
        } else if let intentID = statusQueryIntentID {
            await waitForStatusAttempt(intentID: intentID, ownsRequest: false)
        }
    }

    func cancelStatusRequest(ifIntentID intentID: UUID? = nil) {
        if let intentID, statusQueryIntentID != intentID { return }
        statusFeedbackTimeout?.cancel()
        statusFeedbackTimeout = nil
        statusRequestID = nil
        statusQueryIntentID = nil
        statusRequestGeneration = nil
        isAwaitingStatusRecovery = false
        statusRecoveryRetried = false
        isRequestingStatus = false
        statusFeedback = nil
        statusFeedbackIsError = false
        connectivity?.cancelStatusRequest()
    }

    func reload() {
        guard let repository else { return }
        guard !reloadInFlight else { reloadPending = true; return }
        reloadInFlight = true
        // Event history is presentation data. Background delivery discovery needs
        // only manifest and receipt metadata, even after many thousands of logs.
        let includeEventHistory = UIApplication.shared.applicationState == .active
        let eventReadCancellation = PhoneBackgroundCancellation()
        eventHistoryReadCancellation = eventReadCancellation
        let connectivity = connectivity
        let work = work
        let statusGenerationBeforeRead = statusSuccessfulRequestGeneration
        // UI status needs receipt metadata only. Full audio verification remains
        // in the ACK replay path; coalesce background metadata reads here.
        PhoneBackgroundLease.begin(name: "delivery-discovery", diagnostic: { detail in
            connectivity?.recordBackgroundDiagnostic(kind: "phone.delivery_discovery_lease", detail: detail)
        }) { [weak self] lease in
        guard lease.hasTimeRemaining else {
            lease.end()
            Task { @MainActor in
                self?.reloadInFlight = false
                if self?.eventHistoryReadCancellation === eventReadCancellation {
                    self?.eventHistoryReadCancellation = nil
                }
                PhoneBackgroundSync.shared.schedule()
            }
            return
        }
        work.async { [weak self] in
            let connection = connectivity?.currentState() ?? PhoneConnectionState()
            let result: PhoneLibraryRead
            do {
                let manifests = try repository.manifests()
                let receivedSegmentIDs = try repository.receivedSegmentIDs()
                let eventHistory: RecordingDiagnosticEventSnapshot?
                do {
                    eventHistory = includeEventHistory && lease.hasTimeRemaining && !eventReadCancellation.isCancelled
                        ? try repository.recentEventsSnapshot(limit: 100,
                            while: { lease.hasTimeRemaining && !eventReadCancellation.isCancelled }) : nil
                } catch is CancellationError {
                    // Leaving the foreground cancels presentation work only.
                    // Keep the metadata already read for delivery discovery.
                    eventHistory = nil
                }
                result = PhoneLibraryRead(manifests: manifests,
                    receivedSegmentIDs: receivedSegmentIDs,
                    eventSnapshot: lease.hasTimeRemaining && !eventReadCancellation.isCancelled ? eventHistory : nil,
                    error: nil)
            } catch {
                result = PhoneLibraryRead(manifests: nil, receivedSegmentIDs: nil, eventSnapshot: nil,
                    error: "读取本机记录失败：\(error.localizedDescription)")
            }
            Task { @MainActor [weak self] in
                defer { lease.end() }
                guard let self else { return }
                if self.eventHistoryReadCancellation === eventReadCancellation {
                    self.eventHistoryReadCancellation = nil
                }
                // A library reload can have captured connection state before a
                // successful read-only reply. Do not resurrect its old error or
                // overwrite the newer bound snapshot when that read arrives late.
                if self.statusSuccessfulRequestGeneration == statusGenerationBeforeRead {
                    self.connection = connection
                }
                if let values = result.manifests { self.manifests = values.sorted { $0.startedAt > $1.startedAt } }
                if let values = result.receivedSegmentIDs { self.receivedSegmentIDs = values }
                if let snapshot = result.eventSnapshot, !eventReadCancellation.isCancelled,
                   UIApplication.shared.applicationState == .active {
                    self.events = snapshot.events.sorted {
                        $0.timestamp == $1.timestamp ? $0.id.uuidString > $1.id.uuidString : $0.timestamp > $1.timestamp
                    }
                    self.eventHistorySummary = "近期 \(snapshot.events.count) 条；未加载完整历史"
                        + (snapshot.eventSelection.truncated ? "，范围已限量" : "")
                }
                if let manifests = result.manifests, let received = result.receivedSegmentIDs {
                    self.hasLibrarySnapshot = true
                    self.librarySnapshotObservedAt = Date()
                    self.personalLibrary?.drive.discover(manifests: manifests, receivedIDs: received)
                    self.personalLibrary?.iCloudDrive.discover(manifests: manifests, receivedIDs: received)
                    if lease.hasTimeRemaining {
                        // Foreground discovery already schedules normal work;
                        // do not delay UI metadata publication by waiting for a
                        // provider. Only an actual background discovery lease
                        // grants this additional bounded continuation.
                        let background = UIApplication.shared.applicationState != .active
                        let drive: Task<Bool, Never>? = !background ? nil
                            : Task { @MainActor in
                                await self.personalLibrary?.drive.prepareBackgroundDelivery(isCancelled: {
                                    !lease.hasTimeRemaining
                                }) ?? true
                            }
                        let iCloud: Task<Bool, Never>? = !background ? nil
                            : Task { @MainActor in
                                await self.personalLibrary?.iCloudDrive.prepareBackgroundDelivery(isCancelled: {
                                    !lease.hasTimeRemaining
                                }) ?? true
                            }
                        self.automaticDelivery?.discover(manifests: manifests, receivedSegmentIDs: received)
                        await self.automaticDelivery?.waitForPreparation(isCancelled: { !lease.hasTimeRemaining })
                        let driveCompleted = await drive?.value ?? true
                        let iCloudCompleted = await iCloud?.value ?? true
                        if !driveCompleted || !iCloudCompleted || (background && (
                            self.personalLibrary?.drive.hasPendingWork == true
                            || self.personalLibrary?.iCloudDrive.hasPendingWork == true)) {
                            PhoneBackgroundSync.shared.schedule()
                        }
                    } else {
                        PhoneBackgroundSync.shared.schedule()
                    }
                }
                self.storageError = result.error
                self.reloadInFlight = false
                if self.reloadPending {
                    self.reloadPending = false
                    self.reload()
                }
            }
        }
        }
    }

    func audioURL(for manifest: SegmentManifest) -> URL? { repository?.audioURL(for: manifest) }
    func hasReceipt(for manifest: SegmentManifest) -> Bool { receivedSegmentIDs.contains(manifest.id) }

    func toggleAgentSelection(_ id: UUID) {
        guard !isPreparingAgentExport else { return }
        if agentSelectedIDs.contains(id) { agentSelectedIDs.remove(id) }
        else { agentSelectedIDs.insert(id) }
        agentExportURL = nil
        agentExportError = nil
    }

    func prepareAgentExport() {
        guard !isPreparingAgentExport, let repository else { return }
        let selectedIDs = agentSelectedIDs
        isPreparingAgentExport = true
        agentExportURL = nil
        agentExportError = nil
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("AgentExports", isDirectory: true)
        let transcriptRepository = transcriptRepository
        exportWork.async { [weak self] in
            do {
                let selected = try repository.manifests().filter { selectedIDs.contains($0.id) }
                let transcripts = try transcriptRepository?.transcripts(for: selected) ?? [:]
                let url = try AgentExportBuilder.createArchive(repository: repository,
                    selectedIDs: selectedIDs, destinationDirectory: destination, transcripts: transcripts)
                Task { @MainActor [weak self] in
                    self?.agentExportURL = url
                    self?.isPreparingAgentExport = false
                }
            } catch {
                let message = error.localizedDescription
                Task { @MainActor [weak self] in
                    self?.agentExportError = message
                    self?.isPreparingAgentExport = false
                }
            }
        }
    }

    func todaySegments(at now: Date) -> [SegmentManifest] {
        manifests.filter { Calendar.current.isDate($0.startedAt, inSameDayAs: now) }
    }

    var sessionGroups: [PhoneSessionGroup] { PhoneSessionGroup.groups(from: manifests) }

    func prepareDiagnostics(includeFullHistory: Bool = false) {
        guard !isPreparingDiagnostics else { return }
        // Clear every previous artifact before any fallible operation. Failure
        // cannot accidentally share the last successful report.
        exportURL = nil
        diagnosticExportSummary = nil
        diagnosticExportError = nil
        diagnosticIssueID = nil
        diagnosticBuild = nil
        diagnosticTimingSummary = nil
        diagnosticLifecycle = nil
        diagnosticLifecycleStorageFailed = false
        let repository = repository
        isPreparingDiagnostics = true
        diagnosticPreparationIncludesFullHistory = includeFullHistory
        let issueID = UUID(), startedAt = Date(), startedUptime = ProcessInfo.processInfo.systemUptime
        diagnosticStartedUptime = startedUptime
        diagnosticIssueID = issueID.uuidString
        let build = RedactedDiagnosticReport.safeBuild(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown")
        diagnosticBuild = build
        let runID = diagnosticProcessRunID, operatingSystem = ProcessInfo.processInfo.operatingSystemVersion
        let root = root
        // These are already displayed memory observations, not a new library
        // enumeration or verification. Never request Watch data to fill a gap.
        let memory = RedactedDiagnosticMemory(capturedAt: startedAt,
            librarySnapshotObservedAt: librarySnapshotObservedAt, librarySnapshotAvailable: hasLibrarySnapshot,
            segmentCount: manifests.count, receiptCount: receivedSegmentIDs.count,
            visibleEventCount: events.count, storageFailureObserved: storageError != nil)
        let watch = RedactedDiagnosticWatch(snapshot: connection.snapshot, reachable: connection.reachable, at: startedAt)
        let statusQueries = connectivity?.statusDiagnosticSnapshot()
        // MainActor memory only: no actor call, folder access, refresh or audio
        // verification is permitted while preparing a diagnostic attachment.
        let iCloudStatus = personalLibrary?.iCloudDrive.diagnosticSnapshot(at: startedAt)
            ?? ICloudDriveDiagnosticSnapshot(observation: nil, at: startedAt)
        // Copy the already retained typed fault report. It is a separate local
        // observation: exporting never closes a context window or starts sync.
        let googleFaults = personalLibrary?.drive.diagnosticFaultSnapshot()
            ?? GoogleDriveDiagnosticFaultSnapshot(status: .unavailable, capturedAt: Date(),
                storageFailureObserved: false, report: nil, error: .libraryUnavailable)
        let diagnosticQueue = includeFullHistory ? fullDiagnosticWork : diagnosticWork
        diagnosticQueue.async { [weak self] in
            do {
                let deadline = startedUptime + (includeFullHistory ? 10 : 5)
                let shouldContinue = { ProcessInfo.processInfo.systemUptime < deadline }
                let history: RedactedDiagnosticEventBatch
                if let repository, includeFullHistory {
                    history = try DiagnosticHistoryReader.read(root: repository.root, at: startedAt, while: shouldContinue)
                } else if let repository {
                    history = .recent(try repository.recentEventsSnapshot(at: startedAt, limit: 500,
                        while: shouldContinue), at: startedAt)
                } else {
                    history = .unavailable(includeFullHistory: includeFullHistory, at: startedAt)
                }
                let finishedAt = Date()
                let report = RedactedDiagnosticReport(issueID: issueID, processRunID: runID, build: build,
                    operatingSystem: operatingSystem, collectionStartedAt: startedAt, collectionFinishedAt: finishedAt,
                    collectionElapsedMS: (ProcessInfo.processInfo.systemUptime - startedUptime) * 1_000,
                    memory: memory, watch: watch, eventHistory: history)
                let export = PhoneDiagnosticBundle(report: report, googleTransportFaults: googleFaults,
                    statusQueries: statusQueries, iCloudDriveStatus: iCloudStatus)
                // Enforce the cap on the final envelope, including Google fault
                // and status-query snapshots, not only on each attachment.
                let url = try DiagnosticReportStorage.writeReport(TransportCodec.encode(export), issueID: issueID, root: root)
                let watchSummary: String
                switch watch.availability {
                case .missing: watchSummary = "手表缓存状态缺失，未请求补齐。"
                case .invalidTimestamp: watchSummary = "手表缓存时间无效，未当作当前状态。"
                case .stale: watchSummary = "手表缓存状态已过时（约 \(Int(watch.ageSeconds ?? 0)) 秒前）。"
                case .cached: watchSummary = "附手表缓存状态（约 \(Int(watch.ageSeconds ?? 0)) 秒前）。"
                }
                let summary = (includeFullHistory ? "完整历史" : "近期日志")
                    + "：\(history.events.count) 条脱敏事件。"
                    + (history.availability == .unavailable ? "录音库不可用，事件历史未观察，未当作零条完整历史。" : "")
                    + (history.truncated ? "日志范围已限量，文件中已注明覆盖限制。" : "")
                    + "数量来自已有内存快照，未复验录音。" + watchSummary + " " + googleFaults.summary
                    + " " + iCloudStatus.summary
                Task { @MainActor [weak self] in
                    guard let self, self.diagnosticIssueID == issueID.uuidString else { return }
                    self.diagnosticLifecycle = .init(issueID: issueID, requestedAt: startedAt, fileReadyAt: Date(),
                        fileReadyElapsedMS: (ProcessInfo.processInfo.systemUptime - startedUptime) * 1_000)
                    self.exportURL = url; self.diagnosticExportSummary = summary
                    self.isPreparingDiagnostics = false
                    self.persistDiagnosticLifecycle()
                }
            } catch {
                // Raw error descriptions can contain paths/identities.
                let message = error is CancellationError
                    ? "日志读取超过时间上限，未生成或沿用旧报告。可稍后重试。"
                    : "诊断文件生成失败，未生成或沿用旧报告；未读取或校验音频。"
                Task { @MainActor [weak self] in
                    guard let self, self.diagnosticIssueID == issueID.uuidString else { return }
                    self.exportURL = nil; self.diagnosticExportError = message
                    self.isPreparingDiagnostics = false
                }
            }
        }
    }

    func diagnosticSharePresented() {
        guard var value = diagnosticLifecycle, value.panelPresentedAt == nil,
              exportURL != nil, let start = diagnosticStartedUptime else { return }
        value.panelPresentedAt = Date()
        value.panelPresentedElapsedMS = (ProcessInfo.processInfo.systemUptime - start) * 1_000
        diagnosticLifecycle = value
        persistDiagnosticLifecycle()
    }

    func diagnosticShareCompleted(completed: Bool) {
        guard var value = diagnosticLifecycle, value.activityFinishedAt == nil,
              exportURL != nil, let start = diagnosticStartedUptime else { return }
        value.activityFinishedAt = Date()
        value.activityFinishedElapsedMS = (ProcessInfo.processInfo.systemUptime - start) * 1_000
        value.systemActivityCompleted = completed
        diagnosticLifecycle = value
        persistDiagnosticLifecycle()
    }

    private func persistDiagnosticLifecycle() {
        guard let value = diagnosticLifecycle else { return }
        let milliseconds = { (number: Double) in String(format: "%.2f 秒", number / 1_000) }
        var summary = "文件就绪 \(milliseconds(value.fileReadyElapsedMS))"
        if let panel = value.panelPresentedElapsedMS { summary += " · 分享面板回调 \(milliseconds(panel))" }
        if let finish = value.activityFinishedElapsedMS {
            summary += " · 系统分享结束 \(milliseconds(finish))"
            summary += value.systemActivityCompleted == true ? "（系统回报完成，未确认接收方送达）" : "（未完成或已取消，未确认发送）"
        }
        if diagnosticLifecycleStorageFailed { summary += " · 耗时收据保存失败" }
        diagnosticTimingSummary = summary
        let root = root
        diagnosticWork.async { [weak self] in
            do { try DiagnosticReportStorage.writeLifecycle(value, root: root) }
            catch {
                Task { @MainActor [weak self] in
                    guard let self, self.diagnosticIssueID == value.issueID.uuidString,
                          !self.diagnosticLifecycleStorageFailed else { return }
                    self.diagnosticLifecycleStorageFailed = true
                    self.diagnosticTimingSummary = (self.diagnosticTimingSummary ?? "") + " · 耗时收据保存失败"
                }
            }
        }
    }
}

private struct PhoneLibraryRead: Sendable {
    let manifests: [SegmentManifest]?
    let receivedSegmentIDs: Set<UUID>?
    let eventSnapshot: RecordingDiagnosticEventSnapshot?
    let error: String?
}

private struct PhoneDiagnosticBundle: Encodable, Sendable {
    let report: RedactedDiagnosticReport
    let googleTransportFaults: GoogleDriveDiagnosticFaultSnapshot
    let statusQueries: PhoneStatusDiagnosticSnapshot?
    let iCloudDriveStatus: ICloudDriveDiagnosticSnapshot
}
