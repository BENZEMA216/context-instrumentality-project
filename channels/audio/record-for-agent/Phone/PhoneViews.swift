import RecordingCore
import SwiftUI
import UIKit

private enum PhoneHomeTab: Hashable {
    case record, sync
}

struct PhoneHomeView: View {
    @EnvironmentObject private var store: PhoneStore
    @State private var selection: PhoneHomeTab = .record

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                if let delivery = store.automaticDelivery {
                    ConnectedRecordPage(delivery: delivery, selection: $selection)
                } else {
                    PhoneRecordPage(selection: $selection)
                }
            }
            .tabItem { Label("记录", systemImage: "waveform") }
            .tag(PhoneHomeTab.record)
            NavigationStack {
                if let delivery = store.automaticDelivery {
                    AutomaticDeliveryView(delivery: delivery, legacyLibrary: store.personalLibrary)
                } else if let library = store.personalLibrary {
                    PersonalLibraryView(library: library)
                } else {
                    AgentExportView()
                }
            }
            .tabItem { Label("同步", systemImage: "arrow.triangle.2.circlepath") }
            .tag(PhoneHomeTab.sync)
        }
        .tint(RecordDesign.ink)
    }
}

/// Observe receiver changes without creating another transport or store.
private struct ConnectedRecordPage: View {
    @ObservedObject var delivery: PhoneAutomaticDeliveryStore
    @Binding var selection: PhoneHomeTab

    var body: some View {
        let receiver = delivery.receivers.first { $0.isPaired }
        PhoneRecordPage(selection: $selection,
                        deliveredSegmentIDs: receiver?.deliveredSegmentIDs ?? [],
                        receiverName: receiver?.displayName,
                        receiverCount: delivery.receivers.filter { $0.isPaired }.count)
    }
}

private struct PhoneRecordPage: View {
    @EnvironmentObject private var store: PhoneStore
    @Binding var selection: PhoneHomeTab
    var deliveredSegmentIDs: Set<UUID> = []
    var receiverName: String?
    var receiverCount = 0
    @State private var selectedDay = Date()
    @State private var choosingDate = false
    @State private var showingCalendarMeaning = false
    @State private var showStatus = false
    @State private var showWatchInstructions = false
    @State private var selectedPeriod: PhoneSessionGroup?
    @State private var periodsExpanded = false
    @State private var statusRefreshTask: Task<Void, Never>?
    @State private var statusRefreshOperationID: UUID?
    @State private var statusRefreshIntentID: UUID?

    private var savedManifests: [SegmentManifest] {
        store.manifests.filter { store.receivedSegmentIDs.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                content(now: context.date)
            }
        }
        .foregroundStyle(RecordDesign.ink)
        .background(RecordDesign.background)
        .accessibilityIdentifier("record-home-scroll")
        // Keep the scroll view, refresh and presentation lifetimes outside the
        // periodically rebuilt content, including while a query updates it.
        .refreshable { await refreshHomeStatus() }
        .sheet(isPresented: $choosingDate) {
            NavigationStack {
                DatePicker("选择录音日期", selection: $selectedDay, in: ...Date(), displayedComponents: .date)
                    .accessibilityIdentifier("record-date-picker")
                    .datePickerStyle(.graphical).padding(24)
                    .navigationTitle("录音日历").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { choosingDate = false } } }
            }.presentationDetents([.medium, .large])
        }
        .alert("录音日历", isPresented: $showingCalendarMeaning) {
            Button("知道了", role: .cancel) { }
        } message: {
            Text("灰点表示手机暂无录音，不代表手表没有录音。短线表示手机已收到录音。圆环表示选中日期，浅点表示未来日期。")
        }
        .sheet(isPresented: $showStatus) { RecordStatusSheet() }
        .sheet(isPresented: $showWatchInstructions) {
            WatchRecordingInstructions(action: actionTitle(now: Date()) ?? "开始录音")
        }
        .sheet(item: $selectedPeriod) { group in
            RecordPeriodSheet(groupID: group.id,
                              deliveredSegmentIDs: deliveredSegmentIDs,
                              receiverName: receiverName, library: store.personalLibrary) {
                selectedPeriod = nil
                selection = .sync
            }
        }
        .onChange(of: selectedDay) { _, _ in periodsExpanded = false }
        .onDisappear {
            statusRefreshOperationID = nil
            statusRefreshTask?.cancel()
            statusRefreshTask = nil
            if let intentID = statusRefreshIntentID {
                store.cancelStatusRequest(ifIntentID: intentID)
                statusRefreshIntentID = nil
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { yearSelector }
            if #available(iOS 26.0, *) {
                ToolbarItem(placement: .topBarLeading) { recordTitle }
                    .sharedBackgroundVisibility(.hidden)
                ToolbarItem(placement: .topBarTrailing) { settingsLink }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .topBarLeading) { recordTitle }
                ToolbarItem(placement: .topBarTrailing) { settingsLink }
            }
        }
        .toolbarBackground(RecordDesign.background, for: .navigationBar)
        .background(RecordDesign.background)
    }

    @MainActor
    private func refreshHomeStatus() async {
        guard !Task.isCancelled else { return }
        if let statusRefreshTask {
            await statusRefreshTask.value
            return
        }
        // A busy observer must not take ownership from a sheet or another view.
        guard !store.isRequestingStatus else {
            await store.requestStatusAndWait()
            return
        }
        guard let intentID = store.requestStatus() else { return }
        statusRefreshIntentID = intentID
        let operationID = UUID()
        // SwiftUI may cancel its refresh action while updating the scroll view.
        // The page owns the user's query until it finishes or the page leaves.
        let task = Task { @MainActor [store] in await store.waitForStatusRequest(intentID: intentID) }
        statusRefreshOperationID = operationID
        statusRefreshTask = task
        await task.value
        guard statusRefreshOperationID == operationID else { return }
        statusRefreshOperationID = nil
        statusRefreshTask = nil
    }

    private var recordTitle: some View {
        Image(systemName: "waveform").font(.system(size: 23, weight: .regular))
            .frame(minWidth: 44, minHeight: 44, alignment: .leading).accessibilityLabel("记录")
            .accessibilityAddTraits(.isHeader)
    }

    private var yearSelector: some View {
        Button { choosingDate = true } label: {
            HStack(spacing: 8) {
                Text(String(Calendar.current.component(.year, from: selectedDay)))
                    .font(.system(size: 25, weight: .regular, design: .rounded))
                Image(systemName: "chevron.down").font(.caption2).foregroundStyle(RecordDesign.secondary)
            }.frame(minHeight: 44).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("record-year-picker")
    }

    private var settingsLink: some View {
        NavigationLink { RecordingSettingsView() } label: {
            Image(systemName: "slider.horizontal.3").frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("录音设置")
        .accessibilityIdentifier("record-settings")
    }

    private func content(now: Date) -> some View {
        let saved = savedManifests
        let activity = RecordingActivity(manifests: saved, now: now)
        let savedGroups = PhoneSessionGroup.groups(from: saved)
        let groups = savedGroups.filter {
            RecordingActivity(manifests: $0.segments, now: now).day(on: selectedDay).recordedDuration > 0
        }
        let summary = activity.day(on: selectedDay)
        let year = Calendar.current.component(.year, from: selectedDay)
        return VStack(alignment: .leading, spacing: 0) {
            if let state = currentState(now: now),
               [.recording, .starting, .interrupted, .failed].contains(state) {
                statusLine(state: state).padding(.vertical, 12)
            }
            statusQueryFeedback
            if let error = store.storageError {
                RecordNotice(error, symbol: "exclamationmark.triangle", isError: true).font(.caption).padding(.bottom, 12)
            }
            if !store.hasLibrarySnapshot {
                Text(store.storageError == nil ? "正在读取本机录音" : "本机录音暂不可用")
                    .font(.caption).foregroundStyle(RecordDesign.secondary).padding(.vertical, 12)
            }
            if let latest = savedGroups.first(where: { $0.segments.contains { $0.startedAt < now && $0.duration > 0 } }) {
                recentRecording(latest, now: now)
                Divider().overlay(RecordDesign.rule).padding(.bottom, 12)
            }
            Button { choosingDate = true } label: {
                AnnualRecordingMarks(activity: activity, year: year, selectedDay: selectedDay, now: now)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("recording-calendar")
                .accessibilityLabel("\(year)年录音日历，点按选择日期")
                .accessibilityHint("短线表示手机已收到录音")
            HStack {
                Button("日历标记") { showingCalendarMeaning = true }
                    .font(.caption).frame(minHeight: 44).accessibilityIdentifier("record-calendar-legend")
                Spacer()
                if !Calendar.current.isDate(selectedDay, inSameDayAs: now) {
                    Button("今天") { selectedDay = now }.font(.caption).frame(minHeight: 44)
                        .accessibilityIdentifier("record-calendar-today")
                }
            }.foregroundStyle(RecordDesign.secondary)
            Divider().overlay(RecordDesign.rule)
            Button { periodsExpanded.toggle() } label: {
                VStack(alignment: .leading, spacing: 10) {
                    Text(selectedDay.formatted(.dateTime.month().day()) + " · " + (summary.recordedDuration > 0 ? "手机已收到" : "手机暂无录音"))
                        .font(.caption).foregroundStyle(RecordDesign.secondary)
                        .accessibilityIdentifier("record-calendar-selection")
                    HStack {
                        Text(store.hasLibrarySnapshot ? phoneCompactDuration(summary.recordedDuration) : "—")
                            .font(.system(size: 28, weight: .regular)).monospacedDigit()
                            .accessibilityIdentifier("record-duration")
                        Spacer()
                        Text("\(groups.count) 次").font(.caption).foregroundStyle(RecordDesign.secondary)
                        Image(systemName: periodsExpanded ? "chevron.up" : "chevron.right").font(.caption2)
                    }
                }.frame(maxWidth: .infinity, minHeight: 86, alignment: .leading).padding(.vertical, 12).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("record-periods")
            if periodsExpanded {
                if groups.isEmpty {
                    Text("这一天手机尚未收到已确认的录音时段").font(.subheadline).foregroundStyle(RecordDesign.secondary).padding(.vertical, 16)
                }
                ForEach(groups) { group in
                    Button { selectedPeriod = group } label: { recordPeriodRow(group, now: now) }
                        .buttonStyle(.plain).accessibilityIdentifier("record-period-row")
                    Divider().overlay(RecordDesign.rule)
                }
            }
        }.padding(.horizontal, 24).padding(.bottom, 24)
    }

    private func recentRecording(_ group: PhoneSessionGroup, now: Date) -> some View {
        let duration = RecordingActivity(manifests: group.segments, now: now).totalRecordedDuration
        return Button { selectedPeriod = group } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text("最近一条录音").font(.caption).foregroundStyle(RecordDesign.secondary)
                HStack {
                    Text(group.startedAt.formatted(.dateTime.month().day().hour().minute()))
                        .font(.subheadline.weight(.medium))
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(RecordDesign.secondary)
                }
                Text("手机已收到 \(phoneCompactDuration(duration))")
                    .font(.caption).foregroundStyle(RecordDesign.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 14).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityElement(children: .combine)
            .accessibilityIdentifier("record-latest")
            .accessibilityHint("查看这条录音的同步状态")
    }

    @ViewBuilder
    private var statusQueryFeedback: some View {
        if store.isRequestingStatus || store.statusFeedback != nil {
            HStack(alignment: .top, spacing: 10) {
                if store.isRequestingStatus {
                    ProgressView().controlSize(.small).tint(RecordDesign.secondary)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: store.statusFeedbackIsError ? "exclamationmark.circle" : "checkmark.circle")
                        .foregroundStyle(store.statusFeedbackIsError ? RecordDesign.accent : RecordDesign.secondary)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(store.isRequestingStatus ? "正在获取手表录音状态…" : store.statusFeedback ?? "")
                        .foregroundStyle(store.statusFeedbackIsError ? RecordDesign.ink : RecordDesign.secondary)
                    if !store.isRequestingStatus && store.statusFeedbackIsError {
                        Text("已保存的录音不受影响。")
                            .foregroundStyle(RecordDesign.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .font(.caption)
            .padding(.bottom, 16)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("record-home-status-feedback")
            .accessibilityValue(store.isRequestingStatus ? "获取中" : store.statusFeedbackIsError ? "查询失败" : "查询完成")
        }
    }

    @ViewBuilder
    private func recordingHero(today: RecordingActivity.Day, now: Date) -> some View {
        let state = currentState(now: now)
        if !store.hasLibrarySnapshot {
            VStack(alignment: .leading, spacing: 12) {
                Text("今日记录").font(.caption).foregroundStyle(RecordDesign.secondary)
                Text("—").font(.system(size: 46, weight: .regular))
                    .accessibilityLabel(store.storageError == nil ? "正在读取本机录音" : "本机录音暂不可用")
                    .accessibilityValue("—").accessibilityIdentifier("record-duration")
                Text(store.storageError == nil ? "正在读取本机录音" : "本机录音暂时无法读取。下拉仅更新手表状态。")
                    .font(.subheadline).foregroundStyle(RecordDesign.secondary)
                    .accessibilityIdentifier(store.storageError == nil ? "record-library-loading" : "record-library-failed")
            }.padding(.top, 22).padding(.bottom, 28)
        } else if today.recordedDuration > 0 {
            VStack(alignment: .leading, spacing: 0) {
                if let state { statusLine(state: state) }
                Text(state == nil ? "今日已保存" : "今日录音")
                    .font(.caption).foregroundStyle(RecordDesign.secondary).padding(.top, 10)
                RecordDurationHero(duration: today.recordedDuration,
                                   title: state == nil ? "今日已保存" : "今日录音")
                    .padding(.top, 6).accessibilityIdentifier("record-duration")
                deliverySummary(today: today).padding(.top, 12)
            }.padding(.top, 6).padding(.bottom, 22)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text("今日记录").font(.caption).foregroundStyle(RecordDesign.secondary)
                Text(emptyTitle(state)).font(.title2.weight(.medium)).padding(.top, 12)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("record-empty-title")
                Text(emptyGuidance(state)).font(.subheadline).foregroundStyle(RecordDesign.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
                Button {
                    if state == nil || state == .recording || state == .starting {
                        showStatus = true
                    } else {
                        showWatchInstructions = true
                    }
                } label: {
                    HStack(spacing: 18) {
                        Text(emptyAction(state)).font(.subheadline.weight(.medium))
                        Image(systemName: "chevron.right").font(.caption2)
                    }
                    .padding(.horizontal, 16).frame(minHeight: 44)
                    .foregroundStyle(RecordDesign.background)
                    .background(RecordDesign.ink, in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain).padding(.top, 20)
                .accessibilityIdentifier(state == nil || state == .recording || state == .starting
                                         ? "record-status-open" : "record-watch-instructions")
            }.padding(.top, 22).padding(.bottom, 28)
        }
    }

    private func currentState(now: Date) -> CaptureState? {
        guard store.connection.reachable, let snapshot = store.connection.snapshot,
              !snapshot.isStale(at: now) else { return nil }
        return snapshot.state
    }

    private func emptyTitle(_ state: CaptureState?) -> String {
        switch state {
        case nil: return "等待手表更新"
        case .recording: return "录音中"
        case .starting: return "正在启动录音"
        case .paused: return "继续今天的记录"
        case .interrupted, .failed: return "录音已中断"
        case .idle, .ended: return "开始今天的记录"
        }
    }

    private func emptyGuidance(_ state: CaptureState?) -> String {
        switch state {
        case nil: return "打开手表 App，确认当前录音状态。"
        case .recording, .starting: return "首段录音保存到手机后，这里会显示时长。"
        case .paused: return "在 Apple Watch 上继续录音。"
        case .interrupted, .failed: return "请在手表 App 中恢复录音。"
        case .idle, .ended: return "在 Apple Watch 上开始录音。"
        }
    }

    private func emptyAction(_ state: CaptureState?) -> String {
        switch state {
        case nil, .recording, .starting: return "查看状态"
        case .paused: return "如何继续"
        case .interrupted, .failed: return "如何恢复"
        case .idle, .ended: return "如何开始"
        }
    }

    private func statusLine(state: CaptureState) -> some View {
        HStack(spacing: 7) {
            Circle().fill(state == .recording ? RecordDesign.accent
                          : state == .interrupted || state == .failed
                          ? RecordDesign.warning : RecordDesign.secondary)
                .frame(width: 5, height: 5).accessibilityHidden(true)
            Text(recordStateLabel(state))
                .font(.subheadline).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("record-status")
            Spacer(minLength: 8)
            Button { showStatus = true } label: {
                HStack(spacing: 5) {
                    Text("查看状态")
                    Image(systemName: "chevron.right").font(.caption2)
                }.font(.caption).foregroundStyle(RecordDesign.secondary).frame(minHeight: 44)
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("record-status-open")
        }
    }

    private func actionTitle(now: Date) -> String? {
        switch currentState(now: now) {
        case .idle, .ended: return "开始录音"
        case .paused: return "继续录音"
        case .interrupted, .failed: return "恢复录音"
        case nil, .recording, .starting: return nil
        }
    }

    @ViewBuilder
    private func deliverySummary(today: RecordingActivity.Day) -> some View {
        let remaining = max(0, today.recordedDuration - today.receivedDuration)
        if receiverName == nil || remaining > 0 {
            Button { selection = .sync } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath").font(.caption)
                        Text(receiverName == nil ? "选择同步方式" : "\(phoneCompactDuration(remaining))待同步到电脑")
                            .font(.caption)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right").font(.caption2)
                    }.frame(minHeight: 44)
                    if receiverCount > 1, let receiverName {
                        Text("仅显示 \(receiverName)").font(.caption2)
                    }
                }.foregroundStyle(RecordDesign.secondary).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityIdentifier("record-delivery-summary")
            .accessibilityHint("切换到同步，查看各接收端的进度。已收到不代表已处理")
        }
    }

    private func recordPeriodRow(_ group: PhoneSessionGroup, now: Date) -> some View {
        let summary = RecordingActivity(manifests: group.segments, now: now).day(on: selectedDay)
        let snapshot = store.connection.snapshot
        let isCurrent = Calendar.current.isDate(selectedDay, inSameDayAs: now)
            && (snapshot?.recordingGroupID ?? snapshot?.sessionID) == group.id
            && snapshot?.isStale(at: now) == false && store.connection.reachable
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(phoneSessionTimeRange(summary)).font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                Text(phoneCompactDuration(summary.recordedDuration)).font(.subheadline).monospacedDigit()
            }
            if isCurrent, let snapshot, snapshot.state == .recording || snapshot.state == .starting {
                Text(recordStateLabel(snapshot.state)).font(.caption).foregroundStyle(RecordDesign.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 14)
            .contentShape(Rectangle()).accessibilityElement(children: .combine)
            .accessibilityHint("查看时段与同步详情")
    }
}

private struct AnnualRecordingMarks: View {
    let activity: RecordingActivity
    let year: Int
    let selectedDay: Date
    let now: Date
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 16)
    var body: some View {
        LazyVGrid(columns: columns, spacing: 0) {
            ForEach(RecordingYearLayout(year: year).dates, id: \.self) { day in
                let mark = RecordingDayMark.resolve(
                    isFuture: day > Calendar.current.startOfDay(for: now),
                    hasReceivedAudio: activity.day(on: day).recordedDuration > 0)
                ZStack {
                    if mark == .pending || mark == .archived {
                        Capsule().fill(mark == .archived ? RecordDesign.ink : RecordDesign.secondary)
                            .frame(width: 8, height: 2)
                    } else {
                        Circle().fill(RecordDesign.ink.opacity(mark == .future ? 0.10 : 0.32)).frame(width: 2.5, height: 2.5)
                    }
                    if Calendar.current.isDate(day, inSameDayAs: selectedDay) {
                        Circle().strokeBorder(RecordDesign.ink, lineWidth: 0.8).frame(width: 16, height: 16)
                    }
                }.frame(maxWidth: .infinity).frame(height: 19)
            }
        }.accessibilityHidden(true)
    }
}

private struct RecordDurationHero: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 46
    let duration: TimeInterval
    let title: String

    var body: some View {
        let seconds = Int(max(0, duration.isFinite ? duration : 0))
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                Text(phoneCompactDuration(duration)).font(.largeTitle).fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    if seconds >= 3600 {
                        number(seconds / 3600)
                        unit("小时")
                        if (seconds / 60) % 60 > 0 {
                            number((seconds / 60) % 60)
                            unit("分")
                        }
                    } else if seconds > 0 && seconds < 60 {
                        number(seconds)
                        unit("秒")
                    } else {
                        number(seconds / 60)
                        unit("分")
                    }
                }.lineLimit(1).minimumScaleFactor(0.5)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)，\(phoneSpokenDuration(duration))")
    }

    private func number(_ number: Int) -> some View {
        Text("\(number)").font(.system(size: size, weight: .regular)).monospacedDigit().tracking(-1.5)
    }

    private func unit(_ text: String) -> some View {
        Text(text).font(.subheadline).foregroundStyle(RecordDesign.secondary).padding(.trailing, 4)
    }
}

private struct RecordingCalendar: View {
    let activity: RecordingActivity
    let layout: RecordingCalendarLayout
    let now: Date
    let todayIsUnconfirmed: Bool
    @Binding var selectedDay: Date
    @ScaledMetric(relativeTo: .caption2) private var monthHeight: CGFloat = 18
    @ScaledMetric(relativeTo: .caption2) private var weekdayWidth: CGFloat = 12
    private var weekdayGutter: CGFloat { weekdayWidth + 8 }
    private var rowHeight: CGFloat { max(24, weekdayWidth + 8) }
    private var calendar: Calendar { Calendar.current }
    private var gridHeight: CGFloat {
        monthHeight + 6 + rowHeight * 7 + (layout.trailingMonthLabel == nil ? 0 : monthHeight + 6)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(rangeDate(layout.startDate)) – \(rangeDate(layout.today))")
                .font(.caption2).foregroundStyle(RecordDesign.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)
                .accessibilityIdentifier("record-calendar-range")
            GeometryReader { proxy in
                // One slot width and one center for both labels and cells. At
                // large text sizes the grid scrolls, retaining these anchors.
                let columnWidth = max(weekdayWidth * 2.5,
                                      (proxy.size.width - weekdayGutter) / CGFloat(layout.weekCount))
                HStack(alignment: .top, spacing: 8) {
                    VStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { row in
                            Text(row == 0 ? "一" : row == 2 ? "三" : row == 4 ? "五" : "")
                                .font(.caption2).foregroundStyle(RecordDesign.secondary)
                                .frame(width: weekdayWidth, height: rowHeight)
                        }
                    }
                    .padding(.top, monthHeight + 6)
                    .accessibilityHidden(true)
                    ScrollViewReader { scroll in
                        ScrollView(.horizontal) {
                            VStack(spacing: 0) {
                                HStack(spacing: 0) {
                                    ForEach(0..<layout.weekCount, id: \.self) { column in
                                        let label = layout.monthLabels.first { $0.column == column }
                                        Text(label.map { monthLabel($0.date) } ?? "")
                                            .frame(width: columnWidth, height: monthHeight)
                                    }
                                }
                                .font(.caption2).foregroundStyle(RecordDesign.secondary)
                                .padding(.bottom, 6)
                                ZStack(alignment: .topLeading) {
                                    HStack(alignment: .top, spacing: 0) {
                                        ForEach(0..<layout.weekCount, id: \.self) { column in
                                            VStack(spacing: 0) {
                                                ForEach(0..<7, id: \.self) { row in
                                                    calendarCell(column: column, row: row)
                                                        .frame(width: columnWidth, height: rowHeight)
                                                }
                                            }.id(column)
                                        }
                                    }
                                    monthDividers(columnWidth: columnWidth)
                                        .stroke(RecordDesign.secondary.opacity(0.6), lineWidth: 1)
                                        .allowsHitTesting(false).accessibilityHidden(true)
                                }
                                .frame(height: rowHeight * 7)
                                // Before a month's first Monday (e.g. Sun Nov 1),
                                // label its partial column below the marked day 1,
                                // never above the previous month's six days.
                                if let label = layout.trailingMonthLabel {
                                    HStack(spacing: 0) {
                                        ForEach(0..<layout.weekCount, id: \.self) { column in
                                            Text(column == label.column ? monthLabel(label.date) : "")
                                                .frame(width: columnWidth, height: monthHeight)
                                        }
                                    }
                                    .font(.caption2).foregroundStyle(RecordDesign.secondary)
                                    .padding(.top, 6)
                                }
                            }.frame(width: columnWidth * CGFloat(layout.weekCount))
                        }
                        .scrollIndicators(.hidden)
                        .defaultScrollAnchor(.trailing)
                        .onChange(of: selectedDay) { _, day in
                            if calendar.isDate(day, inSameDayAs: layout.today) {
                                scroll.scrollTo(layout.weekCount - 1, anchor: .trailing)
                            }
                        }
                    }
                }
            }.frame(height: gridHeight)
            HStack(alignment: .firstTextBaseline) {
                Text(selectedDay.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits))
                     + (calendar.isDate(selectedDay, inSameDayAs: now) ? " · 今天" : ""))
                Spacer(minLength: 8)
                Text(daySummary(selectedDay)).monospacedDigit().multilineTextAlignment(.trailing)
            }
            .font(.caption).foregroundStyle(RecordDesign.secondary)
            .frame(minHeight: 40).padding(.top, 6)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("record-calendar-selection")
        }
        .onChange(of: layout.startDate) { _, _ in
            if layout.position(for: selectedDay) == nil { selectedDay = now }
        }
    }

    private func monthDividers(columnWidth: CGFloat) -> Path {
        Path { path in
            for boundary in layout.monthBoundaries {
                let x = CGFloat(boundary.column) * columnWidth
                let y = CGFloat(boundary.row) * rowHeight
                path.move(to: CGPoint(x: x, y: rowHeight * 7))
                path.addLine(to: CGPoint(x: x, y: y))
                if boundary.row > 0 {
                    path.addLine(to: CGPoint(x: x + columnWidth, y: y))
                    path.addLine(to: CGPoint(x: x + columnWidth, y: 0))
                }
            }
        }
    }

    @ViewBuilder
    private func calendarCell(column: Int, row: Int) -> some View {
        if let date = layout.date(column: column, row: row) {
            let duration = activity.day(on: date).recordedDuration
            let selected = calendar.isDate(date, inSameDayAs: selectedDay)
            let unconfirmed = todayIsUnconfirmed && calendar.isDate(date, inSameDayAs: now)
            Button { selectedDay = date } label: {
                RoundedRectangle(cornerRadius: 4)
                    .fill(cellColor(duration: duration))
                    .overlay {
                        if unconfirmed {
                            Canvas { context, size in
                                var lines = Path()
                                for x in stride(from: -size.height, through: size.width, by: 5) {
                                    lines.move(to: CGPoint(x: x, y: size.height))
                                    lines.addLine(to: CGPoint(x: x + size.height, y: 0))
                                }
                                context.stroke(lines, with: .color(RecordDesign.secondary.opacity(0.45)), lineWidth: 1)
                            }.clipShape(RoundedRectangle(cornerRadius: 4)).accessibilityHidden(true)
                        }
                    }
                    .overlay {
                        if calendar.component(.day, from: date) == 1 {
                            Text("1").font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(RecordDesign.ink).accessibilityHidden(true)
                        }
                        if selected {
                            RoundedRectangle(cornerRadius: 6).strokeBorder(RecordDesign.ink, lineWidth: 1.5).padding(-3)
                        }
                    }
                    .frame(width: min(18, rowHeight - 6), height: min(18, rowHeight - 6))
                    .frame(maxWidth: .infinity, maxHeight: .infinity).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("record-calendar-day-\(calendarIdentifier(date))")
            .accessibilityLabel("\(date.formatted(date: .complete, time: .omitted))，\(daySummary(date))")
            .accessibilityAddTraits(selected ? .isSelected : [])
        } else {
            Color.clear.accessibilityHidden(true)
        }
    }

    private func daySummary(_ date: Date) -> String {
        let duration = activity.day(on: date).recordedDuration
        let unconfirmed = todayIsUnconfirmed && calendar.isDate(date, inSameDayAs: now)
        if duration > 0 {
            return unconfirmed ? "已保存 \(phoneCompactDuration(duration)) · 状态待更新" : phoneCompactDuration(duration)
        }
        return unconfirmed ? "待更新" : "暂无已保存录音"
    }

    private func cellColor(duration: TimeInterval) -> Color {
        if duration <= 0 { return RecordDesign.inset }
        if duration <= 3600 { return RecordDesign.good.opacity(0.28) }
        if duration <= 10800 { return RecordDesign.good.opacity(0.48) }
        if duration <= 18000 { return RecordDesign.good.opacity(0.72) }
        return RecordDesign.good
    }

    private func calendarIdentifier(_ date: Date) -> String {
        String(format: "%04d-%02d-%02d", calendar.component(.year, from: date),
               calendar.component(.month, from: date), calendar.component(.day, from: date))
    }

    private func rangeDate(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.defaultDigits).day(.defaultDigits))
    }

    private func monthLabel(_ date: Date) -> String {
        "\(calendar.component(.month, from: date))月"
    }
}

private struct RecordingReminderLink: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var reminder = RecordingReminderStore.shared
    @State private var showReminder = false

    var body: some View {
        Button { showReminder = true } label: {
            HStack {
                Text("录音提醒")
                Spacer()
                Text(reminder.isEnabled ? reminder.time.formatted(date: .omitted, time: .shortened) : "未开启")
                Image(systemName: "chevron.right").font(.caption2)
            }.font(.caption).foregroundStyle(RecordDesign.secondary).frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("record-reminder")
        .sheet(isPresented: $showReminder) { RecordingReminderView() }
        .task { await reminder.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await reminder.refresh() } }
        }
    }
}

struct RecordingSettingsView: View {
    @State private var showWatchStatus = false

    private var privacyPolicyURL: URL? { publicURL(for: "WRPrivacyPolicyURL") }
    private var supportURL: URL? { publicURL(for: "WRSupportURL") }

    var body: some View {
        List {
            Section {
                RecordingReminderLink().recordRow()
                Button { showWatchStatus = true } label: {
                    Label("手表状态", systemImage: "applewatch")
                }
                .accessibilityIdentifier("record-settings-watch-status")
                .recordRow()
                NavigationLink { PhoneDiagnosticsView() } label: {
                    Label("日志与诊断", systemImage: "doc.text.magnifyingglass")
                }.recordRow()
            }
            if privacyPolicyURL != nil || supportURL != nil {
                Section {
                    if let privacyPolicyURL {
                        Link(destination: privacyPolicyURL) {
                            Label("隐私政策", systemImage: "hand.raised")
                        }.recordRow()
                    }
                    if let supportURL {
                        Link(destination: supportURL) {
                            Label("帮助与支持", systemImage: "questionmark.circle")
                        }.recordRow()
                    }
                }
            }
        }
        .recordListAppearance()
        .navigationTitle("设置").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showWatchStatus) { RecordStatusSheet() }
    }

    private func publicURL(for key: String) -> URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              let url = URL(string: value), url.scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }
}

private struct RecordStatusSheet: View {
    @EnvironmentObject private var store: PhoneStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var historyExpanded = false
    @State private var ownedStatusIntentID: UUID?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("录制状态").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("record-status-heading")
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark").font(.body)
                                .foregroundStyle(RecordDesign.secondary).frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).accessibilityLabel("关闭")
                        .accessibilityIdentifier("record-status-close")
                    }.padding(.bottom, 16)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(statusTitle(now: context.date)).font(.title3.weight(.medium))
                            .accessibilityIdentifier("record-status-message")
                        Text(guidance(now: context.date)).font(.subheadline).foregroundStyle(RecordDesign.secondary)
                            .accessibilityIdentifier("record-status-guidance")
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
                    Button { requestStatus() } label: {
                        Text(store.isRequestingStatus ? "获取中…" : "重新获取状态")
                    }
                    .buttonStyle(RecordPrimaryButtonStyle())
                    .disabled(store.isRequestingStatus)
                    .accessibilityIdentifier("record-status-refresh")
                    .padding(.top, 22)
                    if let snapshot = store.connection.snapshot {
                        DisclosureGroup(isExpanded: $historyExpanded) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(recordStateLabel(snapshot.state)) · \(snapshot.observedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                Text("这是手表上次报告的状态。")
                                    .font(.caption2)
                            }
                            .foregroundStyle(RecordDesign.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 8)
                        } label: {
                            Text("查看上次报告").font(.caption).frame(minHeight: 44)
                        }
                        .tint(RecordDesign.secondary)
                        .accessibilityIdentifier("record-status-history")
                        .padding(.top, 10)
                    }
                }.padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 24)
            }
            .foregroundStyle(RecordDesign.ink).background(RecordDesign.background)
        }
        .presentationBackground(RecordDesign.background)
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .presentationDetents(dynamicTypeSize.isAccessibilitySize
                             ? [.large] : [.height(historyExpanded ? 440 : 350), .large])
        .onChange(of: store.statusRequestGeneration) { _, _ in
            if store.isRequestingStatus { announce("正在等待手表回应。") }
        }
        .onChange(of: store.isRequestingStatus) { _, pending in
            guard !pending else { return }
            if store.statusFeedbackIsError, let message = store.statusFeedback {
                announce(message)
            } else if let snapshot = store.connection.snapshot {
                announce(recordStateLabel(snapshot.state))
            }
        }
        .onDisappear {
            if let intentID = ownedStatusIntentID {
                store.cancelStatusRequest(ifIntentID: intentID)
                ownedStatusIntentID = nil
            }
        }
    }

    private func currentState(now: Date) -> CaptureState? {
        guard store.connection.reachable, let snapshot = store.connection.snapshot,
              !snapshot.isStale(at: now) else { return nil }
        return snapshot.state
    }

    private func statusTitle(now: Date) -> String {
        if store.isRequestingStatus { return "正在等待手表回应…" }
        if store.statusFeedbackIsError, let message = store.statusFeedback { return message }
        return currentState(now: now).map(recordStateLabel) ?? "手表状态待更新"
    }

    private func guidance(now: Date) -> String {
        if store.isRequestingStatus { return "请保持手表与手机连接。" }
        if store.statusFeedbackIsError {
            return store.isAwaitingStatusRecovery
                ? "连接恢复后会自动再试一次。已保存的录音不受影响。"
                : "已保存的录音不受影响。"
        }
        switch currentState(now: now) {
        case nil: return "请打开手表 App，确认当前录音状态。"
        case .interrupted, .failed: return "请在手表 App 中恢复录音。"
        case .idle, .ended: return "在 Apple Watch 上开始录音。"
        case .paused: return "如需继续，请在 Apple Watch 上操作。"
        case .recording, .starting: return "首页时长按手机已保存的录音统计。"
        }
    }

    private func requestStatus() {
        guard !store.isRequestingStatus else { return }
        ownedStatusIntentID = store.requestStatus()
    }

    private func announce(_ message: String) {
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: message)
        }
    }
}

private struct WatchRecordingInstructions: View {
    @Environment(\.dismiss) private var dismiss
    let action: String

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: "applewatch").font(.system(size: 48, weight: .light)).padding(.top, 12)
                Text("在手表上\(action)").font(.title2.weight(.medium))
                Text("打开 Apple Watch 上的 Record for Agent，轻点“\(action == "开始录音" ? "开始" : action == "继续录音" ? "继续" : "恢复")”。")
                    .font(.body).fixedSize(horizontal: false, vertical: true)
                Text("当前需从手表启动。手机会在收到新片段后更新时长。")
                    .font(.subheadline).foregroundStyle(RecordDesign.secondary)
                Spacer()
                Button("知道了") { dismiss() }.buttonStyle(RecordPrimaryButtonStyle())
            }
            .padding(24).foregroundStyle(RecordDesign.ink).background(RecordDesign.background)
            .navigationTitle(action).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.tint(RecordDesign.ink)
    }
}

struct PhoneSessionGroup: Identifiable {
    let id: UUID
    let segments: [SegmentManifest]
    var recordingGroup: RecordingGroup? { segments.first?.recordingGroup }
    var startedAt: Date { recordingGroup?.startedAt ?? segments.map(\.startedAt).min() ?? .distantPast }
    var hasSequenceGap: Bool {
        let sequences = segments.map(\.recordingPartIndex).sorted()
        return (sequences.first ?? 0) > 0 || zip(sequences, sequences.dropFirst()).contains { $1 - $0 > 1 }
    }

    static func groups(from manifests: [SegmentManifest]) -> [Self] {
        Dictionary(grouping: manifests, by: \.recordingGroupID).map { id, segments in
            Self(id: id, segments: segments.sorted { $0.sequence < $1.sequence })
        }.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

struct RecordPeriodSheet: View {
    @EnvironmentObject private var store: PhoneStore
    @Environment(\.dismiss) private var dismiss
    let groupID: UUID
    let deliveredSegmentIDs: Set<UUID>
    let receiverName: String?
    let library: PersonalLibraryStore?
    var showSync: (() -> Void)? = nil

    var body: some View {
        let group = PhoneSessionGroup(id: groupID, segments: store.manifests.filter {
            $0.recordingGroupID == groupID && store.receivedSegmentIDs.contains($0.id)
        })
        let summary = RecordingActivity(manifests: group.segments, deliveredSegmentIDs: deliveredSegmentIDs)
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 18) {
                        let format = Date.FormatStyle(date: .numeric, time: .standard,
                                                      timeZone: group.recordingGroup?.timeZone ?? .current)
                        RecordMetadataRow("开始录制", value: group.startedAt.formatted(format))
                        RecordMetadataRow("手机已保存", value: phoneCompactDuration(summary.totalRecordedDuration))
                        if let receiverName {
                            let receipt = summary.totalReceivedDuration > 0
                                ? "已接收 \(phoneCompactDuration(summary.totalReceivedDuration))" : "未接收"
                            RecordMetadataRow("电脑接收端", value: receipt)
                                .accessibilityIdentifier("record-period-computer")
                            Text("设备 \(receiverName)").font(.caption).foregroundStyle(RecordDesign.secondary)
                        }
                        if group.hasSequenceGap {
                            Text("部分片段尚未传到手机。").font(.caption).foregroundStyle(RecordDesign.secondary)
                        }
                        if let library {
                            RecordingCloudDestinations(iCloud: library.iCloudDrive, drive: library.drive,
                                                       segmentIDs: Set(group.segments.map(\.id)))
                        }
                        if let showSync {
                            Button("同步设置", action: showSync).buttonStyle(RecordSecondaryButtonStyle())
                        }
                    }.recordCard().recordRow()
                }
                if let library, !group.segments.isEmpty {
                    Section {
                        NavigationLink {
                            RecordingTranscriptionView(library: library, groupID: groupID)
                        } label: {
                            Label("本机转写", systemImage: "text.alignleft")
                        }
                        .accessibilityIdentifier("recording-transcription")
                        .recordRow()
                    }
                }
            }
            .recordListAppearance().navigationTitle("录音时段").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }.tint(RecordDesign.ink)
    }
}

private func recordStateLabel(_ state: CaptureState) -> String {
    switch state {
    case .idle, .ended: return "未在录音"
    case .starting: return "正在启动"
    case .recording: return "录音中"
    case .paused: return "已暂停"
    case .interrupted, .failed: return "录音已中断"
    }
}

struct PhoneDiagnosticsView: View {
    @EnvironmentObject private var store: PhoneStore
    @State private var shareFile: RecordDiagnosticShareFile?
    @State private var shareRecentWhenReady = false

    private var currentBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "未知"
    }

    var body: some View {
        List {
            Section("观察快照") {
                Button("准备观察快照") {
                    store.prepareObservationSnapshots()
                }
                Text(store.observationPreparationMessage)
                    .font(.caption).foregroundStyle(RecordDesign.secondary)
            }
            Section {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("反馈问题").font(.headline)
                        Text("默认分享脱敏的近期问题报告，保留有限的近期日志和已保存的连接故障。")
                            .font(.subheadline).foregroundStyle(RecordDesign.secondary)
                    }
                    Text("构建 \(store.diagnosticBuild ?? currentBuild)")
                        .font(.caption).monospacedDigit().foregroundStyle(RecordDesign.secondary)
                        .accessibilityIdentifier("diagnostics-build")
                    Button {
                        guard !store.isPreparingDiagnostics else { return }
                        shareRecentWhenReady = true
                        store.prepareDiagnostics()
                    } label: {
                        Label("分享近期问题报告", systemImage: "square.and.arrow.up")
                    }.buttonStyle(RecordPrimaryButtonStyle()).disabled(store.isPreparingDiagnostics)
                        .accessibilityIdentifier("diagnostics-generate-recent")
                    Text("不含音频、转写正文、位置、账号或凭据。不发起同步，也不重新校验录音。")
                        .font(.caption).foregroundStyle(RecordDesign.secondary)
                        .accessibilityIdentifier("diagnostics-privacy")
                    Text("只附已保存的手表状态；缺失或过时会注明，无需连接手表或运行录音校验。")
                        .font(.caption).foregroundStyle(RecordDesign.secondary)
                        .accessibilityIdentifier("diagnostics-watch-scope")
                    if store.isPreparingDiagnostics {
                        ProgressView(store.diagnosticPreparationIncludesFullHistory
                            ? "正在准备完整历史问题报告…" : "正在准备近期问题报告…").font(.subheadline)
                            .accessibilityIdentifier("diagnostics-preparing")
                    }
                    if let issueID = store.diagnosticIssueID {
                        Text("问题编号：\(issueID)")
                            .font(.caption.monospaced()).foregroundStyle(RecordDesign.secondary)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("diagnostics-issue-id")
                    }
                    if let summary = store.diagnosticExportSummary {
                        Text(summary).font(.caption).foregroundStyle(RecordDesign.secondary)
                            .accessibilityIdentifier("diagnostics-export-summary")
                    }
                    if let timing = store.diagnosticTimingSummary {
                        Text(timing).font(.caption).foregroundStyle(RecordDesign.secondary)
                            .accessibilityIdentifier("diagnostics-timing")
                    }
                    if let error = store.diagnosticExportError {
                        Text(error).font(.caption).foregroundStyle(RecordDesign.secondary)
                            .accessibilityIdentifier("diagnostics-export-error")
                    }
                    if let url = store.exportURL {
                        Button {
                            shareFile = RecordDiagnosticShareFile(url: url, issueID: store.diagnosticIssueID)
                        } label: {
                            Label(store.diagnosticPreparationIncludesFullHistory
                                ? "分享完整历史问题报告" : "再次分享此报告", systemImage: "square.and.arrow.up")
                        }.buttonStyle(RecordSecondaryButtonStyle())
                            .accessibilityIdentifier("diagnostics-share-prepared")
                    }
                    Text("打开分享面板后，由你选择接收方；取消不会发送。打开面板不代表报告已发送。")
                        .font(.caption).foregroundStyle(RecordDesign.secondary)
                        .accessibilityIdentifier("diagnostics-share-guidance")
                }.fixedSize(horizontal: false, vertical: true).recordCard().recordRow()
            }
            Section {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("按需读取更多历史；仍有数量、大小和时间上限，受限时会注明，可能较慢。报告仍会脱敏，不含音频或转写正文。")
                            .font(.caption).foregroundStyle(RecordDesign.secondary)
                        Button {
                            shareRecentWhenReady = false
                            store.prepareDiagnostics(includeFullHistory: true)
                        } label: {
                            Label("生成完整历史问题报告", systemImage: "clock.arrow.circlepath")
                        }.buttonStyle(RecordSecondaryButtonStyle()).disabled(store.isPreparingDiagnostics)
                            .accessibilityIdentifier("diagnostics-generate-full-history")
                    }.padding(.top, 12)
                } label: {
                    Text("需要更多历史时").font(.subheadline)
                        .accessibilityIdentifier("diagnostics-history-options")
                }
                .recordCard().recordRow()
            }
            if let drive = store.personalLibrary?.drive {
                GoogleDriveTransportFaultView(drive: drive)
            }
            #if DEBUG
            if let drive = store.personalLibrary?.drive {
                GoogleDriveTLSProbeView(drive: drive)
            }
            #endif
            if let error = store.connection.lastError {
                Section {
                    RecordNotice(error, symbol: "exclamationmark.circle").recordCard().recordRow()
                } header: { RecordSectionHeading("最近通信提示") }
            }
            if let error = store.storageError {
                Section {
                    RecordNotice(error, symbol: "exclamationmark.triangle", isError: true).recordCard().recordRow()
                } header: { RecordSectionHeading("存储提示") }
            }
            Section {
                ForEach(store.events) { event in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(event.timestamp.formatted(date: .abbreviated, time: .standard))
                            .font(.caption).monospacedDigit().foregroundStyle(RecordDesign.secondary)
                        Text(event.detail).font(.subheadline)
                        if let start = event.intervalStart {
                            Text("区间：\(start.formatted(date: .abbreviated, time: .standard)) — \(event.intervalEnd?.formatted(date: .abbreviated, time: .standard) ?? "结束待确认")")
                                .font(.caption)
                        }
                        Text(event.kind).font(.caption.monospaced()).foregroundStyle(RecordDesign.secondary)
                    }.fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        .recordCard().recordRow()
                }
                if store.events.isEmpty {
                    Text("尚无日志").font(.subheadline).foregroundStyle(RecordDesign.secondary)
                        .recordCard().recordRow()
                }
            } header: { RecordSectionHeading("近期录音与同步事件", detail: store.eventHistorySummary) }
        }
        .recordListAppearance()
        .navigationTitle("日志与诊断")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: store.exportURL) { _, url in
            guard shareRecentWhenReady, let url,
                  !store.diagnosticPreparationIncludesFullHistory,
                  let issueID = store.diagnosticIssueID else { return }
            shareRecentWhenReady = false
            shareFile = RecordDiagnosticShareFile(url: url, issueID: issueID)
        }
        .onChange(of: store.diagnosticExportError) { _, error in
            if error != nil { shareRecentWhenReady = false }
        }
        .onDisappear { shareRecentWhenReady = false }
        .sheet(item: $shareFile) { file in
            RecordDiagnosticActivityView(url: file.url,
                accessibilityIdentifier: "diagnostics-share-sheet",
                onPresented: {
                    guard let issueID = file.issueID, store.diagnosticIssueID == issueID else { return }
                    store.diagnosticSharePresented()
                }, onCompleted: { completed in
                    guard let issueID = file.issueID, store.diagnosticIssueID == issueID else { return }
                    store.diagnosticShareCompleted(completed: completed)
                })
        }
    }
}

/// A local report is prepared only after this explicit tap. Presenting the
/// system share sheet does not choose a recipient or send anything itself.
private struct GoogleDriveTransportFaultView: View {
    @ObservedObject var drive: GoogleDriveLibrary
    @State private var shareFile: RecordDiagnosticShareFile?

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                Text("Google 连接故障日志").font(.headline)
                Text(drive.transportFaultCount == 0
                     ? "尚无故障记录。发生网络报错时会自动保存，普通成功不会覆盖已保存的故障。"
                     : "已保留 \(drive.transportFaultCount) 份故障记录。")
                    .font(.subheadline).foregroundStyle(RecordDesign.secondary)
                if let latest = drive.latestTransportFaultAt {
                    Text("最近故障：\(latest.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption).monospacedDigit().foregroundStyle(RecordDesign.secondary)
                }
                Text(drive.transportFaultSummary).font(.subheadline)
                    .accessibilityIdentifier("google-drive-fault-status")
                Button {
                    if let url = drive.prepareTransportFaultShare() {
                        shareFile = RecordDiagnosticShareFile(url: url)
                    }
                } label: {
                    Label("分享故障报告", systemImage: "square.and.arrow.up")
                }.buttonStyle(RecordSecondaryButtonStyle())
                    .disabled(drive.transportFaultCount == 0)
                    .accessibilityIdentifier("google-drive-share-fault-log")
                if let error = drive.transportFaultExportError {
                    Text(error).font(.subheadline).foregroundStyle(RecordDesign.secondary)
                        .accessibilityIdentifier("google-drive-fault-export-error")
                }
                Text("只分享连接故障的 JSON 日志，包含错误代码、连接指标和恢复状态；不含录音、转写、账户或凭据。由你在系统分享面板选择接收方。")
                    .font(.caption).foregroundStyle(RecordDesign.secondary)
            }.fixedSize(horizontal: false, vertical: true).recordCard().recordRow()
        }
        .sheet(item: $shareFile) { file in
            RecordDiagnosticActivityView(url: file.url)
        }
    }
}

private struct RecordDiagnosticShareFile: Identifiable {
    let id = UUID()
    let url: URL
    var issueID: String? = nil
}

private struct RecordDiagnosticActivityView: UIViewControllerRepresentable {
    let url: URL
    var accessibilityIdentifier = "google-drive-fault-share-sheet"
    var onPresented: (() -> Void)?
    var onCompleted: ((Bool) -> Void)?

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = RecordDiagnosticActivityController(activityItems: [url], applicationActivities: nil)
        controller.onFirstPresentation = onPresented
        controller.completionWithItemsHandler = { _, completed, _, error in
            Task { @MainActor in onCompleted?(completed && error == nil) }
        }
        controller.view.accessibilityIdentifier = accessibilityIdentifier
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

private final class RecordDiagnosticActivityController: UIActivityViewController {
    var onFirstPresentation: (() -> Void)?

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let callback = onFirstPresentation
        onFirstPresentation = nil
        callback?()
    }
}

#if DEBUG
/// Explicit, read-only developer checks. No recording or upload operation is
/// started by entering this view, and controlled faults are labelled separately.
private struct GoogleDriveTLSProbeView: View {
    @ObservedObject var drive: GoogleDriveLibrary

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                Text("Google 连接验证").font(.headline)
                Text("只读取账户连接状态，并保存小型验证报告。")
                    .font(.subheadline).foregroundStyle(RecordDesign.secondary)
                Button("检查真实连接（只读）") {
                    drive.startDebugTLSProbe(controlledFault: false)
                }.buttonStyle(RecordSecondaryButtonStyle())
                    .disabled(drive.debugTLSProbeRunning || !drive.isConnected)
                Button("模拟一次断连并验证恢复") {
                    drive.startDebugTLSProbe(controlledFault: true)
                }.buttonStyle(RecordSecondaryButtonStyle())
                    .disabled(drive.debugTLSProbeRunning || !drive.isConnected)
                if drive.debugTLSProbeRunning {
                    ProgressView().frame(maxWidth: .infinity, alignment: .leading)
                    Button("取消验证") { drive.cancelDebugTLSProbe() }
                }
                Text(drive.debugTLSProbeStatus).font(.subheadline)
                    .accessibilityIdentifier("google-drive-tls-probe-status")
                Text("模拟模式仅验证恢复分支及后续真实 Google 请求，不能证明自然 TLS 故障已复现。")
                    .font(.caption).foregroundStyle(RecordDesign.secondary)
            }.fixedSize(horizontal: false, vertical: true).recordCard().recordRow()
        }
    }
}
#endif

private struct RecordSectionHeading: View {
    let title: String
    let detail: String?
    init(_ title: String, detail: String? = nil) { self.title = title; self.detail = detail }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.headline).foregroundStyle(RecordDesign.ink)
                Spacer(minLength: 0)
                if let detail { Text(detail).font(.caption).foregroundStyle(RecordDesign.secondary) }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline).foregroundStyle(RecordDesign.ink)
                if let detail { Text(detail).font(.caption).foregroundStyle(RecordDesign.secondary) }
            }
        }
        .textCase(nil).padding(.top, 22).padding(.bottom, 10)
        .accessibilityAddTraits(.isHeader)
    }
}

struct RecordMetadataRow: View {
    let title: String
    let value: String
    init(_ title: String, value: String) { self.title = title; self.value = value }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(title).foregroundStyle(RecordDesign.secondary)
                Spacer(minLength: 0)
                Text(value).multilineTextAlignment(.trailing)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).foregroundStyle(RecordDesign.secondary)
                Text(value)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

private struct RecordNotice: View {
    let text: String
    let symbol: String
    var isError = false

    init(_ text: String, symbol: String, isError: Bool = false) {
        self.text = text
        self.symbol = symbol
        self.isError = isError
    }

    var body: some View {
        Label {
            Text(text).foregroundStyle(isError ? RecordDesign.ink : RecordDesign.secondary)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(isError ? RecordDesign.accent : RecordDesign.secondary)
        }
        .font(.subheadline)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

private func phoneSessionTimeRange(_ summary: RecordingActivity.Day) -> String {
    guard let interval = summary.recordedInterval else { return "时段待更新" }
    let startTime = interval.start.formatted(date: .omitted, time: .shortened)
    let endTime = interval.end.formatted(date: .omitted, time: .shortened)
    if !Calendar.current.isDate(summary.date, inSameDayAs: interval.end) { return "\(startTime) — 次日 \(endTime)" }
    return summary.recordedDuration < 60 || startTime == endTime ? startTime : "\(startTime) — \(endTime)"
}

func phoneCompactDuration(_ duration: TimeInterval) -> String {
    let seconds = Int(max(0, duration.isFinite ? duration : 0))
    if seconds >= 3600 { return "\(seconds / 3600) 小时 \((seconds / 60) % 60) 分" }
    if seconds >= 60 { return "\(seconds / 60) 分 \(seconds % 60) 秒" }
    return "\(seconds) 秒"
}

private func phoneSpokenDuration(_ duration: TimeInterval) -> String {
    let seconds = Int(max(0, duration.isFinite ? duration : 0))
    return "\(seconds / 3600) 小时 \((seconds / 60) % 60) 分 \(seconds % 60) 秒"
}
