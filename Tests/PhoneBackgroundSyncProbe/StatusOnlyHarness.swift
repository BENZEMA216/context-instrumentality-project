import Foundation
import RecordingCore

extension Probe {
    private func checkStatusHasNoMaintenance(_ f: Fixture, notifications: Locked<Int>) throws {
        try check(f.session.outstandingUserInfoTransfers.isEmpty, "A status query must not enqueue receipts or deferred sync.")
        try check(f.session.sentMessages.current.allSatisfy {
            $0.count == 1 && $0[TransportCodec.statusRequestKey] is Data
        }, "Only the dedicated request-bound status envelope may be sent.")
        try check(f.maintenanceRequests.current == 0 && f.lease.beginCount == 0,
                  "No background maintenance or audio-validation lease may start.")
        try check(f.validator.calls.current.isEmpty, "The status route must not validate audio.")
        try check(notifications.current == 0, "The library/discovery observer must not be notified.")
        try check(!FileManager.default.fileExists(atPath: f.backlogURL.path)
            && !FileManager.default.fileExists(atPath: f.snapshotURL.path),
                  "A presentation-only reply must not persist scheduling evidence or migrate a display snapshot.")
        try check(try f.phone.events().isEmpty, "Status must not write repository events.")
    }

    func runStatusOnlyScenarios() async {
        await runStatusRecoveryScenarios()
        await run("status_only_reachability_grace_sends_once_without_sync") { f in
            let results = Locked<[PhoneStatusRequestResult]>([])
            let notifications = Locked(0)
            f.connectivity.onUpdate = { notifications.access { $0 += 1 } }
            f.session.messageHandler = { payload, reply, _ in
                guard let data = payload[TransportCodec.statusRequestKey] as? Data,
                      let request = try? TransportCodec.decode(RecorderStatusRequest.self, from: data) else { return }
                reply?([TransportCodec.statusResponseKey: try! TransportCodec.encode(
                    RecorderStatusResponse(requestID: request.requestID, snapshot: RecorderSnapshot(state: .paused)))])
            }
            f.connectivity.requestStatus { result in results.access { $0.append(result) } }
            try await Task.sleep(nanoseconds: 350_000_000)
            try check(results.current.isEmpty && f.session.sentMessages.current.isEmpty,
                      "An initially unreachable Watch gets a short grace without a deferred WC message.")
            f.session.isReachable = true
            try await eventually("became reachable once") { results.current.count == 1 }
            try check(f.session.sentMessages.current.count == 1, "A grace period sends exactly one request when live reachability appears.")
            let reportURL = f.phone.root.appendingPathComponent("ConnectivityDiagnostics/phone.json")
            try await eventually("bound reply independently counted") {
                guard let bytes = try? Data(contentsOf: reportURL), bytes.count <= 4_096,
                      let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return false }
                return value["statusRequestCount"] as? Int == 1 && value["statusReplyCount"] as? Int == 1
                    && value["lastStatusOutcome"] as? String == "received"
            }
            try checkStatusHasNoMaintenance(f, notifications: notifications)
        }
        await run("status_only_cancel_during_reachability_grace_never_sends") { f in
            let results = Locked<[PhoneStatusRequestResult]>([])
            f.connectivity.requestStatus { result in results.access { $0.append(result) } }
            try await Task.sleep(nanoseconds: 250_000_000)
            f.connectivity.cancelStatusRequest()
            f.session.isReachable = true
            try await Task.sleep(nanoseconds: 400_000_000)
            try check(results.current.isEmpty && f.session.sentMessages.current.isEmpty,
                      "Cancellation revokes every queued grace poll before it can send or complete.")
        }
        await run("status_only_metadata_observes_without_blocked_library_worker") { f in
            guard let queue = Mirror(reflecting: f.connectivity).children.first(where: { $0.label == "work" })?.value as? DispatchQueue else {
                throw ProbeFailure.failed("Production connectivity worker missing")
            }
            let gate = DispatchSemaphore(value: 0)
            let entered = Locked(false)
            queue.async { entered.access { $0 = true }; _ = gate.wait(timeout: .now() + 5) }
            defer { gate.signal() }
            try await eventually("library worker blocked") { entered.current }
            let results = Locked<[PhoneStatusRequestResult]>([])
            f.connectivity.requestStatus { result in results.access { $0.append(result) } }
            let url = f.phone.root.appendingPathComponent("ConnectivityDiagnostics/phone.json")
            try await eventually("independent metadata writer") {
                guard let bytes = try? Data(contentsOf: url), bytes.count <= 4_096,
                      let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return false }
                return value["trigger"] as? String == "status" && value["activationState"] as? Int == 2
                    && value["reachable"] as? Bool == false
            }
            f.connectivity.cancelStatusRequest()
            try check(results.current.isEmpty && f.session.sentMessages.current.isEmpty && f.validator.calls.current.isEmpty,
                      "WC metadata does not wait for or trigger library/audio work.")
        }
        await run("status_only_store_async_busy_observer_cannot_cancel_owner") { f in
            f.session.isReachable = true
            let callback = Locked<(([String: Any]) -> Void)?>(nil)
            let request = Locked<RecorderStatusRequest?>(nil)
            f.session.messageHandler = { payload, reply, _ in
                request.access { $0 = (payload[TransportCodec.statusRequestKey] as? Data).flatMap {
                    try? TransportCodec.decode(RecorderStatusRequest.self, from: $0) } }
                callback.access { $0 = reply }
            }
            let store = StatusStoreProbe(connectivity: f.connectivity)
            store.requestStatus()
            try await eventually("owner request sent") { callback.current != nil }
            let observer = Task { @MainActor in await store.requestStatusAndWait() }
            try await Task.sleep(nanoseconds: 80_000_000)
            observer.cancel()
            await observer.value
            try check(store.isRequestingStatus, "Cancelling a busy observer cannot cancel another view's query.")
            callback.current?([TransportCodec.statusResponseKey: try TransportCodec.encode(
                RecorderStatusResponse(requestID: request.current!.requestID, snapshot: RecorderSnapshot(state: .paused)))])
            try await eventually("owner receives terminal reply") { !store.isRequestingStatus }
            let owner = Task { @MainActor in await store.requestStatusAndWait() }
            try await eventually("new async owner sends") { f.session.sentMessages.current.count == 2 }
            owner.cancel()
            await owner.value
            try check(!store.isRequestingStatus, "Cancelling the async owner revokes its own pending query.")
        }
        for mode in ["legacy-ack", "valid", "stale", "future", "no-report", "mismatched-id", "mixed", "bad-json", "error"] {
            await run("status_only_\(mode)_does_not_start_sync") { f in
                let notifications = Locked(0)
                f.connectivity.onUpdate = { notifications.access { $0 += 1 } }
                f.session.isReachable = true
                let expected = RecorderSnapshot(state: .paused, sessionID: f.recordingSession.id,
                    observedAt: Date().addingTimeInterval(mode == "stale" ? -600 : mode == "future" ? 600 : 0),
                    pendingCount: 9, pendingCountIsKnown: true)
                f.session.messageHandler = { payload, reply, error in
                    if mode == "error" { error?(ProbeFailure.failed("synthetic transport failure")); return }
                    if mode == "legacy-ack" { reply?(["requestReceived": true]); return }
                    guard let data = payload[TransportCodec.statusRequestKey] as? Data,
                          let request = try? TransportCodec.decode(RecorderStatusRequest.self, from: data) else { return }
                    let response = RecorderStatusResponse(requestID: mode == "mismatched-id" ? UUID() : request.requestID,
                        snapshot: mode == "no-report" ? nil : expected)
                    let bytes = mode == "bad-json" ? Data("{".utf8) : try! TransportCodec.encode(response)
                    var envelope: [String: Any] = [TransportCodec.statusResponseKey: bytes]
                    if mode == "mixed" { envelope[TransportCodec.requestSyncKey] = true }
                    reply?(envelope)
                }
                let results = Locked<[PhoneStatusRequestResult]>([])
                f.connectivity.requestStatus { result in results.access { $0.append(result) } }
                try await eventually("status-only reply") { results.current.count == 1 }
                switch (mode, results.current[0]) {
                case ("legacy-ack", .unsupportedWatchVersion), ("valid", .received),
                     ("stale", .staleReport), ("future", .staleReport), ("no-report", .noReport),
                     ("mismatched-id", .failed), ("mixed", .failed), ("bad-json", .failed), ("error", .failed): break
                default: throw ProbeFailure.failed("Incorrect status-only result for \(mode)")
                }
                try check(f.connectivity.currentState().snapshot == (mode == "valid" ? expected : nil),
                          "Only the bound, current reply may update display metadata.")
                try checkStatusHasNoMaintenance(f, notifications: notifications)
            }
        }
        await run("status_only_unreachable_grace_never_queues_deferred_work") { f in
            let notifications = Locked(0)
            f.connectivity.onUpdate = { notifications.access { $0 += 1 } }
            let results = Locked<[PhoneStatusRequestResult]>([])
            f.connectivity.requestStatus { result in results.access { $0.append(result) } }
            try await Task.sleep(nanoseconds: 7_200_000_000)
            try await eventually("unreachable result") { results.current.count == 1 }
            guard case .waitingForConnection = results.current[0] else { throw ProbeFailure.failed("Unreachable must stay explicit") }
            try check(f.session.sentMessages.current.isEmpty, "No live/deferred request when unreachable.")
            try checkStatusHasNoMaintenance(f, notifications: notifications)
        }
        await run("status_only_cancel_while_worker_blocked_never_sends_late_query") { f in
            f.session.isReachable = true
            guard let queue = Mirror(reflecting: f.connectivity).children
                .first(where: { $0.label == "work" })?.value as? DispatchQueue else {
                throw ProbeFailure.failed("Production connectivity queue missing")
            }
            let gate = DispatchSemaphore(value: 0)
            let entered = Locked(false)
            queue.async { entered.access { $0 = true }; _ = gate.wait(timeout: .now() + 5) }
            try await eventually("historical worker is blocked") { entered.current }
            let results = Locked<[PhoneStatusRequestResult]>([])
            f.connectivity.requestStatus { result in results.access { $0.append(result) } }
            // The production Store calls this directly from its independent
            // MainActor deadline/close handler, never via the blocked queue.
            f.connectivity.cancelStatusRequest()
            gate.signal()
            _ = f.connectivity.currentState()
            try check(f.session.sentMessages.current.isEmpty && results.current.isEmpty,
                      "An expired/closed queued query must never be sent or complete late")
        }
        await run("status_only_store_deadline_works_while_history_worker_is_blocked") { f in
            f.session.isReachable = true
            guard let queue = Mirror(reflecting: f.connectivity).children
                .first(where: { $0.label == "work" })?.value as? DispatchQueue else {
                throw ProbeFailure.failed("Production connectivity queue missing")
            }
            let gate = DispatchSemaphore(value: 0), entered = Locked(false)
            queue.async { entered.access { $0 = true }; _ = gate.wait(timeout: .now() + 20) }
            defer { gate.signal() }
            try await eventually("history queue blocked before Store query") { entered.current }
            let store = StatusStoreProbe(connectivity: f.connectivity)
            let results = Locked<[PhoneStatusRequestResult]>([])
            store.requestStatus { result in results.access { $0.append(result) } }
            try check(store.isRequestingStatus, "Store starts a visible request")
            try await Task.sleep(nanoseconds: 8_200_000_000)
            try await eventually("independent MainActor deadline") { results.current.count == 1 }
            guard case .timedOut = results.current[0] else { throw ProbeFailure.failed("Blocked worker must not hide Store timeout") }
            try check(!store.isRequestingStatus && store.statusFeedbackIsError,
                      "Spinner stops and explains timeout without waiting for the history queue")
            gate.signal()
            _ = f.connectivity.currentState()
            try check(f.session.sentMessages.current.isEmpty && results.current.count == 1,
                      "After queue recovery, the expired Store request is not sent or completed again")
        }
        await run("status_only_cancel_reopen_ignores_old_reply") { f in
            f.session.isReachable = true
            let callbacks = Locked<[((([String: Any]) -> Void))]>([])
            let requests = Locked<[RecorderStatusRequest]>([])
            f.session.messageHandler = { payload, reply, _ in
                if let data = payload[TransportCodec.statusRequestKey] as? Data,
                   let request = try? TransportCodec.decode(RecorderStatusRequest.self, from: data), let reply {
                    requests.access { $0.append(request) }; callbacks.access { $0.append(reply) }
                }
            }
            let results = Locked<[PhoneStatusRequestResult]>([])
            f.connectivity.requestStatus { result in results.access { $0.append(result) } }
            try await eventually("first query sent") { callbacks.current.count == 1 }
            f.connectivity.cancelStatusRequest()
            f.connectivity.requestStatus { result in results.access { $0.append(result) } }
            try await eventually("second query sent") { callbacks.current.count == 2 }
            let first = RecorderSnapshot(state: .recording)
            callbacks.current[0]([TransportCodec.statusResponseKey:
                try TransportCodec.encode(RecorderStatusResponse(requestID: requests.current[0].requestID, snapshot: first))])
            _ = f.connectivity.currentState()
            try check(results.current.isEmpty && f.connectivity.currentState().snapshot == nil,
                      "Cancelled reply cannot complete the reopened sheet.")
            let second = RecorderSnapshot(state: .paused)
            callbacks.current[1]([TransportCodec.statusResponseKey:
                try TransportCodec.encode(RecorderStatusResponse(requestID: requests.current[1].requestID, snapshot: second))])
            try await eventually("new query completes") { results.current.count == 1 }
            try check(f.connectivity.currentState().snapshot == second, "Only the current request's response is accepted.")
        }
        await run("status_only_timeout_then_late_reply_ignored") { f in
            f.session.isReachable = true
            let callback = Locked<(([String: Any]) -> Void)?>(nil)
            let request = Locked<RecorderStatusRequest?>(nil)
            f.session.messageHandler = { payload, reply, _ in
                request.access { $0 = (payload[TransportCodec.statusRequestKey] as? Data).flatMap {
                    try? TransportCodec.decode(RecorderStatusRequest.self, from: $0) } }
                callback.access { $0 = reply }
            }
            let results = Locked<[PhoneStatusRequestResult]>([])
            f.connectivity.requestStatus { result in results.access { $0.append(result) } }
            try await Task.sleep(nanoseconds: 8_200_000_000)
            try await eventually("production timeout delivered on serial queue") { results.current.count == 1 }
            try check(results.current.count == 1, "Production eight-second timeout completes once.")
            guard case .timedOut = results.current[0] else { throw ProbeFailure.failed("Missing explicit timeout") }
            callback.current?([TransportCodec.statusResponseKey: try TransportCodec.encode(
                RecorderStatusResponse(requestID: request.current!.requestID, snapshot: RecorderSnapshot(state: .paused)))])
            _ = f.connectivity.currentState()
            try check(results.current.count == 1 && f.connectivity.currentState().snapshot == nil,
                      "A late reply cannot revive a timed-out query.")
        }
    }

    private func awaitUnreachableIntent(_ f: Fixture, store: StatusStoreProbe,
                                        results: Locked<[PhoneStatusRequestResult]>? = nil) async throws -> (UUID, UUID) {
        guard let intent = store.requestStatus(completion: { result in results?.access { $0.append(result) } }),
              let generation = store.statusRequestGeneration else {
            throw ProbeFailure.failed("A new manual status query must expose its owner and attempt generation")
        }
        try await Task.sleep(nanoseconds: 7_200_000_000)
        try await eventually("initial unreachable outcome arms recovery") {
            !store.isRequestingStatus && store.isAwaitingStatusRecovery
        }
        try check(store.statusFeedbackIsError && store.statusFeedback == PhoneStatusRequestResult.waitingForConnection.message,
                  "The Store publishes only the failure status; the View owns recovery guidance while one retry is armed.")
        try check(f.session.sentMessages.current.isEmpty, "An unreachable query does not queue a live or deferred WC message.")
        return (intent, generation)
    }

    private func decodedStatusRequests(_ f: Fixture) -> [RecorderStatusRequest] {
        f.session.sentMessages.current.compactMap {
            ($0[TransportCodec.statusRequestKey] as? Data).flatMap {
                try? TransportCodec.decode(RecorderStatusRequest.self, from: $0)
            }
        }
    }

    private func runStatusRecoveryScenarios() async {
        await run("status_recovery_connection_edge_retries_once_with_new_generation_and_clears_error") { f in
            let notifications = Locked(0), completions = Locked<[PhoneStatusRequestResult]>([])
            f.connectivity.onUpdate = { notifications.access { $0 += 1 } }
            let pending = Locked<[(RecorderStatusRequest, ([String: Any]) -> Void)]>([])
            f.session.messageHandler = { payload, reply, _ in
                guard let bytes = payload[TransportCodec.statusRequestKey] as? Data,
                      let request = try? TransportCodec.decode(RecorderStatusRequest.self, from: bytes), let reply else { return }
                pending.access { $0.append((request, reply)) }
            }
            let store = StatusStoreProbe(connectivity: f.connectivity)
            let (intent, generation) = try await awaitUnreachableIntent(f, store: store, results: completions)
            f.session.isReachable = true
            f.connectivity.observeStatusAvailability()
            try await eventually("automatic recovery sends a new query") { pending.current.count == 1 }
            try check(store.statusQueryIntentID == intent && store.statusRequestGeneration != generation,
                      "Recovery retains the logical owner but starts a new attempt generation.")
            try check(store.isRequestingStatus && store.statusFeedbackIsError && !store.isAwaitingStatusRecovery,
                      "The retry publishes a pending query; the previous error is only cleared by correlated success.")
            let recoveryGeneration = store.statusRequestGeneration
            for _ in 0..<8 { f.connectivity.observeStatusAvailability() }
            try await Task.sleep(nanoseconds: 150_000_000)
            try check(pending.current.count == 1 && store.statusRequestGeneration == recoveryGeneration,
                      "Repeated availability callbacks cannot duplicate an active automatic attempt.")
            let (request, reply) = pending.current[0]
            let fresh = RecorderSnapshot(state: .paused)
            reply([TransportCodec.statusResponseKey: try TransportCodec.encode(
                RecorderStatusResponse(requestID: request.requestID, snapshot: fresh))])
            try await eventually("automatic response clears the old error") { !store.isRequestingStatus }
            try check(store.connection.snapshot == fresh && !store.statusFeedbackIsError
                && store.statusFeedback == PhoneStatusRequestResult.received(fresh).message,
                      "Only the correlated recovery success clears the old failure and publishes current state.")
            try check(completions.current.count == 1, "The original caller's terminal completion is not reused by automatic attempts.")
            for _ in 0..<4 {
                f.session.isReachable = false; f.connectivity.observeStatusAvailability()
                f.session.isReachable = true; f.connectivity.observeStatusAvailability()
            }
            try await Task.sleep(nanoseconds: 150_000_000)
            try check(decodedStatusRequests(f).count == 1, "A completed owner never turns later connection edges into polling.")
            let metadata = f.phone.root.appendingPathComponent("ConnectivityDiagnostics/phone.json")
            try await eventually("automatic attempt independently recorded") {
                guard let data = try? Data(contentsOf: metadata),
                      let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
                return value["statusRequestCount"] as? Int == 2 && value["statusAutoRetryCount"] as? Int == 1
                    && value["lastStatusRequestTrigger"] as? String == "recovery"
            }
            try checkStatusHasNoMaintenance(f, notifications: notifications)
        }

        await run("status_recovery_old_waiter_cancellation_cannot_cancel_new_attempt") { f in
            let notifications = Locked(0)
            f.connectivity.onUpdate = { notifications.access { $0 += 1 } }
            let pending = Locked<[(RecorderStatusRequest, ([String: Any]) -> Void)]>([])
            let oldWaiter = Locked<Task<Void, Never>?>(nil)
            f.session.messageHandler = { payload, reply, _ in
                guard let bytes = payload[TransportCodec.statusRequestKey] as? Data,
                      let request = try? TransportCodec.decode(RecorderStatusRequest.self, from: bytes), let reply else { return }
                pending.access { $0.append((request, reply)) }
                oldWaiter.current?.cancel()
            }
            let store = StatusStoreProbe(connectivity: f.connectivity)
            let intent = store.requestStatus { result in
                guard case .waitingForConnection = result else { return }
                // Reproduce availability racing with delivery of the initial
                // terminal result, before the old 50ms waiter can wake again.
                f.session.isReachable = true
                store.statusConnectionAvailabilityChanged(true)
            }!
            let initialGeneration = store.statusRequestGeneration
            let waiter = Task { @MainActor in await store.waitForStatusRequest(intentID: intent) }
            oldWaiter.access { $0 = waiter }
            try await Task.sleep(nanoseconds: 7_200_000_000)
            try await eventually("racing availability starts exactly one recovery") { pending.current.count == 1 }
            await waiter.value
            try check(store.statusQueryIntentID == intent && store.statusRequestGeneration != initialGeneration
                && store.isRequestingStatus,
                      "A cancelled waiter for the previous generation cannot revoke the new automatic attempt.")
            for _ in 0..<6 { f.connectivity.observeStatusAvailability() }
            try await Task.sleep(nanoseconds: 100_000_000)
            try check(pending.current.count == 1, "A true observation before failure and repeated callbacks consume one retry only.")
            let (request, reply) = pending.current[0]
            let fresh = RecorderSnapshot(state: .paused)
            reply([TransportCodec.statusResponseKey: try TransportCodec.encode(
                RecorderStatusResponse(requestID: request.requestID, snapshot: fresh))])
            try await eventually("retry survives old waiter cleanup and succeeds") { !store.isRequestingStatus }
            try check(store.connection.snapshot == fresh && !store.statusFeedbackIsError,
                      "The surviving bound success clears the error.")
            try checkStatusHasNoMaintenance(f, notifications: notifications)
        }

        await run("status_recovery_cancel_waiting_owner_prevents_later_connection_query") { f in
            let notifications = Locked(0)
            f.connectivity.onUpdate = { notifications.access { $0 += 1 } }
            let store = StatusStoreProbe(connectivity: f.connectivity)
            let (intent, _) = try await awaitUnreachableIntent(f, store: store)
            store.cancelStatusRequest(ifIntentID: intent)
            f.session.isReachable = true
            f.connectivity.observeStatusAvailability()
            try await Task.sleep(nanoseconds: 250_000_000)
            try check(!store.isAwaitingStatusRecovery && !store.isRequestingStatus && store.statusFeedback == nil,
                      "Leaving or cancelling the owner revokes even an already-failed pending recovery intent.")
            try check(f.session.sentMessages.current.isEmpty, "A later connection cannot revive a cancelled intent.")
            try checkStatusHasNoMaintenance(f, notifications: notifications)
        }

        await run("status_recovery_new_manual_owner_replaces_intent_and_ignores_old_cancel") { f in
            let notifications = Locked(0)
            f.connectivity.onUpdate = { notifications.access { $0 += 1 } }
            let pending = Locked<[(RecorderStatusRequest, ([String: Any]) -> Void)]>([])
            f.session.messageHandler = { payload, reply, _ in
                guard let bytes = payload[TransportCodec.statusRequestKey] as? Data,
                      let request = try? TransportCodec.decode(RecorderStatusRequest.self, from: bytes), let reply else { return }
                pending.access { $0.append((request, reply)) }
            }
            let store = StatusStoreProbe(connectivity: f.connectivity)
            let (oldIntent, oldGeneration) = try await awaitUnreachableIntent(f, store: store)
            f.session.isReachable = true
            guard let manualIntent = store.requestStatus() else { throw ProbeFailure.failed("Manual request failed to take a fresh owner") }
            try await eventually("new manual query sent") { pending.current.count == 1 }
            store.cancelStatusRequest(ifIntentID: oldIntent)
            f.connectivity.observeStatusAvailability()
            try await Task.sleep(nanoseconds: 150_000_000)
            try check(manualIntent != oldIntent && store.statusQueryIntentID == manualIntent
                && store.statusRequestGeneration != oldGeneration && store.isRequestingStatus,
                      "A manual request starts fresh ownership; an old view's cleanup cannot revoke it.")
            try check(pending.current.count == 1 && !store.isAwaitingStatusRecovery,
                      "An old armed edge cannot duplicate the manual replacement query.")
            let (request, reply) = pending.current[0]
            let fresh = RecorderSnapshot(state: .paused)
            reply([TransportCodec.statusResponseKey: try TransportCodec.encode(
                RecorderStatusResponse(requestID: request.requestID, snapshot: fresh))])
            try await eventually("manual replacement succeeds") { !store.isRequestingStatus }
            try check(store.connection.snapshot == fresh && !store.statusFeedbackIsError, "The current owner alone publishes success.")
            try checkStatusHasNoMaintenance(f, notifications: notifications)
        }

        await run("status_recovery_failed_automatic_attempt_never_rearms") { f in
            let notifications = Locked(0)
            f.connectivity.onUpdate = { notifications.access { $0 += 1 } }
            f.session.messageHandler = { _, _, error in error?(ProbeFailure.failed("synthetic automatic request failure")) }
            let store = StatusStoreProbe(connectivity: f.connectivity)
            _ = try await awaitUnreachableIntent(f, store: store)
            f.session.isReachable = true
            f.connectivity.observeStatusAvailability()
            try await eventually("automatic request fails explicitly") {
                f.session.sentMessages.current.count == 1 && !store.isRequestingStatus && store.statusFeedbackIsError
            }
            try check(!store.isAwaitingStatusRecovery, "An automatic failure consumes this intent's one retry budget.")
            for _ in 0..<6 {
                f.session.isReachable = false; f.connectivity.observeStatusAvailability()
                f.session.isReachable = true; f.connectivity.observeStatusAvailability()
            }
            try await Task.sleep(nanoseconds: 200_000_000)
            try check(f.session.sentMessages.current.count == 1, "Connection flapping after retry failure cannot create a retry loop.")
            try checkStatusHasNoMaintenance(f, notifications: notifications)
        }

        await run("status_recovery_cancel_active_retry_and_late_reply_cannot_override_new_manual_query") { f in
            let notifications = Locked(0)
            f.connectivity.onUpdate = { notifications.access { $0 += 1 } }
            let pending = Locked<[(RecorderStatusRequest, ([String: Any]) -> Void)]>([])
            f.session.messageHandler = { payload, reply, _ in
                guard let bytes = payload[TransportCodec.statusRequestKey] as? Data,
                      let request = try? TransportCodec.decode(RecorderStatusRequest.self, from: bytes), let reply else { return }
                pending.access { $0.append((request, reply)) }
            }
            let store = StatusStoreProbe(connectivity: f.connectivity)
            let (oldIntent, _) = try await awaitUnreachableIntent(f, store: store)
            f.session.isReachable = true
            f.connectivity.observeStatusAvailability()
            try await eventually("active automatic attempt captured") { pending.current.count == 1 }
            store.cancelStatusRequest(ifIntentID: oldIntent)
            guard let newIntent = store.requestStatus() else { throw ProbeFailure.failed("New manual query missing") }
            try await eventually("new manual attempt captured") { pending.current.count == 2 }
            let (oldRequest, oldReply) = pending.current[0], (newRequest, newReply) = pending.current[1]
            try check(oldRequest.requestID != newRequest.requestID && newIntent != oldIntent,
                      "A manual replacement uses a new transport UUID and a new logical owner.")
            oldReply([TransportCodec.statusResponseKey: try TransportCodec.encode(
                RecorderStatusResponse(requestID: oldRequest.requestID, snapshot: RecorderSnapshot(state: .recording)))])
            try await Task.sleep(nanoseconds: 150_000_000)
            try check(store.isRequestingStatus && store.statusQueryIntentID == newIntent && store.connection.snapshot == nil,
                      "A cancelled retry's late response cannot finish or update the new query.")
            let fresh = RecorderSnapshot(state: .paused)
            newReply([TransportCodec.statusResponseKey: try TransportCodec.encode(
                RecorderStatusResponse(requestID: newRequest.requestID, snapshot: fresh))])
            try await eventually("current replacement finishes") { !store.isRequestingStatus }
            try check(store.connection.snapshot == fresh && !store.statusFeedbackIsError, "The current correlated reply clears errors.")
            store.cancelStatusRequest(ifIntentID: oldIntent)
            try check(store.connection.snapshot == fresh && store.statusFeedback != nil,
                      "Delayed cleanup from an old owner cannot clear the new owner's terminal feedback.")
            try checkStatusHasNoMaintenance(f, notifications: notifications)
        }

        await run("status_recovery_other_failures_never_arm_connection_retry") { f in
            let notifications = Locked(0), mode = Locked("unsupported")
            f.connectivity.onUpdate = { notifications.access { $0 += 1 } }
            f.session.isReachable = true
            f.session.messageHandler = { payload, reply, error in
                if mode.current == "unsupported" { reply?(["requestReceived": true]); return }
                if mode.current == "failed" { error?(ProbeFailure.failed("synthetic transport failure")); return }
                guard let bytes = payload[TransportCodec.statusRequestKey] as? Data,
                      let request = try? TransportCodec.decode(RecorderStatusRequest.self, from: bytes) else { return }
                let snapshot = mode.current == "no-report" ? nil : RecorderSnapshot(state: .paused, observedAt: Date().addingTimeInterval(-600))
                reply?([TransportCodec.statusResponseKey: try! TransportCodec.encode(
                    RecorderStatusResponse(requestID: request.requestID, snapshot: snapshot))])
            }
            let store = StatusStoreProbe(connectivity: f.connectivity)
            for (index, value) in ["unsupported", "no-report", "stale", "failed"].enumerated() {
                mode.access { $0 = value }
                _ = store.requestStatus()
                try await eventually("explicit non-reachability failure") { !store.isRequestingStatus }
                try check(store.statusFeedbackIsError && !store.isAwaitingStatusRecovery,
                          "Unsupported, absent, stale or transport-failed results do not imply lost reachability.")
                f.session.isReachable = false; f.connectivity.observeStatusAvailability()
                f.session.isReachable = true; f.connectivity.observeStatusAvailability()
                try await Task.sleep(nanoseconds: 80_000_000)
                try check(f.session.sentMessages.current.count == index + 1, "Unrelated failures cannot acquire automatic retry authority.")
            }
            try checkStatusHasNoMaintenance(f, notifications: notifications)
        }
    }
}
