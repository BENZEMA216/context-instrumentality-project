import SwiftUI
import UIKit
import UserNotifications

@MainActor
final class RecordingReminderStore: ObservableObject {
    static let shared = RecordingReminderStore()
    private static let identifier = "record-for-agent.daily-recording-reminder"
    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard
    @Published private(set) var isEnabled: Bool
    @Published private(set) var time: Date
    @Published private(set) var isUpdating = false
    @Published private(set) var message: String?
    @Published private(set) var authorizationDenied = false

    private init() {
        isEnabled = defaults.bool(forKey: "recordingReminder.enabled")
        let hour = defaults.object(forKey: "recordingReminder.hour") as? Int ?? 9
        let minute = defaults.object(forKey: "recordingReminder.minute") as? Int ?? 0
        time = Calendar.current.date(bySettingHour: min(23, max(0, hour)),
                                     minute: min(59, max(0, minute)), second: 0, of: Date()) ?? Date()
    }

    func refresh() async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        let settings = await center.notificationSettings()
        authorizationDenied = settings.authorizationStatus == .denied
        let requests = await center.pendingNotificationRequests()
        let scheduled = requests.first { $0.identifier == Self.identifier }
        isEnabled = Self.permitted(settings.authorizationStatus)
            && scheduled != nil
        if let trigger = scheduled?.trigger as? UNCalendarNotificationTrigger,
           let hour = trigger.dateComponents.hour, let minute = trigger.dateComponents.minute,
           let scheduledTime = Calendar.current.date(bySettingHour: hour, minute: minute,
                                                     second: 0, of: Date()) {
            saveTime(scheduledTime)
        }
        defaults.set(isEnabled, forKey: "recordingReminder.enabled")
        message = authorizationDenied ? "通知已关闭，可在系统设置中开启。" : nil
    }

    /// Called only by the reminder controls, never by launch or background work.
    func setEnabled(_ enabled: Bool, at selectedTime: Date) async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        message = nil
        if !enabled {
            center.removePendingNotificationRequests(withIdentifiers: [Self.identifier])
            center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
            isEnabled = false
            defaults.set(false, forKey: "recordingReminder.enabled")
            return
        }
        do {
            var settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
                settings = await center.notificationSettings()
            }
            authorizationDenied = settings.authorizationStatus == .denied
            guard Self.permitted(settings.authorizationStatus) else {
                isEnabled = false
                defaults.set(false, forKey: "recordingReminder.enabled")
                message = "请先在系统设置中允许通知。"
                return
            }
            try await schedule(at: selectedTime)
            isEnabled = true
            saveTime(selectedTime)
            defaults.set(true, forKey: "recordingReminder.enabled")
        } catch {
            // A failed replacement leaves any existing reminder in place.
            let requests = await center.pendingNotificationRequests()
            isEnabled = requests.contains { $0.identifier == Self.identifier }
            defaults.set(isEnabled, forKey: "recordingReminder.enabled")
            message = "提醒未能保存，请重试。"
        }
    }

    func updateTime(_ selectedTime: Date) async {
        if isEnabled {
            await setEnabled(true, at: selectedTime)
        } else if !isUpdating {
            saveTime(selectedTime)
            message = nil
        }
    }

    private func schedule(at selectedTime: Date) async throws {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: selectedTime)
        let content = UNMutableNotificationContent()
        content.title = "开始今天的录音"
        content.body = "准备好后，在手表上开始录音。"
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: true)
        try await center.add(UNNotificationRequest(identifier: Self.identifier,
                                                  content: content, trigger: trigger))
    }

    private func saveTime(_ selectedTime: Date) {
        time = selectedTime
        let parts = Calendar.current.dateComponents([.hour, .minute], from: selectedTime)
        defaults.set(parts.hour ?? 9, forKey: "recordingReminder.hour")
        defaults.set(parts.minute ?? 0, forKey: "recordingReminder.minute")
    }

    private static func permitted(_ status: UNAuthorizationStatus) -> Bool {
        status == .authorized || status == .provisional || status == .ephemeral
    }
}

struct RecordingReminderView: View {
    @ObservedObject private var reminders = RecordingReminderStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTime = RecordingReminderStore.shared.time

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("每日提醒", isOn: Binding(get: { reminders.isEnabled }, set: { enabled in
                        Task { await reminders.setEnabled(enabled, at: selectedTime) }
                    }))
                    .tint(RecordDesign.good)
                    .accessibilityIdentifier("daily-reminder-toggle")
                    DatePicker("时间", selection: $selectedTime, displayedComponents: .hourAndMinute)
                        .accessibilityIdentifier("daily-reminder-time")
                    Button("保存时间") {
                        Task { await reminders.updateTime(selectedTime) }
                    }
                    .disabled(sameMinute(selectedTime, reminders.time))
                } footer: {
                    Text("每天提醒你在手表开始录音。")
                }
                if let message = reminders.message {
                    Section {
                        Text(message).font(.subheadline)
                        if reminders.authorizationDenied {
                            Button("前往系统设置") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                            }
                        }
                    }
                }
            }
            .disabled(reminders.isUpdating)
            .scrollContentBackground(.hidden)
            .background(RecordDesign.background)
            .tint(RecordDesign.ink)
            .navigationTitle("录音提醒")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .task { await reminders.refresh() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await reminders.refresh() } }
            }
            .onChange(of: reminders.time) { _, time in selectedTime = time }
        }
    }

    private func sameMinute(_ left: Date, _ right: Date) -> Bool {
        Calendar.current.dateComponents([.hour, .minute], from: left)
            == Calendar.current.dateComponents([.hour, .minute], from: right)
    }
}
