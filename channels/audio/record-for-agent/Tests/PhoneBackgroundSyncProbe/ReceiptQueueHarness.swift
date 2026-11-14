import Foundation
import RecordingCore

extension Fixture {
    func receiptHistory(_ count: Int) throws -> [SegmentManifest] {
        try (1...count).map { sequence in
            let manifest = try seal(sequence)
            _ = try phone.acceptIncomingFile(at: watch.audioURL(for: manifest), manifest: manifest)
            return manifest
        }
    }

    func remainingReplayIDs() throws -> [UUID] {
        try TransportCodec.decode([UUID].self,
            from: Data(contentsOf: phone.root.appendingPathComponent("receipt-replay-pending.json")))
    }

    @discardableResult func finishReceiptTransfer(error: Error? = nil) throws -> SegmentReceipt {
        guard let transfer = session.removeReceiptTransfer(),
              let data = transfer.userInfo[TransportCodec.receiptKey] as? Data else {
            throw ProbeFailure.failed("Expected a synthetic native receipt transfer")
        }
        let receipt = try TransportCodec.decode(SegmentReceipt.self, from: data)
        connectivity.session(session, didFinish: transfer, error: error)
        _ = connectivity.currentState()
        return receipt
    }
}

extension Probe {
    func runReceiptQueueScenarios() async {
        let discoveryWrites = Locked(0)
        await run("receipt_queue_discovery_cooldown_survives_restart_without_blocking_fresh_or_targeted_ack", fault: { point in
            if case .afterReceiptWriteBeforeSync = point { discoveryWrites.access { $0 += 1 } }
        }) { f in
            let historical = try f.receiptHistory(2)
            f.begin()
            try await eventually("initial history sweep finishes") { f.callbacks.current.count == 1 }
            while !f.session.receipts.isEmpty { try f.finishReceiptTransfer() }
            let writes = discoveryWrites.current
            try f.restart()
            f.begin()
            try await eventually("restarted automatic grant finishes") { f.callbacks.current.count == 2 }
            try check(f.session.receipts.isEmpty, "A connection or process restart must not requeue the entire old library inside the discovery cooldown.")
            try check(discoveryWrites.current == writes, "Debounce must avoid source verification and receipt persistence, not just suppress native delivery afterwards.")
            let incoming = try f.seal(30)
            try f.deliver(incoming)
            try await eventually("fresh receipt bypasses historical discovery debounce") {
                f.session.receipts.contains { $0.segmentID == incoming.id }
            }
            let request = try TargetedReceiptRequest(manifest: historical[0])
            f.connectivity.session(f.session, didReceiveUserInfo: [TransportCodec.targetedReceiptRequestKey: try TransportCodec.encode(request)])
            try await eventually("an exact Watch request bypasses discovery debounce") {
                f.session.receipts.contains { $0.segmentID == request.segmentID }
            }
            try check(!f.session.receipts.contains { $0.segmentID == historical[1].id },
                      "Targeted recovery must not pull an unrelated historical receipt into the native queue.")
        }
        await run("receipt_queue_discovery_corrupt_hint_never_disables_recovery") { f in
            _ = try f.receiptHistory(1)
            try Data("invalid scheduling hint".utf8).write(to: f.phone.root.appendingPathComponent("receipt-replay-discovery.json"))
            try f.restart()
            f.begin()
            try await eventually("invalid hint permits real durable recovery") { f.callbacks.current.count == 1 }
            try check(f.session.receipts.count == 1, "Corrupt scheduling metadata must never become ACK authority or permanently block history.")
        }
        await run("receipt_queue_discovery_cooldown_expiry_and_explicit_watch_recovery") { f in
            _ = try f.receiptHistory(1)
            f.begin()
            try await eventually("first sweep completes") { f.callbacks.current.count == 1 }
            while !f.session.receipts.isEmpty { try f.finishReceiptTransfer() }
            let hint = f.phone.root.appendingPathComponent("receipt-replay-discovery.json")
            try TransportCodec.encode(Date().addingTimeInterval(-301)).write(to: hint, options: .atomic)
            try f.restart()
            f.begin()
            try await eventually("elapsed cooldown permits a fresh sweep") { f.callbacks.current.count == 2 }
            try check(f.session.receipts.count == 1, "Automatic historical recovery remains available after five minutes.")
            while !f.session.receipts.isEmpty { try f.finishReceiptTransfer() }
            try f.restart()
            f.connectivity.session(f.session, didReceiveUserInfo: [TransportCodec.requestSyncKey: true])
            try await eventually("explicit legacy Watch recovery bypasses the persisted hint") { f.session.receipts.count == 1 }
        }
        await run("receipt_queue_exact_request_does_not_start_a_library_sweep") { f in
            let historical = try f.receiptHistory(3)
            let exact = historical[1]
            f.connectivity.session(f.session, didReceiveUserInfo: [TransportCodec.requestSyncKey: true,
                TransportCodec.targetedReceiptRequestKey: try TransportCodec.encode(TargetedReceiptRequest(manifest: exact))])
            try await eventually("only the exact receipt is verified and the grant completes") {
                try f.phone.events().contains { $0.kind == "phone.background_sync_finished" }
            }
            try check(f.session.receipts.map(\.segmentID) == [exact.id],
                "An exact request with the legacy bit must not queue any other receipt.")
            let pending = f.phone.root.appendingPathComponent("receipt-replay-pending.json")
            let discovery = f.phone.root.appendingPathComponent("receipt-replay-discovery.json")
            try check(!FileManager.default.fileExists(atPath: pending.path)
                && !FileManager.default.fileExists(atPath: discovery.path),
                "An exact request cannot seed a future full sweep even when discovery would be eligible.")
        }
        await runP57ReceiptQueueScenarios()
        let handoffCompanion = Locked<WCSession?>(nil)
        let loseCompanionAtReceiptCommit = Locked(false)
        await run("receipt_queue_unavailable_after_verification_preserves_durable_head_and_cursor_across_restart",
                  fault: { point in
                      if case .afterReceiptWriteBeforeSync = point, loseCompanionAtReceiptCommit.current {
                          handoffCompanion.current?.isWatchAppInstalled = false
                      }
                  }) { f in
            _ = try f.receiptHistory(3)
            handoffCompanion.access { $0 = f.session }
            loseCompanionAtReceiptCommit.access { $0 = true }
            let expected = ReceiptReplayPolicy.orderedIDs(try f.phone.receiptIDsForReplay(), after: nil)
            f.begin()
            try await eventually("companion disappears between verification and native handoff") { f.callbacks.current.count == 1 }
            try check(f.session.receipts.isEmpty, "Verified bytes alone cannot count as an enqueued receipt.")
            try check(try f.remainingReplayIDs() == expected, "Unavailable native handoff retains the exact first item and all remaining IDs.")
            let cursorURL = f.phone.root.appendingPathComponent("receipt-replay-cursor.json")
            try check(!FileManager.default.fileExists(atPath: cursorURL.path), "No successful handoff means no durable replay cursor advance.")
            let pending = try Data(contentsOf: f.phone.root.appendingPathComponent("receipt-replay-pending.json"))
            try f.restart()
            f.begin()
            try await eventually("restart with unavailable companion yields") { f.callbacks.current.count == 2 }
            try check(try Data(contentsOf: f.phone.root.appendingPathComponent("receipt-replay-pending.json")) == pending,
                      "Unavailable restart must preserve pending state byte for byte.")
            loseCompanionAtReceiptCommit.access { $0 = false }
            f.session.isWatchAppInstalled = true
            f.begin()
            try await eventually("a later real grant resumes the exact durable head") { f.callbacks.current.count == 3 }
            try check(f.session.receipts.map(\.segmentID) == expected, "Recovery cannot skip the previously verified but unsent head.")
            try check(try f.remainingReplayIDs().isEmpty, "Only successful native ownership commits the replay tail.")
            try check(try TransportCodec.decode(UUID.self, from: Data(contentsOf: cursorURL)) == expected.last,
                      "The durable cursor follows the actual successful handoffs.")
        }
        loseCompanionAtReceiptCommit.access { $0 = false }
        await run("receipt_queue_targeted_unavailable_after_verification_survives_restart_until_handoff",
                  fault: { point in
                      if case .afterReceiptWriteBeforeSync = point, loseCompanionAtReceiptCommit.current {
                          handoffCompanion.current?.isWatchAppInstalled = false
                      }
                  }) { f in
            let value = try f.receiptHistory(1)[0]
            handoffCompanion.access { $0 = f.session }
            loseCompanionAtReceiptCommit.access { $0 = true }
            let request = try TargetedReceiptRequest(manifest: value)
            f.connectivity.session(f.session, didReceiveUserInfo: [TransportCodec.targetedReceiptRequestKey: try TransportCodec.encode(request)])
            let pendingURL = f.phone.root.appendingPathComponent("targeted-receipt-pending.json")
            try await eventually("targeted verification reaches unavailable native handoff") {
                try f.connectivity.probeReadOnWork {
                    let events = try f.phone.events()
                    return !f.session.isWatchAppInstalled && events.contains { $0.kind == "phone.targeted_receipt_deferred" }
                }
            }
            let pending = try Data(contentsOf: pendingURL)
            try check(try TransportCodec.decode([TargetedReceiptRequest].self, from: pending) == [request],
                      "A verified targeted request remains durable until native ownership succeeds.")
            try check(f.session.receipts.isEmpty, "No receipt was enqueued while the companion was unavailable.")
            try f.restart()
            f.begin()
            try await eventually("unavailable targeted restart yields") { f.callbacks.current.count == 1 }
            try check(try Data(contentsOf: pendingURL) == pending, "Restart cannot discard the unsent exact target.")
            loseCompanionAtReceiptCommit.access { $0 = false }
            f.session.isWatchAppInstalled = true
            f.begin()
            try await eventually("targeted recovery commits the same handoff") { f.callbacks.current.count == 2 }
            try check(f.session.receipts.filter { request.matches($0) }.count == 1, "Recovery queues exactly one matching receipt.")
            try check(try TransportCodec.decode([TargetedReceiptRequest].self, from: Data(contentsOf: pendingURL)).isEmpty,
                      "The targeted queue advances only after the successful native handoff.")
        }
        loseCompanionAtReceiptCommit.access { $0 = false }
        let receiptWrites = Locked(0)
        await run("receipt_queue_history_is_bounded_across_grants_without_rehashing",
                  fault: { point in
                      if case .afterReceiptWriteBeforeSync = point { receiptWrites.access { $0 += 1 } }
                  }) { f in
            _ = try f.receiptHistory(12)
            f.begin()
            try await eventually("history fills only eight native receipt slots") { f.callbacks.current.count == 1 }
            try check(f.session.receipts.count == 8, "One finite pass may enqueue only eight historical ACKs.")
            try check(try f.remainingReplayIDs().count == 4, "The unsent tail must stay durable.")
            let writes = receiptWrites.current
            let cursor = try Data(contentsOf: f.phone.root.appendingPathComponent("receipt-replay-cursor.json"))
            for expected in 2...4 {
                f.begin()
                try await eventually("full native receipt queue yields") { f.callbacks.current.count == expected }
            }
            try check(f.session.receipts.count == 8, "Repeated grants cannot append the full old library behind native work.")
            try check(receiptWrites.current == writes, "Backpressure must be checked before any historical source verification.")
            try check(try f.remainingReplayIDs().count == 4, "Backpressure cannot consume pending IDs.")
            try check(try Data(contentsOf: f.phone.root.appendingPathComponent("receipt-replay-cursor.json")) == cursor,
                      "Backpressure cannot move the durable cursor.")
            try check(f.maintenanceResults.current.allSatisfy { $0.succeeded && $0.needsMore },
                      "Native backpressure is successful bounded work with a retained tail, not data failure.")
        }
        await run("receipt_queue_unrelated_and_oversized_user_info_never_uses_ack_capacity") { f in
            _ = try f.receiptHistory(1)
            for index in 0..<24 { f.session.transferUserInfo(["unrelated": index]) }
            f.session.transferUserInfo([TransportCodec.receiptKey: Data(repeating: 0, count: 4_097)])
            f.session.transferUserInfo([TransportCodec.receiptKey: Data("invalid".utf8)])
            f.begin()
            try await eventually("unrelated traffic does not block the historical ACK") { f.callbacks.current.count == 1 }
            try check(f.session.receipts.count == 1, "Only a small typed receipt consumes ACK queue capacity.")
            try check(try f.remainingReplayIDs().isEmpty, "Non-receipt traffic must not starve a valid source.")
        }
        await run("receipt_queue_new_and_targeted_ack_bypass_history_backpressure_idempotently") { f in
            _ = try f.receiptHistory(10)
            f.begin()
            try await eventually("historical queue is full") { f.callbacks.current.count == 1 }
            let incoming = try f.seal(30)
            try f.deliver(incoming)
            try await eventually("new arrival gets its durable ACK despite old queue") {
                f.session.receipts.contains { $0.segmentID == incoming.id }
            }
            try f.deliver(incoming)
            try await eventually("duplicate incoming delivery is committed") { try f.inbox.pendingIDs().isEmpty }
            try check(f.session.receipts.filter { $0.segmentID == incoming.id }.count == 1,
                      "A fresh ACK keeps native deduplication when the same source arrives twice.")
            let requestedID = try f.remainingReplayIDs().first!
            let requested = try f.phone.manifest(id: requestedID)
            let payload: [String: Any] = [TransportCodec.targetedReceiptRequestKey:
                try TransportCodec.encode(TargetedReceiptRequest(manifest: requested))]
            f.connectivity.session(f.session, didReceiveUserInfo: payload)
            try await eventually("exact target gets its ACK despite old queue") {
                f.session.receipts.contains { $0.segmentID == requestedID }
            }
            f.connectivity.session(f.session, didReceiveUserInfo: payload)
            _ = f.connectivity.currentState()
            try await Task.sleep(nanoseconds: 250_000_000)
            try check(f.session.receipts.filter { $0.segmentID == requestedID }.count == 1,
                      "Targeted retries may verify but cannot duplicate an already queued exact receipt.")
            try check(f.session.receipts.count == 10, "Only the fresh and exact-target ACKs bypass the eight historical slots.")
        }
        await run("receipt_queue_native_completion_refills_saved_tail_without_foreground_or_empty_loop") { f in
            _ = try f.receiptHistory(10)
            let enqueued = Locked<[UUID]>([])
            f.session.onReceipt = { receipt in enqueued.access { $0.append(receipt.segmentID) } }
            f.begin()
            try await eventually("first finite pass completes") { f.callbacks.current.count == 1 }
            for expected in [1, 0] {
                try f.finishReceiptTransfer()
                try await eventually("native completion advances only saved tail") {
                    try f.remainingReplayIDs().count == expected
                }
            }
            try check(f.session.receipts.count == 8, "A completed native receipt releases one historical slot.")
            try check(enqueued.current.count == 10 && Set(enqueued.current).count == 10,
                      "Callback continuation must finish the original sweep once without replaying completed IDs.")
            let leases = f.lease.beginCount
            while !f.session.receipts.isEmpty { try f.finishReceiptTransfer() }
            try await Task.sleep(nanoseconds: 350_000_000)
            try check(f.session.receipts.isEmpty && enqueued.current.count == 10,
                      "Draining the final ACKs must not rebuild the entire historical sweep.")
            try check(f.lease.beginCount == leases, "An empty saved tail must not acquire callback-driven leases.")
        }
        await run("receipt_queue_failed_completion_retains_tail_for_system_retry_without_tight_loop") { f in
            _ = try f.receiptHistory(10)
            f.begin()
            try await eventually("bounded history pass completes") { f.callbacks.current.count == 1 }
            let leases = f.lease.beginCount, requests = f.maintenanceRequests.current
            try f.finishReceiptTransfer(error: NSError(domain: "WCErrorDomain", code: 7_007))
            try await Task.sleep(nanoseconds: 350_000_000)
            try check(f.lease.beginCount == leases && f.session.receipts.count == 7,
                      "A failed callback must not immediately restart the failed native wave.")
            try check(try f.remainingReplayIDs().count == 2, "Failure cannot consume an unverified tail item.")
            try check(f.maintenanceRequests.current > requests, "Failure must retain an existing system retry opportunity.")
            f.begin()
            try await eventually("later system grant uses released capacity") { f.callbacks.current.count == 2 }
            try check(f.session.receipts.count == 8 && (try f.remainingReplayIDs().count) == 1,
                      "A later finite grant may continue without a foreground transition.")
        }
        await run("receipt_queue_callback_after_history_allowance_keeps_one_real_continuation") { f in
            _ = try f.receiptHistory(10)
            let enqueued = Locked<[UUID]>([])
            f.session.onReceipt = { receipt in
                let count = enqueued.access { values -> Int in values.append(receipt.segmentID); return values.count }
                // This callback is delivered after the eighth attempt consumed
                // this lease's allowance, before its delayed finish step runs.
                if count == 8, let transfer = f.session.removeReceiptTransfer() {
                    f.connectivity.session(f.session, didFinish: transfer, error: nil)
                }
            }
            f.begin()
            try await eventually("spent history allowance finishes its original parent") { f.callbacks.current.count == 1 }
            try await eventually("native completion wake survives the old lease's completion") {
                let remaining = try f.remainingReplayIDs().count
                return enqueued.current.count == 9 && remaining == 1
            }
            try check(f.session.receipts.count == 8 && f.lease.beginCount == 2,
                      "One native completion may open one finite continuation, not reset the old lease's allowance.")
            try await Task.sleep(nanoseconds: 350_000_000)
            try check(f.lease.beginCount == 2 && enqueued.current.count == 9,
                      "Without another native completion a full queue cannot renew itself.")
        }
        await run("receipt_queue_expired_callback_lease_cannot_consume_tail_or_cancel_new_generation") { f in
            _ = try f.receiptHistory(10)
            let enqueued = Locked<[UUID]>([])
            f.session.onReceipt = { receipt in enqueued.access { $0.append(receipt.segmentID) } }
            f.begin()
            try await eventually("initial queue is parked") { f.callbacks.current.count == 1 }
            f.lease.state.access { $0.hold = true }
            try f.finishReceiptTransfer()
            try await eventually("callback continuation waits for its lease") { f.lease.beginCount == 2 }
            f.connectivity.expireBackgroundMaintenance()
            _ = f.connectivity.currentState()
            f.lease.release()
            _ = f.connectivity.currentState()
            try check(try f.remainingReplayIDs().count == 2 && enqueued.current.count == 8,
                      "An expired pending grant cannot consume the sweep when its stale completion arrives.")
            try f.finishReceiptTransfer()
            try await eventually("a fresh callback can continue after expiry") {
                try f.remainingReplayIDs().isEmpty
            }
            try check(enqueued.current.count == 10 && Set(enqueued.current).count == 10,
                      "The new generation may use the two real released slots within its finite allowance.")
        }
        await run("receipt_queue_backpressure_and_native_callback_continue_same_sweep_after_restart") { f in
            _ = try f.receiptHistory(10)
            f.begin()
            try await eventually("first process captures a durable tail") { f.callbacks.current.count == 1 }
            let pending = try f.remainingReplayIDs()
            try f.restart()
            f.begin()
            try await eventually("restarted process respects existing native queue") { f.callbacks.current.count == 2 }
            try check(try f.remainingReplayIDs() == pending && f.session.receipts.count == 8,
                      "Restart cannot replace pending IDs or bypass the native receipt bound.")
            try f.finishReceiptTransfer()
            try await eventually("restarted receiver resumes automatically from callback") {
                try f.remainingReplayIDs().count == 1
            }
            try check(f.session.receipts.count == 8, "Restored callback continuation replaces only one released native slot.")
            try check(try f.remainingReplayIDs() == Array(pending.dropFirst()),
                      "Restart continuation must use the persisted tail rather than enumerate a fresh sweep.")
        }
    }
}

extension Probe {
    func runP57ReceiptQueueScenarios() async {
        for unavailable in ["not_activated", "not_paired", "not_installed"] {
            await run("p57_incoming_" + unavailable + "_persists_same_receipt_across_restart_and_file_callback") { f in
                switch unavailable {
                case "not_activated": f.session.activationState = .notActivated
                case "not_paired": f.session.isPaired = false
                default: f.session.isWatchAppInstalled = false
                }
                let original = try f.seal(101)
                let enqueued = Locked<[SegmentReceipt]>([])
                f.session.onReceipt = { receipt in enqueued.access { $0.append(receipt) } }
                try f.deliver(original)
                try await eventually("unavailable incoming file is durably received") {
                    try f.inbox.pendingIDs().isEmpty && f.phone.receipts().count == 1
                        && f.phone.events().contains { $0.kind == "phone.background_sync_finished" }
                }
                try check(enqueued.current.isEmpty, "Unavailable WCSession cannot own an ACK.")
                try check(try f.remainingReplayIDs() == [original.id],
                    "Completing the incoming inbox must first retain the exact unsent segment in durable replay state.")
                let receipt = try f.phone.receipts()[0]
                let pending = try Data(contentsOf: f.phone.root.appendingPathComponent("receipt-replay-pending.json"))
                try f.restart()
                f.begin()
                try await eventually("unavailable restart finishes a bounded grant") { f.maintenanceResults.current.count == 1 }
                try check(try Data(contentsOf: f.phone.root.appendingPathComponent("receipt-replay-pending.json")) == pending,
                    "Process reconstruction must preserve the unavailable incoming ACK queue byte for byte.")
                try check(f.maintenanceResults.current[0].succeeded && f.maintenanceResults.current[0].needsMore,
                    "Unavailable transport is successful bounded work with a pending receipt.")
                f.session.activationState = .activated
                f.session.isPaired = true
                f.session.isWatchAppInstalled = true
                let wake = try f.seal(102)
                try f.deliver(wake) // file_received requests includeReceipts: false.
                try await eventually("a later incoming callback resumes the durable ACK") {
                    try enqueued.current.contains(receipt) && f.remainingReplayIDs().isEmpty
                }
                try check(enqueued.current.filter { $0.segmentID == original.id } == [receipt],
                    "Recovery must hand off the same segmentID, checksum, byte count and receipt timestamp exactly once.")
                try f.deliver(original)
                f.begin()
                try await eventually("duplicate arrival and replay finish") { f.maintenanceResults.current.count == 2 }
                try check(enqueued.current.filter { $0.segmentID == original.id } == [receipt],
                    "An already queued exact ACK cannot be handed to native transport again.")
                try check(try f.inbox.pendingIDs().isEmpty && f.remainingReplayIDs().isEmpty,
                    "Successful native ownership clears durable retry work, including duplicate arrivals.")
            }
        }

        for queue in ["targeted", "replay"] {
            await run("p57_" + queue + "_unverified_head_keeps_budget_and_native_continuation_successful") { f in
                let healthy = try f.receiptHistory(9)
                let badID = UUID()
                let pendingURL = f.phone.root.appendingPathComponent("receipt-replay-pending.json")
                if queue == "targeted" {
                    let request = try TargetedReceiptRequest(segmentID: badID,
                        sha256: String(repeating: "a", count: 64), byteCount: 8_192)
                    try TransportCodec.encode([request]).write(to:
                        f.phone.root.appendingPathComponent("targeted-receipt-pending.json"))
                    try TransportCodec.encode(healthy.map(\.id)).write(to: pendingURL)
                } else {
                    // The invalid JSON is synthetic metadata, never audio.
                    try Data("synthetic invalid receipt JSON".utf8).write(to: f.phone.root
                        .appendingPathComponent("receipts").appendingPathComponent(badID.uuidString.lowercased() + ".json"))
                    try TransportCodec.encode([badID] + healthy.map(\.id)).write(to: pendingURL)
                }
                try f.restart()
                let enqueued = Locked<[UUID]>([])
                f.session.onReceipt = { receipt in
                    let count = enqueued.access { values -> Int in values.append(receipt.segmentID); return values.count }
                    // The bad head spent one of eight verification attempts.
                    // Native completion arrives after the seventh good handoff
                    // exhausted that lease, before its finishing step runs.
                    if count == 7, let transfer = f.session.removeReceiptTransfer() {
                        f.connectivity.session(f.session, didFinish: transfer, error: nil)
                    }
                }
                f.begin()
                try await eventually("bad-head parent lease completes") { f.maintenanceResults.current.count == 1 }
                try check(f.maintenanceResults.current[0].succeeded && f.maintenanceResults.current[0].needsMore,
                    "An unverified entry is a rejected ACK, not a failed background maintenance round.")
                try await eventually("native completion continues the healthy saved tail") {
                    try enqueued.current.count == 9 && f.remainingReplayIDs().isEmpty
                }
                try await eventually("continuation finishes before the next synthetic fixture") {
                    try f.phone.events().filter { $0.kind == "phone.background_sync_finished" }.count == 2
                }
                try check(enqueued.current == healthy.map(\.id) && Set(enqueued.current).count == 9,
                    "Every healthy pending source must receive one handoff, with no ACK for the unverified head.")
                try check(f.lease.beginCount == 2 && f.session.receipts.count == 8,
                    "The exhausted finite lease must use exactly one real native continuation.")
                let events = try f.phone.events()
                let kind = queue == "targeted" ? "phone.targeted_receipt_unavailable" : "phone.ack_replay_unavailable"
                let rejected = events.filter { $0.kind == kind }
                try check(rejected.count == 1 && rejected[0].detail.contains("reason=")
                    && rejected[0].detail.count < 160 && !rejected[0].detail.contains("synthetic invalid"),
                    "The rejected entry must produce one bounded diagnostic code without raw decoder details.")
                let finished = events.filter { $0.kind == "phone.background_sync_finished" }
                try check(finished.first?.detail.contains("completed=true") == true,
                    "The real maintenance result feeding BGTask must remain successful despite the bad head.")
                try check(finished.first?.detail.contains(queue == "targeted"
                    ? "historical_attempts=7 targeted_attempts=1" : "historical_attempts=8 targeted_attempts=0") == true,
                    "Rejected entries consume the same finite attempt budget as successful verification.")
            }
        }

        await run("p57_incoming_already_queued_clears_saved_pending_before_native_completion") { f in
            f.session.isWatchAppInstalled = false
            let manifest = try f.seal(104)
            try f.deliver(manifest)
            try await eventually("original unavailable receive saves its retry") {
                try f.connectivity.probeReadOnWork {
                    try f.phone.events().contains { $0.kind == "phone.background_sync_finished" }
                }
            }
            let receipt = try f.phone.receipts()[0]
            try check(try f.remainingReplayIDs() == [manifest.id], "The original receive must retain its exact unsent ID.")
            let enqueued = Locked<[SegmentReceipt]>([])
            f.session.onReceipt = { receipt in enqueued.access { $0.append(receipt) } }
            f.session.isWatchAppInstalled = true
            // Model native ownership surviving a process interruption before
            // the local pending checkpoint was cleared.
            f.session.transferUserInfo([TransportCodec.receiptKey: try TransportCodec.encode(receipt)])
            try f.deliver(manifest)
            try await eventually("duplicate incoming delivery clears its stale pending intent") {
                try f.connectivity.probeReadOnWork {
                    try f.inbox.pendingIDs().isEmpty && f.remainingReplayIDs().isEmpty
                        && f.phone.events().filter { $0.kind == "phone.background_sync_finished" }.count == 2
                }
            }
            try check(enqueued.current == [receipt], "Already queued receipt ownership cannot create another native handoff.")
            let leases = f.lease.beginCount
            try check(try f.finishReceiptTransfer() == receipt, "The original native receipt must complete unchanged.")
            try await Task.sleep(nanoseconds: 250_000_000)
            try check(enqueued.current == [receipt] && f.session.receipts.isEmpty && f.lease.beginCount == leases,
                "Native completion after pending cleanup cannot replay the already handed-off ACK.")
        }

        await run("p57_targeted_handoff_clears_same_incoming_replay_before_native_completion") { f in
            let manifest = try f.receiptHistory(1)[0]
            let receipt = try f.phone.receipts()[0]
            let request = try TargetedReceiptRequest(manifest: manifest)
            try TransportCodec.encode([manifest.id]).write(to: f.phone.root.appendingPathComponent("receipt-replay-pending.json"))
            try TransportCodec.encode([request]).write(to: f.phone.root.appendingPathComponent("targeted-receipt-pending.json"))
            try f.restart()
            let enqueued = Locked<[SegmentReceipt]>([])
            f.session.onReceipt = { receipt in
                enqueued.access { $0.append(receipt) }
                if let transfer = f.session.removeReceiptTransfer() {
                    f.connectivity.session(f.session, didFinish: transfer, error: nil)
                }
            }
            f.begin()
            try await eventually("targeted and incoming retry queues settle") { f.maintenanceResults.current.count == 1 }
            try check(f.maintenanceResults.current[0].succeeded && !f.maintenanceResults.current[0].needsMore,
                "One successful targeted handoff must satisfy the matching incoming replay intent.")
            try check(enqueued.current == [receipt] && f.session.receipts.isEmpty,
                "Immediate native completion cannot make the same receipt reappear from the other pending queue.")
            try check(try f.remainingReplayIDs().isEmpty
                && TransportCodec.decode([TargetedReceiptRequest].self, from: Data(contentsOf:
                    f.phone.root.appendingPathComponent("targeted-receipt-pending.json"))).isEmpty,
                "Both durable scheduling queues must clear the exact successfully handed-off receipt.")
            try check(f.lease.beginCount == 1, "A satisfied duplicate retry intent cannot open a receipt continuation lease.")
        }

        for queue in ["targeted", "replay"] {
            let failSync = Locked(false)
            await run("p57_" + queue + "_receipt_io_failure_stays_failed_and_preserves_head", fault: { point in
                if case .afterReceiptWriteBeforeSync = point, failSync.current {
                    throw RepositoryError.persistenceFailure("synthetic receipt synchronization failure")
                }
            }) { f in
                let manifest = try f.receiptHistory(1)[0]
                let request = try TargetedReceiptRequest(manifest: manifest)
                let pendingURL = f.phone.root.appendingPathComponent(queue == "targeted"
                    ? "targeted-receipt-pending.json" : "receipt-replay-pending.json")
                let pending = queue == "targeted" ? try TransportCodec.encode([request]) : try TransportCodec.encode([manifest.id])
                try pending.write(to: pendingURL)
                try f.restart()
                failSync.access { $0 = true }
                f.begin()
                try await eventually("receipt synchronization failure finishes") { f.maintenanceResults.current.count == 1 }
                try check(!f.maintenanceResults.current[0].succeeded && f.maintenanceResults.current[0].needsMore,
                    "A real persistence error must fail the maintenance round and retain retry work.")
                try check(f.session.receipts.isEmpty, "Failed receipt synchronization cannot authorize native ACK ownership.")
                try check(try Data(contentsOf: pendingURL) == pending,
                    "A temporary persistence error cannot discard the exact pending queue head.")
                failSync.access { $0 = false }
                f.begin()
                try await eventually("receipt synchronization recovers in a later grant") { f.maintenanceResults.current.count == 2 }
                try check(f.maintenanceResults.current[1].succeeded && f.session.receipts.map(\.segmentID) == [manifest.id],
                    "The retained request must recover to exactly one native ACK once persistence succeeds.")
            }
        }

        await run("p57_incoming_pending_queue_persistence_failure_keeps_inbox_for_retry") { f in
            let pendingURL = f.phone.root.appendingPathComponent("receipt-replay-pending.json")
            try FileManager.default.createDirectory(at: pendingURL, withIntermediateDirectories: true)
            f.session.isWatchAppInstalled = false
            f.lease.state.access { $0.hold = true }
            let manifest = try f.seal(103)
            try f.deliver(manifest)
            f.begin()
            try await eventually("incoming retry-state failure waits for its controlled lease") { f.lease.beginCount == 1 }
            f.lease.release()
            try await eventually("incoming retry-state persistence failure finishes") { f.maintenanceResults.current.count == 1 }
            try check(!f.maintenanceResults.current[0].succeeded && f.maintenanceResults.current[0].needsMore,
                "Failure to persist unsent ACK intent must fail the background round.")
            try check(f.session.receipts.isEmpty && (try f.inbox.pendingIDs().count) == 1,
                "The original staged incoming copy cannot be completed before retry state becomes durable.")
            try FileManager.default.removeItem(at: pendingURL)
            try f.restart()
            f.session.isWatchAppInstalled = true
            f.begin()
            try await eventually("retained inbox recovers after queue storage is repaired") { f.maintenanceResults.current.count == 2 }
            try check(f.maintenanceResults.current[1].succeeded && f.session.receipts.map(\.segmentID) == [manifest.id],
                "Recovery from the retained inbox must enqueue the original ACK exactly once.")
            try check(try f.inbox.pendingIDs().isEmpty, "Successful recovery can finally complete the original incoming copy.")
        }
    }
}
