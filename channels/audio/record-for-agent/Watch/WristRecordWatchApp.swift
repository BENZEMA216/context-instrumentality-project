import RecordingCore
import SwiftUI
import WatchKit

@main
struct WristRecordWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchApplicationDelegate.self) private var applicationDelegate
    @StateObject private var recorder = WatchRecorderModel.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        WatchStartupDiagnostics.shared.recordOnce(.appInitEntered)
        WatchRuntimeDiagnostics.shared.record(.appConstructed)
    }

    var body: some Scene {
        WatchStartupDiagnostics.shared.recordOnce(.appBodyEntered)
        return WindowGroup {
            WatchRecorderView()
                .environmentObject(recorder)
                .onAppear { WatchStartupDiagnostics.shared.recordOnce(.sceneFirstAppeared) }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            let value: WatchLifecyclePolicy.Phase
            switch phase {
            case .active: value = .active
            case .inactive: value = .inactive
            case .background: value = .background
            @unknown default: value = .unknown
            }
            recorder.observeLifecycle(source: .scene, phase: value)
        }
    }
}

@MainActor
final class WatchApplicationDelegate: NSObject, WKApplicationDelegate {
    private var transferTasks: [UUID: WKRefreshBackgroundTask] = [:]

    override init() {
        super.init()
        WatchStartupDiagnostics.shared.recordOnce(.delegateInitEntered)
        // This writer does not depend on creating/opening the recording library.
        WatchRuntimeDiagnostics.shared.record(.delegateCreated)
    }

    func applicationDidFinishLaunching() {
        WatchStartupDiagnostics.shared.recordOnce(.delegateLaunchEntered)
        WatchRuntimeDiagnostics.shared.record(.launchCallback)
        // A system background launch does not have to create an active scene.
        _ = WatchRecorderModel.shared
    }

    func applicationDidEnterBackground() {
        WatchRecorderModel.shared.observeLifecycle(source: .delegateDidEnterBackground, phase: .background)
    }

    func applicationDidBecomeActive() {
        WatchStartupDiagnostics.shared.recordOnce(.delegateActiveEntered)
        WatchRecorderModel.shared.observeLifecycle(source: .delegateDidBecomeActive, phase: .active)
    }

    func applicationWillResignActive() {
        WatchRecorderModel.shared.observeLifecycle(source: .delegateWillResignActive, phase: .inactive)
    }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let connectivityTask = task as? WKWatchConnectivityRefreshBackgroundTask {
                WatchRuntimeDiagnostics.shared.record(.connectivityTaskArrived)
                beginTransferTask(connectivityTask, waitsForIncoming: true)
            } else if let refreshTask = task as? WKApplicationRefreshBackgroundTask {
                WatchRuntimeDiagnostics.shared.record(.refreshTaskArrived)
                // The system decides when this fallback runs. Only bounded
                // transfer work is prepared; no recorder or history scan starts.
                beginTransferTask(refreshTask, waitsForIncoming: false)
            } else if let snapshot = task as? WKSnapshotRefreshBackgroundTask {
                WatchRuntimeDiagnostics.shared.record(.snapshotTaskArrived)
                snapshot.setTaskCompleted(restoredDefaultState: true,
                                          estimatedSnapshotExpiration: .distantFuture, userInfo: nil)
            } else {
                WatchRuntimeDiagnostics.shared.record(.otherTaskArrived)
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }

    private func beginTransferTask(_ task: WKRefreshBackgroundTask, waitsForIncoming: Bool) {
        let id = UUID()
        transferTasks[id] = task
        task.expirationHandler = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.transferTasks[id] != nil else { return }
                WatchRuntimeDiagnostics.shared.record(.transferTaskExpired)
                WatchRecorderModel.shared.expireBackgroundConnectivityTask(id: id)
                self.finishTransferTask(id: id, expired: true)
            }
        }
        let completion: @Sendable () -> Void = { [weak self] in
            DispatchQueue.main.async { self?.finishTransferTask(id: id) }
        }
        if waitsForIncoming {
            WatchRecorderModel.shared.performBackgroundConnectivityTask(id: id, completion: completion)
        } else {
            WatchRecorderModel.shared.performBackgroundRefreshTask(id: id, completion: completion)
        }
    }

    private func finishTransferTask(id: UUID, expired: Bool = false) {
        guard let task = transferTasks.removeValue(forKey: id) else { return }
        if !expired { WatchRuntimeDiagnostics.shared.record(.transferTaskCompleted) }
        task.expirationHandler = nil
        task.setTaskCompletedWithSnapshot(false)
    }
}

private struct WatchWaveformView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let waveform: WatchRecordingWaveform

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / (reduceMotion ? 12 : 30))) { timeline in
            let samples = waveform.snapshot()
            // Let short batches from the microphone scroll past the playhead
            // one at a time, and hold position if the next batch is late.
            let lead = samples.latestSampleAt?.timeIntervalSince(timeline.date) ?? 0
            let delayedBars = reduceMotion ? 0 : min(10, max(0, (lead + 0.18) * WatchRecordingWaveform.barsPerSecond))
            Canvas { context, size in
                let playhead = size.width - 7
                let spacing = playhead / 36
                let width = min(2, spacing * 0.6)
                let middle = size.height / 2
                var quiet = Path()
                var waveform = Path()
                for (index, level) in samples.levels.enumerated() {
                    let stepsFromLatest = Double(samples.levels.count - index) - 0.5
                    let x = playhead - (stepsFromLatest - delayedBars) * spacing
                    guard x >= width / 2, x <= playhead - width / 2 else { continue }
                    let height = max(width, CGFloat(level) * (size.height - 8))
                    let rect = CGRect(x: x - width / 2, y: middle - height / 2, width: width, height: height)
                    let bar = Path(roundedRect: rect, cornerRadius: width / 2)
                    if level > 0.025 { waveform.addPath(bar) } else { quiet.addPath(bar) }
                }
                context.fill(quiet, with: .color(RecordWatchPalette.secondary.opacity(0.55)))
                context.fill(waveform, with: .color(RecordWatchPalette.foreground))
                let marker = CGRect(x: playhead - 0.75, y: 1, width: 1.5, height: size.height - 2)
                context.fill(Path(roundedRect: marker, cornerRadius: 0.75), with: .color(RecordWatchPalette.accent))
            }
        }
        .padding(.horizontal, 10)
        .accessibilityHidden(true)
    }
}

private struct WatchRecorderView: View {
    @EnvironmentObject private var recorder: WatchRecorderModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @ScaledMetric(relativeTo: .title) private var timerSize = 33
    @State private var showMore = false

    private var showsWaveform: Bool {
        recorder.isForeground && scenePhase == .active && !isLuminanceReduced && !showMore
    }

    var body: some View {
        // A refresh only checks evidence freshness. It never advances the timer.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let phase = recorder.uiPhase(at: context.date)
            ScrollView {
                captureContent(phase: phase, at: context.date)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
            }
        }
        .foregroundStyle(RecordWatchPalette.foreground)
        .background(RecordWatchPalette.background)
        .containerBackground(RecordWatchPalette.background, for: .navigation)
        .modifier(RecordingLocationIntroductionModifier(location: recorder.recordingLocation,
                                                       isAllowed: !showMore))
        .sheet(isPresented: $showMore) { moreSheet }
        .onChange(of: showsWaveform, initial: true) { _, visible in
            recorder.waveform.setVisible(visible)
        }
        .onDisappear { recorder.waveform.setVisible(false) }
    }

    private func captureContent(phase: WatchRecorderUIPhase, at date: Date) -> some View {
        let needsConfirmation = recorder.audioNeedsConfirmation(at: date)
        let startingAfterSave = phase == .starting && (recorder.snapshot.state == .paused || recorder.snapshot.state == .ended)
        let elapsed = startingAfterSave ? 0 : recorder.effectiveDuration
        return VStack(spacing: 0) {
            HStack(spacing: 6) {
                if phase != .idle {
                    Circle().fill(statusColor(phase)).frame(width: 5, height: 5)
                        .accessibilityHidden(true)
                }
                Text(statusTitle(phase, needsConfirmation: needsConfirmation))
                    .font(.caption2.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(phase == .recovering || phase == .interrupted
                             ? RecordWatchPalette.warning : RecordWatchPalette.foreground)
            .frame(minHeight: 17)
            .accessibilityElement(children: .combine)

            Text(duration(elapsed))
                .font(.system(size: timerSize, weight: .regular))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .accessibilityLabel("有效录音时长 \(spokenDuration(elapsed))")
                .padding(.top, 8)

            primaryControl(phase: phase, needsConfirmation: needsConfirmation)
                .frame(minHeight: 70)
                .padding(.top, 8)

            if phase == .recording, showsWaveform {
                WatchWaveformView(waveform: recorder.waveform)
                    .frame(height: 42)
                    .padding(.top, 4)
            }

            if phase == .interrupted, recorder.canEnd {
                Button("停止录音", action: recorder.end)
                    .buttonStyle(RecordWatchSecondaryButtonStyle())
                    .accessibilityHint("保存已录音频并结束本次录音")
                    .padding(.top, 4)
            }

            moreButton.padding(.top, 6)
            mainNotice(needsConfirmation: needsConfirmation)
        }
    }

    @ViewBuilder
    private func primaryControl(phase: WatchRecorderUIPhase, needsConfirmation: Bool) -> some View {
        switch phase {
        case .recording, .recovering:
            captureButton(isStop: true)
        case .starting where recorder.canEnd:
            captureButton(isStop: true)
        case .idle, .paused, .ended:
            captureButton(isStop: false)
        case .interrupted:
            Button {
                if needsConfirmation { recorder.recoverStalledCapture() }
                else { recorder.startOrResume() }
            } label: { Text(needsConfirmation ? "重新连接麦克风" : "恢复录音") }
            .buttonStyle(RecordWatchPrimaryButtonStyle())
            .disabled(!needsConfirmation && !recorder.canStart)
        case .checking, .starting, .saving:
            ProgressView()
                .progressViewStyle(.circular)
                .controlSize(.mini)
                .tint(RecordWatchPalette.secondary)
                .accessibilityHidden(true)
        }
    }

    private func captureButton(isStop: Bool) -> some View {
        let isEnabled = isStop ? recorder.canEnd : recorder.canStart
        return Button(action: isStop ? recorder.end : recorder.startOrResume) {
            Group {
                if isStop {
                    RoundedRectangle(cornerRadius: 5).frame(width: 30, height: 30)
                } else {
                    Circle().frame(width: 46, height: 46)
                }
            }
            .foregroundStyle(RecordWatchPalette.accent)
            .frame(width: 70, height: 70)
            .background(RecordWatchPalette.foreground.opacity(0.03), in: Circle())
            .overlay { Circle().stroke(RecordWatchPalette.foreground.opacity(0.9), lineWidth: 1.5) }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(isStop ? "停止录音" : "开始录音")
        .accessibilityHint(isStop ? "停止并保存本次录音" : "开始一条新录音")
    }

    private var moreButton: some View {
        Button { showMore = true } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(RecordWatchUtilityButtonStyle())
        .accessibilityLabel("更多")
        .accessibilityHint("查看同步、录音位置、诊断及需要处理的问题")
    }

    @ViewBuilder
    private func mainNotice(needsConfirmation: Bool) -> some View {
        if needsConfirmation {
            Text("未确认收到新音频")
                .font(.caption2)
                .foregroundStyle(RecordWatchPalette.warning)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        } else if recorder.errorMessage != nil || recorder.snapshot.state == .failed {
            Text("录音需要处理，详见更多")
                .font(.caption2)
                .foregroundStyle(RecordWatchPalette.warning)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        } else if recorder.syncFeedback.phase == .failed || recorder.syncWarning != nil || recorder.transferMessage != nil {
            Text("同步需要处理，详见更多")
                .font(.caption2)
                .foregroundStyle(RecordWatchPalette.warning)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }

    private var moreSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("已保存").font(.caption.weight(.semibold))
                        detailRow("最近封存", value: savedThrough)
                        detailRow("本次已封存", value: "\(recorder.sealedCount) 段")
                    }
                    .font(.caption2)
                    .padding(.vertical, 4)

                    ForEach(recordingMessages, id: \.self) { message in
                        messageView(message, symbol: "exclamationmark.triangle", color: RecordWatchPalette.warning)
                    }
                    if let message = recorder.recoveryMessage {
                        messageView(message, symbol: "externaldrive.badge.checkmark", color: RecordWatchPalette.secondary)
                    }

                    NavigationLink {
                        syncPage
                    } label: {
                        moreRow("同步到手机", detail: syncTitle, symbol: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        ScrollView {
                            RecordingLocationSettingsView(location: recorder.recordingLocation)
                                .padding(.horizontal, 6)
                        }
                        .navigationTitle("录音位置")
                        .containerBackground(RecordWatchPalette.background, for: .navigation)
                    } label: {
                        moreRow("录音位置", symbol: "location")
                    }
                    .buttonStyle(.plain)

                    NavigationLink {
                        diagnosticsPage
                    } label: {
                        moreRow("诊断", symbol: "waveform.path.ecg")
                    }
                    .buttonStyle(.plain)

                    ForEach(syncMessages, id: \.self) { message in
                        messageView(message, symbol: "exclamationmark.circle", color: RecordWatchPalette.warning)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
            }
            .navigationTitle("更多")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { showMore = false }
                }
            }
            .containerBackground(RecordWatchPalette.background, for: .navigation)
        }
        .foregroundStyle(RecordWatchPalette.foreground)
        .background(RecordWatchPalette.background)
    }

    private var syncPage: some View {
        ScrollView {
            VStack(spacing: 12) {
                detailRow("待手机确认", value: recorder.pendingCountText)
                    .font(.caption2)
                syncStatusCard
                Button(action: recorder.synchronize) {
                    Label(recorder.syncTapCoolingDown ? "已请求同步" : "请求同步",
                          systemImage: recorder.syncTapCoolingDown ? "checkmark" : "arrow.triangle.2.circlepath")
                }
                .buttonStyle(RecordWatchSecondaryButtonStyle())
                .disabled(!recorder.canSynchronize)
                .accessibilityHint("请求传送已保存片段，并核对手机是否已确认保存")
                .accessibilityValue(syncTitle)
                ForEach(syncMessages, id: \.self) { message in
                    messageView(message, symbol: "exclamationmark.circle", color: RecordWatchPalette.warning)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 12)
        }
        .navigationTitle("同步到手机")
        .containerBackground(RecordWatchPalette.background, for: .navigation)
    }

    private var diagnosticsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                detailRow("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "未知")
                Button("准备观察快照", action: recorder.prepareObservationSnapshots)
                Text(recorder.observationPreparationMessage)
                detailRow("本次已封存", value: "\(recorder.sealedCount) 段")
                if let bytes = recorder.freeBytes {
                    detailRow("可用空间", value: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
                }
                if recorder.batteryLevel >= 0 {
                    detailRow("上次记录电量", value: "\(Int(recorder.batteryLevel * 100))%")
                }
                Text("保存完成后等待手机确认；未确认的片段保留在手表。")
                Text("原型仅录音，不转写、不上传云端。")
                Button("录音快检") { recorder.requestIntegrityAudit(mode: .quick) }
                    .disabled(!recorder.canRequestIntegrityAudit)
                Button("完整校验") { recorder.requestIntegrityAudit(mode: .full) }
                    .disabled(!recorder.canRequestIntegrityAudit)
                Text("完整校验在手表本地读取录音，只导出校验报告。请先停止录音并保持 App 打开；开始录音时检查会让路。")
                if let message = recorder.integrityAuditMessage {
                    Text(message).foregroundStyle(RecordWatchPalette.foreground)
                }
                ForEach(diagnosticMessages, id: \.self) { message in
                    messageView(message, symbol: "exclamationmark.triangle", color: RecordWatchPalette.warning)
                }
                if let message = recorder.recoveryMessage {
                    messageView(message, symbol: "externaldrive.badge.checkmark", color: RecordWatchPalette.secondary)
                }
            }
            .font(.caption2)
            .foregroundStyle(RecordWatchPalette.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 6)
            .padding(.bottom, 12)
        }
        .navigationTitle("诊断")
        .containerBackground(RecordWatchPalette.background, for: .navigation)
    }

    private var recordingMessages: [String] {
        var messages = [String]()
        if let error = recorder.errorMessage { messages.append(error) }
        if recorder.audioNeedsConfirmation() {
            messages.append("暂未确认收到新音频。可返回录音页恢复或停止录音。")
        }
        if recorder.snapshot.state == .interrupted || recorder.snapshot.state == .failed {
            let detail = recorder.snapshot.detail ?? "上次录音未正常结束，点击恢复后才会重新录音。"
            if !messages.contains(detail) { messages.append(detail) }
        }
        return messages
    }

    private var diagnosticMessages: [String] {
        (recordingMessages + syncMessages).reduce(into: []) { messages, message in
            if !messages.contains(message) { messages.append(message) }
        }
    }

    private var syncMessages: [String] {
        var messages = [String]()
        for message in [recorder.syncWarning, recorder.transferMessage] {
            if let message, !messages.contains(message) { messages.append(message) }
        }
        return messages
    }

    private var savedThrough: String {
        guard let date = recorder.snapshot.lastSealedAt else { return "暂无封存片段" }
        return date.formatted(date: .omitted, time: .standard)
    }

    private var syncStatusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(syncTitle, systemImage: syncIcon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(RecordWatchPalette.foreground)
            Text(syncDetail)
                .font(.caption2)
                .foregroundStyle(RecordWatchPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let confirmedAt = recorder.syncFeedback.lastConfirmedAt {
                Text("本次打开已确认 \(recorder.syncFeedback.confirmedCount) 段 · \(confirmedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(RecordWatchPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RecordWatchPalette.surface, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private var syncTitle: String {
        guard recorder.hasDisplayablePendingCount else { return "同步状态待核对" }
        if recorder.snapshot.pendingCount > 0,
           recorder.syncFeedback.phase == .completed || recorder.syncFeedback.phase == .idle {
            return "等待手机确认"
        }
        switch recorder.syncFeedback.phase {
        case .idle: return recorder.syncFeedback.observedAt == nil ? "同步状态待检查" : "暂无待同步片段"
        case .requested: return "已请求同步"
        case .waitingForConnection: return "等待手机连接"
        case .queued: return recorder.syncFeedback.queuedCount > 0 ? "已加入同步队列" : "等待传送安排"
        case .transferring: return "正在传送至手机"
        case .waitingForConfirmation: return "等待手机确认"
        case .retryScheduled: return "等待自动重试"
        case .completed: return "已保存到手机"
        case .failed: return "同步需要处理"
        }
    }

    private var syncIcon: String {
        guard recorder.hasDisplayablePendingCount else { return "questionmark.circle" }
        if recorder.snapshot.pendingCount > 0,
           recorder.syncFeedback.phase == .completed || recorder.syncFeedback.phase == .idle {
            return "checkmark.bubble"
        }
        switch recorder.syncFeedback.phase {
        case .idle: return "iphone"
        case .requested: return "checkmark"
        case .waitingForConnection: return "iphone.slash"
        case .queued, .retryScheduled: return "clock"
        case .transferring: return "arrow.up.circle"
        case .waitingForConfirmation: return "checkmark.bubble"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle"
        }
    }

    private var syncDetail: String {
        guard recorder.pendingCountIsKnown else {
            if recorder.hasDisplayablePendingCount {
                return recorder.pendingCountIsRefreshing ? "正在更新，显示上次结果。" : "暂未核对最新数量，显示上次结果。"
            }
            return recorder.syncWarning ?? "正在核对已保存片段和手机确认，暂不显示待传数量。"
        }
        let feedback = recorder.syncFeedback
        let pending = recorder.snapshot.pendingCount
        if pending > 0, feedback.phase == .completed || feedback.phase == .idle {
            return "\(pending) 段待确认。正在更新同步进度，尚不能确认全部送达。"
        }
        switch feedback.phase {
        case .idle:
            return "录音保存成片段后会自动传送；同步按钮可立即检查进度。"
        case .requested:
            return "正在核对已保存片段和手机确认。"
        case .waitingForConnection:
            return "\(pending) 段待确认。两端连接恢复后会自动续传，请保持靠近。"
        case .queued:
            return feedback.queuedCount > 0
                ? "队列中 \(feedback.queuedCount) 段，共 \(pending) 段待确认。系统会安排传送。"
                : "共 \(pending) 段待确认，正在等待可用的传送位置。"
        case .transferring:
            return "传送中 \(feedback.transferringCount) 段，共 \(pending) 段待确认。"
        case .waitingForConfirmation:
            return "\(pending) 段待确认。手机确认保存后才算完成，原录音仍在手表。"
        case .retryScheduled:
            if let retryAt = feedback.retryAt {
                return "\(pending) 段待确认。\(retryAt.formatted(date: .omitted, time: .shortened)) 后会在系统允许的后台机会自动重试。"
            }
            return "\(pending) 段待确认，会在系统允许的后台机会自动重试。"
        case .completed:
            return "当前已保存片段均已获手机确认。新录音保存后继续同步。"
        case .failed:
            return feedback.message ?? "暂时无法确认同步结果，原录音已保留，等待自动重试。"
        }
    }

    private func statusTitle(_ phase: WatchRecorderUIPhase, needsConfirmation: Bool) -> String {
        if needsConfirmation { return "录音待确认" }
        switch phase {
        case .idle: return "开始录音"
        case .checking: return "检查本地录音"
        case .starting: return recorder.isBusy ? "准备麦克风" : "等待音频"
        case .recording: return "录音中"
        case .paused, .ended: return recorder.sealedCount > 0 ? "已保存" : "未录到音频"
        case .saving: return "正在保存…"
        case .recovering: return "正在恢复录音…"
        case .interrupted: return "录音已中断"
        }
    }

    private func statusColor(_ phase: WatchRecorderUIPhase) -> Color {
        switch phase {
        case .recording: return RecordWatchPalette.accent
        case .paused, .ended: return recorder.sealedCount > 0 ? RecordWatchPalette.success : RecordWatchPalette.secondary
        case .recovering, .interrupted: return RecordWatchPalette.warning
        default: return RecordWatchPalette.secondary
        }
    }

    private func spokenDuration(_ seconds: TimeInterval) -> String {
        let value = Int(max(0, seconds))
        return "\(value / 3600) 小时 \((value / 60) % 60) 分 \(value % 60) 秒"
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let value = Int(max(0, seconds))
        return String(format: "%02d:%02d:%02d", value / 3600, (value / 60) % 60, value % 60)
    }

    private func detailRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(RecordWatchPalette.secondary)
            Spacer(minLength: 6)
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private func moreRow(_ title: String, detail: String? = nil, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.caption2).frame(width: 15)
                .foregroundStyle(RecordWatchPalette.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.footnote.weight(.medium))
                if let detail {
                    Text(detail).font(.caption2).foregroundStyle(RecordWatchPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption2)
                .foregroundStyle(RecordWatchPalette.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RecordWatchPalette.surface, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }

    private func messageView(_ text: String, symbol: String, color: Color) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption2)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .background(RecordWatchPalette.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct RecordingLocationSettingsView: View {
    @ObservedObject var location: RecordingLocationManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("为新录音记录位置", isOn: Binding(
                get: { location.isEnabled },
                set: { location.setEnabled($0) }
            ))
            .font(.caption)
            .tint(RecordWatchPalette.accent)
            Text(location.status.text)
                .font(.caption2.weight(.medium))
            Text("手表 App 在前台且录音时获取位置；后台或取不到位置仍正常录音。")
                .font(.caption2)
                .foregroundStyle(RecordWatchPalette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if location.status == .noPermission {
                Text("可在系统设置中允许位置访问。")
                    .font(.caption2)
                    .foregroundStyle(RecordWatchPalette.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RecordWatchPalette.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Attached to the main screen, independent of the settings row's scroll position.
private struct RecordingLocationIntroductionModifier: ViewModifier {
    @ObservedObject var location: RecordingLocationManager
    let isAllowed: Bool

    func body(content: Content) -> some View {
        content.onChange(of: isAllowed, initial: true) { _, allowed in
            location.setIntroductionPresentationAllowed(allowed)
        }
        .background {
            if let id = location.introductionPresentationID {
                RecordingLocationIntroductionPresenter(location: location, presentationID: id)
                    .id(id)
            }
        }
    }
}

/// Every SwiftUI lifecycle closure carries this presentation's immutable identity.
private struct RecordingLocationIntroductionPresenter: View {
    @ObservedObject var location: RecordingLocationManager
    let presentationID: UUID

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .sheet(isPresented: Binding(
                get: { location.introductionPresentationID == presentationID && location.isIntroductionPresented },
                set: { if !$0 { location.declineIntroduction(id: presentationID) } }
            ), onDismiss: { location.introductionDidDismiss(id: presentationID) }) {
                RecordingLocationIntroductionView(location: location, presentationID: presentationID)
                    .interactiveDismissDisabled()
                    .onAppear { location.introductionDidAppear(id: presentationID) }
            }
    }
}

private struct RecordingLocationIntroductionView: View {
    @ObservedObject var location: RecordingLocationManager
    let presentationID: UUID

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("为录音记录位置")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text("仅在手表 App 前台录音时获取位置；不开启也能正常录音。")
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
                Button("开启位置记录") { location.acceptIntroduction(id: presentationID) }
                    .buttonStyle(RecordWatchPrimaryButtonStyle())
                Button("暂不开启") { location.declineIntroduction(id: presentationID) }
                    .buttonStyle(RecordWatchSecondaryButtonStyle())
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 12)
        }
        .foregroundStyle(RecordWatchPalette.foreground)
        .background(RecordWatchPalette.background)
    }
}

private enum RecordWatchPalette {
    static let background = Color(red: 23 / 255, green: 25 / 255, blue: 22 / 255)
    static let foreground = Color(red: 241 / 255, green: 241 / 255, blue: 233 / 255)
    static let accent = Color(red: 223 / 255, green: 105 / 255, blue: 92 / 255)
    static let secondary = Color(red: 150 / 255, green: 157 / 255, blue: 144 / 255)
    static let surface = Color(red: 43 / 255, green: 46 / 255, blue: 40 / 255)
    static let success = Color(red: 167 / 255, green: 188 / 255, blue: 162 / 255)
    static let warning = Color(red: 210 / 255, green: 183 / 255, blue: 127 / 255)
    static let utility = Color(red: 124 / 255, green: 132 / 255, blue: 116 / 255)
}

private struct RecordWatchPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.footnote, design: .default, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(isEnabled ? RecordWatchPalette.background : RecordWatchPalette.secondary)
            .background(isEnabled ? RecordWatchPalette.foreground : RecordWatchPalette.surface, in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
    }
}

private struct RecordWatchSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.footnote.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(RecordWatchPalette.foreground.opacity(isEnabled ? 1 : 0.4))
            .background(RecordWatchPalette.surface, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

private struct RecordWatchUtilityButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(RecordWatchPalette.utility)
            .background(configuration.isPressed ? RecordWatchPalette.surface : Color.clear, in: Circle())
            .contentShape(Rectangle())
    }
}
