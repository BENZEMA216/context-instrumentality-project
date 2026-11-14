import Foundation
import RecordingCore

// Controlled BackgroundTasks and PhoneStore adapters. PhoneBackgroundSync itself
// is compiled unchanged except for its unavailable platform import.
class BGTask: @unchecked Sendable {
    let identifier: String
    var expirationHandler: (() -> Void)?
    private let results = Locked<[Bool]>([])
    init(identifier: String) { self.identifier = identifier }
    var completionResults: [Bool] { results.current }
    func setTaskCompleted(success: Bool) { results.access { $0.append(success) } }
}

final class BGProcessingTask: BGTask, @unchecked Sendable {}

class BGTaskRequest: @unchecked Sendable {
    let identifier: String
    var earliestBeginDate: Date?
    init(identifier: String) { self.identifier = identifier }
}

final class BGProcessingTaskRequest: BGTaskRequest, @unchecked Sendable {
    var requiresExternalPower = false
    var requiresNetworkConnectivity = false
}

final class BGTaskScheduler: @unchecked Sendable {
    static var shared = BGTaskScheduler()
    private struct PendingQuery {
        let requests: [BGTaskRequest]
        let completion: ([BGTaskRequest]) -> Void
    }
    private struct State {
        var handlers: [String: (BGTask) -> Void] = [:]
        var requests: [String: BGTaskRequest] = [:]
        var submissions = 0
        var cancellations: [String] = []
        var holdQueries = false
        var pendingQueries: [PendingQuery] = []
    }
    private let state = Locked(State())

    var pendingCount: Int { state.access { $0.requests.count } }
    var submissionCount: Int { state.access { $0.submissions } }
    var cancellationCount: Int { state.access { $0.cancellations.count } }
    var heldQueryCount: Int { state.access { $0.pendingQueries.count } }
    var holdPendingQueries: Bool {
        get { state.access { $0.holdQueries } }
        set { state.access { $0.holdQueries = newValue } }
    }

    func register(forTaskWithIdentifier identifier: String, using queue: DispatchQueue?,
                  launchHandler: @escaping (BGTask) -> Void) -> Bool {
        state.access { $0.handlers[identifier] = launchHandler }
        return true
    }

    func getPendingTaskRequests(completionHandler: @escaping ([BGTaskRequest]) -> Void) {
        let immediate = state.access { value -> [BGTaskRequest]? in
            let requests = Array(value.requests.values)
            if value.holdQueries {
                value.pendingQueries.append(PendingQuery(requests: requests, completion: completionHandler))
                return nil
            }
            return requests
        }
        if let immediate { completionHandler(immediate) }
    }

    func releasePendingQueries() {
        let waiting = state.access { value -> [PendingQuery] in
            value.holdQueries = false
            let result = value.pendingQueries
            value.pendingQueries = []
            return result
        }
        // Preserve the response captured when the asynchronous query began.
        waiting.forEach { $0.completion($0.requests) }
    }

    func submit(_ request: BGTaskRequest) throws {
        state.access {
            $0.requests[request.identifier] = request
            $0.submissions += 1
        }
    }

    func cancel(taskRequestWithIdentifier identifier: String) {
        state.access {
            $0.requests.removeValue(forKey: identifier)
            $0.cancellations.append(identifier)
        }
    }

    func launch() throws -> BGProcessingTask {
        let launch = try state.access { value -> (BGProcessingTask, (BGTask) -> Void) in
            guard let identifier = value.requests.keys.sorted().first,
                  let handler = value.handlers[identifier] else {
                throw ProbeFailure.failed("A controlled BG launch requires a registered pending request.")
            }
            value.requests.removeValue(forKey: identifier)
            return (BGProcessingTask(identifier: identifier), handler)
        }
        launch.1(launch.0)
        return launch.0
    }
}

@MainActor
final class PhoneStore {
    static let shared = PhoneStore()
    private var completions: [@Sendable (Bool, Bool) -> Void] = []
    private(set) var performCount = 0
    private(set) var expireCount = 0
    var heldCompletionCount: Int { completions.count }

    func reset() {
        completions = []
        performCount = 0
        expireCount = 0
    }

    func performBackgroundSync(cancellation: PhoneBackgroundCancellation,
                               completion: @escaping @Sendable (Bool, Bool) -> Void) {
        performCount += 1
        completions.append(completion)
    }

    func expireBackgroundSync() { expireCount += 1 }

    func completeNext(success: Bool, needsMore: Bool) throws {
        guard !completions.isEmpty else {
            throw ProbeFailure.failed("No controlled PhoneStore maintenance completion is waiting.")
        }
        completions.removeFirst()(success, needsMore)
    }
}

extension Probe {
    private func startScheduler(_ fixture: Fixture) async throws
        -> (PhoneBackgroundSync, BGTaskScheduler, BGProcessingTask) {
        let scheduler = BGTaskScheduler()
        BGTaskScheduler.shared = scheduler
        PhoneStore.shared.reset()
        let coordinator = PhoneBackgroundSync()
        coordinator.register()
        let requests = fixture.maintenanceRequests
        fixture.connectivity.onNeedsBackgroundMaintenance = {
            requests.access { $0 += 1 }
            Task { @MainActor in coordinator.schedule() }
        }
        coordinator.schedule()
        try await eventually("controlled scheduler receives its first request") { scheduler.pendingCount == 1 }
        let task = try scheduler.launch()
        try await eventually("production BG handler is waiting for PhoneStore") {
            PhoneStore.shared.heldCompletionCount == 1
        }
        try check(scheduler.pendingCount == 1 && scheduler.submissionCount == 2,
                  "The real BG handler must synchronously install its fallback before maintenance.")
        return (coordinator, scheduler, task)
    }

    private func schedulerSnapshot(_ fixture: Fixture, pendingCount: Int, at date: Date) throws {
        let snapshot = RecorderSnapshot(state: .recording, sessionID: fixture.recordingSession.id,
            observedAt: date, lastAudioAt: date, pendingCount: pendingCount, pendingCountIsKnown: true)
        fixture.connectivity.session(fixture.session, didReceiveApplicationContext: [
            TransportCodec.snapshotKey: try TransportCodec.encode(snapshot)
        ])
        let received = fixture.connectivity.currentState().snapshot
        try check(received?.pendingCount == pendingCount,
                  "The production receiver must accept the test's Watch snapshot before completion fires.")
    }

    func runSchedulerScenarios() async {
        await run("scheduler_empty_completion_cancels_after_routine_schedule") { f in
            let (coordinator, scheduler, task) = try await self.startScheduler(f)
            defer { f.connectivity.onNeedsBackgroundMaintenance = nil }
            // Ordinary replay/fallback scheduling is not new work and must not
            // make every successful maintenance pass invalidate itself.
            scheduler.holdPendingQueries = true
            coordinator.schedule()
            try self.check(scheduler.heldQueryCount == 1, "Routine scheduling must reach the controlled query.")
            scheduler.releasePendingQueries()
            try PhoneStore.shared.completeNext(success: true, needsMore: false)
            try await self.eventually("empty BG task completes") { task.completionResults == [true] }
            try self.check(scheduler.cancellationCount == 1 && scheduler.pendingCount == 0,
                           "An unchanged, successful empty pass must cancel its fallback rather than loop.")
        }

        await run("scheduler_late_positive_survives_old_completion_then_known_zero_can_cancel") { f in
            let (_, scheduler, task) = try await self.startScheduler(f)
            defer { f.connectivity.onNeedsBackgroundMaintenance = nil }
            let observedAt = Date()
            try self.schedulerSnapshot(f, pendingCount: 3, at: observedAt)
            try PhoneStore.shared.completeNext(success: true, needsMore: false)
            try await self.eventually("old empty BG completion arrives after new Watch work") {
                task.completionResults == [true]
            }
            try self.check(scheduler.cancellationCount == 0 && scheduler.pendingCount == 1,
                           "An old empty completion must not cancel the fallback after a newly accepted positive Watch snapshot.")

            try self.schedulerSnapshot(f, pendingCount: 0, at: observedAt.addingTimeInterval(1))
            let next = try scheduler.launch()
            try await self.eventually("next BG round holds its own completion") {
                PhoneStore.shared.performCount == 2 && PhoneStore.shared.heldCompletionCount == 1
            }
            try PhoneStore.shared.completeNext(success: true, needsMore: false)
            try await self.eventually("fresh empty completion after known zero") { next.completionResults == [true] }
            try self.check(scheduler.cancellationCount == 1 && scheduler.pendingCount == 0,
                           "After newer verified zero clears the backlog, a new empty pass must be able to cancel again.")
        }

        await run("scheduler_positive_during_pending_request_query_blocks_old_cancel") { f in
            let (coordinator, scheduler, task) = try await self.startScheduler(f)
            defer { f.connectivity.onNeedsBackgroundMaintenance = nil }
            scheduler.holdPendingQueries = true
            coordinator.schedule()
            try self.check(scheduler.heldQueryCount == 1, "Pending-request inspection must still be in flight.")
            try self.schedulerSnapshot(f, pendingCount: 2, at: Date())
            try PhoneStore.shared.completeNext(success: true, needsMore: false)
            try await self.eventually("old completion arrives before the scheduler query returns") {
                task.completionResults == [true]
            }
            try self.check(scheduler.cancellationCount == 0 && scheduler.pendingCount == 1,
                           "New Watch work must protect fallback even before getPendingTaskRequests completes.")
            scheduler.releasePendingQueries()
        }

        await run("scheduler_new_inbox_item_blocks_old_empty_completion") { f in
            let (_, scheduler, task) = try await self.startScheduler(f)
            defer { f.connectivity.onNeedsBackgroundMaintenance = nil }
            f.lease.state.access { $0.hold = true }
            defer { f.lease.release() }
            let manifest = try f.seal(300)
            try f.deliver(manifest)
            _ = f.connectivity.currentState()
            let pending = try f.inbox.pendingIDs()
            try self.check(pending.count == 1,
                           "The real callback must durably stage one new synthetic inbox item.")
            try self.check(try f.inbox.load(id: pending[0]).manifest == manifest,
                           "The staged transfer must retain the new recording's complete manifest.")
            try PhoneStore.shared.completeNext(success: true, needsMore: false)
            try await self.eventually("old completion arrives after a new durable inbox item") {
                task.completionResults == [true]
            }
            try self.check(scheduler.cancellationCount == 0 && scheduler.pendingCount == 1,
                           "A newly staged inbox item must invalidate the old empty result before cancellation.")
            f.lease.release()
            try await self.eventually("new synthetic inbox item finishes its controlled worker") {
                f.session.receipts.contains { $0.segmentID == manifest.id }
            }
        }

        await run("scheduler_late_targeted_request_blocks_old_empty_completion") { f in
            let (_, scheduler, task) = try await self.startScheduler(f)
            defer { f.connectivity.onNeedsBackgroundMaintenance = nil }
            let manifest = try f.seal(301)
            _ = try f.phone.acceptIncomingFile(at: f.watch.audioURL(for: manifest), manifest: manifest)
            let request = try TargetedReceiptRequest(manifest: manifest)
            f.lease.state.access { $0.hold = true }
            defer { f.lease.release() }
            f.connectivity.session(f.session, didReceiveUserInfo: [
                TransportCodec.targetedReceiptRequestKey: try TransportCodec.encode(request)
            ])
            _ = f.connectivity.currentState()
            try await self.eventually("new targeted request is waiting for its lease") { f.lease.beginCount == 1 }
            let pendingURL = f.phone.root.appendingPathComponent("targeted-receipt-pending.json")
            let pending = try TransportCodec.decode([TargetedReceiptRequest].self,
                from: Data(contentsOf: pendingURL))
            try self.check(pending == [request] && f.session.receipts.isEmpty,
                           "The real receiver must persist the late targeted request before its worker can finish.")
            try PhoneStore.shared.completeNext(success: true, needsMore: false)
            try await self.eventually("old empty BG completion arrives after a targeted request") {
                task.completionResults == [true]
            }
            try self.check(scheduler.cancellationCount == 0 && scheduler.pendingCount == 1,
                           "A newly accepted targeted receipt request must protect fallback from an older empty result.")
            f.lease.release()
            try await self.eventually("late targeted request finishes its controlled worker") {
                f.session.receipts.contains { $0.segmentID == manifest.id }
            }
        }

        await run("scheduler_late_legacy_request_blocks_old_empty_completion") { f in
            let (_, scheduler, task) = try await self.startScheduler(f)
            defer { f.connectivity.onNeedsBackgroundMaintenance = nil }
            let manifest = try f.seal(302)
            _ = try f.phone.acceptIncomingFile(at: f.watch.audioURL(for: manifest), manifest: manifest)
            f.lease.state.access { $0.hold = true }
            defer { f.lease.release() }
            f.connectivity.session(f.session, didReceiveUserInfo: [TransportCodec.requestSyncKey: true])
            _ = f.connectivity.currentState()
            try await self.eventually("new external legacy request is waiting for its lease") {
                f.lease.beginCount == 1
            }
            try self.check(f.session.receipts.isEmpty,
                           "The controlled lease must hold the new external receipt sweep unfinished.")
            try PhoneStore.shared.completeNext(success: true, needsMore: false)
            try await self.eventually("old empty BG completion arrives after an external legacy request") {
                task.completionResults == [true]
            }
            try self.check(scheduler.cancellationCount == 0 && scheduler.pendingCount == 1,
                           "A valid external legacy sync request must protect fallback from an older empty result.")
            f.lease.release()
            try await self.eventually("late external legacy request finishes its controlled worker") {
                f.session.receipts.contains { $0.segmentID == manifest.id }
            }
        }

        await run("scheduler_failed_completion_preserves_fallback") { f in
            let (_, scheduler, task) = try await self.startScheduler(f)
            defer { f.connectivity.onNeedsBackgroundMaintenance = nil }
            try PhoneStore.shared.completeNext(success: false, needsMore: false)
            try await self.eventually("failed BG completion") { task.completionResults == [false] }
            try self.check(scheduler.cancellationCount == 0 && scheduler.pendingCount == 1,
                           "A failed maintenance result cannot remove its retry request.")
        }

        await run("scheduler_remaining_work_preserves_fallback") { f in
            let (_, scheduler, task) = try await self.startScheduler(f)
            defer { f.connectivity.onNeedsBackgroundMaintenance = nil }
            try PhoneStore.shared.completeNext(success: true, needsMore: true)
            try await self.eventually("successful BG completion still has work") { task.completionResults == [true] }
            try self.check(scheduler.cancellationCount == 0 && scheduler.pendingCount == 1,
                           "Successful maintenance with remaining work must retain the fallback.")
        }

        await run("scheduler_expiration_preserves_fallback_and_completes_once") { f in
            let (_, scheduler, task) = try await self.startScheduler(f)
            defer { f.connectivity.onNeedsBackgroundMaintenance = nil }
            task.expirationHandler?()
            try await self.eventually("expiration reaches the production completion and store") {
                task.completionResults == [false] && PhoneStore.shared.expireCount == 1
            }
            try PhoneStore.shared.completeNext(success: true, needsMore: false)
            // Let the already queued main-actor completion run after expiration.
            try await Task.sleep(nanoseconds: 20_000_000)
            try self.check(task.completionResults == [false], "An expired task may complete only once.")
            try self.check(scheduler.cancellationCount == 0 && scheduler.pendingCount == 1,
                           "A late successful callback from cancelled work must preserve the fallback.")
        }
    }
}
