import Foundation
import RecordingCore

// Controlled adapters only; the repository, inbox, cancellation and complete
// PhoneConnectivity worker execute production code against synthetic disk data.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func access<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body(&value)
    }
    var current: Value { access { $0 } }
}

enum WCSessionActivationState: Int { case activated = 2, inactive = 1, notActivated = 0 }
protocol WCSessionDelegate: AnyObject {}
final class WCSessionFile {
    let fileURL: URL
    let metadata: [String: Any]?
    init(fileURL: URL, metadata: [String: Any]?) { self.fileURL = fileURL; self.metadata = metadata }
}
final class WCSessionUserInfoTransfer {
    let userInfo: [String: Any]
    private(set) var cancelCount = 0
    var onCancel: (() -> Void)?
    init(_ userInfo: [String: Any]) { self.userInfo = userInfo }
    func cancel() { cancelCount += 1; onCancel?() }
}
final class WCSession: @unchecked Sendable {
    static var `default` = WCSession()
    static func isSupported() -> Bool { true }
    weak var delegate: WCSessionDelegate?
    var activationState = WCSessionActivationState.activated
    var isPaired = true
    var isWatchAppInstalled = true
    var isReachable = false
    var hasContentPending = false
    let activationCalls = Locked(0)
    var receivedApplicationContext: [String: Any] = [:]
    private let transfers = Locked<[WCSessionUserInfoTransfer]>([])
    let sentMessages = Locked<[[String: Any]]>([])
    let updatedContexts = Locked<[[String: Any]]>([])
    let contextAttemptPayloads = Locked<[[String: Any]]>([])
    var contextError: Error?
    var messageHandler: (([String: Any], (([String: Any]) -> Void)?, ((Error) -> Void)?) -> Void)?
    var onReceipt: (@Sendable (SegmentReceipt) -> Void)?
    var outstandingUserInfoTransfers: [WCSessionUserInfoTransfer] { transfers.current }
    var receipts: [SegmentReceipt] {
        transfers.current.compactMap {
            guard let data = $0.userInfo[TransportCodec.receiptKey] as? Data else { return nil }
            return try? TransportCodec.decode(SegmentReceipt.self, from: data)
        }
    }
    func removeReceiptTransfer() -> WCSessionUserInfoTransfer? {
        transfers.access { values in
            guard let index = values.firstIndex(where: { $0.userInfo[TransportCodec.receiptKey] is Data }) else { return nil }
            return values.remove(at: index)
        }
    }
    func removeControlTransfer() -> WCSessionUserInfoTransfer? {
        transfers.access { values in
            guard let index = values.firstIndex(where: { $0.userInfo[TransportCodec.requestSyncKey] as? Bool == true }) else { return nil }
            return values.remove(at: index)
        }
    }
    func activate() { activationCalls.access { $0 += 1 } }
    func updateApplicationContext(_ payload: [String: Any]) throws {
        contextAttemptPayloads.access { $0.append(payload) }
        if let contextError { throw contextError }
        updatedContexts.access { $0.append(payload) }
    }
    @discardableResult func transferUserInfo(_ payload: [String: Any]) -> WCSessionUserInfoTransfer {
        let transfer = WCSessionUserInfoTransfer(payload)
        transfers.access { $0.append(transfer) }
        if let data = payload[TransportCodec.receiptKey] as? Data,
           let receipt = try? TransportCodec.decode(SegmentReceipt.self, from: data) {
            onReceipt?(receipt)
        }
        return transfer
    }
    func sendMessage(_ payload: [String: Any], replyHandler: (([String: Any]) -> Void)?,
                     errorHandler: ((Error) -> Void)?) {
        sentMessages.access { $0.append(payload) }
        if let messageHandler { messageHandler(payload, replyHandler, errorHandler) }
        else { replyHandler?(["requestReceived": true]) }
    }
}

final class LeaseController: @unchecked Sendable {
    struct State {
        var hold = false
        var incomingBypassesHold = false
        var steps = Int.max
        var pending: [@Sendable () -> Void] = []
        var begins = 0
    }
    let state = Locked(State())
    var beginCount: Int { state.current.begins }
    func release() {
        let pending = state.access { value -> [@Sendable () -> Void] in
            value.hold = false
            let result = value.pending
            value.pending = []
            return result
        }
        pending.forEach { $0() }
    }
}
// Platform assertion adapter; import leases below remain independently held.
final class PhoneIncomingCallbackLease: @unchecked Sendable {
    static let outstanding = Locked(0)
    private let ended = Locked(false)
    static func begin() -> PhoneIncomingCallbackLease {
        outstanding.access { $0 += 1 }
        return PhoneIncomingCallbackLease()
    }
    func end() {
        let changed = ended.access { value -> Bool in
            guard !value else { return false }; value = true; return true
        }
        if changed { Self.outstanding.access { $0 -= 1 } }
    }
    deinit { end() }
}
final class PhoneBackgroundLease: @unchecked Sendable {
    static var controller = LeaseController()
    private let remaining: Locked<Int>
    init(steps: Int) { remaining = Locked(steps) }
    static func begin(name: String, systemGranted: Bool = false, incomingCallback: Bool = false,
                      diagnostic: (@Sendable (String) -> Void)? = nil,
                      completion: @escaping @Sendable (PhoneBackgroundLease) -> Void) {
        let controller = controller
        let run = controller.state.access { state -> (@Sendable () -> Void)? in
            state.begins += 1
            let lease = PhoneBackgroundLease(steps: state.steps)
            let callback: @Sendable () -> Void = {
                diagnostic?("application_state=active background_refresh_status=available"
                    + " low_power_mode=false grant_valid=true system_granted=\(systemGranted)"
                    + " protected_data_available=true adapter=synthetic")
                completion(lease)
            }
            if state.hold && !(incomingCallback && state.incomingBypassesHold) {
                state.pending.append(callback); return nil
            }
            return callback
        }
        run?()
    }
    var hasTimeRemaining: Bool {
        remaining.access { value in
            guard value > 0 else { return false }
            value -= 1
            return true
        }
    }
    func expire() { end() }
    func end() { remaining.access { $0 = 0 } }
}

enum ProbeFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case .failed(let value): return value } }
}
final class ValidatorController: @unchecked Sendable {
    let calls = Locked<[UUID]>([])
    let rejected = Locked<Set<UUID>>([])
    var onValidate: (@Sendable (SegmentManifest) -> Void)?
}
enum IncomingAudioValidator {
    static var controller = ValidatorController()
    static func validate(_ url: URL, against manifest: SegmentManifest) throws {
        let controller = controller
        controller.calls.access { $0.append(manifest.id) }
        controller.onValidate?(manifest)
        if controller.rejected.current.contains(manifest.id) {
            throw ProbeFailure.failed("Synthetic decoder rejected the entry")
        }
    }
}

final class Fixture: @unchecked Sendable {
    let root: URL
    let watch: RecordingRepository
    let phone: RecordingRepository
    let inbox: IncomingTransferInbox
    let session = WCSession()
    let lease = LeaseController()
    let validator = ValidatorController()
    let callbacks = Locked<[Bool]>([])
    let maintenanceResults = Locked<[PhoneBackgroundMaintenanceResult]>([])
    let maintenanceRequests = Locked(0)
    let backlogFault: (@Sendable (PhoneBacklogPersistencePoint) throws -> Void)?
    var connectivity: PhoneConnectivity
    let recordingSession: RecordingSession

    init(root: URL, fault: ((RepositoryFaultPoint) throws -> Void)? = nil,
         backlogFault: (@Sendable (PhoneBacklogPersistencePoint) throws -> Void)? = nil) throws {
        self.root = root
        self.backlogFault = backlogFault
        watch = try RecordingRepository(root: root.appendingPathComponent("watch"))
        phone = try RecordingRepository(root: root.appendingPathComponent("phone"), faultInjector: fault)
        inbox = try IncomingTransferInbox(root: phone.root.appendingPathComponent("incoming-transfers"))
        var active = try watch.createSession(at: Date(timeIntervalSince1970: 1_800_000_000))
        active.state = .recording
        try watch.saveSession(active)
        recordingSession = active
        WCSession.default = session
        PhoneBackgroundLease.controller = lease
        IncomingAudioValidator.controller = validator
        connectivity = try PhoneConnectivity(repository: phone, root: phone.root, backlogFaultInjector: backlogFault)
        installCallbacks()
        connectivity.start()
        _ = connectivity.currentState()
    }
    func installCallbacks() {
        let requests = maintenanceRequests
        connectivity.onNeedsBackgroundMaintenance = { requests.access { $0 += 1 } }
    }
    func seal(_ sequence: Int) throws -> SegmentManifest {
        let id = UUID()
        let staging = watch.stagingURL(for: id)
        try Data(repeating: UInt8(sequence % 250), count: 8_192).write(to: staging)
        let start = recordingSession.startedAt.addingTimeInterval(Double(sequence * 60))
        return try watch.sealSegment(stagedURL: staging, id: id, sessionID: recordingSession.id,
            sequence: sequence, startedAt: start, endedAt: start.addingTimeInterval(60),
            sampleRate: 16_000, frameCount: 960_000)
    }
    func temporaryFile(_ manifest: SegmentManifest) throws -> URL {
        let url = root.appendingPathComponent("framework-" + UUID().uuidString + ".caf")
        try FileManager.default.copyItem(at: watch.audioURL(for: manifest), to: url)
        return url
    }
    func deliver(_ manifest: SegmentManifest, url: URL? = nil) throws {
        let temporary = try url ?? temporaryFile(manifest)
        connectivity.session(session, didReceive: WCSessionFile(fileURL: temporary,
            metadata: [TransportCodec.manifestKey: try TransportCodec.encode(manifest)]))
        try FileManager.default.removeItem(at: temporary)
    }
    @discardableResult func begin(_ cancellation: PhoneBackgroundCancellation = PhoneBackgroundCancellation())
        -> PhoneBackgroundCancellation {
        let callbacks = callbacks, results = maintenanceResults
        connectivity.performBackgroundMaintenance(cancellation: cancellation, resultCompletion: { result in
            results.access { $0.append(result) }
            callbacks.access { $0.append(result.succeeded && !result.needsMore) }
        })
        return cancellation
    }
    func restart() throws {
        connectivity = try PhoneConnectivity(repository: phone, root: phone.root, backlogFaultInjector: backlogFault)
        installCallbacks()
        connectivity.start()
        _ = connectivity.currentState()
    }
    func reportSnapshot(pending: Int, known: Bool, at seconds: TimeInterval) throws {
        let snapshot = RecorderSnapshot(state: .paused, sessionID: recordingSession.id,
            observedAt: Date(timeIntervalSince1970: seconds), pendingCount: pending,
            pendingCountIsKnown: known)
        connectivity.session(session, didReceiveApplicationContext: [TransportCodec.snapshotKey: try TransportCodec.encode(snapshot)])
        _ = connectivity.currentState()
    }
}

@MainActor
final class Probe {
    var assertions = 0
    var cases: [[String: Any]] = []
    let root: URL
    init(root: URL) { self.root = root }
    func check(_ condition: @autoclosure () throws -> Bool, _ reason: String) throws {
        assertions += 1
        guard try condition() else { throw ProbeFailure.failed(reason) }
    }
    func eventually(_ reason: String, _ condition: () throws -> Bool) async throws {
        for _ in 0..<400 {
            if try condition() { assertions += 1; return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw ProbeFailure.failed("Timed out: " + reason)
    }
    func run(_ name: String, fault: ((RepositoryFaultPoint) throws -> Void)? = nil,
             backlogFault: (@Sendable (PhoneBacklogPersistencePoint) throws -> Void)? = nil,
             _ body: (Fixture) async throws -> Void) async {
        do {
            let fixture = try Fixture(root: root.appendingPathComponent(name), fault: fault, backlogFault: backlogFault)
            try await body(fixture)
            try check(try fixture.watch.sessions().first?.state == .recording,
                      "Receiver work must not alter the source's active recording state.")
            cases.append(["name": name, "status": "passed"])
        } catch {
            cases.append(["name": name, "status": "failed", "error": String(describing: error)])
        }
    }

    func execute() async {
        await run("runtime_context_is_diagnostic_only_and_preserves_source_time") { f in
            let requests = f.maintenanceRequests.current
            try await Task.sleep(nanoseconds: 300_000_000) // Drain startup UI notification.
            let updates = Locked(0)
            f.connectivity.onUpdate = { updates.access { $0 += 1 } }
            var runtime = WatchRuntimeObservation(build: "107", processRunID: UUID(), observerEpochID: UUID(),
                sequence: 10, observedAtMS: 1_800_000_000_000)
            runtime.nativeQueueCount = 12; runtime.nativeQueueObservedAtMS = runtime.observedAtMS - 100
            runtime.queueSamples = [.init(attemptID: UUID(), isTransferring: false, completedUnits: 24, totalUnits: 100)]
            runtime.lastACKFailure = .init(observedAtMS: runtime.observedAtMS - 50, stage: .commit, reason: .cocoaIO, systemCode: 260)
            runtime.lastACKFailure?.operation = .manifestRead
            f.connectivity.session(f.session, didReceiveApplicationContext:
                [TransportCodec.watchRuntimeKey: try TransportCodec.encode(runtime)])
            _ = f.connectivity.currentState()
            try await Task.sleep(nanoseconds: 100_000_000)
            let path = f.phone.root.appendingPathComponent("ConnectivityDiagnostics/transfer-phases.json")
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
            let report = json["watchRuntime"] as? [String: Any]
            try self.check(report?["build"] as? String == "107", "Runtime source build must survive the actual Phone delegate")
            let persisted = try report.map { try JSONSerialization.data(withJSONObject: $0) }
                .flatMap(WatchRuntimeObservation.decode)
            try self.check(persisted?.queueSamples == runtime.queueSamples && persisted?.lastACKFailure == runtime.lastACKFailure,
                "Actual Phone delegate preserves native progress and exact bounded failure classification.")
            try self.check(report?["observedAtMS"] as? Int64 == runtime.observedAtMS, "Receipt must not refresh source observation time")
            try self.check(f.connectivity.currentState().snapshot == nil, "Runtime must not fabricate recorder state")
            try self.check(f.maintenanceRequests.current == requests, "Runtime must not request library maintenance")
            try await Task.sleep(nanoseconds: 300_000_000)
            try self.check(updates.current == 0, "Runtime-only context cannot trigger PhoneStore library reload")
            try self.check(f.session.receipts.isEmpty, "Runtime must not create an audio receipt")
            try self.check(try f.phone.manifests().isEmpty, "Runtime must not import recordings")
        }
        await runStatusDiagnosticScenarios()
        await runStatusOnlyScenarios()
        await runSchedulerScenarios()
        await runBacklogPersistenceScenarios()
        await runReceiptQueueScenarios()
        await runTransferProgressScenarios()
        await runAutomaticControlScenarios()
        await run("unknown_zero_snapshot_preserves_prior_positive_maintenance_evidence") { f in
            try f.reportSnapshot(pending: 3, known: true, at: 1_800_000_100)
            try f.reportSnapshot(pending: 0, known: false, at: 1_800_000_101)
            try self.check(f.connectivity.currentState().snapshot?.pendingCountIsKnown == false,
                "Capture metadata must retain the incoming unknown-count state.")
            f.begin()
            try await self.eventually("maintenance completes with retained backlog evidence") { f.maintenanceResults.current.count == 1 }
            try self.check(f.maintenanceResults.current[0].needsMore,
                "An unknown zero cannot erase an earlier positive Watch backlog observation.")
            try f.restart()
            f.begin()
            try await self.eventually("restart still retains backlog evidence") { f.maintenanceResults.current.count == 2 }
            try self.check(f.maintenanceResults.current[1].needsMore,
                "Sticky scheduling evidence must survive replacing the display snapshot and restarting.")
        }
        await run("positive_snapshot_requests_fallback_without_another_trigger") { f in
            try f.reportSnapshot(pending: 2, known: true, at: 1_800_000_100)
            try self.check(f.maintenanceRequests.current > 0,
                "A newly accepted positive snapshot must request the existing maintenance fallback.")
        }
        await run("legacy_positive_snapshot_migrates_before_unknown_zero_replacement") { f in
            let snapshot = RecorderSnapshot(state: .paused, sessionID: f.recordingSession.id,
                observedAt: Date(timeIntervalSince1970: 1_800_000_100), pendingCount: 4)
            var legacy = try JSONSerialization.jsonObject(with: TransportCodec.encode(snapshot)) as! [String: Any]
            legacy.removeValue(forKey: "pendingCountIsKnown")
            try JSONSerialization.data(withJSONObject: legacy).write(to: f.phone.root.appendingPathComponent("phone-watch-snapshot.json"))
            try f.restart()
            try f.reportSnapshot(pending: 0, known: false, at: 1_800_000_101)
            try f.restart()
            f.begin()
            try await self.eventually("legacy evidence is checked after two restarts") { f.maintenanceResults.current.count == 1 }
            try self.check(f.maintenanceResults.current[0].needsMore,
                "Migrated positive evidence must remain durable before an unknown zero replaces its legacy source.")
        }
        await run("successful_maintenance_with_watch_backlog_is_not_a_failure") { f in
            let snapshot = RecorderSnapshot(state: .recording, sessionID: f.recordingSession.id, pendingCount: 3)
            f.connectivity.session(f.session, didReceiveApplicationContext: [TransportCodec.snapshotKey: try TransportCodec.encode(snapshot)])
            _ = f.connectivity.currentState()
            f.begin()
            try await self.eventually("maintenance reports independent success and remaining work") { f.maintenanceResults.current.count == 1 }
            try self.check(f.maintenanceResults.current.first?.succeeded == true,
                           "A successfully completed local pass must not fail solely because Watch still has a backlog.")
            try self.check(f.maintenanceResults.current.first?.needsMore == true,
                           "Watch backlog must retain the system fallback even when this pass succeeded.")
            try self.check(f.maintenanceRequests.current > 0, "Remaining Watch backlog must request later maintenance.")
        }
        await run("callback_stages_before_validation_and_restart_recovers_deleted_framework_file") { f in
            f.lease.state.access { $0.hold = true }
            let manifest = try f.seal(1)
            try f.deliver(manifest)
            try await self.eventually("lease request waiting") { f.lease.beginCount == 1 }
            try self.check(f.validator.calls.current.isEmpty, "Delegate callback must finish without audio validation.")
            try self.check(f.session.receipts.isEmpty, "Staging alone must not send an ACK.")
            try self.check(try f.inbox.pendingIDs().count == 1, "The callback must retain one private pending copy.")
            f.connectivity.expireBackgroundMaintenance()
            _ = f.connectivity.currentState()
            f.lease.release()
            try f.restart()
            f.begin()
            try await self.eventually("restarted import completes") { f.callbacks.current.count == 1 }
            try self.check(f.callbacks.current == [true], "Recovery must complete successfully.")
            try self.check(f.session.receipts.map(\.segmentID) == [manifest.id], "ACK must follow the recovered commit.")
            try self.check(try f.inbox.pendingIDs().isEmpty, "Only a committed item may leave the inbox.")
            try self.check(try f.watch.pendingSegments().map(\.id) == [manifest.id], "Phone sending does not prune Watch.")
        }
        await run("new_delivery_preempts_historical_replay") { f in
            var history: [SegmentManifest] = []
            for sequence in 1...4 {
                let manifest = try f.seal(sequence)
                _ = try f.phone.acceptIncomingFile(at: f.watch.audioURL(for: manifest), manifest: manifest)
                history.append(manifest)
            }
            let incoming = try f.seal(5)
            let temporary = try f.temporaryFile(incoming)
            let metadata = try TransportCodec.encode(incoming)
            let fired = Locked(false)
            f.session.onReceipt = { _ in
                let first = fired.access { value -> Bool in
                    if value { return false }; value = true; return true
                }
                if first {
                    f.connectivity.session(f.session, didReceive: WCSessionFile(fileURL: temporary,
                        metadata: [TransportCodec.manifestKey: metadata]))
                    try? FileManager.default.removeItem(at: temporary)
                }
            }
            f.begin()
            try await self.eventually("history and incoming complete") { f.callbacks.current.count == 1 }
            let order = f.session.receipts.map(\.segmentID)
            try self.check(order.count == 5, "Each distinct durable receipt should be enqueued once.")
            try self.check(order[1] == incoming.id, "New incoming work must precede the next historical replay.")
            try self.check(Set(order) == Set(history.map(\.id) + [incoming.id]), "Every healthy item must complete.")
        }
        await run("incoming_burst_preserves_staging_order_across_bounded_grants") { f in
            let first = try f.seal(1)
            let second = try f.seal(2)
            f.lease.state.access { $0.hold = true; $0.steps = 1 }
            try f.deliver(first)
            try f.deliver(second)
            _ = f.connectivity.currentState()
            try self.check(f.lease.beginCount == 1, "Both staged files must share the pending import grant.")
            f.lease.release()
            try await self.eventually("the exhausted grant requests another turn with one file still staged") {
                f.maintenanceRequests.current >= 2 && f.session.receipts.count == 1
                    && (try? f.inbox.pendingIDs().count) == 1
            }
            try self.check(f.session.receipts.map(\.segmentID) == [first.id],
                "A later callback must not overtake an already staged file when runtime is limited.")

            f.lease.state.access { $0.steps = 10 }
            f.begin()
            try await self.eventually("the next grant commits the remaining file") { f.callbacks.current.count == 1 }
            try self.check(f.session.receipts.map(\.segmentID) == [first.id, second.id],
                "The retained file must complete without a repeated native callback.")
            try self.check(try f.inbox.pendingIDs().isEmpty, "Only the two committed files leave the inbox.")
        }
        await run("bounded_lease_stops_between_items_and_resumes_remaining_inbox") { f in
            var manifests: [SegmentManifest] = []
            for sequence in 1...3 {
                let manifest = try f.seal(sequence)
                manifests.append(manifest)
                try f.inbox.stage(fileURL: f.watch.audioURL(for: manifest), manifest: manifest)
            }
            f.lease.state.access { $0.steps = 1 }
            f.begin()
            try await self.eventually("finite lease finishes") { f.callbacks.current.count == 1 }
            try self.check(f.callbacks.current == [false], "An exhausted grant cannot report completed.")
            try self.check(f.session.receipts.count == 1, "Exactly one item should commit in a one-step grant.")
            try self.check(try f.inbox.pendingIDs().count == 2, "Unstarted items must remain durable.")
            try self.check(f.maintenanceRequests.current >= 1, "Remaining work must request another opportunity.")
            f.lease.state.access { $0.steps = Int.max }
            f.begin()
            try await self.eventually("remaining inbox drains") { f.callbacks.current.count == 2 }
            try self.check(f.callbacks.current == [false, true], "A later grant must recover the unfinished batch.")
            try self.check(Set(f.session.receipts.map(\.segmentID)) == Set(manifests.map(\.id)), "No item may be lost.")
            try self.check(try f.inbox.pendingIDs().isEmpty, "Successful resume drains only completed jobs.")
        }
        await run("corrupt_metadata_audio_and_decoder_failure_are_isolated") { f in
            let manifests = try (1...4).map { try f.seal($0) }
            var ids: [UUID] = []
            for manifest in manifests {
                ids.append(try f.inbox.stage(fileURL: f.watch.audioURL(for: manifest), manifest: manifest))
            }
            let badMetadata = f.inbox.root.appendingPathComponent(ids[0].uuidString.lowercased())
                .appendingPathComponent("manifest.json")
            try Data("broken JSON".utf8).write(to: badMetadata)
            let badAudio = try f.inbox.load(id: ids[1]).audioURL
            try Data("corrupt audio".utf8).write(to: badAudio)
            _ = f.validator.rejected.access { $0.insert(manifests[2].id) }
            f.begin()
            try await self.eventually("isolated batch finishes") { f.callbacks.current.count == 1 }
            try self.check(f.callbacks.current == [false], "The completion must report retained failures.")
            try self.check(f.session.receipts.map(\.segmentID) == [manifests[3].id], "Only the healthy item gets ACK.")
            try self.check(try f.inbox.pendingIDs().count == 3, "Rejected input copies must remain.")
            try self.check(try f.watch.pendingSegments().count == 4, "Failures cannot delete any source audio.")
            try self.check(try Data(contentsOf: badAudio) == Data("corrupt audio".utf8), "Preserve failed bytes.")
        }
        await run("expiry_before_lease_creation_completes_each_callback_once") { f in
            f.lease.state.access { $0.hold = true }
            f.begin()
            f.begin()
            try await self.eventually("begin queued") { f.lease.beginCount == 1 }
            f.connectivity.expireBackgroundMaintenance()
            try await self.eventually("both pending callbacks cancelled") { f.callbacks.current.count == 2 }
            try self.check(f.callbacks.current == [false, false], "Both callbacks must receive cancellation exactly once.")
            f.lease.release()
            f.begin()
            try await self.eventually("replacement generation finishes") { f.callbacks.current.count == 3 }
            f.connectivity.expireBackgroundMaintenance()
            _ = f.connectivity.currentState()
            try self.check(f.callbacks.current == [false, false, true], "Stale lease completion must not finish a new run.")
        }
        await run("pre_cancelled_task_does_no_work") { f in
            let manifest = try f.seal(1)
            try f.inbox.stage(fileURL: f.watch.audioURL(for: manifest), manifest: manifest)
            let cancellation = PhoneBackgroundCancellation()
            cancellation.cancel()
            f.begin(cancellation)
            try await self.eventually("cancelled task completion") { f.callbacks.current.count == 1 }
            try self.check(f.callbacks.current == [false], "Pre-cancelled tasks must fail immediately.")
            try self.check(f.lease.beginCount == 0, "Cancellation before queue execution must not acquire a lease.")
            try self.check(f.validator.calls.current.isEmpty && f.session.receipts.isEmpty, "No import or ACK is allowed.")
            try self.check(try f.inbox.pendingIDs().count == 1, "Cancelled work remains durable.")
        }
        await run("cancellation_during_current_item_stops_before_next") { f in
            let first = try f.seal(1), second = try f.seal(2)
            try f.inbox.stage(fileURL: f.watch.audioURL(for: first), manifest: first)
            try f.inbox.stage(fileURL: f.watch.audioURL(for: second), manifest: second)
            let cancellation = PhoneBackgroundCancellation()
            f.validator.onValidate = { _ in cancellation.cancel() }
            f.begin(cancellation)
            try await self.eventually("current atomic item finishes after expiry") { f.callbacks.current.count == 1 }
            try self.check(f.callbacks.current == [false], "Cancellation must terminate the batch.")
            try self.check(f.validator.calls.current.count == 1 && f.session.receipts.count == 1,
                           "Finish the current durable commit, but never start a second item after cancellation.")
            try self.check(try f.inbox.pendingIDs().count == 1, "Unstarted audio remains available.")
        }
        await run("zero_step_grant_preserves_request_for_unloaded_receipt_backlog") { f in
            let manifest = try f.seal(1)
            _ = try f.phone.acceptIncomingFile(at: f.watch.audioURL(for: manifest), manifest: manifest)
            f.lease.state.access { $0.steps = 0 }
            f.begin()
            try await self.eventually("zero-step grant finishes") { f.callbacks.current.count == 1 }
            try self.check(f.session.receipts.isEmpty, "An expired grant cannot replay audio.")
            try self.check(f.maintenanceRequests.current >= 1,
                           "Expiry before receipt enumeration must still request a later maintenance grant.")
            f.lease.state.access { $0.steps = Int.max }
            f.begin()
            try await self.eventually("later grant replays receipt") { f.callbacks.current.count == 2 }
            try self.check(f.session.receipts.map(\.segmentID) == [manifest.id], "The backlog must recover.")
        }
        let receiptWrites = Locked(0)
        await run("historical_sweep_resumes_after_restart_and_finishes_without_reverifying_attempted_ids",
                  fault: { point in
                      if case .afterReceiptWriteBeforeSync = point { receiptWrites.access { $0 += 1 } }
                  }) { f in
            var manifests: [SegmentManifest] = []
            for sequence in 1...3 {
                let manifest = try f.seal(sequence)
                manifests.append(manifest)
                _ = try f.phone.acceptIncomingFile(at: f.watch.audioURL(for: manifest), manifest: manifest)
            }
            try self.check(receiptWrites.current == 3, "Fixture must begin with three durable receipt commits.")
            try self.check(try f.inbox.pendingIDs().isEmpty, "This scenario isolates historical replay.")
            f.lease.state.access { $0.steps = 1 }
            f.begin()
            try await self.eventually("first historical grant expires") { f.callbacks.current.count == 1 }
            try self.check(f.callbacks.current == [false], "One bounded grant cannot complete the full history.")
            try self.check(receiptWrites.current == 4, "Exactly one historical receipt must be reverified.")
            try self.check(f.session.receipts.count == 1, "First grant enqueues one verified ACK.")

            try f.restart()
            f.lease.state.access { $0.steps = Int.max }
            f.begin()
            try await self.eventually("persisted remaining sweep completes") { f.callbacks.current.count == 2 }
            try self.check(f.callbacks.current == [false, true], "A resumed finite sweep must eventually finish.")
            try self.check(receiptWrites.current == 6,
                           "Restart must reverify only the two remaining IDs, not begin a new full sweep.")
            try self.check(Set(f.session.receipts.map(\.segmentID)) == Set(manifests.map(\.id)),
                           "Every historical receipt must be enqueued exactly once.")

            f.begin()
            try await self.eventually("automatic grant inside discovery cooldown finishes") { f.callbacks.current.count == 3 }
            try self.check(f.callbacks.current == [false, true, true] && receiptWrites.current == 6,
                           "A completed sweep must not be reverified on the next automatic grant.")
            f.connectivity.session(f.session, didReceiveUserInfo: [TransportCodec.requestSyncKey: true])
            try await self.eventually("explicit Watch recovery can start a fresh sweep") { receiptWrites.current == 9 }
            try self.check(receiptWrites.current == 9, "The completed queue must allow a fresh full verification later.")
            try self.check(f.session.receipts.count == 3, "Fresh verification must respect already queued ACK deduplication.")
        }
        do {
            let name = "no_ack_until_repository_receipt_synchronization_succeeds"
            let failSync = Locked(true)
            let f = try Fixture(root: root.appendingPathComponent(name), fault: {
                if case .afterReceiptWriteBeforeSync = $0, failSync.current { throw ProbeFailure.failed("sync fault") }
            })
            let manifest = try f.seal(1)
            f.lease.state.access { $0.hold = true }
            try f.deliver(manifest)
            f.begin()
            try await eventually("commit fault test lease") { f.lease.beginCount == 1 }
            f.lease.release()
            try await eventually("commit failure reported") { f.callbacks.current.count == 1 }
            try check(f.session.receipts.isEmpty, "Visible receipt file before successful fsync cannot authorize ACK.")
            try check(f.maintenanceResults.current.first?.succeeded == false,
                      "A real receipt persistence failure must remain a failed BG maintenance result.")
            try check(f.maintenanceResults.current.first?.needsMore == true,
                      "Failed receipt persistence must preserve a later maintenance request.")
            try check(try f.inbox.pendingIDs().count == 1, "Commit failure must retain the incoming copy.")
            try check(try f.watch.pendingSegments().map(\.id) == [manifest.id], "Source audio remains unacknowledged.")
            failSync.access { $0 = false }
            f.begin()
            try await eventually("durable commit retry succeeds") { f.callbacks.current.count == 2 }
            try check(f.callbacks.current == [false, true], "Retry must recover the prior visible-but-unsynced receipt.")
            try check(f.session.receipts.map(\.segmentID) == [manifest.id], "Only the successful durable commit gets ACK.")
            try check(try f.inbox.pendingIDs().isEmpty, "Inbox cleanup follows successful receipt persistence.")
            try check(try f.watch.sessions().first?.state == .recording, "Receive failure must not alter source recording.")
            cases.append(["name": name, "status": "passed"])
        } catch {
            cases.append(["name": "no_ack_until_repository_receipt_synchronization_succeeds",
                          "status": "failed", "error": String(describing: error)])
        }
    }
}

@main
struct Main {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        let report = URL(fileURLWithPath: args[1])
        let probe = Probe(root: URL(fileURLWithPath: args[2]))
        await probe.execute()
        let failures = probe.cases.filter { $0["status"] as? String == "failed" }
        let result: [String: Any] = ["status": failures.isEmpty ? "passed" : "failed",
            "caseCount": probe.cases.count, "assertionCount": probe.assertions,
            "cases": probe.cases, "failures": failures]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: report)
        print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted]), encoding: .utf8)!)
        if !failures.isEmpty { exit(1) }
    }
}
