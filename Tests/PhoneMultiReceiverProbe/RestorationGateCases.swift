import Foundation
import RecordingCore

extension Probe {
    @MainActor func executeRestorationGateCases() async {
        await executeArchiveColdRestoreCases()
        await run("restoration_gate_safe_diagnostics_report_actual_completion_order") { _ in
            var time: TimeInterval = 10
            let tracker = BackgroundSessionEventTracker()
            let gate = BackgroundSessionRestorationGate(isForeground: { true }, now: { time }, eventTracker: tracker)
            var events: [(String, String)] = [], callbacks = 0
            gate.setDiagnosticHandler { events.append(($0, $1)) }
            let privateIdentifier = "synthetic-private-account-session-DO-NOT-LOG"
            gate.receive(privateIdentifier) { callbacks += 1; events.append(("actual_callback", "")) }
            let first = tracker.capture(privateIdentifier)
            time = 11
            gate.finish(first.identifier, token: first.token)
            gate.receive(privateIdentifier) { callbacks += 1 }
            gate.finish(first.identifier, token: first.token)
            let token = gate.beginHandoff(privateIdentifier)
            gate.finish(privateIdentifier, token: token)
            try self.check(callbacks == 1, "Rejected stale and held drain diagnostics must not imply UIKit completion")
            gate.completeHandoff(privateIdentifier, token: token)
            try self.check(callbacks == 2 && events.filter { $0.0 == "phone.background_handoff_completion_called" }.count == 2,
                "Completion diagnostics must count actual closure invocations only")
            let callbackIndex = events.firstIndex { $0.0 == "actual_callback" }!
            let completionIndex = events.firstIndex { $0.0 == "phone.background_handoff_completion_called" }!
            try self.check(callbackIndex < completionIndex, "The completion event must follow the actual closure")
            let details = events.map(\.1).joined()
            try self.check(!details.contains(privateIdentifier) && !details.contains(first.token!.uuidString)
                           && !details.contains(token.uuidString) && details.contains("owner_seq=1")
                           && details.contains("wave_seq=2") && details.contains("reason=stale_token"),
                "Only random process aliases, counters and fixed reasons may be logged")
        }
        await run("restoration_gate_safe_diagnostics_buffer_is_bounded") { _ in
            let gate = BackgroundSessionRestorationGate(isForeground: { false }, eventTracker: .init())
            for index in 0..<20 { gate.finish("private-\(index)", token: nil) }
            var events: [String] = []
            gate.setDiagnosticHandler { events.append($0 + $1) }
            try self.check(events.count == 8 && events.allSatisfy { !$0.contains("private-") },
                "Diagnostics before PhoneStore exists must remain bounded and contain no private session identifiers")
        }
        await run("cold_registration_waits_for_handler_before_restore") { _ in
            let tracker = BackgroundSessionEventTracker()
            let gate = BackgroundSessionRestorationGate(isForeground: { false }, eventTracker: tracker)
            var restored = 0, completed = 0
            gate.registerRestore("cold") { restored += 1 }
            try self.check(restored == 0 && !gate.canRestore("cold"), "Cold init must not attach a native session")
            gate.receive("cold") { completed += 1 }
            try self.check(restored == 1 && gate.canRestore("cold"), "Handler must be stored before permitted cold restore")
            let fresh = tracker.capture("cold")
            try self.check(fresh.token != nil && !gate.requiresInvalidation("cold"), "Fresh cold attach must not need cancellation")
            gate.finish(fresh.identifier, token: fresh.token)
            try self.check(completed == 1, "Matching fresh wave must finish its handler")
        }
        await run("processing_early_drain_late_handler_requires_new_barrier") { _ in
            let tracker = BackgroundSessionEventTracker()
            let gate = BackgroundSessionRestorationGate(isForeground: { false }, eventTracker: tracker)
            var restored = 0, completed = 0
            gate.registerRestore("processing") { restored += 1 }
            let parent = gate.beginProcessing(isCancelled: { false })
            try self.check(restored == 1, "A real processing parent may restore unfinished native work")
            let old = tracker.capture("processing") // Delegate entered before UIKit, actor consumption delayed.
            gate.endProcessing(parent)
            gate.receive("processing") { completed += 1 }
            try self.check(old.token == nil && gate.requiresInvalidation("processing"), "Ingress must preserve the unclaimed old wave")
            gate.finish(old.identifier, token: old.token)
            try self.check(completed == 0, "Delayed old drain cannot finish a later handler")
            let barrier = gate.beginHandoff("processing")
            let misleading = tracker.capture("processing")
            gate.finish(misleading.identifier, token: misleading.token)
            gate.completeHandoff("processing", token: UUID())
            try self.check(completed == 0, "Ordinary drains and unrelated barrier tokens cannot release hold")
            gate.completeHandoff("processing", token: barrier)
            try self.check(completed == 1 && !gate.requiresInvalidation("processing"), "Only exact invalidation barrier clears ambiguity")
        }
        await run("old_bound_token_cannot_finish_next_wave") { _ in
            let tracker = BackgroundSessionEventTracker()
            let gate = BackgroundSessionRestorationGate(isForeground: { true }, eventTracker: tracker)
            var completed = 0
            gate.receive("reused") { completed += 1 }
            let previous = tracker.capture("reused")
            gate.finish(previous.identifier, token: previous.token)
            gate.receive("reused") { completed += 1 }
            gate.finish(previous.identifier, token: previous.token)
            try self.check(completed == 1 && gate.requiresInvalidation("reused"), "An old claimed drain must not satisfy a new wave")
            let token = gate.beginHandoff("reused")
            gate.completeHandoff("reused", token: token)
            try self.check(completed == 2, "New wave completes after its own barrier")
        }
        await run("unknown_waits_for_registry_and_duplicate_handlers_are_retained") { _ in
            let tracker = BackgroundSessionEventTracker()
            let gate = BackgroundSessionRestorationGate(isForeground: { false }, eventTracker: tracker)
            var unknown: [String] = [], completed = 0, restores = 0
            gate.restoreUnknown = { unknown.append($0) }
            gate.receive("receiver") { completed += 1 }
            gate.receive("receiver") { completed += 1 }
            gate.registerRestore("drive") { restores += 1 }
            try self.check(unknown.isEmpty, "Drive registration alone must not discard an unloaded receiver")
            gate.registerRestore("receiver") { restores += 1 }
            gate.finishRegistration()
            try self.check(unknown.isEmpty && restores >= 1, "Known receiver must be resolved before unknown cancellation")
            let event = tracker.capture("receiver")
            gate.finish(event.identifier, token: event.token)
            gate.finish(event.identifier, token: event.token)
            try self.check(completed == 2, "All duplicate UIKit handlers complete once")
            gate.receive("retired") {}
            try self.check(unknown == ["retired"], "Only a truly unknown exact identifier is discarded")
        }
        await run("processing_permission_expires_and_cancellation_is_live") { _ in
            var time: TimeInterval = 0, foreground = false
            let cancelled = SyntheticDeliveryLease()
            let gate = BackgroundSessionRestorationGate(isForeground: { foreground }, now: { time },
                eventTracker: BackgroundSessionEventTracker())
            let first = gate.beginProcessing(isCancelled: { !cancelled.hasTimeRemaining })
            try self.check(gate.canRestore("id"), "Live processing token permits recovery")
            cancelled.end()
            try self.check(!gate.canRestore("id"), "Cancellation predicate must close permission immediately")
            gate.endProcessing(first)
            _ = gate.beginProcessing(isCancelled: { false })
            time = 121
            try self.check(!gate.canRestore("id"), "Processing restoration permission is bounded")
            foreground = true
            try self.check(gate.canRestore("id"), "Actual foreground remains a restoration opportunity")
        }
        await run("receiver_cold_attach_waits_for_handler_then_preserves_running_task") { f in
            let gate = BackgroundSessionRestorationGate(isForeground: { false })
            let payload = self.payload("cold-receiver-gate")
            let manifest = try f.addRecording(0)
            let worker = try f.isolatedWorker(payload, restorationGate: gate, beginExecution: { _ in nil })
            worker.discover(manifests: [manifest], receivedSegmentIDs: [manifest.id])
            try await self.settle()
            try self.check(f.factory.all.isEmpty, "Cold store init/discovery must not create native session early")
            let pairing = try f.pairing(payload.receiverID)
            let identifier = AutomaticReceiverClient.sessionIdentifier(for: pairing.credentials.scope)
            var completed = 0
            gate.receive(identifier) { completed += 1 }
            try await self.eventually("cold native upload", { f.factory.all.first?.uploads.count == 1 })
            let transport = f.factory.all[0]
            try self.check(transport.cancellationCount == 0 && completed == 0, "Normal handler must retain a valid running native task")
            transport.acknowledge(transport.uploads[0], recordingID: manifest.id)
            transport.finishEvents()
            try await self.eventually("normal native completion", { completed == 1 })
            try self.check(transport.cancellationCount == 0 && worker.deliveredCount == 1,
                           "Receipt must persist before fresh wave completion, without cancellation")
            worker.retire()
        }
        await run("receiver_early_drain_late_handler_waits_for_native_invalidation") { f in
            var foreground = true
            let gate = BackgroundSessionRestorationGate(isForeground: { foreground })
            let payload = self.payload("late-receiver-gate")
            let manifest = try f.addRecording(0)
            let worker = try f.isolatedWorker(payload, restorationGate: gate, beginExecution: { _ in nil })
            worker.discover(manifests: [manifest], receivedSegmentIDs: [manifest.id])
            try await self.eventually("initial native upload", { f.factory.all.first?.uploads.count == 1 })
            let transport = f.factory.all[0]
            let delivery = transport.uploads[0].id
            transport.holdInvalidation = true
            transport.finishEvents() // capture nil before UIKit, even if MainActor delivery is later.
            foreground = false
            var completed = 0
            gate.receive(transport.identifier) { completed += 1 }
            try await self.eventually("exact native cancellation", { transport.cancellationCount == 1 })
            try self.check(completed == 0 && f.factory.all.count == 1, "Old drain cannot bypass held native invalidation")
            transport.acknowledge(transport.uploads[0], recordingID: manifest.id)
            transport.releaseInvalidation()
            try await self.eventually("late barrier completion", { completed == 1 })
            try self.check(worker.deliveredCount == 1 && (try f.ledger(payload.receiverID).job(for: delivery)?.receipt) != nil,
                           "Authorized receipt remains durable even when its event belongs to old wave")
            try self.check(f.factory.all.count == 2 && f.factory.all[1].identifier == transport.identifier,
                           "Barrier must restore the same durable scope, without new grant or delivery identity")
            worker.retire()
        }
        await run("receiver_pause_during_handoff_does_not_recreate_transport") { f in
            let gate = BackgroundSessionRestorationGate(isForeground: { true })
            let payload = self.payload("paused-receiver-gate")
            let worker = try f.isolatedWorker(payload, restorationGate: gate, beginExecution: { _ in nil })
            try await self.eventually("native initial restore", { f.factory.all.count == 1 })
            let old = f.factory.all[0]
            old.holdInvalidation = true
            old.finishEvents()
            var completed = 0
            gate.receive(old.identifier) { completed += 1 }
            try await self.eventually("handoff entered", { old.cancellationCount >= 1 })
            worker.setEnabled(false)
            old.releaseInvalidation()
            try await self.eventually("paused handoff completion", { completed == 1 })
            try self.check(!worker.isEnabled && f.factory.all.count == 1, "Pause must prevent replacement or new upload")
            try self.check(try f.vault.loadAll().count == 1, "Handoff/pause must retain pairing credentials")
            worker.retire()
        }
        await run("receiver_retire_during_handoff_keeps_single_native_owner") { f in
            let gate = BackgroundSessionRestorationGate(isForeground: { true })
            var unknown = 0, completed = 0
            gate.restoreUnknown = { _ in unknown += 1 }
            let payload = self.payload("retire-receiver-gate")
            let worker = try f.isolatedWorker(payload, restorationGate: gate, beginExecution: { _ in nil })
            gate.finishRegistration()
            try await self.eventually("native owner ready", { f.factory.all.count == 1 })
            let old = f.factory.all[0]
            old.holdInvalidation = true
            gate.receive(old.identifier) { completed += 1 }
            worker.retire()
            try await self.eventually("retired owner invalidating", { old.cancellationCount >= 1 })
            try self.check(unknown == 0 && f.factory.all.count == 1 && completed == 0,
                           "Retire must not create an unknown second native owner or release its handler early")
            old.releaseInvalidation()
            try await self.eventually("retired handler completes", { completed == 1 })
            try await self.settle()
            try self.check(unknown == 0 && f.factory.all.count == 1 && !worker.isPaired,
                           "Retired scope must drain once, unregister after completion, and never reconnect")
        }
        await run("native_invalidation_barrier_waits_for_ordered_local_persistence") { _ in
            let drain = AutomaticReceiverEventDrain()
            let barrier = AutomaticReceiverInvalidationBarrier()
            let held = DeliveryLeaseGate()
            let observed = SyntheticDeliveryLease()
            drain.append { _ = await held.acquire() }
            drain.append { barrier.complete() }
            barrier.request {}
            let waiter = Task { await barrier.wait(); observed.end() }
            try await self.eventually("local completion held", { held.count == 1 })
            try self.check(observed.endCount == 0, "Native invalidation cannot skip a previous async persistence callback")
            held.release(SyntheticDeliveryLease())
            await waiter.value
            try self.check(observed.endCount == 1, "Drain releases after prior persistence finishes")
            var uploadRejected = false
            do { try barrier.whileActive {} } catch { uploadRejected = true }
            try self.check(uploadRejected, "An invalidated native client must reject further task creation")
            let unexpectedlyInvalidated = AutomaticReceiverInvalidationBarrier()
            unexpectedlyInvalidated.complete()
            var rejectedAfterDelegate = false
            do { try unexpectedlyInvalidated.whileActive {} } catch { rejectedAfterDelegate = true }
            try self.check(rejectedAfterDelegate, "Delegate invalidation itself must fence new task creation")
        }
    }
}
