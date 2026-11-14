import RecordingCore
import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// Kept for the existing library-tools entry point.
struct ICloudDriveLibraryCard: View {
    @ObservedObject var library: ICloudDriveLibrary
    let manifests: [SegmentManifest]
    let receivedIDs: Set<UUID>
    let hasLibrarySnapshot: Bool

    var body: some View {
        ICloudDriveConnectionRow(library: library, manifests: manifests, receivedIDs: receivedIDs,
                                 hasLibrarySnapshot: hasLibrarySnapshot)
            .background(RecordDesign.surface, in: RoundedRectangle(cornerRadius: 20))
            .recordRow()
    }
}

/// Showing connection details never changes its enabled state or starts a scan.
struct ICloudDriveConnectionRow: View {
    @ObservedObject var library: ICloudDriveLibrary
    let manifests: [SegmentManifest]
    let receivedIDs: Set<UUID>
    let hasLibrarySnapshot: Bool
    @State private var showingDetails = false

    var body: some View {
        let status = ICloudDriveDetailStatus(library: library)
        CloudConnectionRow(title: "iCloud Drive", subtitle: status.summary,
                           systemImage: "icloud", statusSymbol: status.symbol,
                           statusColor: status.color, actionTitle: library.isConnected ? nil : "连接") {
            showingDetails = true
        }
        .padding(16)
        .accessibilityIdentifier("icloud-drive-row")
        .sheet(isPresented: $showingDetails) {
            ICloudDriveLibraryDetailView(library: library, manifests: manifests,
                                        receivedIDs: receivedIDs, hasLibrarySnapshot: hasLibrarySnapshot)
        }
    }
}

struct ICloudDriveLibraryDetailView: View {
    @ObservedObject var library: ICloudDriveLibrary
    let manifests: [SegmentManifest]
    let receivedIDs: Set<UUID>
    let hasLibrarySnapshot: Bool
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    @State private var choosingFolder = false
    @State private var choosingScope = false
    @State private var confirmingDisconnect = false
    @State private var confirmingReselect = false
    @State private var confirmingResume = false
    @State private var confirmingDirectoryRecovery = false
    @State private var showingStatus = false

    private var status: ICloudDriveDetailStatus { ICloudDriveDetailStatus(library: library) }

    var body: some View {
        Group {
            if embedded { detailContent } else { ScrollView { detailContent } }
        }
        .background(RecordDesign.background).foregroundStyle(RecordDesign.ink)
        .presentationDetents([.large]).presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .sheet(isPresented: $choosingFolder) {
            ICloudDriveFolderPicker { url in library.connect(to: url) }
        }
        .alert(status.title, isPresented: $showingStatus) {
            Button("知道了", role: .cancel) { }
        } message: { Text(status.explanation) }
        .confirmationDialog("同步哪些录音？", isPresented: $choosingScope, titleVisibility: .visible) {
            Button("仅新录音") {
                library.authorize(scope: .futureOnly, knownManifests: manifests, receivedIDs: receivedIDs)
            }
            .accessibilityIdentifier("icloud-drive-scope-future")
            Button("全部录音") {
                library.authorize(scope: .existingAndFuture, knownManifests: manifests, receivedIDs: receivedIDs)
            }
            .accessibilityIdentifier("icloud-drive-scope-all")
            Button("取消", role: .cancel) { }
        } message: {
            Text("仅新录音：仅授权后开始录制、并传到手机的录音，已有录音和旧积压不会加入。全部录音：手机现有及以后收到的录音。此次独立授权包含原录音和已有转写。")
        }
        .confirmationDialog("断开 iCloud Drive？", isPresented: $confirmingDisconnect, titleVisibility: .visible) {
            Button("停止后续保存并断开", role: .destructive) { library.disconnect() }
                .accessibilityIdentifier("icloud-drive-disconnect-confirm")
            Button("取消", role: .cancel) { }
                .accessibilityIdentifier("icloud-drive-disconnect-cancel")
        } message: {
            Text("停止后续写入。原录音和已保存到目录的文件保留，系统可能继续上传已写入的文件。")
        }
        .alert("重新选择原 iCloud Drive 文件夹？", isPresented: $confirmingReselect) {
            Button("选择原文件夹") { choosingFolder = true }
                .accessibilityIdentifier("icloud-drive-reselect-confirm")
            Button("取消", role: .cancel) { }
                .accessibilityIdentifier("icloud-drive-reselect-cancel")
        } message: {
            Text("请选择原录音库所在的文件夹。会先核对目录身份；不匹配时不会改用新目录或覆盖已有文件。原录音范围保留，重新连接后持续保存保持关闭，需再次明确开启。")
        }
        .alert("继续保存到 iCloud Drive？", isPresented: $confirmingResume) {
            Button("按原范围继续保存") { library.setEnabled(true) }
                .accessibilityIdentifier("icloud-drive-resume-confirm")
            Button("取消", role: .cancel) { }
                .accessibilityIdentifier("icloud-drive-resume-cancel")
        } message: {
            Text("会先核对原目录身份，通过后按原录音范围继续写入未完成的文件，不更换目录或覆盖冲突文件。已写入文件的上传仍由 iCloud 管理。")
        }
        .alert("确认这是原文件夹？", isPresented: $confirmingDirectoryRecovery) {
            Button("这是原目录，恢复连接") { library.confirmDirectoryRecovery() }
                .accessibilityIdentifier("icloud-drive-directory-recovery-confirm")
            Button("取消", role: .cancel) { library.cancelDirectoryRecovery() }
                .accessibilityIdentifier("icloud-drive-directory-recovery-cancel")
        } message: {
            Text("复制的文件夹也可能包含相同库标记。只有确认所选的是原文件夹时才继续；会再次核对，保留原录音范围和历史，持续保存保持关闭。")
        }
    }

    private var detailContent: some View {
            VStack(alignment: .leading, spacing: 20) {
                if !embedded {
                HStack {
                    Text("iCloud Drive").font(.title3.weight(.semibold))
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.subheadline).frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain).foregroundStyle(RecordDesign.secondary)
                    .accessibilityLabel("关闭 iCloud Drive 详情")
                    .accessibilityIdentifier("icloud-drive-close")
                }
                }
                HStack(spacing: 12) {
                    CloudProviderIcon(systemImage: "icloud")
                    VStack(alignment: .leading, spacing: 5) {
                        Text(library.isConnected || library.hasAuthorizationHistory ? library.folderName : "选择录音文件夹")
                            .font(.subheadline.weight(.medium)).lineLimit(2)
                        Text(status.authorizationSummary)
                            .font(.caption).foregroundStyle(RecordDesign.secondary)
                            .accessibilityIdentifier("icloud-drive-authorization-state")
                    }
                    Spacer(minLength: 4)
                    Button { showingStatus = true } label: {
                        Image(systemName: status.symbol).font(.system(size: 20)).frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain).foregroundStyle(status.color)
                    .accessibilityLabel("\(status.title)，查看说明")
                    .accessibilityIdentifier("icloud-drive-status")
                }

                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("持续保存", value: status.synchronizationSummary)
                        .accessibilityIdentifier("icloud-drive-sync-state")
                    LabeledContent("当前状态", value: status.summary)
                        .accessibilityIdentifier("icloud-drive-current-state")
                    Text("最近结果").font(.caption).foregroundStyle(RecordDesign.secondary)
                    Text(status.latestResult).font(.subheadline).foregroundStyle(status.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("icloud-drive-latest-result")
                }

                if !embedded || library.pendingCloudFileCount == 0 {
                    ICloudDriveCloudStatusCheck(library: library)
                }

                if library.recoveryConfirmationRequired {
                    settings
                    Text("已找到匹配的原录音库，但系统提供的目录标识已变化。若未更换或复制录音文件夹，可直接确认恢复，无需重新选择目录；持续保存仍保持关闭。")
                        .font(.subheadline).foregroundStyle(RecordDesign.secondary)
                        .accessibilityIdentifier("icloud-drive-directory-recovery-explanation")
                    Button("确认恢复原目录") { confirmingDirectoryRecovery = true }
                        .buttonStyle(RecordPrimaryButtonStyle()).disabled(library.isBusy)
                        .accessibilityIdentifier("icloud-drive-directory-recovery-review")
                    Button("取消恢复") { library.cancelDirectoryRecovery() }
                        .buttonStyle(RecordSecondaryButtonStyle()).disabled(library.isBusy)
                        .accessibilityIdentifier("icloud-drive-directory-recovery-dismiss")
                } else if !library.isConnected {
                    if library.scope != nil {
                        settings
                        Text("重新选择原来的 iCloud Drive 文件夹，沿用原录音范围。其他目录不能沿用此授权；连接后需明确继续保存。")
                            .font(.caption).foregroundStyle(RecordDesign.secondary)
                    } else {
                        Text("先选择 iCloud Drive 文件夹，再单独选择录音范围。选目录本身不会导出录音。")
                            .font(.subheadline).foregroundStyle(RecordDesign.secondary)
                    }
                    Button(library.hasAuthorizationHistory ? "重新选择原目录" : "选择 iCloud Drive 文件夹") {
                        requestFolderSelection()
                    }
                        .buttonStyle(RecordPrimaryButtonStyle()).disabled(library.isBusy)
                        .accessibilityIdentifier(library.hasAuthorizationHistory ? "icloud-drive-reconnect" : "icloud-drive-connect")
                    if library.isBusy {
                        disabledReason("当前操作尚未结束，完成后才可选择文件夹。", identifier: "icloud-drive-connect-disabled-reason")
                    }
                } else if library.scope == nil {
                    Text("同步设置").font(.caption.weight(.semibold))
                    Button("选择录音范围") { choosingScope = true }
                        .buttonStyle(RecordSecondaryButtonStyle())
                        .disabled(!hasLibrarySnapshot || library.isBusy)
                        .accessibilityIdentifier("icloud-drive-choose-scope")
                    Text("包含原录音与已有转写。此次授权仅用于 iCloud Drive。")
                        .font(.caption).foregroundStyle(RecordDesign.secondary)
                    if !hasLibrarySnapshot || library.isBusy {
                        disabledReason(library.isBusy ? "正在处理当前操作，完成后才可选择范围。" : "手机录音列表尚未载入，载入后才可选择录音范围。",
                                       identifier: "icloud-drive-scope-disabled-reason")
                    }
                } else {
                    settings
                    if !library.isEnabled {
                        Text("系统仍可能上传已写入的文件。")
                            .font(.caption).foregroundStyle(RecordDesign.secondary)
                    }
                    Button(library.isBusy ? library.busyMessage : "检查同步") { library.resume() }
                        .buttonStyle(RecordSecondaryButtonStyle())
                        .disabled(library.isBusy || !library.isEnabled)
                        .accessibilityIdentifier("icloud-drive-check")
                    if library.isBusy || !library.isEnabled {
                        disabledReason(library.isBusy ? "当前保存或核对尚未结束，请等待本轮结果。" : "持续保存已关闭。先明确开启后，才能检查并继续同步。",
                                       identifier: "icloud-drive-check-disabled-reason")
                    }
                    if library.hasBlockingError {
                        Button("重新选择原目录") { requestFolderSelection() }
                            .buttonStyle(RecordSecondaryButtonStyle()).disabled(library.isBusy)
                            .accessibilityIdentifier("icloud-drive-reconnect")
                        if library.isBusy {
                            disabledReason("当前操作尚未结束，完成后才可重新选择目录。", identifier: "icloud-drive-connect-disabled-reason")
                        }
                        Text("仅重新授权原目录，原录音范围不变；连接后需明确继续保存。")
                            .font(.caption).foregroundStyle(RecordDesign.secondary)
                    }
                }

                if library.isConnected {
                    Button("断开连接", role: .destructive) { confirmingDisconnect = true }
                        .buttonStyle(.borderless)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .foregroundStyle(RecordDesign.accent)
                        .accessibilityIdentifier("icloud-drive-disconnect")
                }
            }
            .padding(.horizontal, embedded ? 0 : 24).padding(.top, 12).padding(.bottom, 24)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("同步设置").font(.caption.weight(.semibold))
            VStack(spacing: 0) {
                HStack {
                    Text("录音范围").foregroundStyle(RecordDesign.secondary)
                    Spacer()
                    Text(library.scope == .futureOnly ? "仅新录音" : "全部录音")
                }
                .font(.subheadline).padding(.vertical, 16)
                Divider().overlay(RecordDesign.rule)
                Toggle("持续保存", isOn: Binding(
                    get: { library.isEnabled },
                    set: { enabled in if enabled { confirmingResume = true } else { library.setEnabled(false) } }))
                    .font(.subheadline).tint(RecordDesign.secondary)
                    .padding(.vertical, 10)
                    .disabled(status.toggleDisabledReason != nil)
                    .accessibilityIdentifier("icloud-drive-toggle")
                if let reason = status.toggleDisabledReason {
                    Text(reason).font(.caption).foregroundStyle(RecordDesign.secondary)
                        .padding(.bottom, 12)
                        .accessibilityIdentifier("icloud-drive-toggle-disabled-reason")
                }
            }
            .padding(.horizontal, 16)
            .background(RecordDesign.surface, in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func requestFolderSelection() {
        if library.hasAuthorizationHistory { confirmingReselect = true }
        else { choosingFolder = true }
    }

    private func disabledReason(_ text: String, identifier: String) -> some View {
        Text(text).font(.caption).foregroundStyle(RecordDesign.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(identifier)
    }
}

struct ICloudDriveCloudStatusCheck: View {
    @ObservedObject var library: ICloudDriveLibrary

    var body: some View {
        if library.isConnected && library.scope != nil && !library.recoveryConfirmationRequired {
            VStack(alignment: .leading, spacing: 8) {
                Button(library.isBusy ? library.busyMessage : "检查云端状态（只读）") {
                    library.checkCloudStatusReadOnly()
                }
                .buttonStyle(RecordSecondaryButtonStyle())
                .disabled(library.isBusy)
                .accessibilityIdentifier("icloud-drive-check-cloud-readonly")
                Text("只查询已写入文件的上传状态，每次最多检查 32 份。")
                    .font(.caption).foregroundStyle(RecordDesign.secondary)
                    .accessibilityIdentifier("icloud-drive-check-cloud-readonly-explanation")
            }
        }
    }
}

// BEGIN ICLOUD CONNECTION PRESENTATION
struct ICloudDriveDetailStatus {
    let title: String
    let symbol: String
    let color: Color
    let explanation: String
    let note: String?
    let authorizationSummary: String
    let synchronizationSummary: String
    let latestResult: String
    let toggleDisabledReason: String?

    var summary: String { title }

    @MainActor
    init(library: ICloudDriveLibrary) {
        let diagnostics = library.diagnosticSnapshot()
        authorizationSummary = library.hasBlockingError ? "文件夹连接需要处理"
            : library.isConnected ? "已授权访问所选文件夹"
            : library.hasAuthorizationHistory ? "原文件夹需重新授权" : "尚未选择文件夹"
        synchronizationSummary = library.isEnabled ? "已开启" : "已关闭"
        latestResult = library.error ?? library.activity
        toggleDisabledReason = !library.isConnected ? "请先重新授权原文件夹，持续保存保持关闭。"
            : library.isBusy && !library.isEnabled ? "当前操作尚未结束，完成后才可开启持续保存。" : nil
        if let error = library.error {
            title = "需处理"; symbol = "exclamationmark.circle"; color = RecordDesign.warning
            explanation = error; note = error
        } else if !library.isConnected {
            title = library.hasAuthorizationHistory ? "需重选原目录" : "未连接"
            symbol = "link"; color = RecordDesign.secondary
            explanation = library.hasAuthorizationHistory ? "重新选择原目录，原录音范围保持不变。不会自动改用其他文件夹。" : "选择目录后，还需单独授权录音同步范围。"
            note = nil
        } else if library.scope == nil {
            title = "待选择范围"; symbol = "circle.dashed"; color = RecordDesign.secondary
            explanation = "文件夹已连接，尚未授权导出录音。请选择本次允许保存的录音范围。"
            note = nil
        } else if !library.isEnabled {
            title = "已暂停写入"; symbol = "pause.circle"; color = RecordDesign.secondary
            explanation = "已暂停后续写入。系统仍可能上传已写入的文件，原录音范围和进度保留。"
            note = title
        } else if library.isBusy {
            title = library.busyMessage.replacingOccurrences(of: "…", with: "")
            symbol = "arrow.triangle.2.circlepath"; color = RecordDesign.secondary
            explanation = "正在检查新增内容、保存未完成的文件或核对系统上传状态。实际传输由 iCloud 管理。"
            note = library.busyMessage
        } else if diagnostics.availability == .unavailable {
            title = "状态暂不可用"; symbol = "exclamationmark.circle"; color = RecordDesign.warning
            explanation = "上一轮检查未能完成，已有缓存不能代表当前上传状态。原录音和已保存文件保留；可导出日志报告，或在下次正常同步机会再核对。"
            note = "本轮状态不可用，未当作上传完成。"
        } else if diagnostics.availability == .stale || diagnostics.availability == .invalidTimestamp
                    || diagnostics.availability == .notObserved {
            title = "状态待核对"; symbol = "clock"; color = RecordDesign.secondary
            explanation = "尚未取得有效的近期状态，旧计数不能代表当前上传情况。查看此说明或导出日志不会触发同步或录音检查。"
            note = "近期上传状态未知。"
        } else if diagnostics.status == .needsIdentityRevalidation {
            title = "需核对文件身份"; symbol = "exclamationmark.shield"; color = RecordDesign.warning
            explanation = "部分已导出文件的身份与原记录不一致，暂不能确认这些文件仍是原内容。只读检查不会校验音频。持续保存开启时，正常同步可继续校验仅元数据变化的已保存文件；通过后才更新身份。其他差异仍需处理，原录音保留。"
            note = "已导出文件需重新核对身份，原录音保留。"
        } else if library.isWaitingForNewRecordings {
            title = "等待新录音"; symbol = "clock"; color = RecordDesign.secondary
            explanation = "授权后开始录制、并传到手机的录音才会加入。"
            note = title
        } else if library.isCurrentScopeUploaded {
            title = "系统已确认上传"; symbol = "checkmark.icloud"; color = RecordDesign.good
            explanation = "系统已确认本次核对的文件上传到 iCloud；另一台设备是否已经下载，需在该设备核对。"
            note = nil
        } else if library.isCurrentScopeWritten && library.pendingCloudFileCount > 0 {
            title = "上传待确认"; symbol = "clock"; color = RecordDesign.warning
            explanation = "文件已写入所选目录，系统尚未确认全部上传。"
            note = title
        } else if library.hasPendingWork {
            title = "保存未完成"; symbol = "arrow.triangle.2.circlepath"; color = RecordDesign.secondary
            explanation = "仍有内容等待保存或核对，系统提供后台时间或打开 App 时会继续。原录音和已经写入的文件保留。"
            note = "保存或核对尚未完成"
        } else if library.isCurrentScopeWritten {
            title = "已写入目录"; symbol = "checkmark.circle"; color = RecordDesign.secondary
            explanation = "文件已写入所选目录；当前没有足够的系统状态证据确认全部上传。"
            note = "上传状态待核对"
        } else {
            title = "已连接"; symbol = "link"; color = RecordDesign.secondary
            explanation = "已连接所选目录；当前尚无可确认完成保存与上传的录音。"
            note = nil
        }
    }
}
// END ICLOUD CONNECTION PRESENTATION

private struct ICloudDriveFolderPicker: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let selected: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        controller.allowsMultipleSelection = false
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) { }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: ICloudDriveFolderPicker
        init(parent: ICloudDriveFolderPicker) { self.parent = parent }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if urls.count == 1, let url = urls.first { parent.selected(url) }
            parent.dismiss()
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { parent.dismiss() }
    }
}
