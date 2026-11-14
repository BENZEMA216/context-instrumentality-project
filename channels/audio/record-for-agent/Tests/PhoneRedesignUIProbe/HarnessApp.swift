import Combine
import Foundation
import RecordingCore
import SwiftUI
import UIKit

// Simulator-only executable. Production views and RecordingActivity are compiled
// unchanged; all stores below are synthetic in-memory doubles. No repository,
// transport, Keychain, WatchConnectivity, audio, file draft or notification center.
@main
struct RedesignUIProbeApp: App {
    @StateObject private var store = PhoneStore()
    private let largeType = ProcessInfo.processInfo.environment["PROBE_LARGE_TYPE"] == "1"
    private let dark = ProcessInfo.processInfo.environment["PROBE_DARK"] == "1"
    private let controls = ProcessInfo.processInfo.environment["PROBE_CONTROLS"] != "0"
    @State private var statusExitScheduled = false

    init() { UserDefaults.standard.removeObject(forKey: "sync.destination.v1") }
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 0) {
                if controls, let delivery = store.automaticDelivery {
                    HStack(spacing: 12) {
                        Button("Next", action: delivery.advance).accessibilityIdentifier("probe-next")
                        Button("Cycle", action: delivery.startCycle).accessibilityIdentifier("probe-cycle")
                        Button("Stop", action: delivery.stopCycle).accessibilityIdentifier("probe-stop")
                        Button("Draft") { delivery.draftAvailable = true }
                            .accessibilityIdentifier("probe-draft")
                        Button("Fail") { delivery.failRemoval = true }
                            .accessibilityIdentifier("probe-fail-removal")
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityValue("合成连接提交 \(delivery.pairSubmissionCount) 次")
                    .font(.caption).dynamicTypeSize(.medium).frame(height: 38)
                    .frame(maxWidth: .infinity).background(.yellow.opacity(0.15))
                }
                if let library = store.personalLibrary {
                    ProbeCloudCalls(drive: library.drive, iCloud: library.iCloudDrive)
                }
                PhoneHomeView().environmentObject(store)
                    .environment(\.dynamicTypeSize, largeType ? .accessibility5 : .large)
            }
            .overlay(alignment: .topTrailing) {
                if ProcessInfo.processInfo.environment["PROBE_STATUS_TRACE"] == "1" {
                    Text(store.statusWaitProbeTrace).font(.system(size: 7)).frame(width: 250)
                        .foregroundStyle(.secondary).allowsHitTesting(false)
                        .accessibilityIdentifier("probe-status-wait-trace")
                }
            }
            .preferredColorScheme(dark ? .dark : .light)
            .onChange(of: store.isRequestingStatus) { _, pending in
                guard pending, !statusExitScheduled,
                      ProcessInfo.processInfo.environment["PROBE_LEAVE_HOME_DURING_STATUS"] == "1" else { return }
                statusExitScheduled = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard store.isRequestingStatus else { return }
                    // XCTest waits for the native refresh animation to end.
                    // Move the real tab controller during the pending query so
                    // the production page's disappearance can be exercised.
                    let windows = UIApplication.shared.connectedScenes
                        .compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
                    if let root = windows.first(where: \.isKeyWindow)?.rootViewController,
                       let tabs = Self.tabController(in: root) {
                        tabs.selectedIndex = 1
                    }
                }
            }
        }
    }

    private static func tabController(in controller: UIViewController) -> UITabBarController? {
        if let tabs = controller as? UITabBarController { return tabs }
        return controller.children.compactMap { tabController(in: $0) }.first
    }
}

private struct ProbeCloudCalls: View {
    @ObservedObject var drive: GoogleDriveLibrary
    @ObservedObject var iCloud: ICloudDriveLibrary

    var body: some View {
        Text("G:\(drive.callDescription) I:\(iCloud.callDescription)")
            .font(.system(size: 6)).accessibilityIdentifier("probe-cloud-calls")
    }
}

private enum SyntheticLibrary {
    static let now = Date()
    static let recordState = ProcessInfo.processInfo.environment["PROBE_RECORD_STATE"] ?? "recorded"
    static let manifests: [SegmentManifest] = {
        guard !["empty", "unknown", "stale-empty", "recording-empty"].contains(recordState) else { return [] }
        let midnight = Calendar.current.startOfDay(for: now)
        if recordState == "long-directory" {
            return (1...12).map { offset in
                let day = Calendar.current.date(byAdding: .day, value: -offset, to: midnight)!
                let start = day.addingTimeInterval(3_600)
                let id = UUID()
                return SegmentManifest(id: id, sessionID: UUID(), sequence: 0,
                    startedAt: start, endedAt: start.addingTimeInterval(60), sampleRate: 24_000,
                    frameCount: 1_440_000, fileName: "synthetic-day-\(offset).m4a", byteCount: 0,
                    sha256: String(repeating: "0", count: 64))
            }
        }
        if recordState == "yesterday-only" {
            let start = midnight.addingTimeInterval(-1_050)
            let id = UUID()
            return [SegmentManifest(id: id, sessionID: UUID(), sequence: 0,
                startedAt: start, endedAt: start.addingTimeInterval(23), sampleRate: 24_000,
                frameCount: 552_000, fileName: "synthetic-yesterday.m4a", byteCount: 0,
                sha256: String(repeating: "0", count: 64),
                recordingGroup: RecordingGroup(startedAt: start, timeZone: .current, firstSequence: 0))]
        }
        if recordState == "two-recording-groups" || recordState == "partial-recording-sync" {
            let start = recordState == "partial-recording-sync"
                ? midnight.addingTimeInterval(-480) : max(midnight, now.addingTimeInterval(-480))
            let secondStart = start.addingTimeInterval(150)
            let session = UUID()
            let first = RecordingGroup(startedAt: start, timeZone: .current, firstSequence: 0)
            let second = RecordingGroup(startedAt: secondStart, timeZone: .current, firstSequence: 2)
            // Deliver the second recording's last part first, as the system may do.
            return [6, 0, 1, 2, 3, 4, 5].map { sequence in
                let group = sequence < 2 ? first : second
                let date = group.startedAt.addingTimeInterval(Double(sequence - group.firstSequence) * 60)
                let id = UUID()
                return SegmentManifest(id: id, sessionID: session, sequence: sequence,
                    startedAt: date, endedAt: date.addingTimeInterval(60), sampleRate: 24_000,
                    frameCount: 1_440_000, fileName: id.uuidString.lowercased() + ".caf",
                    byteCount: 0, sha256: String(repeating: "0", count: 64), recordingGroup: group)
            }
        }
        if recordState == "cross-day-period" {
            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: midnight)!
            let morning = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: yesterday)!
            let beforeMidnight = midnight.addingTimeInterval(-120)
            let intervals = [(morning, morning.addingTimeInterval(1_200)),
                             (beforeMidnight, midnight.addingTimeInterval(120))]
            return intervals.enumerated().map { index, interval in
                SegmentManifest(
                    id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1))!,
                    sessionID: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!,
                    sequence: index, startedAt: interval.0, endedAt: interval.1, sampleRate: 24_000,
                    frameCount: Int64(interval.1.timeIntervalSince(interval.0) * 24_000),
                    fileName: "synthetic-cross-day-\(index).m4a", byteCount: 0,
                    sha256: String(repeating: "0", count: 64), timeZoneIdentifier: TimeZone.current.identifier)
            }
        }
        let availableSeconds = max(1, now.timeIntervalSince(midnight) - 2)
        let totalDuration = min(3 * 3600 + 42 * 60 + 18, availableSeconds)
        let segmentDuration = totalDuration / 137
        let firstStart = now.addingTimeInterval(-totalDuration - 1)
        return (0..<137).map { index in
            let session = index < 47 ? 1 : index < 94 ? 2 : 3
            let firstSequence = session == 1 ? 0 : session == 2 ? 47 : 94
            let start = firstStart.addingTimeInterval(Double(index) * segmentDuration)
            return SegmentManifest(
                id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1))!,
                sessionID: UUID(uuidString: String(format: "10000000-0000-4000-8000-%012d", session))!,
                sequence: index - firstSequence, startedAt: start,
                endedAt: start.addingTimeInterval(segmentDuration), sampleRate: 24_000,
                frameCount: Int64((segmentDuration * 24_000).rounded()),
                fileName: "synthetic-\(index).m4a", byteCount: 0,
                sha256: String(repeating: "0", count: 64), timeZoneIdentifier: TimeZone.current.identifier)
        }
    }()
}

struct PhoneConnectionState {
    var supported = true
    var activated = true
    var paired = true
    var watchAppInstalled = true
    var reachable = true
    var snapshot: RecorderSnapshot?
    var lastError: String?
}

// These outcomes match the production status-only store API. This harness has
// no WatchConnectivity transport and cannot issue a sync or inspect recordings.
enum PhoneStatusRequestResult {
    case received(RecorderSnapshot)
    case unsupportedWatchVersion, noReport, staleReport, waitingForConnection, connectionStarting
    case unsupported, watchNotPaired, watchAppMissing, timedOut, failed

    var message: String {
        switch self {
        case .received: return "已收到手表录音状态。"
        case .unsupportedWatchVersion: return "当前手表版本不支持只读状态查询。请在手表 App 查看当前状态。"
        case .noReport: return "手表尚无可用的录音状态报告。请在手表 App 查看当前状态。"
        case .staleReport: return "手表返回的是上次报告，尚未收到当前状态。请在手表 App 核对。"
        case .waitingForConnection: return "暂时无法联系手表。"
        case .connectionStarting: return "正在建立手表连接，请稍后重试。"
        case .unsupported: return "当前设备不支持 Apple Watch 状态查询。"
        case .watchNotPaired: return "请先在这台 iPhone 上配对 Apple Watch。"
        case .watchAppMissing: return "请先在配对的 Apple Watch 上安装 Record for Agent。"
        case .timedOut: return "暂未收到状态更新。请打开手表 App，确认当前录音状态。"
        case .failed: return "暂时无法读取手表状态，请稍后重试。"
        }
    }
    var isError: Bool {
        if case .received = self { return false }
        return true
    }
}

@MainActor
final class PhoneStore: ObservableObject {
    @Published var observationPreparationMessage = "合成观察状态；不读取同步记录。"
    func prepareObservationSnapshots() { observationPreparationMessage = "合成观察请求；未访问真实数据。" }

    @Published var hasLibrarySnapshot = ProcessInfo.processInfo.environment["PROBE_LIBRARY_FAILED"] != "1"
    @Published var manifests = SyntheticLibrary.manifests
    @Published var receivedSegmentIDs = Set(SyntheticLibrary.manifests.map(\.id))
    @Published var events: [RecordingEvent] = []
    @Published var connection: PhoneConnectionState
    @Published var storageError: String? = ProcessInfo.processInfo.environment["PROBE_LIBRARY_FAILED"] == "1"
        ? "Synthetic failure" : nil
    @Published var exportURL: URL? = ProcessInfo.processInfo.environment["PROBE_DIAGNOSTICS"] == "export_error"
        ? URL(fileURLWithPath: "/synthetic-stale-report.json") : nil
    @Published var isPreparingDiagnostics = false
    @Published var diagnosticPreparationIncludesFullHistory = false
    @Published var diagnosticExportSummary: String?
    @Published var diagnosticExportError: String?
    @Published var diagnosticIssueID: String?
    @Published var diagnosticBuild: String?
    @Published var diagnosticTimingSummary: String?
    var eventHistorySummary: String { "近期 0 条；未加载完整历史" }
    @Published var syncFeedback: String?
    @Published var isRequestingSync = false
    @Published var isRequestingStatus = false
    @Published var statusFeedback: String?
    @Published var statusFeedbackIsError = false
    @Published var statusQueryIntentID: UUID?
    @Published var statusRequestGeneration: UUID?
    @Published var isAwaitingStatusRecovery = false
    @Published var statusWaitProbeTrace = "waitEntries=0; cancelledAtEntry=0; requestStarts=0; cancelRequests=0; waitCancellations=0; waitFinishes=0"
    @Published var personalLibrary: PersonalLibraryStore? = PersonalLibraryStore()
    @Published var automaticDelivery: PhoneAutomaticDeliveryStore? = PhoneAutomaticDeliveryStore()
    private var syncRequestSequence = 0
    private var statusRequestSequence = 0
    private var statusWaitEntries = 0
    private var statusWaitCancelledAtEntry = 0
    private var statusRequestStarts = 0
    private var statusCancelRequests = 0
    private var statusWaitCancellations = 0
    private var statusWaitFinishes = 0
    private var statusWaitStartedAt: Date?
    private var statusWaitCancelledAfterMS = -1
    private var statusWaitFinishedAfterMS = -1

    private func updateStatusWaitProbeTrace() {
        statusWaitProbeTrace = "waitEntries=\(statusWaitEntries); cancelledAtEntry=\(statusWaitCancelledAtEntry); requestStarts=\(statusRequestStarts); cancelRequests=\(statusCancelRequests); waitCancellations=\(statusWaitCancellations); waitFinishes=\(statusWaitFinishes); cancelledAfterMS=\(statusWaitCancelledAfterMS); finishedAfterMS=\(statusWaitFinishedAfterMS)"
    }

    init() {
        let state = SyntheticLibrary.recordState
        if state == "unknown" || state == "unknown-saved" {
            connection = PhoneConnectionState(snapshot: nil)
            return
        }
        let stale = state.hasPrefix("stale")
        let captureState: CaptureState
        switch state {
        case "empty": captureState = .idle
        case "paused": captureState = .paused
        case "interrupted", "stale-interrupted": captureState = .interrupted
        case "failed": captureState = .failed
        default: captureState = .recording
        }
        connection = PhoneConnectionState(snapshot: RecorderSnapshot(
            state: captureState, sessionID: SyntheticLibrary.manifests.last?.sessionID,
            observedAt: SyntheticLibrary.now.addingTimeInterval(stale ? -600 : 0),
            pendingCount: SyntheticLibrary.manifests.isEmpty ? 0 : 2, pendingCountIsKnown: true))
    }

    var sessionGroups: [PhoneSessionGroup] { PhoneSessionGroup.groups(from: manifests) }

    func requestSync() {
        // Match the production request gate, but use only scheduled in-memory
        // events. An acknowledgement is deliberately separate from a snapshot.
        guard !isRequestingSync else { return }
        syncRequestSequence += 1
        let request = syncRequestSequence
        let previousObservedAt = connection.snapshot?.observedAt
        let response = ProcessInfo.processInfo.environment["PROBE_SYNC_RESPONSE"] ?? "report"
        isRequestingSync = true
        syncFeedback = "合成状态请求；未连接手表。"
        Task { @MainActor [weak self] in
            if response == "no-response" {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard let self, self.syncRequestSequence == request else { return }
                self.isRequestingSync = false
                self.syncFeedback = "合成请求超时；没有收到报告。"
                return
            }

            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, self.syncRequestSequence == request else { return }
            self.isRequestingSync = false
            self.syncFeedback = "合成请求已接收；这不是新的录制报告。"
            if response == "ack-only" { return }

            if response == "newer-stale-then-report" {
                // A timestamp newer than the request baseline is insufficient
                // when the report itself is still more than 60 seconds old.
                self.receiveSyntheticReport(at: (previousObservedAt ?? Date().addingTimeInterval(-600))
                    .addingTimeInterval(1), state: .paused)
            }
            if response == "ack-then-report" || response == "newer-stale-then-report" {
                try? await Task.sleep(nanoseconds: 3_750_000_000)
            } else if response == "late-report" {
                try? await Task.sleep(nanoseconds: 9_750_000_000)
            }
            guard self.syncRequestSequence == request else { return }
            self.receiveSyntheticReport(at: Date(), state: .paused)
        }
    }

    @discardableResult
    func requestStatus(completion: @escaping @MainActor (PhoneStatusRequestResult) -> Void = { _ in }) -> UUID? {
        guard !isRequestingStatus else { return nil }
        cancelStatusRequest()
        let intent = UUID()
        statusQueryIntentID = intent
        startSyntheticStatus(intent: intent, isRecovery: false, completion: completion)
        return intent
    }

    private func startSyntheticStatus(intent: UUID, isRecovery: Bool,
                                      completion: @escaping @MainActor (PhoneStatusRequestResult) -> Void = { _ in }) {
        guard statusQueryIntentID == intent, !isRequestingStatus else { return }
        statusRequestStarts += 1
        updateStatusWaitProbeTrace()
        statusRequestSequence += 1
        let request = statusRequestSequence
        statusRequestGeneration = UUID()
        let previousObservedAt = connection.snapshot?.observedAt
        let response = ProcessInfo.processInfo.environment["PROBE_SYNC_RESPONSE"] ?? "report"
        isRequestingStatus = true
        isAwaitingStatusRecovery = false
        statusFeedback = isRecovery ? "连接已恢复，正在重新查询手表录音状态…" : "正在查询手表录音状态…"
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: response == "no-response" || response == "late-report"
                                  ? 8_000_000_000 : 250_000_000)
            guard let self, self.statusRequestSequence == request, self.statusQueryIntentID == intent else { return }
            let outcome: PhoneStatusRequestResult
            switch response {
            case "unreachable-then-recovery" where !isRecovery: outcome = .waitingForConnection
            case "unsupported", "ack-only": outcome = .unsupportedWatchVersion
            case "no-report": outcome = .noReport
            case "stale-report": outcome = .staleReport
            case "no-response", "late-report": outcome = .timedOut
            default:
                if response == "newer-stale-then-report" {
                    self.receiveSyntheticReport(at: (previousObservedAt ?? Date().addingTimeInterval(-600))
                        .addingTimeInterval(1), state: .paused)
                }
                if response == "ack-then-report" || response == "newer-stale-then-report" || response == "delayed-report" {
                    // The early uncorrelated event never completes this query.
                    try? await Task.sleep(nanoseconds: response == "delayed-report" ? 6_250_000_000 : 3_750_000_000)
                    guard self.statusRequestSequence == request else { return }
                }
                self.receiveSyntheticReport(at: Date(), state: .paused)
                outcome = .received(self.connection.snapshot!)
            }
            self.isRequestingStatus = false
            self.statusFeedback = outcome.message
            self.statusFeedbackIsError = outcome.isError
            if case .waitingForConnection = outcome {
                self.isAwaitingStatusRecovery = true
                self.statusFeedback = outcome.message
            }
            completion(outcome)
            if self.isAwaitingStatusRecovery {
                // Controlled UI fixture only. Production availability/retry logic
                // is exercised separately with actual Connectivity/Store methods.
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard self.statusQueryIntentID == intent, self.statusRequestSequence == request,
                      self.isAwaitingStatusRecovery else { return }
                self.startSyntheticStatus(intent: intent, isRecovery: true)
            }
            if response == "late-report" {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard self.statusRequestSequence == request else { return }
                self.receiveSyntheticReport(at: Date(), state: .paused)
            }
        }
    }

    func cancelStatusRequest(ifIntentID: UUID? = nil) {
        if let ifIntentID, statusQueryIntentID != ifIntentID { return }
        if statusQueryIntentID != nil {
            statusCancelRequests += 1
            updateStatusWaitProbeTrace()
        }
        statusRequestSequence += 1
        statusQueryIntentID = nil
        statusRequestGeneration = nil
        isAwaitingStatusRecovery = false
        isRequestingStatus = false
        statusFeedback = nil
        statusFeedbackIsError = false
    }

    func waitForStatusRequest(intentID: UUID) async {
        await waitForSyntheticStatus(intentID: intentID, ownsRequest: true)
    }

    func requestStatusAndWait() async {
        guard !Task.isCancelled else { return }
        let ownsRequest = !isRequestingStatus
        if ownsRequest {
            guard let intent = requestStatus() else { return }
            await waitForSyntheticStatus(intentID: intent, ownsRequest: true)
        } else if let intent = statusQueryIntentID {
            await waitForSyntheticStatus(intentID: intent, ownsRequest: false)
        }
    }

    private func waitForSyntheticStatus(intentID: UUID, ownsRequest: Bool) async {
        statusWaitEntries += 1
        statusWaitStartedAt = Date()
        if Task.isCancelled { statusWaitCancelledAtEntry += 1 }
        updateStatusWaitProbeTrace()
        guard statusQueryIntentID == intentID else { return }
        let observedRequest = statusRequestSequence
        while statusQueryIntentID == intentID && statusRequestSequence == observedRequest && isRequestingStatus {
            do { try await Task.sleep(nanoseconds: 50_000_000) }
            catch {
                statusWaitCancellations += 1
                statusWaitCancelledAfterMS = Int(Date().timeIntervalSince(statusWaitStartedAt ?? Date()) * 1_000)
                updateStatusWaitProbeTrace()
                if ownsRequest && statusQueryIntentID == intentID && statusRequestSequence == observedRequest {
                    cancelStatusRequest(ifIntentID: intentID)
                }
                return
            }
        }
        statusWaitFinishes += 1
        statusWaitFinishedAfterMS = Int(Date().timeIntervalSince(statusWaitStartedAt ?? Date()) * 1_000)
        updateStatusWaitProbeTrace()
    }

    private func receiveSyntheticReport(at observedAt: Date, state: CaptureState) {
        var updated = connection
        updated.reachable = true
        updated.snapshot = RecorderSnapshot(
            state: state, sessionID: SyntheticLibrary.manifests.last?.sessionID,
            observedAt: observedAt, pendingCount: SyntheticLibrary.manifests.isEmpty ? 0 : 2,
            pendingCountIsKnown: true)
        connection = updated
        // No manifests, receipts or durations change when a status report arrives.
    }
    func prepareDiagnostics(includeFullHistory: Bool = false) {
        guard !isPreparingDiagnostics else { return }
        isPreparingDiagnostics = true
        diagnosticPreparationIncludesFullHistory = includeFullHistory
        exportURL = nil
        diagnosticExportSummary = nil
        diagnosticExportError = nil
        diagnosticIssueID = nil
        diagnosticTimingSummary = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            defer { isPreparingDiagnostics = false }
            if ProcessInfo.processInfo.environment["PROBE_DIAGNOSTICS"] == "export_error" {
                diagnosticExportError = "合成诊断导出失败；没有使用旧文件。"
                return
            }
            do {
                // Only a constant synthetic JSON is written for the native
                // share UI. This store has no repository or transport.
                let issueID = UUID().uuidString
                let folder = FileManager.default.temporaryDirectory
                    .appendingPathComponent("IssueShareUIProbe", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                       attributes: [.posixPermissions: 0o700])
                let scope = includeFullHistory ? "full-history" : "recent"
                let url = folder.appendingPathComponent("synthetic-issue-\(scope)-\(issueID).json")
                try Data(#"{"synthetic":true,"includesAudio":false,"includesTranscripts":false}"#.utf8)
                    .write(to: url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                diagnosticIssueID = issueID
                diagnosticBuild = "UI-PROBE"
                diagnosticExportSummary = includeFullHistory
                    ? "完整历史：合成日志 24 条，未截断。未读取音频或转写。"
                    : "近期与故障日志：合成日志 8 条，范围已限制，完整历史未加载。"
                diagnosticTimingSummary = "合成报告已准备；分享面板尚未打开。"
                exportURL = url
            } catch {
                diagnosticExportError = "合成诊断导出失败；没有使用旧文件。"
            }
        }
    }

    func diagnosticSharePresented() {
        diagnosticTimingSummary = "合成报告分享面板已打开；不代表已发送。"
    }

    func diagnosticShareCompleted(completed: Bool) {
        diagnosticTimingSummary = completed
            ? "系统活动已完成；不代表接收方已收到。" : "已取消分享；未发送。"
    }
}

struct AutomaticReceiverPairingPayload: Codable {
    let schemaVersion: Int
    let endpoint: String
    let receiverID: UUID
    let token: String
    let certificateSHA256: String

    static func parse(_ input: String) throws -> Self {
        guard let data = input.data(using: .utf8),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.schemaVersion == 1,
              URL(string: value.endpoint)?.scheme == "https" else {
            throw AutomaticReceiverError.invalidPairing
        }
        return value
    }
}

enum AutomaticReceiverError: LocalizedError {
    case invalidPairing
    var errorDescription: String? { "配对信息无效（合成测试）。" }
}

@MainActor
final class PhoneReceiverDeliveryStore: ObservableObject, Identifiable {
    let id: UUID
    var receiverID: UUID { id }
    let displayName: String
    let receiverName = "synthetic-receiver.invalid"
    let endpoint: String? = "https://synthetic-receiver.invalid:9443"
    let certificateSHA256: String? = String(repeating: "a", count: 64)
    let isPaired = true
    @Published var isEnabled: Bool
    @Published var isPreparing: Bool
    @Published var deliveredSegmentIDs: Set<UUID>
    @Published var lastReceiptAt: Date? = SyntheticLibrary.now.addingTimeInterval(-60)
    @Published var lastProbeAt: Date?
    @Published var lastProbeFailure: AutomaticReceiverFailureCategory?
    @Published var isCheckingConnection = false
    @Published var lastTransferAt: Date?
    @Published var lastTransferFailure: AutomaticReceiverFailureCategory?
    @Published var lastTransferDeliveryID: UUID?
    @Published var lastIncompleteDeliveryAt: Date?
    @Published var lastIncompleteDeliveryMessage: String?
    @Published var deliveredCount: Int
    @Published var queuedCount: Int
    @Published var uploadingCount = 0
    @Published var blockedCount = 0
    @Published var blockedReason: String?
    @Published var activity = "正在准备合成片段。"
    @Published var error: String?
    let availableRecordings = SyntheticLibrary.manifests
    let receivedSegmentIDs = Set(SyntheticLibrary.manifests.map(\.id))
    let hasLibrarySnapshot = true
    var availableReceivedCount: Int { availableRecordings.count }
    var totalJobs: Int { availableRecordings.count }
    var phase = 0
    var pairingStatusTitle: String { "配对已保存" }
    var reachabilityTitle: String {
        if isCheckingConnection { return "正在检查连接" }
        guard lastProbeAt != nil else { return "当前可达性未确认" }
        return lastProbeFailure.map { "连接检查：\($0.title)" } ?? "检查时可连接"
    }
    var lastTransferTitle: String {
        guard lastTransferAt != nil else { return "尚无传输结果记录" }
        return lastTransferFailure.map { "失败 · \($0.title)" } ?? "成功 · 保存回执已核对"
    }
    var connectionWarning: Bool { lastProbeFailure != nil || lastTransferFailure != nil || error != nil }
    var connectionHint: String? { (lastProbeFailure ?? lastTransferFailure)?.hint }
    var connectionSummary: String {
        if lastProbeFailure != nil { return "配对已保存 · 连接检查失败" }
        if lastTransferFailure != nil { return "配对已保存 · 最近传输失败" }
        let reachability = lastProbeAt == nil ? "可达性未确认" : "检查时可连接"
        return (isEnabled ? "自动同步已开启 · " : "自动同步已暂停 · ") + reachability
    }

    init(index: Int = 0) {
        id = UUID(uuidString: String(format: "20000000-0000-4000-8000-%012d", index + 1))!
        displayName = index == 0 ? "我的 Agent" : "工作 Agent"
        isEnabled = index == 0
        isPreparing = index == 0
        let count = min(index == 0 ? 132 : 80, SyntheticLibrary.manifests.count)
        deliveredCount = count
        queuedCount = SyntheticLibrary.manifests.count - count
        deliveredSegmentIDs = Set(SyntheticLibrary.manifests.prefix(count).map(\.id))
        if ProcessInfo.processInfo.environment["PROBE_RECEIVER_HEALTH"] == "reachable-transfer-failed" {
            lastTransferAt = SyntheticLibrary.now.addingTimeInterval(-90)
            lastTransferFailure = .timeout
            lastTransferDeliveryID = UUID(uuidString: "30000000-0000-4000-8000-000000000001")!
        }
    }

    var statusTitle: String {
        if !isEnabled { return "已暂停自动发送" }
        if blockedCount > 0 { return "部分交付需要检查" }
        if uploadingCount > 0 { return "正在交付到接收端" }
        if isPreparing { return "正在准备交付" }
        if queuedCount > 0 { return "等待接收端接收" }
        return "自动同步已开启"
    }

    func checkConnectionIfNeeded() async {
        // Cadence is verified against the production worker in the multi-receiver probe.
        if lastProbeAt == nil { await checkConnection() }
    }
    func checkConnection() async {
        // Fixed metadata-only states exercise production presentation. Actual
        // request lifecycle and receipt validation run in PhoneMultiReceiverProbe.
        switch ProcessInfo.processInfo.environment["PROBE_RECEIVER_HEALTH"] {
        case "timeout": lastProbeAt = SyntheticLibrary.now; lastProbeFailure = .timeout
        case "reachable-transfer-failed": lastProbeAt = SyntheticLibrary.now; lastProbeFailure = nil
        default: break
        }
    }
    func requestDeliveryCheck() { resume() }
    func resume() { isPreparing = isEnabled && queuedCount > 0 }
    func setEnabled(_ value: Bool) {
        isEnabled = value
        if !value { isPreparing = false; uploadingCount = 0 }
    }
    func advance() {
        guard isEnabled else { return }
        phase = (phase + 1) % 3
        switch phase {
        case 0:
            isPreparing = true
            uploadingCount = 0
            activity = "正在准备合成片段。"
        case 1:
            isPreparing = false
            uploadingCount = 1
            activity = "正在发送合成片段。"
        default:
            isPreparing = false
            uploadingCount = 0
            deliveredCount = deliveredCount == totalJobs ? 0 : deliveredCount + 1
            deliveredSegmentIDs = Set(availableRecordings.prefix(deliveredCount).map(\.id))
            lastReceiptAt = SyntheticLibrary.now
            activity = "接收端已确认保存。同一录音可供已接入的多个 Agent 读取。"
        }
        queuedCount = max(0, totalJobs - deliveredCount - uploadingCount)
    }
}

@MainActor
final class PhoneAutomaticDeliveryStore: ObservableObject {
    @Published var receivers: [PhoneReceiverDeliveryStore]
    @Published var error: String?
    @Published var activity = ""
    let availableRecordings = SyntheticLibrary.manifests
    let receivedSegmentIDs = Set(SyntheticLibrary.manifests.map(\.id))
    var availableReceivedCount: Int { availableRecordings.count }
    let hasLibrarySnapshot = true
    var draftAvailable = ProcessInfo.processInfo.environment["PROBE_DRAFT"] == "1"
    var failRemoval = ProcessInfo.processInfo.environment["PROBE_FAIL_REMOVAL"] == "1"
    @Published var pairSubmissionCount = 0
    private var timer: Timer?
    private var observations: Set<AnyCancellable> = []
    var isPaired: Bool { !receivers.isEmpty }
    var statusTitle: String { "已配对 \(receivers.count) 个接收端 · 合成测试" }

    init() {
        let count = min(2, max(0, Int(ProcessInfo.processInfo.environment["PROBE_RECEIVERS"] ?? "1") ?? 1))
        receivers = (0..<count).map { PhoneReceiverDeliveryStore(index: $0) }
        for receiver in receivers { observe(receiver) }
    }
    private func observe(_ receiver: PhoneReceiverDeliveryStore) {
        receiver.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &observations)
    }
    func resume() {}
    func advance() { receivers.first?.advance() }
    func startCycle() {
        stopCycle()
        timer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advance() }
        }
    }
    func stopCycle() { timer?.invalidate(); timer = nil }
    func loadPairingDraft() throws -> String? {
        guard draftAvailable else { return nil }
        let value = AutomaticReceiverPairingPayload(
            schemaVersion: 1, endpoint: "https://fresh-fixture.invalid:9443",
            receiverID: UUID(uuidString: "11111111-2222-4333-8444-555555555555")!,
            token: "SYNTHETIC-NON-AUTHENTICATING-TEST-TOKEN",
            certificateSHA256: String(repeating: "a", count: 64))
        return String(data: try JSONEncoder().encode(value), encoding: .utf8)
    }
    func pair(_ payload: AutomaticReceiverPairingPayload, name: String) -> Bool {
        // Records the explicitly authorized UI action only. No transport exists.
        pairSubmissionCount += 1
        activity = "合成配对提交已记录。"
        return true
    }
    func removeReceiver(_ id: UUID) -> Bool {
        if failRemoval {
            receivers.first(where: { $0.id == id })?.setEnabled(false)
            error = "合成删除失败：原接收端和队列已保留。"
            return false
        }
        receivers.removeAll { $0.id == id }
        return true
    }
}

// The production reminder VIEW is extracted verbatim by verify.py. Its store
// double ensures even an explicit toggle never requests permission or schedules.
@MainActor
final class RecordingReminderStore: ObservableObject {
    static let shared = RecordingReminderStore()
    @Published var isEnabled = false
    @Published var time = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date())!
    @Published var isUpdating = false
    @Published var message: String?
    @Published var authorizationDenied = false
    func refresh() async {}
    func setEnabled(_ enabled: Bool, at selectedTime: Date) async {
        time = selectedTime
        isEnabled = enabled
        message = "合成提醒设置；未请求通知权限或创建通知。"
    }
    func updateTime(_ selectedTime: Date) async { time = selectedTime }
}

@MainActor final class PersonalLibraryStore: ObservableObject {
    let drive = GoogleDriveLibrary()
    let iCloudDrive = ICloudDriveLibrary()
}
@MainActor
final class GoogleDriveLibrary: ObservableObject {
    var apiFailureReason: GoogleDriveAPIReason?

    @Published var allowsCellularAccess = false
    private var isOnSyntheticCellularPath = false
    var isWaitingForWiFi: Bool { isOnSyntheticCellularPath && !allowsCellularAccess && hasPendingWork }
    @Published var isConnected = true
    @Published var isEnabled = true
    @Published var isBusy = false
    @Published var isRevocationPending = false
    @Published var canRetryRevocation = true
    @Published var accountLabel = "Synthetic Google Account"
    @Published var scope: GoogleDriveRecordingScope? = .existingAndFuture
    @Published var authorizedManifests = SyntheticLibrary.manifests
    @Published var cloudConfirmedRecordingIDs: Set<UUID> = []
    @Published var authorizedCount = 3
    @Published var savedAudioCount = 2
    @Published var savedTranscriptCount = 1
    @Published var pendingFileCount = 4
    @Published var folderURL: URL? = URL(string: "https://drive.google.com/drive/folders/synthetic-library")
    @Published var activity = "合成状态；不连接云盘。"
    @Published var isNetworkFailure = false
    @Published var needsCredential = false
    @Published var lastFailureAt: Date?
    @Published var nextPlannedAttemptAt: Date?
    @Published var canCheckNetworkRecovery = false
    func checkAfterNetworkRecovery() {}
    @Published var error: String?
    let isConfigured = true
    @Published var transportFaultCount = 0
    @Published var latestTransportFaultAt: Date?
    @Published var transportFaultSummary = "尚无故障记录。"
    @Published var transportFaultExportError: String?
    func prepareTransportFaultShare() -> URL? {
        guard ProcessInfo.processInfo.environment["PROBE_DRIVE_FAULT"] == "retained" else {
            transportFaultExportError = "合成导出失败；已有故障记录保留。"
            return nil
        }
        do {
            // This fixture writes only this constant synthetic JSON. It owns no
            // repository, transport, cloud account, recording or credential.
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("FaultShareUIProbe", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            let url = folder.appendingPathComponent("synthetic-fault-\(UUID().uuidString).json")
            try Data(#"{"schemaVersion":1,"synthetic":true,"reports":[{"state":"interrupted"}]}"#.utf8)
                .write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            transportFaultExportError = nil
            return url
        } catch {
            transportFaultExportError = "合成导出失败；已有故障记录保留。"
            return nil
        }
    }
    @Published private(set) var resumeCalls = 0
    @Published private(set) var continueCalls = 0
    @Published private(set) var pauseCalls = 0
    @Published private(set) var enableCalls = 0
    @Published private(set) var revokeCalls = 0
    @Published private(set) var connectCalls = 0

    init(scenario: String = ProcessInfo.processInfo.environment["PROBE_PROVIDER_SCENARIO"] ?? "complete") {
        isOnSyntheticCellularPath = scenario == "waiting-wifi"
        if scenario == "paused" { isEnabled = false }
        if scenario == "complete" { savedAudioCount = 3; savedTranscriptCount = 2; pendingFileCount = 0 }
        if scenario == "waiting-retry" { nextPlannedAttemptAt = Date(timeIntervalSinceNow: 600) }
        if scenario == "unscoped" { scope = nil; isEnabled = false; authorizedCount = 0; savedAudioCount = 0; savedTranscriptCount = 0; pendingFileCount = 0 }
        if scenario == "revoking" || scenario == "revoking-busy" {
            isRevocationPending = true; isEnabled = false; isConnected = false
            isBusy = scenario == "revoking-busy"
        }
        if scenario == "revoking-legacy" {
            isRevocationPending = true; isEnabled = false; isConnected = false; canRetryRevocation = false
        }
        if scenario == "auth-error" {
            isEnabled = false; isConnected = false
            error = "Google 授权已失效，请重新登录原账户。"
        }
    }

    var hasPendingWork: Bool { isEnabled && pendingFileCount > 0 }
    var hasAuthorizationHistory: Bool { scope != nil }
    var isCurrentScopeSaved: Bool {
        isConnected && isEnabled && scope != nil && authorizedCount > 0
            && savedAudioCount == authorizedCount && !isBusy && error == nil && !hasPendingWork
    }
    var isWaitingForNewRecordings: Bool {
        isConnected && isEnabled && scope == .futureOnly && authorizedCount == 0
            && !isBusy && error == nil && !hasPendingWork
    }
    var callDescription: String { "resume=\(resumeCalls);continue=\(continueCalls);pause=\(pauseCalls);enable=\(enableCalls);revoke=\(revokeCalls);connect=\(connectCalls)" }
    var grantDescription: String { "connected=\(isConnected);enabled=\(isEnabled);scope=\(scope?.rawValue ?? "none")" }
    func setAllowsCellularAccess(_ value: Bool) { allowsCellularAccess = value }
    func resume() { resumeCalls += 1 }
    func connect() { connectCalls += 1 }
    func enable(_ mode: GoogleDriveRecordingScope) { enableCalls += 1; scope = mode; isEnabled = true }
    func pause() { pauseCalls += 1; isEnabled = false }
    func continueSync() { continueCalls += 1; isEnabled = true }
    func revoke() { revokeCalls += 1; isConnected = false; isEnabled = false }
}

@MainActor
final class ICloudDriveLibrary: ObservableObject {
    @Published private(set) var readOnlyCalls = 0
    @Published var recoveryConfirmationRequired = false
    @Published private(set) var recoveryConfirmCalls = 0
    @Published private(set) var recoveryCancelCalls = 0
    @Published var folderName = "Synthetic iCloud Folder"
    @Published var isConnected = true
    @Published var isEnabled = true
    @Published var isBusy = false
    @Published var busyMessage = "正在核对合成状态"
    @Published var scope: ICloudDriveRecordingScope? = .existingAndFuture
    @Published var authorizedManifests = SyntheticLibrary.manifests
    @Published var locallyWrittenRecordingIDs = Set(SyntheticLibrary.manifests.map(\.id))
    @Published var cloudConfirmedRecordingIDs: Set<UUID> = []
    @Published var authorizedCount = 3
    @Published var savedAudioCount = 2
    @Published var savedTranscriptCount = 1
    @Published var uploadedFileCount = 10
    @Published var pendingCloudFileCount = 4
    @Published var activity = "合成状态；不访问 iCloud、录音或网络。"
    @Published var error: String?
    // This harness only injects a folder-identity failure. Keep that scenario
    // blocking when the production View distinguishes provider warnings.
    var hasBlockingError: Bool { error != nil }
    @Published private(set) var resumeCalls = 0
    @Published private(set) var setEnabledCalls = 0
    @Published private(set) var authorizeCalls = 0
    @Published private(set) var disconnectCalls = 0
    @Published private(set) var connectCalls = 0

    init(scenario: String = ProcessInfo.processInfo.environment["PROBE_PROVIDER_SCENARIO"] ?? "complete") {
        if scenario == "paused" { isEnabled = false }
        if scenario == "directory-recovery" { isEnabled = false; recoveryConfirmationRequired = true }
        if scenario == "folder-mismatch" {
            isEnabled = false
            error = "所选文件夹无法确认为原同步目录，已停止写入。请选择原来用于同步录音的文件夹；不会覆盖现有文件。"
        }
        if scenario == "complete" || scenario == "waiting-retry" {
            savedAudioCount = 3; savedTranscriptCount = 2; uploadedFileCount = 14; pendingCloudFileCount = 0
            cloudConfirmedRecordingIDs = locallyWrittenRecordingIDs
        }
        if SyntheticLibrary.recordState == "partial-recording-sync" {
            cloudConfirmedRecordingIDs = Set(SyntheticLibrary.manifests.filter { $0.sequence != 1 }.map(\.id))
            pendingCloudFileCount = 1
        }
        if scenario == "unscoped" { scope = nil; isEnabled = false; authorizedCount = 0; savedAudioCount = 0; savedTranscriptCount = 0; uploadedFileCount = 0; pendingCloudFileCount = 0 }
    }

    func diagnosticSnapshot(at now: Date = Date()) -> ICloudDriveDiagnosticSnapshot {
        .init(observation: .init(observedAt: now, sourceDiscoveryComplete: true,
            counts: .init(authorizedSources: authorizedCount, locallyWrittenAudio: savedAudioCount,
                locallyWrittenTranscripts: savedTranscriptCount, providerConfirmedFiles: uploadedFileCount,
                pendingProviderFiles: pendingCloudFileCount)), at: now,
            connected: isConnected, enabled: isEnabled, operationFailed: error != nil)
    }
    var hasAuthorizationHistory: Bool { scope != nil }
    var hasPendingWork: Bool {
        isConnected && isEnabled && scope != nil
            && (isBusy || error != nil || savedAudioCount < authorizedCount || pendingCloudFileCount > 0)
    }
    private var hasSettledCurrentGrant: Bool {
        isConnected && isEnabled && scope != nil && !isBusy && error == nil
    }
    var isWaitingForNewRecordings: Bool { hasSettledCurrentGrant && scope == .futureOnly && authorizedCount == 0 }
    var isCurrentScopeWritten: Bool { hasSettledCurrentGrant && authorizedCount > 0 && savedAudioCount == authorizedCount }
    var isCurrentScopeUploaded: Bool { isCurrentScopeWritten && uploadedFileCount > 0 && pendingCloudFileCount == 0 }
    var callDescription: String { "readOnly=\(readOnlyCalls);resume=\(resumeCalls);toggle=\(setEnabledCalls);authorize=\(authorizeCalls);disconnect=\(disconnectCalls);connect=\(connectCalls)" }
    var grantDescription: String { "connected=\(isConnected);enabled=\(isEnabled);scope=\(scope?.rawValue ?? "none")" }
    var recoveryDescription: String { "pending=\(recoveryConfirmationRequired);confirm=\(recoveryConfirmCalls);cancel=\(recoveryCancelCalls)" }
    func confirmDirectoryRecovery() { recoveryConfirmCalls += 1; recoveryConfirmationRequired = false; isEnabled = false }
    func cancelDirectoryRecovery() { recoveryCancelCalls += 1; recoveryConfirmationRequired = false }
    func checkCloudStatusReadOnly() { readOnlyCalls += 1; activity = "只读检查完成；持续保存设置不变。" }
    func resume() { resumeCalls += 1 }
    func disconnect() { disconnectCalls += 1; isConnected = false; isEnabled = false }
    func setEnabled(_ enabled: Bool) { setEnabledCalls += 1; isEnabled = enabled }
    func pause() { setEnabled(false) }
    func connect(to url: URL) { connectCalls += 1 }
    func authorize(scope: ICloudDriveRecordingScope, knownManifests: [SegmentManifest], receivedIDs: Set<UUID>) {
        authorizeCalls += 1; self.scope = scope; isEnabled = true
    }
}

struct PersonalLibraryView: View {
    let library: PersonalLibraryStore
    var body: some View { Text("合成测试不连接旧录音库。") }
}
struct AgentExportView: View {
    var body: some View { Text("合成测试不导出录音。") }
}
