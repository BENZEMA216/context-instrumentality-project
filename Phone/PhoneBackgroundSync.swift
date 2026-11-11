import BackgroundTasks
import Foundation

/// WatchConnectivity remains the transport. BGProcessing only resumes local
/// inbox/receipt work when iOS chooses to grant execution time.
@MainActor
final class PhoneBackgroundSync {
    static let shared = PhoneBackgroundSync()
    private nonisolated static let workGeneration = PhoneBackgroundWorkGeneration()
    private let identifier = (Bundle.main.bundleIdentifier ?? "dev.benzema.WristRecord") + ".recording-sync"
    private var registered = false
    private var lastScheduledAt: TimeInterval?
    private var scheduleCheckInFlight = false
    private var requestedEarliestDate: Date?
    private var diagnosticHandler: (@Sendable (String, String) -> Void)?
    private var pendingDiagnostics: [(kind: String, detail: String)] = []
    private var lastDiagnostics: [String: (signature: String, uptime: TimeInterval)] = [:]

    /// Called synchronously when the receiver accepts new work, before dispatching
    /// its scheduling callback. Ordinary fallback scheduling is not new work.
    nonisolated static func noteNewWork() { workGeneration.advance() }

    private nonisolated static var currentWorkGeneration: UInt64 { workGeneration.current }

    /// AppDelegate registers before PhoneStore is constructed. Buffer only a few
    /// metadata events, then connect the logger after the repository is ready;
    /// diagnostics must never initialize PhoneStore.shared recursively.
    func setDiagnosticHandler(_ handler: @escaping @Sendable (String, String) -> Void) {
        diagnosticHandler = handler
        let waiting = pendingDiagnostics
        pendingDiagnostics.removeAll(keepingCapacity: true)
        waiting.forEach { handler($0.kind, $0.detail) }
    }

    func register() {
        guard !registered else { return }
        registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let processing = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in self.handle(processing) }
        }
        // register() exposes Bool, not NSError. Preserve that exact result
        // rather than assigning a fabricated scheduler error code.
        recordDiagnostic(kind: "phone.bg_register",
            detail: "identifier=\(identifier) registered=\(registered)"
                + (registered ? "" : " error_domain=not_provided_by_api error_code=not_provided_by_api"))
    }

    func schedule(earliestBeginDate: Date? = nil) {
        guard registered else { return }
        let requested = earliestBeginDate ?? Date(timeIntervalSinceNow: 15 * 60)
        requestedEarliestDate = min(requestedEarliestDate ?? requested, requested)
        // Repeated file callbacks should not keep moving an existing request's
        // earliest date forward. The scheduler keeps one request for this ID.
        guard !scheduleCheckInFlight else { return }
        scheduleCheckInFlight = true
        BGTaskScheduler.shared.getPendingTaskRequests { [weak self] requests in
            Task { @MainActor in
                guard let self else { return }
                self.scheduleCheckInFlight = false
                guard let requested = self.requestedEarliestDate else { return }
                self.requestedEarliestDate = nil
                if let existing = requests.first(where: { $0.identifier == self.identifier }),
                   (existing.earliestBeginDate ?? .distantPast) <= requested {
                    self.recordDiagnostic(kind: "phone.bg_request_pending",
                        detail: "identifier=\(self.identifier) earliest_begin_at=\(self.timestamp(existing.earliestBeginDate))")
                    return
                }
                self.submitRequest(earliestBeginDate: requested)
            }
        }
    }

    private func submitRequest(earliestBeginDate: Date = Date(timeIntervalSinceNow: 15 * 60)) {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.earliestBeginDate = earliestBeginDate
        request.requiresExternalPower = false
        request.requiresNetworkConnectivity = false
        do {
            try BGTaskScheduler.shared.submit(request)
            lastScheduledAt = ProcessInfo.processInfo.systemUptime
            recordDiagnostic(kind: "phone.bg_submit",
                detail: "identifier=\(identifier) submitted_at=\(timestamp(Date()))"
                    + " earliest_begin_at=\(timestamp(request.earliestBeginDate))"
                    + " requires_external_power=\(request.requiresExternalPower)"
                    + " requires_network_connectivity=\(request.requiresNetworkConnectivity)")
        } catch {
            // No data or receipt is removed if scheduling is unavailable.
            // The next WC callback, foreground or background transition retries.
            lastScheduledAt = nil
            let value = error as NSError
            recordDiagnostic(kind: "phone.bg_submit_failed",
                detail: "identifier=\(identifier) error_domain=\(value.domain) error_code=\(value.code)")
        }
    }

    private func handle(_ task: BGProcessingTask) {
        recordDiagnostic(kind: "phone.bg_task_started", detail: "identifier=\(task.identifier)")
        lastScheduledAt = nil
        // This request has been consumed. Submit the fallback synchronously now,
        // before any file work or expiration can release our execution time.
        submitRequest()
        let completion = PhoneBackgroundTaskCompletion(task: task)
        let cancellation = PhoneBackgroundCancellation()
        task.expirationHandler = {
            // Visible to the next worker step immediately, even while one file is
            // inside an atomic commit. Never wait for the worker on this queue.
            cancellation.cancel()
            Task { @MainActor in PhoneStore.shared.expireBackgroundSync() }
            completion.finish(success: false)
        }
        let generation = Self.currentWorkGeneration
        PhoneStore.shared.performBackgroundSync(cancellation: cancellation) { success, needsMore in
            Task { @MainActor in
                if success && !needsMore && !cancellation.isCancelled {
                    // Successful maintenance with no remaining inbox, receipt
                    // sweep or Watch backlog must not create an empty wake loop.
                    // Keep the comparison and synchronous cancellation atomic
                    // with receiver callbacks that can arrive off the main actor.
                    Self.workGeneration.ifUnchanged(generation) {
                        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: self.identifier)
                        self.lastScheduledAt = nil
                    }
                }
                completion.finish(success: success)
            }
        }
    }

    private func recordDiagnostic(kind: String, detail: String) {
        let detail = String(detail.prefix(768))
        let now = ProcessInfo.processInfo.systemUptime
        if let previous = lastDiagnostics[kind],
           previous.signature == detail, now - previous.uptime < 60 { return }
        lastDiagnostics[kind] = (detail, now)
        if let diagnosticHandler {
            diagnosticHandler(kind, detail)
        } else {
            if pendingDiagnostics.count == 8 { pendingDiagnostics.removeFirst() }
            pendingDiagnostics.append((kind, detail))
        }
    }

    private func timestamp(_ date: Date?) -> String {
        guard let date else { return "nil" }
        return ISO8601DateFormatter().string(from: date)
    }
}

/// Shared across coordinator instances because all of them schedule the same
/// request identifier. The lock is held only for a counter operation or the
/// short synchronous scheduler cancellation, never for file or async work.
private final class PhoneBackgroundWorkGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    var current: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    func advance() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }

    func ifUnchanged(_ expected: UInt64, _ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard generation == expected else { return }
        body()
    }
}

private final class PhoneBackgroundTaskCompletion: @unchecked Sendable {
    private let task: BGTask
    private let lock = NSLock()
    private var completed = false

    init(task: BGTask) { self.task = task }

    func finish(success: Bool) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        lock.unlock()
        task.setTaskCompleted(success: success)
    }
}
