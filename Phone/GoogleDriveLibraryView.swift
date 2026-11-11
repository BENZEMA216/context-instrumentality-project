import RecordingCore
import SwiftUI

/// Kept for the existing library-tools entry point.
struct GoogleDriveLibraryCard: View {
    @ObservedObject var drive: GoogleDriveLibrary
    let phoneRecordingCount: Int

    var body: some View {
        GoogleDriveConnectionRow(drive: drive, phoneRecordingCount: phoneRecordingCount)
            .background(RecordDesign.surface, in: RoundedRectangle(cornerRadius: 20))
            .recordRow()
    }
}

/// Opening a connection only presents its settings; it does not resume work.
struct GoogleDriveConnectionRow: View {
    @ObservedObject var drive: GoogleDriveLibrary
    let phoneRecordingCount: Int
    @State private var showingDetails = false

    var body: some View {
        let status = GoogleDriveDetailStatus(drive: drive)
        CloudConnectionRow(title: "Google Drive", subtitle: status.summary,
                           systemImage: "triangle", statusSymbol: status.symbol,
                           statusColor: status.color,
                           actionTitle: drive.isConnected || drive.isRevocationPending ? nil : "连接") {
            showingDetails = true
        }
        .padding(16)
        .accessibilityIdentifier("google-drive-row")
        .sheet(isPresented: $showingDetails) {
            GoogleDriveLibraryDetailView(drive: drive, phoneRecordingCount: phoneRecordingCount)
        }
    }
}

struct GoogleDriveLibraryDetailView: View {
    @ObservedObject var drive: GoogleDriveLibrary
    let phoneRecordingCount: Int
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    @State private var selection: GoogleDriveRecordingScope?
    @State private var confirmsRevoke = false
    @State private var confirmsReconnect = false
    @State private var confirmsResume = false
    @State private var showingStatus = false

    private var status: GoogleDriveDetailStatus { GoogleDriveDetailStatus(drive: drive) }

    var body: some View {
        Group {
            if embedded { detailContent } else { ScrollView { detailContent } }
        }
        .background(RecordDesign.background).foregroundStyle(RecordDesign.ink)
        .presentationDetents([.large]).presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .alert(status.title, isPresented: $showingStatus) {
            Button("知道了", role: .cancel) { }
        } message: { Text(status.explanation) }
        .confirmationDialog("断开 Google Drive？", isPresented: $confirmsRevoke, titleVisibility: .visible) {
            Button("停止并撤销授权", role: .destructive) { drive.revoke() }
                .accessibilityIdentifier("google-drive-disconnect-confirm")
            Button("取消", role: .cancel) { }
                .accessibilityIdentifier("google-drive-disconnect-cancel")
        } message: {
            Text("停止同步并撤销此应用的 Google 授权。手机和云盘文件保留，Agent 的 Google 连接单独管理。")
        }
        .alert("重新连接原 Google 账户？", isPresented: $confirmsReconnect) {
            Button(drive.isRevocationPending ? "重新授权并保持同步关闭" : "继续登录原账户") { drive.connect() }
                .accessibilityIdentifier("google-drive-reconnect-confirm")
            Button("取消", role: .cancel) { }
                .accessibilityIdentifier("google-drive-reconnect-cancel")
        } message: {
            Text(drive.isRevocationPending
                 ? "这会重新授权此应用，不表示 Google 已确认旧授权撤销。请登录原 Google 账户；原文件夹、录音范围和已有文件保留。重新连接后自动同步仍关闭，需再次明确开启。"
                 : "重新连接会先关闭本机自动同步。请使用原 Google 账户；原文件夹、录音范围和已有文件保留。登录完成后仍需明确开启自动同步。")
        }
        .alert("继续 Google Drive 自动同步？", isPresented: $confirmsResume) {
            Button("按原范围继续同步") { drive.continueSync() }
                .accessibilityIdentifier("google-drive-resume-confirm")
            Button("取消", role: .cancel) { }
                .accessibilityIdentifier("google-drive-resume-cancel")
        } message: {
            Text("将按当前账户、原文件夹和原录音范围继续上传未完成的录音及已有转写，不更换目录或扩大范围。已有云盘文件保留。")
        }
    }

    private var detailContent: some View {
            VStack(alignment: .leading, spacing: 20) {
                if !embedded {
                HStack {
                    Text("Google Drive").font(.title3.weight(.semibold))
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.subheadline).frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain).foregroundStyle(RecordDesign.secondary)
                    .accessibilityLabel("关闭 Google Drive 详情")
                    .accessibilityIdentifier("google-drive-close")
                }
                }
                HStack(spacing: 12) {
                    CloudProviderIcon(systemImage: "triangle")
                    VStack(alignment: .leading, spacing: 5) {
                        Text(drive.accountLabel).font(.subheadline.weight(.medium))
                        Text(status.authorizationSummary)
                            .font(.caption).foregroundStyle(RecordDesign.secondary)
                            .accessibilityIdentifier("google-drive-authorization-state")
                    }
                    Spacer(minLength: 4)
                    Button { showingStatus = true } label: {
                        Image(systemName: status.symbol).font(.system(size: 20)).frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain).foregroundStyle(status.color)
                    .accessibilityLabel("\(status.title)，查看说明")
                    .accessibilityIdentifier("google-drive-status")
                }

                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("自动同步", value: status.synchronizationSummary)
                        .accessibilityIdentifier("google-drive-sync-state")
                    LabeledContent("当前状态", value: status.summary)
                        .accessibilityIdentifier("google-drive-current-state")
                    Text("同步说明").font(.caption).foregroundStyle(RecordDesign.secondary)
                    Text(status.latestResult).font(.subheadline).foregroundStyle(status.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("google-drive-latest-result")
                    if let failedAt = drive.lastFailureAt {
                        Text("最近失败：" + failedAt.formatted(date: .abbreviated, time: .standard))
                            .font(.caption).foregroundStyle(RecordDesign.secondary)
                            .accessibilityIdentifier("google-drive-last-failure-time")
                    }
                    if let next = status.retryEstimate {
                        Text("预计重试 \(next.formatted(date: .abbreviated, time: .shortened)) · 后台执行由系统安排")
                            .font(.caption).foregroundStyle(RecordDesign.secondary)
                            .accessibilityIdentifier("google-drive-next-attempt-time")
                    }
                    if drive.canCheckNetworkRecovery {
                        Button("网络已恢复，检查并继续") { drive.checkAfterNetworkRecovery() }
                            .buttonStyle(RecordSecondaryButtonStyle())
                            .accessibilityIdentifier("google-drive-check-network-recovery")
                    }
                    if drive.apiFailureReason == .storageQuotaExceeded && drive.isEnabled && drive.isConnected {
                        Button("检查同步") { drive.resume() }
                            .buttonStyle(RecordSecondaryButtonStyle()).disabled(drive.isBusy)
                            .accessibilityIdentifier("google-drive-check-sync")
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("允许使用蜂窝网络", isOn: Binding(
                        get: { drive.allowsCellularAccess },
                        set: { drive.setAllowsCellularAccess($0) }))
                        .tint(RecordDesign.secondary)
                        .accessibilityIdentifier("google-drive-cellular-toggle")
                    Text("关闭时仅使用 Wi-Fi 等非蜂窝网络。开启后可能产生移动数据费用。更改适用于新请求；已交给系统的上传保留提交时的选择。旧版本队列完成核对前，新上传仍可使用 Wi-Fi，暂不能使用蜂窝网络。")
                        .font(.caption).foregroundStyle(RecordDesign.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if drive.isWaitingForWiFi {
                        Text("等待 Wi-Fi：当前仅有蜂窝网络，且未允许使用蜂窝网络。")
                            .font(.caption).foregroundStyle(RecordDesign.secondary)
                            .accessibilityIdentifier("google-drive-waiting-wifi")
                    }
                }
                .padding(16).background(RecordDesign.surface, in: RoundedRectangle(cornerRadius: 16))

                if drive.isRevocationPending {
                    Text("本机已停止同步。Google 尚未确认撤销此应用授权；Agent 的 Google 连接单独管理。")
                        .font(.subheadline).foregroundStyle(RecordDesign.secondary)
                    Button("重试撤销授权") { drive.revoke() }
                        .buttonStyle(RecordSecondaryButtonStyle())
                        .disabled(drive.isBusy || !drive.canRetryRevocation)
                        .accessibilityIdentifier("google-drive-retry-revoke")
                    if !drive.canRetryRevocation {
                        disabledReason("当前无法取得可用于撤销的凭据，暂不能再次提交。请前往 Google 权限管理，核对并移除此应用授权；云盘文件保留。",
                                       identifier: "google-drive-revoke-disabled-reason")
                    } else if drive.isBusy {
                        disabledReason("正在等待本次撤销结果，完成后才可重试。", identifier: "google-drive-revoke-disabled-reason")
                    }
                    Link("前往 Google 权限管理", destination: URL(string: "https://myaccount.google.com/permissions")!)
                        .buttonStyle(RecordSecondaryButtonStyle())
                        .accessibilityIdentifier("google-drive-manage-permissions")
                    Button("重新连接原 Google 账户") { confirmsReconnect = true }
                        .buttonStyle(RecordSecondaryButtonStyle())
                        .disabled(status.connectionDisabledReason != nil)
                        .accessibilityIdentifier("google-drive-reconnect")
                    if let reason = status.connectionDisabledReason {
                        disabledReason(reason, identifier: "google-drive-connect-disabled-reason")
                    }
                } else if !drive.isConnected || drive.needsCredential {
                    if drive.scope != nil {
                        settings(scope: drive.scope)
                        Text("重新登录原 Google 账户，沿用原录音范围；登录后再开启自动同步。")
                            .font(.caption).foregroundStyle(RecordDesign.secondary)
                    }
                    Button(drive.scope == nil ? "连接 Google 账户" : "重新连接原 Google 账户") {
                        if drive.hasAuthorizationHistory { confirmsReconnect = true } else { drive.connect() }
                    }
                        .buttonStyle(RecordPrimaryButtonStyle())
                        .disabled(!drive.isConfigured || drive.isBusy)
                        .accessibilityIdentifier(drive.scope == nil ? "google-drive-connect" : "google-drive-reconnect")
                    if let reason = status.connectionDisabledReason {
                        disabledReason(reason, identifier: "google-drive-connect-disabled-reason")
                    }
                } else if drive.scope == nil {
                    Text("同步设置").font(.caption.weight(.semibold))
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("录音范围", selection: $selection) {
                            Text("选择范围").tag(nil as GoogleDriveRecordingScope?)
                            Text("仅新录音").tag(GoogleDriveRecordingScope.futureOnly as GoogleDriveRecordingScope?)
                                .accessibilityIdentifier("google-drive-scope-future")
                            Text("全部录音").tag(GoogleDriveRecordingScope.existingAndFuture as GoogleDriveRecordingScope?)
                                .accessibilityIdentifier("google-drive-scope-all")
                        }
                        .pickerStyle(.menu).disabled(drive.isBusy)
                        .accessibilityIdentifier("google-drive-scope")
                        Text(selection == nil ? "选择允许保存到 Google Drive 的录音。" : selection == .futureOnly
                             ? "仅授权后开始录制、并传到手机的录音。已有录音和旧积压不会加入。"
                             : "手机现有及以后收到的录音，包含原录音和已有转写。")
                            .font(.caption).foregroundStyle(RecordDesign.secondary)
                    }
                    .padding(16).background(RecordDesign.surface, in: RoundedRectangle(cornerRadius: 16))
                    Text("此次授权仅用于 Google Drive。")
                        .font(.caption).foregroundStyle(RecordDesign.secondary)
                    Button("开启同步") { if let selection { drive.enable(selection) } }
                        .buttonStyle(RecordPrimaryButtonStyle()).disabled(drive.isBusy || selection == nil)
                        .accessibilityIdentifier("google-drive-enable")
                    if drive.isBusy || selection == nil {
                        disabledReason(drive.isBusy ? "当前操作尚未结束，完成后才可开启同步。" : "请先选择录音范围。",
                                       identifier: "google-drive-enable-disabled-reason")
                    }
                } else {
                    settings(scope: drive.scope)
                    if let url = drive.folderURL {
                        Link("查看云盘文件夹", destination: url)
                            .buttonStyle(RecordSecondaryButtonStyle())
                            .accessibilityIdentifier("google-drive-folder")
                    }
                    if drive.error != nil && !drive.isEnabled {
                        Button("重新连接原 Google 账户") { confirmsReconnect = true }
                            .buttonStyle(.borderless).disabled(drive.isBusy)
                            .accessibilityIdentifier("google-drive-reconnect")
                        if let reason = status.connectionDisabledReason {
                            disabledReason(reason, identifier: "google-drive-connect-disabled-reason")
                        }
                    }
                }

                if drive.isConnected && !drive.isRevocationPending {
                    Button("断开连接", role: .destructive) { confirmsRevoke = true }
                        .buttonStyle(.borderless)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(RecordDesign.accent)
                        .accessibilityIdentifier("google-drive-disconnect")
                }
            }
            .padding(.horizontal, embedded ? 0 : 24).padding(.top, 12).padding(.bottom, 24)
    }

    private func settings(scope: GoogleDriveRecordingScope?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("同步设置").font(.caption.weight(.semibold))
            VStack(spacing: 0) {
                HStack {
                    Text("录音范围").foregroundStyle(RecordDesign.secondary)
                    Spacer()
                    Text(scope == .futureOnly ? "仅新录音" : "全部录音")
                }
                .font(.subheadline).padding(.vertical, 16)
                Divider().overlay(RecordDesign.rule)
                Toggle("自动同步", isOn: Binding(
                    get: { drive.isEnabled },
                    set: { enabled in if enabled { confirmsResume = true } else { drive.pause() } }))
                    .font(.subheadline).tint(RecordDesign.secondary)
                    .padding(.vertical, 10)
                    .disabled(status.toggleDisabledReason != nil)
                    .accessibilityIdentifier("google-drive-toggle")
                if let reason = status.toggleDisabledReason {
                    Text(reason).font(.caption).foregroundStyle(RecordDesign.secondary)
                        .padding(.bottom, 12)
                        .accessibilityIdentifier("google-drive-toggle-disabled-reason")
                }
            }
            .padding(.horizontal, 16)
            .background(RecordDesign.surface, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func disabledReason(_ text: String, identifier: String) -> some View {
        Text(text).font(.caption).foregroundStyle(RecordDesign.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(identifier)
    }
}

// BEGIN GOOGLE CONNECTION PRESENTATION
struct GoogleDriveDetailStatus {
    let title: String
    let symbol: String
    let color: Color
    let explanation: String
    let note: String?
    let authorizationSummary: String
    let synchronizationSummary: String
    let latestResult: String
    let retryEstimate: Date?
    let connectionDisabledReason: String?
    let toggleDisabledReason: String?

    var summary: String { title }

    @MainActor
    init(drive: GoogleDriveLibrary) {
        let mayRetry = drive.isEnabled && drive.isConnected && drive.isConfigured
            && !drive.isRevocationPending && !drive.needsCredential && !drive.isWaitingForWiFi
            && (drive.apiFailureReason?.isRateLimit ?? true)
        retryEstimate = mayRetry ? drive.nextPlannedAttemptAt : nil
        let waitingToRetry = retryEstimate != nil && !drive.isBusy
        let retryGuidance = "将自动重试，无需操作。"
        authorizationSummary = drive.isRevocationPending ? "Google 撤销尚未确认"
            : !drive.isConfigured ? "此版本暂不可登录"
            : drive.needsCredential ? "原 Google 账户需重新连接"
            : drive.isNetworkFailure ? (drive.isConnected ? "Google 凭据已保留" : "Google 尚未连接")
            : drive.error != nil && drive.nextPlannedAttemptAt == nil ? "账户连接需要处理"
            : drive.isConnected ? "Google 账户已连接"
            : drive.hasAuthorizationHistory ? "原 Google 账户需重新连接" : "尚未连接 Google 账户"
        synchronizationSummary = drive.isRevocationPending ? "本机已停止"
            : drive.isEnabled ? "已开启" : "已关闭"
        latestResult = drive.isRevocationPending
            ? "本机已停止同步，Google 尚未确认撤销此应用授权。云盘文件保留。" + (drive.error.map { "\n最近操作：" + $0 } ?? "")
            : drive.needsCredential ? "Google 凭据需要处理，请重新连接原账户。原同步范围保持不变。"
            : drive.isNetworkFailure ? "连接 Google 失败。请检查当前网络及连接 Google 所需的网络服务；恢复后可检查并继续。"
            : drive.apiFailureReason?.isRateLimit == true ? "Google 暂时限制了请求频率。" + (waitingToRetry ? retryGuidance : "")
            : waitingToRetry ? [drive.error, retryGuidance].compactMap { $0 }.joined(separator: "\n")
            : drive.error ?? drive.activity
        connectionDisabledReason = !drive.isConfigured ? "此版本未配置 Google 登录，暂时无法连接。"
            : drive.isBusy ? "正在处理当前操作，完成后才可连接账户。" : nil
        toggleDisabledReason = !drive.isConnected || drive.needsCredential ? "请先连接原 Google 账户，自动同步保持关闭。"
            : drive.isBusy && !drive.isEnabled ? "当前操作尚未结束，完成后才可开启自动同步。" : nil
        if drive.isRevocationPending {
            title = "本机已停止 · 撤销待确认"; symbol = "exclamationmark.circle"; color = RecordDesign.warning
            explanation = "本机已停止发送。Google 尚未确认撤销此应用授权；云盘文件保留。"
            note = "本机已停止同步，Google 撤销仍待确认"
        } else if !drive.isConfigured {
            title = "暂不可用"; symbol = "exclamationmark.circle"; color = RecordDesign.warning
            explanation = "此安装版本尚未配置 Google 登录。手机录音和现有同步不受影响。"
            note = explanation
        } else if drive.needsCredential {
            title = "需重新连接"; symbol = "link"; color = RecordDesign.warning
            explanation = "Google 凭据需要处理，请重新连接原账户。原录音范围和云盘文件保留。"
            note = explanation
        } else if drive.isNetworkFailure && drive.isEnabled {
            title = "Google 连接失败"; symbol = "wifi.exclamationmark"; color = RecordDesign.warning
            explanation = "连接 Google 失败。请检查当前网络及连接 Google 所需的网络服务。网络恢复后可点击“网络已恢复，检查并继续”；重试会保留原账户、范围和上传进度。"
            note = drive.nextPlannedAttemptAt == nil ? title : "Google 连接失败 · 等待重试"
        } else if let reason = drive.apiFailureReason, !reason.isRateLimit {
            title = reason == .storageQuotaExceeded ? "云盘空间不足" : "需处理"
            symbol = "exclamationmark.circle"; color = RecordDesign.warning
            explanation = reason.explanation; note = title
        } else if waitingToRetry {
            title = "等待重试"; symbol = "clock"; color = RecordDesign.secondary
            explanation = (drive.apiFailureReason?.isRateLimit == true ? "Google 暂时限制了请求频率。" : "")
                + retryGuidance + "后台执行时间由系统安排。"
            note = title
        } else if let error = drive.error {
            title = "需处理"; symbol = "exclamationmark.circle"; color = RecordDesign.warning
            explanation = error; note = error
        } else if !drive.isConnected {
            title = drive.hasAuthorizationHistory ? "需重新连接" : "未连接"
            symbol = "link"; color = RecordDesign.secondary
            explanation = drive.hasAuthorizationHistory ? "请重新登录原 Google 账户。原录音范围保持不变。" : "连接后，还需单独选择录音同步范围。"
            note = nil
        } else if drive.scope == nil {
            title = "待选择范围"; symbol = "circle.dashed"; color = RecordDesign.secondary
            explanation = "Google 账户已连接；选择录音范围并开启同步后，才会发送录音。"
            note = nil
        } else if !drive.isEnabled {
            title = "已暂停同步"; symbol = "pause.circle"; color = RecordDesign.secondary
            explanation = "后续自动同步已暂停，已保存的文件、进度和原录音范围保留。"
            note = "已暂停同步"
        } else if drive.isWaitingForWiFi {
            title = "等待 Wi-Fi"; symbol = "wifi"; color = RecordDesign.secondary
            explanation = "当前仅有蜂窝网络，且未允许使用蜂窝网络。可连接 Wi-Fi，或在同步设置中允许蜂窝网络；原同步范围保持不变。"
            note = title
        } else if drive.isBusy || drive.hasPendingWork {
            title = "同步未完成"; symbol = "arrow.triangle.2.circlepath"; color = RecordDesign.secondary
            explanation = "正在处理或等待继续保存所选范围的录音和相关文件。网络恢复或再次打开 App 后会继续。"
            note = "同步未完成，将继续保存"
        } else if drive.isWaitingForNewRecordings {
            title = "等待新录音"; symbol = "clock"; color = RecordDesign.secondary
            explanation = "授权后开始录制、并传到手机的录音才会加入。"
            note = title
        } else if drive.isCurrentScopeSaved {
            title = "已保存"; symbol = "checkmark.circle"; color = RecordDesign.good
            explanation = "所选范围的录音和相关文件已保存到 Google Drive。云盘保存不代表 Agent 已读取。"
            note = nil
        } else {
            title = "已连接"; symbol = "link"; color = RecordDesign.secondary
            explanation = "已连接 Google Drive；当前尚无可确认已保存的录音。"
            note = nil
        }
    }
}
// END GOOGLE CONNECTION PRESENTATION
