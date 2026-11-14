import RecordingCore
import SwiftUI
import UIKit

/// Selection is a presentation preference, never an authorization or a pause action.
enum SyncDestination: String, CaseIterable, Identifiable {
    case iCloud, google, computer, baidu, weiyun
    var id: String { rawValue }
    var name: String {
        switch self { case .iCloud: return "iCloud Drive"; case .google: return "Google Drive"
        case .computer: return "电脑"; case .baidu: return "百度网盘"; case .weiyun: return "腾讯微云" }
    }
    var supported: Bool { self != .baidu && self != .weiyun }
    var symbol: String {
        switch self {
        case .iCloud: return "icloud"
        case .google, .baidu, .weiyun: return "externaldrive"
        case .computer: return "desktopcomputer"
        }
    }
}

struct SyncBrand: View {
    let destination: SyncDestination
    var size: CGFloat = 30
    var body: some View {
        Image(systemName: destination.symbol)
            .resizable()
            .scaledToFit()
            .padding(4)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct SyncSetupSelectionState: Equatable {
    let destination: SyncDestination?
    let enabled: Bool
}

struct SyncSetupHome: View {
    @EnvironmentObject private var store: PhoneStore
    @ObservedObject var delivery: PhoneAutomaticDeliveryStore
    @ObservedObject var drive: GoogleDriveLibrary
    @ObservedObject var iCloud: ICloudDriveLibrary
    let library: PersonalLibraryStore
    @AppStorage("sync.destination.v1") private var selectedRaw = ""
    @State private var expanded: Int? = nil
    @State private var initialized = false
    @State private var copied = false
    @State private var showingTools = false

    private var selected: SyncDestination? {
        if let saved = SyncDestination(rawValue: selectedRaw), saved.supported { return saved }
        if iCloud.isConnected || iCloud.hasAuthorizationHistory { return .iCloud }
        if drive.isConnected || drive.hasAuthorizationHistory { return .google }
        if !delivery.receivers.isEmpty { return .computer }
        return nil
    }
    private var enabled: Bool {
        switch selected {
        case .iCloud: return iCloud.isConnected && iCloud.isEnabled && iCloud.scope != nil && !iCloud.recoveryConfirmationRequired
        case .google: return drive.isConnected && drive.isEnabled && drive.scope != nil && !drive.isRevocationPending
        case .computer: return delivery.receivers.contains { $0.isPaired && $0.isEnabled }
        default: return false
        }
    }
    private var scopeSummary: String {
        switch selected {
        case .iCloud: return iCloud.scope.map { $0 == .futureOnly ? "后续录音" : "全部已有 + 后续录音" } ?? "选择范围"
        case .google: return drive.scope.map { $0 == .futureOnly ? "后续录音" : "全部已有 + 后续录音" } ?? "选择范围"
        case .computer: return delivery.receivers.isEmpty ? "连接电脑" : "全部已有 + 后续录音"
        default: return ""
        }
    }
    private var googleFolder: URL? { drive.isConnected && !drive.isRevocationPending ? drive.folderURL : nil }
    private var iCloudFolder: String? {
        iCloud.isConnected && !iCloud.recoveryConfirmationRequired && !iCloud.hasBlockingError ? iCloud.folderName : nil
    }
    private var agentLocation: String? {
        switch selected {
        case .iCloud: return iCloudFolder.map { "iCloud Drive 文件夹 · \($0)" }
        case .google: return googleFolder.map { _ in "Google Drive 文件夹 · Record for Agent" }
        case .computer: return delivery.receivers.contains { $0.isPaired } ? "已配对的电脑接收端" : nil
        default: return nil
        }
    }
    private var statement: String {
        let text: String
        switch selected {
        case .google:
            text = AgentOnboardingStatement.make(googleDriveURL: googleFolder, selectedCloud: .googleDrive)
        case .iCloud:
            text = AgentOnboardingStatement.make(iCloudFolderName: iCloudFolder, selectedCloud: .iCloudDrive)
        case .computer:
            text = "我的 Record for Agent 录音通过已配对电脑接收端保存。请先用已授权的本机文件或录音工具定位接收库；手机未提供电脑绝对路径，不要猜测。按清单中的片段 ID、时间、时区和顺序处理我的需求。读取失败时依据工具说明纠正参数，临时错误最多额外重试两次；仍缺工具、路径或授权时再告诉我。已接收不代表已处理，不改动原文件或扩大共享。"
        default:
            text = AgentOnboardingStatement.text
        }
        return text + "\n当前选择：\(selected?.name ?? "尚未选择")；授权范围：\(scopeSummary.isEmpty ? "尚未确认" : scopeSummary)。\(enabled ? "自动同步已开启。" : "自动同步未开启或需处理；不要假定文件已全部保存。")"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                step(1, title: "保存到", summary: selected?.name ?? "") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 12)], spacing: 24) {
                        ForEach(SyncDestination.allCases) { destination in
                            Button {
                                selectedRaw = destination.rawValue
                                expanded = 2
                                copied = false
                            } label: {
                                VStack(spacing: 9) {
                                    SyncBrand(destination: destination, size: 34)
                                        .frame(width: 52, height: 52)
                                        .background(RecordDesign.inset, in: RoundedRectangle(cornerRadius: 16))
                                    Text(destination.name).font(.caption).fixedSize(horizontal: false, vertical: true)
                                    if !destination.supported { Text("待接入").font(.caption2).foregroundStyle(RecordDesign.secondary) }
                                }.frame(maxWidth: .infinity, minHeight: 104).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(!destination.supported)
                                .accessibilityLabel(destination.name + (destination.supported ? "" : "，待接入"))
                                .accessibilityIdentifier("sync-destination-\(destination.rawValue)")
                        }
                    }.padding(.vertical, 20)
                }
                step(2, title: enabled ? "自动同步" : "连接与范围", summary: scopeSummary) {
                    connection
                    if selected == .iCloud || selected == .google {
                        Text("当前支持后续录音，或全部已有与后续录音。历史日期区间暂不支持。")
                            .font(.caption).foregroundStyle(RecordDesign.secondary).padding(.bottom, 14)
                    }
                    if enabled {
                        Button("保留设置，继续") { expanded = 3 }
                            .buttonStyle(RecordPrimaryButtonStyle()).accessibilityIdentifier("sync-keep-settings")
                    }
                }
                step(3, title: "Agent 接入说明", summary: selected == nil ? "" : "查看") {
                    if let agentLocation {
                        Text(agentLocation).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("agent-connection-guide").padding(.vertical, 12)
                        Button(copied ? "已复制" : "复制给 Agent") {
                            UIPasteboard.general.string = statement; copied = true
                        }.buttonStyle(RecordPrimaryButtonStyle()).accessibilityIdentifier("agent-statement-copy")
                        if selected == .iCloud ? iCloud.scope != nil : selected == .google ? drive.scope != nil : true {
                            Button("查看目录") { expanded = nil }
                                .buttonStyle(RecordSecondaryButtonStyle()).padding(.top, 10)
                                .accessibilityIdentifier("sync-view-directory")
                        }
                    } else {
                        Text(selected == nil ? "先选择保存位置。" : "保存位置暂不可用，请查看连接设置。")
                            .font(.subheadline).padding(.vertical, 20)
                    }
                }
                directory.padding(.top, 32)
            }.padding(.horizontal, 24).padding(.top, 24)
        }
        .safeAreaPadding(.bottom, 32)
        .background(RecordDesign.background).foregroundStyle(RecordDesign.ink).tint(RecordDesign.ink)
        .navigationTitle("同步").navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("sync-setup-home")
        .toolbar { ToolbarItem(placement: .topBarTrailing) {
            Button { showingTools = true } label: { Image(systemName: "slider.horizontal.3").frame(minWidth: 44, minHeight: 44) }
                .accessibilityLabel("同步设置与工具").accessibilityIdentifier("sync-tools")
        } }
        .sheet(isPresented: $showingTools) {
            NavigationStack {
                List {
                    NavigationLink("设置与诊断") { RecordingSettingsView() }
                    NavigationLink("本机转写与首批备份") { PersonalLibraryView(library: library) }
                }.recordListAppearance().navigationTitle("工具").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("关闭") { showingTools = false } } }
            }
        }
        .onAppear {
            if !initialized { expanded = selected == nil ? 1 : enabled ? nil : 2; initialized = true }
        }
        .onChange(of: SyncSetupSelectionState(destination: selected, enabled: enabled)) { old, new in
            if old.destination != new.destination { expanded = 2 }
            else if !old.enabled && new.enabled { expanded = 3 }
        }
        .onChange(of: statement) { _, _ in copied = false }
    }

    private func step<Content: View>(_ number: Int, title: String, summary: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded = expanded == number ? nil : number } label: {
                VStack(spacing: 0) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) { stepLabel(number, title: title); Spacer(minLength: 8); stepSummary(number, summary); chevron(number) }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { stepLabel(number, title: title); Spacer(); chevron(number) }
                        stepSummary(number, summary).padding(.leading, 30)
                    }.padding(.vertical, 12)
                }
                }.frame(maxWidth: .infinity, minHeight: 72).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("sync-step-\(number)")
                .accessibilityValue(expanded == number ? "已展开" : "已折叠")
            if expanded == number { content().padding(.bottom, 22) }
            Divider().overlay(RecordDesign.rule)
        }
    }
    private func stepLabel(_ number: Int, title: String) -> some View {
        HStack(spacing: 14) {
            Text(String(format: "%02d", number)).font(.caption.monospaced()).foregroundStyle(RecordDesign.secondary)
            Text(title).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
    }
    @ViewBuilder private func stepSummary(_ number: Int, _ text: String) -> some View {
        if expanded != number && !text.isEmpty {
            HStack(spacing: 6) {
                if number == 1, let selected { SyncBrand(destination: selected, size: 18) }
                Text(text).font(.caption).foregroundStyle(RecordDesign.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func chevron(_ number: Int) -> some View {
        Image(systemName: expanded == number ? "chevron.up" : "chevron.down").font(.caption2).foregroundStyle(RecordDesign.secondary)
    }
    @ViewBuilder private var connection: some View {
        switch selected {
        case .iCloud:
            ICloudDriveLibraryDetailView(library: iCloud, manifests: store.manifests,
                receivedIDs: store.receivedSegmentIDs, hasLibrarySnapshot: store.hasLibrarySnapshot, embedded: true)
        case .google:
            GoogleDriveLibraryDetailView(drive: drive, phoneRecordingCount: store.manifests.count, embedded: true)
        case .computer:
            ForEach(delivery.receivers) { receiver in
                ReceiverConnectionRow(receiver: receiver) { delivery.removeReceiver(receiver.id) ? nil : delivery.error }
                    .padding(.vertical, 10)
            }
            AutomaticReceiverPairingView(delivery: delivery, embedded: true, onPaired: { expanded = 3 })
        default: Text("先选择保存位置。").font(.subheadline).padding(.vertical, 20)
        }
    }
    @ViewBuilder private var directory: some View {
        switch selected {
        case .iCloud:
            if iCloud.isConnected && iCloud.scope != nil {
                let status = iCloud.recoveryConfirmationRequired ? "文件夹连接需要处理"
                    : ICloudDriveDetailStatus(library: iCloud).summary
                SyncDirectory(title: iCloud.folderName, destination: .iCloud, status: status,
                    manifests: iCloud.authorizedManifests, library: library,
                    deliveredIDs: iCloud.hasBlockingError || iCloud.recoveryConfirmationRequired ? [] : iCloud.cloudConfirmedRecordingIDs,
                    isSyncing: iCloud.isBusy, canContinue: iCloud.isEnabled,
                    needsAttention: iCloud.hasBlockingError || iCloud.recoveryConfirmationRequired,
                    cloudStatusCheck: iCloud.pendingCloudFileCount > 0 ? ICloudDriveCloudStatusCheck(library: iCloud) : nil)
            }
        case .google:
            if drive.isConnected && drive.scope != nil {
                SyncDirectory(title: "Record for Agent", destination: .google,
                    status: GoogleDriveDetailStatus(drive: drive).summary,
                    manifests: drive.authorizedManifests, library: library,
                    deliveredIDs: drive.needsCredential || drive.isRevocationPending ? [] : drive.cloudConfirmedRecordingIDs,
                    isSyncing: drive.isBusy,
                    canContinue: drive.isEnabled && !drive.isWaitingForWiFi && drive.nextPlannedAttemptAt == nil,
                    needsAttention: drive.needsCredential || drive.isRevocationPending
                        || drive.apiFailureReason == .storageQuotaExceeded,
                    folderURL: drive.folderURL)
            }
        case .computer:
            ForEach(delivery.receivers) { receiver in ReceiverSyncDirectory(receiver: receiver, library: library) }
        default: EmptyView()
        }
    }
}

struct RecordingCloudDestinations: View {
    @ObservedObject var iCloud: ICloudDriveLibrary
    @ObservedObject var drive: GoogleDriveLibrary
    let segmentIDs: Set<UUID>

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("云盘同步").font(.caption).foregroundStyle(RecordDesign.secondary)
            RecordMetadataRow("iCloud Drive", value: iCloudStatus)
                .accessibilityIdentifier("record-period-icloud")
            RecordMetadataRow("Google Drive", value: googleStatus)
                .accessibilityIdentifier("record-period-google")
        }
    }

    private var iCloudStatus: String {
        if iCloud.recoveryConfirmationRequired { return "请重新连接原文件夹" }
        if iCloud.hasBlockingError { return "请检查 iCloud 同步设置" }
        if !iCloud.isConnected { return "未连接" }
        if iCloud.scope == nil { return "待选择范围" }
        if segmentIDs.isSubset(of: iCloud.cloudConfirmedRecordingIDs), !segmentIDs.isEmpty {
            return "手机已收到的音频已上传"
        }
        if !iCloud.isEnabled { return "持续保存已暂停" }
        if segmentIDs.isDisjoint(with: iCloud.authorizedManifests.map(\.id)) { return "尚未加入同步" }
        if !segmentIDs.isDisjoint(with: iCloud.cloudConfirmedRecordingIDs) { return "部分音频已上传" }
        return segmentIDs.isSubset(of: iCloud.locallyWrittenRecordingIDs) ? "等待 iCloud 确认上传" : "等待写入 iCloud Drive"
    }

    private var googleStatus: String {
        let status = GoogleDriveDetailStatus(drive: drive).summary
        if !drive.isConnected || drive.needsCredential || drive.isRevocationPending || drive.scope == nil { return status }
        if segmentIDs.isSubset(of: drive.cloudConfirmedRecordingIDs), !segmentIDs.isEmpty {
            return "手机已收到的音频已上传"
        }
        if drive.apiFailureReason == .storageQuotaExceeded { return "请释放 Google Drive 空间" }
        if !drive.isEnabled || drive.error != nil || drive.isWaitingForWiFi || drive.isNetworkFailure || drive.nextPlannedAttemptAt != nil {
            return status
        }
        if !segmentIDs.isDisjoint(with: drive.cloudConfirmedRecordingIDs) { return "部分音频已上传" }
        return segmentIDs.isDisjoint(with: drive.authorizedManifests.map(\.id)) ? "尚未加入同步" : "等待 Google Drive 确认"
    }
}

private struct ReceiverSyncDirectory: View {
    @ObservedObject var receiver: PhoneReceiverDeliveryStore
    let library: PersonalLibraryStore

    var body: some View {
        SyncDirectory(title: receiver.displayName.isEmpty ? "电脑接收端" : receiver.displayName,
            destination: .computer, status: receiver.activity,
            manifests: receiver.availableRecordings.filter { receiver.receivedSegmentIDs.contains($0.id) },
            library: library, deliveredIDs: receiver.deliveredSegmentIDs, canContinue: receiver.isEnabled)
    }
}

private struct SyncDirectory: View {
    @EnvironmentObject private var store: PhoneStore
    let title: String
    let destination: SyncDestination
    let status: String
    let manifests: [SegmentManifest]
    let library: PersonalLibraryStore
    let deliveredIDs: Set<UUID>
    var isSyncing = false
    var canContinue = true
    var needsAttention = false
    var cloudStatusCheck: ICloudDriveCloudStatusCheck? = nil
    var folderURL: URL? = nil
    @State private var selectedDay: Date?
    @State private var selectedRecording: PhoneSessionGroup?

    var body: some View {
        let activity = RecordingActivity(manifests: manifests, deliveredSegmentIDs: deliveredIDs)
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Text("同步状态").font(.headline).accessibilityAddTraits(.isHeader)
                HStack(spacing: 8) {
                    SyncBrand(destination: destination, size: 20)
                    Text(title).font(.subheadline).foregroundStyle(RecordDesign.secondary)
                }
                Text(status).font(.subheadline.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sync-directory-status")
                Text("以下录音来自手机已收到的音频。")
                    .font(.caption).foregroundStyle(RecordDesign.secondary)
                if let cloudStatusCheck { cloudStatusCheck }
                if let folderURL {
                    Link("查看 Google Drive 文件夹", destination: folderURL).font(.subheadline)
                }
            }.recordCard()

            VStack(alignment: .leading, spacing: 10) {
                Text("按日期查看").font(.headline).accessibilityAddTraits(.isHeader)
                if activity.days.isEmpty {
                    Text("范围内尚无手机已确认的录音").font(.caption).foregroundStyle(RecordDesign.secondary)
                }
                ForEach(activity.days.reversed()) { day in
                    Button { selectedDay = day.date } label: {
                        HStack {
                            Text(day.date.formatted(.dateTime.year().month().day())).font(.subheadline)
                            Spacer()
                            Text(dayStatus(day)).font(.caption).foregroundStyle(RecordDesign.secondary)
                            Image(systemName: "chevron.right").font(.caption2)
                        }.frame(minHeight: 50).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityIdentifier("sync-directory-date")
                    Divider().overlay(RecordDesign.rule)
                }
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("sync-directory")
        .sheet(isPresented: Binding(get: { selectedDay != nil }, set: { if !$0 { selectedDay = nil } })) {
            if let date = selectedDay {
                let phoneSegmentsByGroup = Dictionary(grouping: store.manifests.filter {
                    store.receivedSegmentIDs.contains($0.id)
                }, by: \.recordingGroupID)
                NavigationStack {
                    List {
                        ForEach(recordings(on: date)) { recording in
                            Button { selectedRecording = recording } label: {
                                recordingRow(recording, date: date,
                                    phoneSegments: phoneSegmentsByGroup[recording.id] ?? recording.segments)
                            }.buttonStyle(.plain).recordRow()
                                .accessibilityIdentifier("sync-recording-row")
                        }
                    }
                    .recordListAppearance()
                    .navigationTitle(date.formatted(.dateTime.year().month().day()))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("关闭") { selectedDay = nil } } }
                    .sheet(item: $selectedRecording) { recording in
                        RecordPeriodSheet(groupID: recording.id,
                            deliveredSegmentIDs: destination == .computer ? deliveredIDs : [],
                            receiverName: destination == .computer ? title : nil, library: library)
                    }
                }.presentationDetents([.medium, .large])
            }
        }
    }

    private func dayStatus(_ day: RecordingActivity.Day) -> String {
        if day.receivedDuration >= day.recordedDuration { return deliveredAudioLabel }
        if needsAttention { return "需要处理" }
        return isSyncing || canContinue && day.receivedDuration > 0 ? "同步中" : "等待同步"
    }

    private var deliveredAudioLabel: String {
        destination == .computer ? "已收到的音频已发送" : "已收到的音频已上传至 \(destination.name)"
    }

    private var deliveredScopeLabel: String {
        destination == .computer ? "已同步范围内收到的音频" : "范围内收到的音频已上传至 \(destination.name)"
    }

    private func recordings(on date: Date) -> [PhoneSessionGroup] {
        guard let day = Calendar.current.dateInterval(of: .day, for: date) else { return [] }
        return PhoneSessionGroup.groups(from: manifests).filter { group in
            group.segments.contains { segment in
                segment.startedAt < day.end && (segment.endedAt > day.start || segment.startedAt >= day.start)
            }
        }
    }

    private func recordingRow(_ recording: PhoneSessionGroup, date: Date, phoneSegments: [SegmentManifest]) -> some View {
        let group = PhoneSessionGroup(id: recording.id, segments: phoneSegments)
        let eligibleIDs = Set(recording.segments.map(\.id))
        let allEligibleDelivered = eligibleIDs.isSubset(of: deliveredIDs)
        let status: String
        if allEligibleDelivered && !group.hasSequenceGap {
            status = phoneSegments.allSatisfy { eligibleIDs.contains($0.id) } ? deliveredAudioLabel : deliveredScopeLabel
        } else if needsAttention {
            status = "需要处理"
        } else {
            status = isSyncing || canContinue && !allEligibleDelivered && !eligibleIDs.isDisjoint(with: deliveredIDs)
                ? "同步中" : "等待同步"
        }
        let start = recording.startedAt
        let startLabel = start.formatted(date: Calendar.current.isDate(start, inSameDayAs: date) ? .omitted : .abbreviated,
                                         time: .shortened)
        let duration = RecordingActivity(manifests: group.segments).totalRecordedDuration
        return VStack(alignment: .leading, spacing: 6) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Text("\(startLabel) 开始的录音").fixedSize()
                    Spacer(minLength: 0)
                    Text(status).font(.caption).foregroundStyle(RecordDesign.secondary).fixedSize()
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(startLabel) 开始的录音")
                    Text(status).font(.caption).foregroundStyle(RecordDesign.secondary)
                }
            }
            if duration >= 60 && (!allEligibleDelivered || group.hasSequenceGap) {
                let time = duration >= 3_600 ? phoneCompactDuration(duration) : "\(Int(duration / 60)) 分钟"
                Text("手机已收到约 \(time)")
                    .font(.caption).foregroundStyle(RecordDesign.secondary)
            }
        }
        .font(.subheadline).frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .contentShape(Rectangle()).accessibilityElement(children: .combine)
        .accessibilityHint("查看同步详情")
    }
}
