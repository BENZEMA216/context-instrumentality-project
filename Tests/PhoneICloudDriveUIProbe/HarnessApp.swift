import Combine
import Foundation
import RecordingCore
import SwiftUI

/// A separate simulator app. Production rows own their real detail sheets;
/// only the libraries are replaced by stores that count calls in memory.
@main
struct ICloudDriveUIProbeApp: App {
    @StateObject private var google: GoogleDriveLibrary
    @StateObject private var cloud: ICloudDriveLibrary

    init() {
        let args = ProcessInfo.processInfo.arguments
        let index = args.firstIndex(of: "--probe-scenario")
        let scenario = index.flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } ?? "pending"
        _google = StateObject(wrappedValue: GoogleDriveLibrary(scenario: scenario))
        _cloud = StateObject(wrappedValue: ICloudDriveLibrary(scenario: scenario))
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                List {
                    GoogleDriveConnectionRow(drive: google, phoneRecordingCount: 3)
                    ICloudDriveConnectionRow(library: cloud, manifests: [],
                        receivedIDs: [], hasLibrarySnapshot: true)
                }
                .recordListAppearance()
                .navigationTitle("云盘合成界面验证")
                .safeAreaInset(edge: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(google.callDescription).accessibilityIdentifier("probe-google-calls")
                        Text(google.grantDescription).accessibilityIdentifier("probe-google-grant")
                        Text(cloud.callDescription).accessibilityIdentifier("probe-icloud-calls")
                        Text(cloud.grantDescription).accessibilityIdentifier("probe-icloud-grant")
                        Text(cloud.recoveryDescription).accessibilityIdentifier("probe-icloud-recovery")
                        Text("readonly=\(cloud.readOnlyCalls)").accessibilityIdentifier("probe-icloud-readonly")
                    }
                    .font(.system(size: 8)).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(5).background(.yellow.opacity(0.12))
                }
            }
        }
    }
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
    @Published var authorizedCount = 3
    @Published var savedAudioCount = 2
    @Published var savedTranscriptCount = 1
    @Published var pendingFileCount = 4
    @Published var folderURL: URL?
    @Published var activity = "合成状态；不连接云盘。"
    @Published var isNetworkFailure = false
    @Published var needsCredential = false
    @Published var lastFailureAt: Date?
    @Published var nextPlannedAttemptAt: Date?
    @Published var canCheckNetworkRecovery = false
    func checkAfterNetworkRecovery() {}
    @Published var error: String?
    let isConfigured = true
    @Published private(set) var resumeCalls = 0
    @Published private(set) var continueCalls = 0
    @Published private(set) var pauseCalls = 0
    @Published private(set) var enableCalls = 0
    @Published private(set) var revokeCalls = 0
    @Published private(set) var connectCalls = 0

    init(scenario: String) {
        isOnSyntheticCellularPath = scenario == "waiting-wifi"
        if scenario == "paused" { isEnabled = false }
        if scenario == "complete" { savedAudioCount = 3; savedTranscriptCount = 2; pendingFileCount = 0 }
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

    init(scenario: String) {
        if scenario == "paused" { isEnabled = false }
        if scenario == "directory-recovery" { isEnabled = false; recoveryConfirmationRequired = true }
        if scenario == "folder-mismatch" {
            isEnabled = false
            error = "所选文件夹无法确认为原同步目录，已停止写入。请选择原来用于同步录音的文件夹；不会覆盖现有文件。"
        }
        if scenario == "complete" { savedAudioCount = 3; savedTranscriptCount = 2; uploadedFileCount = 14; pendingCloudFileCount = 0 }
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
    var callDescription: String { "resume=\(resumeCalls);toggle=\(setEnabledCalls);authorize=\(authorizeCalls);disconnect=\(disconnectCalls);connect=\(connectCalls)" }
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
