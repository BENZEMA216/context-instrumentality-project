import RecordingCore
import SwiftUI
import UIKit

struct AutomaticDeliveryView: View {
    @ObservedObject var delivery: PhoneAutomaticDeliveryStore
    let legacyLibrary: PersonalLibraryStore?

    var body: some View {
        Group {
            if let legacyLibrary {
                SyncSetupHome(delivery: delivery, drive: legacyLibrary.drive, iCloud: legacyLibrary.iCloudDrive, library: legacyLibrary)
            } else {
                SyncConnectionsHome(delivery: delivery, library: nil, drive: nil, iCloud: nil)
            }
        }
    }
}

private struct SyncConnectionsHome: View {
    @EnvironmentObject private var store: PhoneStore
    @ObservedObject var delivery: PhoneAutomaticDeliveryStore
    let library: PersonalLibraryStore?
    let drive: GoogleDriveLibrary?
    let iCloud: ICloudDriveLibrary?
    @State private var showingConnections = false
    @State private var showingTools = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let drive, let iCloud {
                    ObservedCloudConnections(delivery: delivery, drive: drive, iCloud: iCloud,
                        manifests: store.manifests, receivedIDs: store.receivedSegmentIDs,
                        hasLibrarySnapshot: store.hasLibrarySnapshot,
                        addConnection: { showingConnections = true })
                } else {
                    connectionHeading(count: delivery.receivers.count)
                    receiverConnections
                    addButton
                }
                Button { showingTools = true } label: { SyncToolRow(title: "录音库工具") }
                    .buttonStyle(.plain).padding(.top, 14)
                    .accessibilityIdentifier("legacy-library-tools")
                if let error = delivery.error {
                    Text(error).font(.subheadline).foregroundStyle(RecordDesign.accent)
                        .accessibilityIdentifier("delivery-error")
                }
            }
            .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 28)
        }
        .background(RecordDesign.background).foregroundStyle(RecordDesign.ink)
        .tint(RecordDesign.ink)
        .accessibilityIdentifier("automatic-delivery-list")
        .navigationTitle("同步").navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showingConnections) {
            NavigationStack {
                SyncConnectionCatalogue(delivery: delivery, library: library)
            }
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingTools) {
            NavigationStack { SyncLibraryTools(library: library) }
                .presentationDragIndicator(.visible)
        }
    }

    private var receiverConnections: some View {
        VStack(spacing: 0) {
            ForEach(delivery.receivers) { receiver in
                ReceiverConnectionRow(receiver: receiver) { [id = receiver.id] in
                    delivery.removeReceiver(id) ? nil : (delivery.error ?? "断开连接未能保存，请稍后重试。")
                }
                .padding(16)
                if receiver.id != delivery.receivers.last?.id { Divider().padding(.horizontal, 16) }
            }
        }
        .background(RecordDesign.surface, in: RoundedRectangle(cornerRadius: 22))
        .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(RecordDesign.rule) }
    }

    private var addButton: some View {
        AddSyncConnectionButton(action: { showingConnections = true })
    }
}

/// Observe the two independent cloud stores so connected/paused/error changes
/// update the home list without starting any provider operation on appearance.
private struct ObservedCloudConnections: View {
    @ObservedObject var delivery: PhoneAutomaticDeliveryStore
    @ObservedObject var drive: GoogleDriveLibrary
    @ObservedObject var iCloud: ICloudDriveLibrary
    let manifests: [SegmentManifest]
    let receivedIDs: Set<UUID>
    let hasLibrarySnapshot: Bool
    let addConnection: () -> Void

    private var showsGoogle: Bool { drive.isConnected || drive.isRevocationPending }
    private var count: Int { (showsGoogle ? 1 : 0) + (iCloud.isConnected ? 1 : 0) + delivery.receivers.count }

    var body: some View {
        connectionHeading(count: count)
        if count == 0 {
            VStack(spacing: 15) {
                CloudProviderIcon(systemImage: "arrow.triangle.2.circlepath")
                Text("还没有连接").font(.headline)
                Text("选择云盘或电脑").font(.subheadline).foregroundStyle(RecordDesign.secondary)
                Button("添加连接", action: addConnection).buttonStyle(RecordPrimaryButtonStyle())
                    .accessibilityIdentifier("sync-add-connection")
            }
            .padding(24).recordCard()
        } else {
            VStack(spacing: 0) {
                if showsGoogle {
                    GoogleDriveConnectionRow(drive: drive, phoneRecordingCount: manifests.count)
                    if iCloud.isConnected || !delivery.receivers.isEmpty { connectionDivider }
                }
                if iCloud.isConnected {
                    ICloudDriveConnectionRow(library: iCloud, manifests: manifests,
                        receivedIDs: receivedIDs, hasLibrarySnapshot: hasLibrarySnapshot)
                    if !delivery.receivers.isEmpty { connectionDivider }
                }
                ForEach(delivery.receivers) { receiver in
                    ReceiverConnectionRow(receiver: receiver) { [id = receiver.id] in
                        delivery.removeReceiver(id) ? nil : (delivery.error ?? "断开连接未能保存，请稍后重试。")
                    }
                    .padding(16)
                    if receiver.id != delivery.receivers.last?.id { connectionDivider }
                }
            }
            .background(RecordDesign.surface, in: RoundedRectangle(cornerRadius: 22))
            .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(RecordDesign.rule) }
            AddSyncConnectionButton(action: addConnection)
        }
    }

    private var connectionDivider: some View { Divider().overlay(RecordDesign.rule).padding(.horizontal, 16) }
}

private func connectionHeading(count: Int) -> some View {
    ViewThatFits(in: .horizontal) {
        HStack {
            Text("保存给 Agent").font(.subheadline.weight(.medium)).fixedSize()
            Spacer()
            if count > 0 { Text("\(count) 个连接").font(.caption).foregroundStyle(RecordDesign.secondary).fixedSize() }
        }
        VStack(alignment: .leading, spacing: 8) {
            Text("保存给 Agent").font(.subheadline.weight(.medium))
            if count > 0 { Text("\(count) 个连接").font(.caption).foregroundStyle(RecordDesign.secondary) }
        }
    }
    .padding(.bottom, 2)
}

private struct AddSyncConnectionButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label("添加连接", systemImage: "plus")
                .font(.subheadline.weight(.medium)).frame(maxWidth: .infinity, minHeight: 50)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(RecordDesign.rule,
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
        .accessibilityIdentifier("sync-add-connection")
    }
}

private struct SyncConnectionCatalogue: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: PhoneStore
    @ObservedObject var delivery: PhoneAutomaticDeliveryStore
    let library: PersonalLibraryStore?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("选择云盘或电脑").font(.subheadline).foregroundStyle(RecordDesign.secondary)
                VStack(spacing: 0) {
                    if let library {
                        GoogleDriveConnectionRow(drive: library.drive, phoneRecordingCount: store.manifests.count)
                        Divider().padding(.horizontal, 16)
                        ICloudDriveConnectionRow(library: library.iCloudDrive, manifests: store.manifests,
                            receivedIDs: store.receivedSegmentIDs, hasLibrarySnapshot: store.hasLibrarySnapshot)
                        Divider().padding(.horizontal, 16)
                    }
                    NavigationLink {
                        AutomaticReceiverPairingView(delivery: delivery)
                    } label: {
                        HStack(spacing: 12) {
                            CloudProviderIcon(systemImage: "desktopcomputer")
                            VStack(alignment: .leading, spacing: 5) {
                                Text("电脑接收端").font(.subheadline.weight(.semibold))
                                Text("同步到 Mac 上的 Agent").font(.caption).foregroundStyle(RecordDesign.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(RecordDesign.secondary)
                        }
                        .frame(minHeight: 50).padding(16).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityIdentifier("pairing-connect")
                }
                .background(RecordDesign.surface, in: RoundedRectangle(cornerRadius: 22))
                .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(RecordDesign.rule) }
            }.padding(24)
        }
        .background(RecordDesign.background).foregroundStyle(RecordDesign.ink)
        .navigationTitle("添加连接").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button("关闭", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
        } }
    }
}

private struct SyncLibraryTools: View {
    @Environment(\.dismiss) private var dismiss
    let library: PersonalLibraryStore?
    var body: some View {
        List {
            if let library {
                NavigationLink { PersonalLibraryView(library: library) } label: { Text("本机转写与首批备份") }
            }
            if let library {
                AgentCloudConnectionGuide(drive: library.drive, iCloud: library.iCloudDrive)
            } else {
                AgentConnectionGuideContent(statement: AgentOnboardingStatement.text)
            }
        }
        .recordListAppearance().navigationTitle("录音库工具").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button("关闭", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
        } }
    }
}

private struct AgentCloudConnectionGuide: View {
    @ObservedObject var drive: GoogleDriveLibrary
    @ObservedObject var iCloud: ICloudDriveLibrary

    var body: some View {
        AgentConnectionGuideContent(statement: AgentOnboardingStatement.make(
            googleDriveURL: drive.isConnected ? drive.folderURL : nil,
            iCloudFolderName: iCloud.isConnected ? iCloud.folderName : nil))
    }
}

private struct AgentConnectionGuideContent: View {
    let statement: String
    @State private var copied = false

    var body: some View {
        Section("Agent 连接指引") {
            Text(statement).font(.subheadline).textSelection(.enabled)
                .accessibilityIdentifier("agent-connection-guide")
            Button {
                UIPasteboard.general.string = statement
                copied = true
            } label: { Text(copied ? "已复制连接指引" : "复制 Agent 连接指引") }
                .buttonStyle(.borderless).accessibilityIdentifier("agent-statement-copy")
            Text("粘贴到要处理录音的 Agent 聊天；云盘访问权限需在对应 Agent 中授权。")
                .font(.caption).foregroundStyle(RecordDesign.secondary)
        }
        .onChange(of: statement) { _, _ in copied = false }
    }
}

struct ReceiverConnectionRow: View {
    @ObservedObject var receiver: PhoneReceiverDeliveryStore
    let removeReceiver: () -> String?
    @State private var showingDetails = false

    private var subtitle: String {
        receiver.connectionSummary
    }

    var body: some View {
        CloudConnectionRow(title: receiverTitle(receiver), subtitle: subtitle, systemImage: "desktopcomputer",
            statusSymbol: receiver.connectionWarning ? "exclamationmark.circle"
                : (receiver.lastProbeAt == nil ? "questionmark.circle" : "clock"),
            statusColor: receiver.connectionWarning ? RecordDesign.warning : RecordDesign.secondary,
            action: { showingDetails = true })
            .accessibilityIdentifier("receiver-manage")
            .task { await receiver.checkConnectionIfNeeded() }
            .sheet(isPresented: $showingDetails) {
                NavigationStack { SyncManagementView(receiver: receiver, removeReceiver: removeReceiver) }
                    .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
            }
    }
}

/// Reused by management and connection details so pairing, point-in-time
/// reachability and receipt-verified delivery never share a single healthy badge.
private struct ReceiverConnectionHealthView: View {
    @ObservedObject var receiver: PhoneReceiverDeliveryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(receiver.reachabilityTitle).font(.subheadline.weight(.medium))
                .accessibilityIdentifier("receiver-reachability")
            if let date = receiver.lastProbeAt {
                LabeledContent("最近连接检查") {
                    Text(date, format: .dateTime.year().month().day().hour().minute().second())
                }.font(.caption).accessibilityIdentifier("receiver-probe-time")
            }
            Text("连接结果仅代表检查时刻，不代表持续在线，也不代表录音已保存。")
                .font(.caption).foregroundStyle(RecordDesign.secondary)
            if let hint = receiver.connectionHint {
                Text(hint).font(.caption)
                    .foregroundStyle(receiver.connectionWarning ? RecordDesign.warning : RecordDesign.secondary)
                    .accessibilityIdentifier("receiver-connection-hint")
            }
            Button("检查连接") { Task { await receiver.checkConnection() } }
                .buttonStyle(RecordSecondaryButtonStyle())
                .disabled(receiver.isCheckingConnection || !receiver.isPaired)
                .accessibilityIdentifier("receiver-check-connection")
            Text("只检查接收程序与配对授权，不发送录音。")
                .font(.caption).foregroundStyle(RecordDesign.secondary)
            LabeledContent("最近传输", value: receiver.lastTransferTitle)
                .font(.caption).accessibilityIdentifier("receiver-transfer-result")
            if let date = receiver.lastTransferAt {
                LabeledContent("传输结果时间") {
                    Text(date, format: .dateTime.year().month().day().hour().minute().second())
                }.font(.caption).accessibilityIdentifier("receiver-transfer-time")
            }
            if let failure = receiver.lastTransferFailure, failure != receiver.lastProbeFailure {
                Text(failure.hint).font(.caption).foregroundStyle(RecordDesign.warning)
            }
            if let reason = receiver.blockedReason {
                Text("暂停交付原因：\(reason)").font(.caption).foregroundStyle(RecordDesign.warning)
                    .accessibilityIdentifier("receiver-blocked-reason")
            }
        }
        .task { await receiver.checkConnectionIfNeeded() }
    }
}

private struct SyncManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var receiver: PhoneReceiverDeliveryStore
    let removeReceiver: () -> String?
    @State private var confirmingRemoval = false
    @State private var removalError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 12) {
                    CloudProviderIcon(systemImage: "desktopcomputer")
                    VStack(alignment: .leading, spacing: 5) {
                        Text(receiverTitle(receiver)).font(.subheadline.weight(.semibold))
                        Text("电脑接收端 · \(receiver.pairingStatusTitle)")
                            .font(.caption).foregroundStyle(RecordDesign.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    ReceiverConnectionHealthView(receiver: receiver)
                    Text("配对只保存接收地址和授权，不代表电脑当前在线。请确认电脑接收程序正在运行，且手机与电脑处于可互访的局域网。")
                        .font(.caption).foregroundStyle(RecordDesign.secondary)
                    if let receipt = receiver.lastReceiptAt {
                        LabeledContent("最近确认保存") {
                            Text(receipt, format: .dateTime.month().day().hour().minute())
                        }
                    } else { LabeledContent("最近确认保存", value: "尚无有效保存回执") }
                    if let failure = receiver.lastIncompleteDeliveryMessage {
                        Text("未完成交付：\(failure)").font(.caption).foregroundStyle(RecordDesign.warning)
                        if let date = receiver.lastIncompleteDeliveryAt {
                            LabeledContent("交付记录时间") {
                                Text(date, format: .dateTime.month().day().hour().minute())
                            }.font(.caption)
                        }
                    }
                }
                .accessibilityIdentifier("receiver-connection-status")
                if receiver.hasLibrarySnapshot {
                    let today = syncActivity(receiver).day(on: Date())
                    let pending = max(0, today.recordedDuration - today.receivedDuration)
                    if pending > 0 {
                        Text("\(syncDuration(pending))待同步").font(.subheadline).foregroundStyle(RecordDesign.secondary)
                    }
                }
                Toggle("自动同步", isOn: Binding(get: { receiver.isEnabled }, set: { receiver.setEnabled($0) }))
                    .font(.subheadline).tint(RecordDesign.ink).padding(16)
                    .background(RecordDesign.surface, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityIdentifier("receiver-toggle")
                Text(receiver.isEnabled ? "已开启自动发送；电脑可用时会尝试交付。" : "已暂停自动发送；配对和已有回执仍保留。")
                    .font(.caption).foregroundStyle(RecordDesign.secondary)
                Button("发送待同步录音") { receiver.requestDeliveryCheck() }
                    .buttonStyle(RecordSecondaryButtonStyle()).disabled(!receiver.isEnabled || !receiver.isPaired)
                    .accessibilityIdentifier("receiver-sync")
                Text("此操作会发送手机已收到的待同步录音，不是连接检查。")
                    .font(.caption).foregroundStyle(RecordDesign.secondary)
                NavigationLink { SyncConnectionInfoView(receiver: receiver) } label: { SyncToolRow(title: "连接信息") }
                    .buttonStyle(.plain).accessibilityIdentifier("receiver-connection-info")
                if receiver.connectionWarning {
                    NavigationLink { SyncReceiverDetailsView(receiver: receiver) } label: { SyncToolRow(title: "查看同步问题") }
                        .buttonStyle(.plain).accessibilityIdentifier("receiver-details")
                }
                Button("断开连接", role: .destructive) { removalError = nil; confirmingRemoval = true }
                    .buttonStyle(.borderless).foregroundStyle(RecordDesign.accent)
                    .frame(maxWidth: .infinity, minHeight: 44).accessibilityIdentifier("receiver-remove")
                if let error = removalError ?? receiver.error {
                    Text(error).font(.caption).foregroundStyle(RecordDesign.accent)
                        .accessibilityIdentifier("receiver-removal-error")
                }
            }.padding(24)
        }
        .background(RecordDesign.background).foregroundStyle(RecordDesign.ink)
        .navigationTitle("电脑接收端").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button("关闭", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
        } }
        .confirmationDialog("断开与“\(receiverTitle(receiver))”的连接？", isPresented: $confirmingRemoval,
                            titleVisibility: .visible) {
            Button("断开连接", role: .destructive) {
                if let error = removeReceiver() { removalError = error }
                else { dismiss() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("停止向这个接收端同步。手机原录音、接收端已保存的文件和其他连接均保留。")
        }
    }
}

private struct SyncReceiverDetailsView: View {
    @ObservedObject var receiver: PhoneReceiverDeliveryStore

    var body: some View {
        let today = syncActivity(receiver).day(on: Date())
        List {
            Section {
                LabeledContent("接收端", value: receiverTitle(receiver))
                LabeledContent("状态", value: receiver.statusTitle)
                ReceiverConnectionHealthView(receiver: receiver)
                if receiver.hasLibrarySnapshot {
                    LabeledContent("今日本机录音", value: syncDuration(today.recordedDuration))
                    LabeledContent("今日已收到", value: syncDuration(today.receivedDuration))
                    LabeledContent("今日待同步", value: syncDuration(max(0, today.recordedDuration - today.receivedDuration)))
                } else { Text("正在读取本机录音，今日时长尚未确认。") }
                if let receipt = receiver.lastReceiptAt {
                    LabeledContent("最近确认保存") {
                        Text(receipt, format: .dateTime.month().day().hour().minute())
                    }
                } else { LabeledContent("最近确认保存", value: "尚无有效保存回执") }
            }
            Section("全部同步任务") {
                LabeledContent("已收到录音", value: "\(receiver.deliveredCount) 段")
                LabeledContent("待发送", value: "\(receiver.queuedCount) 项")
                LabeledContent("发送中", value: "\(receiver.uploadingCount) 项")
                LabeledContent("需要检查", value: "\(receiver.blockedCount) 项")
            }
            Section {
                Text("已收到表示这个接收端已保存录音并返回有效回执，不代表 Agent 已处理。处理结果请在对应聊天查看。")
                Text("今日进度以本机已收到的有效音频时长计算。尚在手表上的录音不计入；全部同步任务还可能包含历史录音及转写文件。")
                Text("暂停只影响这个接收端。录音会保留，重新开启后继续补齐；网络恢复后会继续尝试。")
            }
            .font(.caption).foregroundStyle(RecordDesign.secondary)
            if let error = receiver.error {
                Section { Text(error).font(.subheadline).foregroundStyle(RecordDesign.accent) }
            }
        }
        .recordListAppearance()
        .navigationTitle("同步详情")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SyncConnectionInfoView: View {
    @ObservedObject var receiver: PhoneReceiverDeliveryStore

    var body: some View {
        List {
            Section {
                LabeledContent("名称", value: receiverTitle(receiver))
                LabeledContent("配对记录", value: receiver.pairingStatusTitle)
                ReceiverConnectionHealthView(receiver: receiver)
                if !receiver.receiverName.isEmpty {
                    LabeledContent("接收位置", value: receiver.receiverName)
                }
                if let endpoint = receiver.endpoint {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("设备地址").font(.caption).foregroundStyle(RecordDesign.secondary)
                        Text(endpoint).font(.subheadline.monospaced()).textSelection(.enabled)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("接收端 ID").font(.caption).foregroundStyle(RecordDesign.secondary)
                    Text(receiver.receiverID.uuidString.lowercased())
                        .font(.caption.monospaced()).textSelection(.enabled)
                }
                if let fingerprint = receiver.certificateSHA256 {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("证书指纹").font(.caption).foregroundStyle(RecordDesign.secondary)
                        Text(fingerprint).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
            Section {
                Text("配对记录和自动同步开关只表示已保存的设置。打开同步页、查看连接或手动检查时才检查连接，不持续轮询。旧版接收程序需升级后才能提供连接检查；保留原配对、证书与存储目录。")
                    .font(.caption).foregroundStyle(RecordDesign.secondary)
                Text("多个 Agent 聊天可以共用这个录音库，无需重复连接。独立接收端分别保留各自的开关、同步任务和回执。")
                    .font(.caption).foregroundStyle(RecordDesign.secondary)
            }
        }
        .recordListAppearance()
        .navigationTitle("连接信息")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct AutomaticReceiverPairingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var delivery: PhoneAutomaticDeliveryStore
    var embedded = false
    var onPaired: (() -> Void)? = nil
    @State private var pairingText = ""
    @State private var pairingName = ""
    @State private var pendingPairing: AutomaticReceiverPairingPayload?
    @State private var pairingError: String?
    @State private var loadedDraftText: String?
    @State private var consentsToAllRecordings = false
    // Both inputs use UIKit-owned responder state. Mixing SwiftUI FocusState
    // with a UIKit responder can asynchronously dismiss the newly focused field.
    @State private var nameIsFocused = false
    @State private var payloadIsFocused = false

    private enum PairingField: Hashable { case name, payload }
    private var focusedPairingField: PairingField? {
        payloadIsFocused ? .payload : nameIsFocused ? .name : nil
    }

    var body: some View {
        ScrollViewReader { scrollProxy in
            Group {
                if embedded { VStack(alignment: .leading, spacing: 16) { pairingContent } }
                else { List { pairingContent } }
            }
            .recordListAppearance()
            .listRowSpacing(0)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(embedded ? "同步" : "连接 Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !embedded {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭", systemImage: "xmark") {
                        clearPairingFocus()
                        dismiss()
                    }.labelStyle(.iconOnly)
                }
            }
            }
            .task { loadPairingDraftIfEmpty(explicit: false) }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { loadPairingDraftIfEmpty(explicit: false) }
            }
            .onChange(of: nameIsFocused) { _, active in
                if active { payloadIsFocused = false }
                revealFocusedPairingField(using: scrollProxy)
            }
            .onChange(of: payloadIsFocused) { _, active in
                if active { nameIsFocused = false }
                revealFocusedPairingField(using: scrollProxy)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
                revealFocusedPairingField(using: scrollProxy)
            }
            .onDisappear { clearPairingFocus() }
        }
    }

    private var pairingContent: some View {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("在电脑上复制配对信息。")
                            .font(.headline)
                        Text("手机和电脑需接入同一 Wi-Fi。配对信息只填在 App 中，请勿粘贴到 Agent 聊天。")
                            .font(.subheadline).foregroundStyle(RecordDesign.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .modifier(PairingFormRow(isFirst: true))
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("pairing-form-heading")

                    NativePairingTextField(text: $pairingName, isFocused: Binding(
                        get: { nameIsFocused },
                        set: { active in
                            nameIsFocused = active
                            if active { payloadIsFocused = false }
                        }), isSecure: false, placeholder: "名称（选填）", identifier: "pairing-name") {
                            nameIsFocused = false
                            payloadIsFocused = true
                        }
                        .frame(minHeight: 44)
                        .padding(.horizontal, 14).padding(.vertical, 2)
                        .background(RecordDesign.inset, in: RoundedRectangle(cornerRadius: 12))
                        .modifier(PairingFormRow())
                        .id(PairingField.name)

                    NativePairingTextField(text: $pairingText, isFocused: Binding(
                        get: { payloadIsFocused },
                        set: { active in
                            payloadIsFocused = active
                            if active { nameIsFocused = false }
                        }), isSecure: true, placeholder: "粘贴电脑的配对信息", identifier: "pairing-payload")
                    .frame(minHeight: 44)
                    .privacySensitive()
                    .padding(10)
                    .background(RecordDesign.inset, in: RoundedRectangle(cornerRadius: 12))
                    .onChange(of: pairingText) { _, current in
                        consentsToAllRecordings = false
                        if current != loadedDraftText { loadedDraftText = nil }
                        inspectPairing()
                    }
                    .modifier(PairingFormRow())
                    .id(PairingField.payload)

                    VStack(alignment: .leading, spacing: 14) {
                        Button("读取电脑配对信息") { loadPairingDraftIfEmpty(explicit: true) }
                            .buttonStyle(RecordSecondaryButtonStyle())
                            .disabled(!pairingText.isEmpty)
                            .accessibilityIdentifier("pairing-load-draft")
                        if let pairingError {
                            Text(pairingError).font(.subheadline).foregroundStyle(RecordDesign.accent)
                        }
                        if let pairing = pendingPairing {
                            Divider()
                            if loadedDraftText == pairingText {
                                Label("已找到这台电脑的配对信息", systemImage: "checkmark.circle")
                                    .font(.subheadline.weight(.semibold))
                            }
                            Text(URL(string: pairing.endpoint)?.host ?? "接收端").font(.headline)
                            DisclosureGroup("核对接收信息") {
                                Text("接收端 ID：\(pairing.receiverID.uuidString.lowercased())")
                                    .font(.caption.monospaced()).textSelection(.enabled)
                                Text("证书指纹").font(.caption).foregroundStyle(RecordDesign.secondary)
                                Text(pairing.certificateSHA256).font(.caption.monospaced()).textSelection(.enabled)
                            }.font(.subheadline)
                            Text("连接后，会向这里同步本机当前全部 \(delivery.availableReceivedCount) 段录音，以及以后新收到的录音。已有接收端继续保留。")
                                .font(.subheadline).foregroundStyle(RecordDesign.secondary)
                            if let duplicateReceiver {
                                Text("“\(receiverTitle(duplicateReceiver))”已经连接。共用这个录音库的聊天无需重复添加；更新配对信息前，请先明确断开这个接收端。")
                                    .font(.subheadline).foregroundStyle(RecordDesign.accent)
                            }
                            Toggle("同意同步全部已有和新增录音", isOn: $consentsToAllRecordings)
                                .font(.subheadline).tint(RecordDesign.good)
                                .accessibilityIdentifier("pairing-consent")
                            Button("连接并同步全部录音") { connect(pairing) }
                                .buttonStyle(RecordPrimaryButtonStyle())
                                .disabled(!delivery.hasLibrarySnapshot || duplicateReceiver != nil || !consentsToAllRecordings)
                                .accessibilityIdentifier("pairing-add")
                            if !delivery.hasLibrarySnapshot {
                                Text("正在读取本机录音，完成后即可连接。")
                                    .font(.caption).foregroundStyle(RecordDesign.secondary)
                            }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .modifier(PairingFormRow(isLast: true))
                }

    }

    private func connect(_ pairing: AutomaticReceiverPairingPayload) {
        guard consentsToAllRecordings, duplicateReceiver == nil else { return }
        pairingError = nil
        if delivery.pair(pairing, name: pairingName.trimmingCharacters(in: .whitespacesAndNewlines)) {
            clearPairingFocus()
            pairingText = ""; pairingName = ""; pendingPairing = nil; loadedDraftText = nil
            if embedded { onPaired?() } else { dismiss() }
        } else { pairingError = delivery.error ?? "暂时未能连接，请稍后再试。" }
    }

    private func clearPairingFocus() {
        nameIsFocused = false
        payloadIsFocused = false
    }

    private func revealFocusedPairingField(using scrollProxy: ScrollViewProxy) {
        guard let field = focusedPairingField else { return }
        // Only focus and keyboard events reveal fields. Delivery progress never
        // changes the scroll position or replaces the input rows.
        DispatchQueue.main.async {
            guard focusedPairingField == field else { return }
            withAnimation(.easeOut(duration: 0.2)) { scrollProxy.scrollTo(field, anchor: .center) }
        }
    }

    private func loadPairingDraftIfEmpty(explicit: Bool) {
        guard pairingText.isEmpty else { return }
        do {
            guard let draft = try delivery.loadPairingDraft() else {
                if explicit { pairingError = "未找到电脑配对草稿。请先将配对文件传入此 App，再点击读取；也可以粘贴完整配对信息。" }
                return
            }
            loadedDraftText = draft
            pairingText = draft
            inspectPairing()
        } catch { pairingError = "电脑配对草稿无法读取，请重新传入文件，或粘贴完整配对信息。" }
    }

    private var duplicateReceiver: PhoneReceiverDeliveryStore? {
        guard let pendingPairing else { return nil }
        return delivery.receivers.first { $0.receiverID == pendingPairing.receiverID }
    }

    private func inspectPairing() {
        guard !pairingText.isEmpty else {
            pendingPairing = nil; pairingError = nil; loadedDraftText = nil
            return
        }
        do {
            pendingPairing = try AutomaticReceiverPairingPayload.parse(pairingText)
            pairingError = nil
        } catch {
            pendingPairing = nil
            pairingError = AutomaticReceiverError.invalidPairing.localizedDescription
        }
    }
}

/// UITextField provides actual visual masking for the credential-bearing payload.
/// The UIKit responder has independent state so SwiftUI cannot clear its focus.
private struct NativePairingTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let isSecure: Bool
    let placeholder: String
    let identifier: String
    var onSubmit: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UITextField {
        let view = UITextField()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.tintColor = .label
        view.isSecureTextEntry = isSecure
        view.clearsOnBeginEditing = false
        view.clearsOnInsertion = false
        view.placeholder = placeholder
        view.returnKeyType = onSubmit == nil ? .done : .next
        view.keyboardType = isSecure ? .asciiCapable : .default
        view.autocapitalizationType = isSecure ? .none : .words
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.textContentType = nil
        view.clearButtonMode = .never
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.addTarget(context.coordinator, action: #selector(Coordinator.textChanged(_:)), for: .editingChanged)
        view.accessibilityLabel = placeholder
        view.accessibilityIdentifier = identifier
        let toolbar = UIToolbar()
        toolbar.items = [UIBarButtonItem(systemItem: .flexibleSpace),
            UIBarButtonItem(title: "完成", style: .done, target: context.coordinator, action: #selector(Coordinator.done))]
        toolbar.sizeToFit()
        view.inputAccessoryView = toolbar
        return view
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        context.coordinator.parent = self
        if uiView.text != text { uiView.text = text }
        uiView.clearsOnInsertion = false
        uiView.accessibilityValue = isSecure ? (text.isEmpty ? "空" : "已填写配对信息") : text
        if isFocused && !uiView.isFirstResponder {
            DispatchQueue.main.async {
                guard context.coordinator.parent.isFocused else { return }
                uiView.becomeFirstResponder()
            }
        } else if !isFocused && uiView.isFirstResponder { uiView.resignFirstResponder() }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextField, context: Context) -> CGSize? {
        // Keep a usable touch target while allowing accessibility fonts to grow.
        CGSize(width: proposal.width ?? uiView.intrinsicContentSize.width,
               height: max(44, (uiView.font?.lineHeight ?? 44).rounded(.up)))
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: NativePairingTextField
        private var restoringSecureText = false
        init(parent: NativePairingTextField) { self.parent = parent }
        @objc func textChanged(_ textField: UITextField) {
            // Restoring an existing secure value is not a user edit. In
            // particular, it must not invalidate consent or the loaded draft.
            guard !restoringSecureText else { return }
            parent.text = textField.text ?? ""
        }
        func textFieldDidBeginEditing(_ textField: UITextField) {
            if parent.isSecure {
                let currentText = parent.text
                let length = (currentText as NSString).length
                let selection: (start: Int, end: Int)?
                // A replace-on-insertion selection is UIKit's implicit reset,
                // not a selection the user made; resume at the existing end.
                if !textField.clearsOnInsertion, textField.text == currentText,
                   let range = textField.selectedTextRange {
                    let start = textField.offset(from: textField.beginningOfDocument, to: range.start)
                    let end = textField.offset(from: textField.beginningOfDocument, to: range.end)
                    selection = start >= 0 && end >= start && end <= length ? (start, end) : nil
                } else { selection = nil }
                // A secure field also keeps an internal first-insertion reset
                // after refocusing. Reinserting through UIKit consumes it;
                // assigning the same text alone does not. Secure entry stays on.
                restoringSecureText = true
                textField.text = nil
                if !currentText.isEmpty { textField.insertText(currentText) }
                let offsets = selection ?? (start: length, end: length)
                if let start = textField.position(from: textField.beginningOfDocument, offset: offsets.start),
                   let end = textField.position(from: textField.beginningOfDocument, offset: offsets.end) {
                    textField.selectedTextRange = textField.textRange(from: start, to: end)
                }
                textField.clearsOnInsertion = false
                textField.accessibilityValue = currentText.isEmpty ? "空" : "已填写配对信息"
                restoringSecureText = false
            }
            parent.isFocused = true
        }
        func textFieldDidEndEditing(_ textField: UITextField) { parent.isFocused = false }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            done()
            parent.onSubmit?()
            return false
        }
        @objc func done() { parent.isFocused = false }
    }
}

private struct PairingFormRow: ViewModifier {
    var isFirst = false
    var isLast = false
    func body(content: Content) -> some View {
        content
            .padding(EdgeInsets(top: isFirst ? 20 : 7, leading: 20,
                                bottom: isLast ? 20 : 7, trailing: 20))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RecordDesign.surface, in: UnevenRoundedRectangle(
                topLeadingRadius: isFirst ? 22 : 0, bottomLeadingRadius: isLast ? 22 : 0,
                bottomTrailingRadius: isLast ? 22 : 0, topTrailingRadius: isFirst ? 22 : 0))
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: isFirst ? 7 : 0, leading: 24,
                                     bottom: isLast ? 7 : 0, trailing: 24))
            .listRowSeparator(.hidden)
    }
}

private struct SyncToolRow: View {
    let title: String
    var body: some View {
        HStack {
            Text(title).font(.subheadline)
            Spacer(minLength: 10)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(RecordDesign.secondary)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: 54)
        .contentShape(Rectangle())
        .overlay(alignment: .bottom) { Rectangle().fill(RecordDesign.rule).frame(height: 0.5) }
    }
}

private struct SyncDurationText: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let duration: TimeInterval
    var body: some View {
        let seconds = max(0, Int(duration.rounded(.down)))
        let hours = seconds / 3600, minutes = (seconds % 3600) / 60
        let unit = Font.caption
        let numeral = Font.system(size: 36, weight: .regular, design: .rounded)
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                Text(syncDuration(duration)).font(.title2).fixedSize(horizontal: false, vertical: true)
            } else if hours > 0 {
                Text("\(hours)").font(numeral) + Text(" 小时 ").font(unit)
                    + Text("\(minutes)").font(numeral) + Text(" 分").font(unit)
            } else if minutes > 0 {
                Text("\(minutes)").font(numeral) + Text(" 分").font(unit)
            } else {
                Text("\(seconds)").font(numeral) + Text(" 秒").font(unit)
            }
        }
        .monospacedDigit()
        .accessibilityLabel(syncDuration(duration))
    }
}

@MainActor
private func syncActivity(_ receiver: PhoneReceiverDeliveryStore) -> RecordingActivity {
    RecordingActivity(manifests: receiver.availableRecordings.filter { receiver.receivedSegmentIDs.contains($0.id) },
                      deliveredSegmentIDs: receiver.deliveredSegmentIDs)
}

private func syncDuration(_ duration: TimeInterval) -> String {
    let seconds = max(0, Int(duration.rounded(.down)))
    let hours = seconds / 3600, minutes = (seconds % 3600) / 60
    if hours > 0 { return "\(hours)小时\(minutes)分" }
    if minutes > 0 { return "\(minutes)分钟" }
    return "\(seconds)秒"
}

private func syncReceiptLabel(_ date: Date?) -> String {
    guard let date else { return "尚无回执" }
    if Calendar.current.isDateInToday(date) { return "更新于 " + date.formatted(date: .omitted, time: .shortened) }
    return "更新于 " + date.formatted(.dateTime.month().day().hour().minute())
}

@MainActor
private func receiverTitle(_ receiver: PhoneReceiverDeliveryStore) -> String {
    if !receiver.displayName.isEmpty { return receiver.displayName }
    return receiver.receiverName.isEmpty ? "未命名接收端" : receiver.receiverName
}
