import Foundation
import RecordingCore

extension Fixture {
    var transferProgressURL: URL {
        phone.root.appendingPathComponent("ConnectivityDiagnostics/background-sync.json")
    }
    func transferProgress() -> [String: Any]? {
        guard let bytes = try? Data(contentsOf: transferProgressURL), !bytes.isEmpty, bytes.count <= 8_192 else { return nil }
        return try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
    }
    func transferProgressCount(_ key: String) -> Int? { transferProgress()?[key] as? Int }
    func transferPhases() -> [String: Any]? {
        let url = phone.root.appendingPathComponent("ConnectivityDiagnostics/transfer-phases.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

extension Probe {
    func runTransferProgressScenarios() async {
        await run("transfer_progress_background_grant_retries_failed_activation_once") { f in
            let cancelled = PhoneBackgroundCancellation()
            cancelled.cancel()
            f.session.activationState = .notActivated
            f.connectivity.session(f.session, activationDidCompleteWith: .notActivated,
                error: NSError(domain: "WCErrorDomain", code: 7004))
            f.begin(cancelled)
            _ = f.connectivity.currentState()
            try check(f.session.activationCalls.current == 1,
                "A failed activation callback and a cancelled grant must not activate again.")
            f.begin()
            f.begin()
            _ = f.connectivity.currentState()
            try check(f.session.activationCalls.current == 2,
                "A live background grant retries the failure once while its activation is in flight.")
            f.session.activationState = .activated
            f.connectivity.session(f.session, activationDidCompleteWith: .activated, error: nil)
            f.connectivity.appDidBecomeActive()
            _ = f.connectivity.currentState()
            try check(f.session.activationCalls.current == 2,
                "An already activated session must not be activated again at foreground entry.")
            try await eventually("activation report shows failure, retry and success") {
                let report = f.transferProgress()?["wcActivation"] as? [String: Any]
                let counts = report?["counts"] as? [String: Int]
                return counts?["failed"] == 1 && counts?["retried"] == 1 && counts?["completed"] == 1
            }
        }
        await run("transfer_progress_system_pending_signal_is_not_a_file_or_an_ack") { f in
            f.session.hasContentPending = true
            f.connectivity.observeApplicationForeground(false)
            try await eventually("report records pending platform data while the app is in background") {
                let report = f.transferProgress()
                let pending = report?["wcPendingContent"] as? [String: Any]
                return pending?["isPending"] as? Bool == true && pending?["foreground"] as? Bool == false
                    && report?["lastWCPendingInBackgroundAtMS"] is Int64
            }
            let observed = f.transferProgress()?["lastWCPendingInBackgroundAtMS"] as? Int64
            f.session.hasContentPending = false
            f.connectivity.observeApplicationForeground(true)
            try await eventually("new observation does not erase prior pending-in-background time") {
                let report = f.transferProgress()
                let pending = report?["wcPendingContent"] as? [String: Any]
                return pending?["isPending"] as? Bool == false && pending?["foreground"] as? Bool == true
                    && report?["lastWCPendingInBackgroundAtMS"] as? Int64 == observed
            }
            try check(f.session.receipts.isEmpty && f.lease.beginCount == 0 && f.validator.calls.current.isEmpty,
                "Observing pending platform data cannot stage, verify or acknowledge a recording.")
        }
        await run("transfer_progress_callback_url_deleted_before_import_survives_restart") { f in
            f.connectivity.observeApplicationForeground(false)
            let manifest = try f.seal(1)
            let expectedBytes = try Data(contentsOf: f.watch.audioURL(for: manifest))
            let temporary = try f.temporaryFile(manifest)
            f.lease.state.access { $0.hold = true }
            try f.deliver(manifest, url: temporary)
            try await eventually("callback returned while import grant is held") { f.lease.beginCount == 1 }
            try check(!FileManager.default.fileExists(atPath: temporary.path)
                && (try f.inbox.pendingIDs().count) == 1,
                "The synthetic framework URL is already deleted; independent staged ownership must survive the callback boundary.")
            try check(f.session.receipts.isEmpty && f.validator.calls.current.isEmpty,
                "A staged file cannot fabricate a durable receipt before the import grant.")
            f.lease.release()
            try await eventually("persisted source and exact ACK after temporary URL expiry") {
                f.session.receipts.contains { $0.segmentID == manifest.id && $0.sha256 == manifest.sha256
                    && $0.byteCount == manifest.byteCount }
            }
            try f.restart()
            try check(try f.phone.manifest(id: manifest.id) == manifest
                && Data(contentsOf: f.phone.audioURL(for: manifest)) == expectedBytes,
                "Restart preserves the exact synthetic source after its framework URL has expired.")
            try check(try f.inbox.pendingIDs().isEmpty && f.phone.receipts().contains {
                $0.segmentID == manifest.id && $0.sha256 == manifest.sha256 && $0.byteCount == manifest.byteCount
            }, "Durable receipt identity survives restart independently of the disposed callback URL.")
        }
        await run("transfer_progress_diagnostic_replay_stays_bounded_and_preserves_legacy_journal") { f in
            let process = UUID(), first: Int64 = 1_800_000_000_000
            func observation(_ count: Int) -> RecordingEvent {
                let value = WatchTransferRefusalDiagnostic(reason: .nativeOccupied, observedAtMS: first,
                    generation: 1, foreground: false, liveCapture: true, nativeCount: 3,
                    processRunID: process, observationCount: count, lastObservedAtMS: first + Int64(count - 1) * 10_000)
                return RecordingEvent(kind: "watch.transfer_refusal", detail: value.detail()!)
            }
            let oldDiagnostic = observation(1)
            // Existing journals are evidence: upgrades must not migrate/delete them.
            try f.phone.appendEvent(oldDiagnostic)
            let capture = RecordingEvent(kind: "segment_sealed", detail: "sealed", sessionID: f.recordingSession.id)
            func deliver(_ events: [RecordingEvent]) throws {
                f.connectivity.session(f.session, didReceiveUserInfo: [TransportCodec.eventsKey: try TransportCodec.encode(events)])
                _ = f.connectivity.currentState()
            }
            try deliver([capture] + (1...360).map(observation))
            try await eventually("one aggregate preserves latest state") {
                let rows = f.transferPhases()?["watchEvents"] as? [[String: Any]] ?? []
                return rows.count == 1 && (rows.first?["refusal"] as? [String: Any])?["observationCount"] as? Int == 360
            }
            let before = try f.phone.events()
            try check(before.filter { $0.kind == "watch.transfer_refusal" }.map(\.id) == [oldDiagnostic.id],
                "New transfer observations must not create permanent files or delete the old journal evidence.")
            try check(before.filter { $0.id == capture.id }.count == 1, "Ordinary capture evidence remains durable.")
            try f.restart()
            let current = observation(360)
            let malformed = RecordingEvent(kind: "watch.transfer_refusal", detail: "PRIVATE_ERROR_PATH")
            let unknown = RecordingEvent(kind: "watch.transfer_future", detail: "PRIVATE_ERROR_PATH")
            try deliver(Array(repeating: current, count: 360) + [observation(2), capture, malformed, unknown])
            let events = try f.phone.events()
            try check(events.filter { $0.kind.hasPrefix("watch.transfer_") }.map(\.id) == [oldDiagnostic.id],
                "Restart replay, malformed, and unknown transfer diagnostics cannot grow the permanent journal.")
            try check(events.filter { $0.id == capture.id }.count == 1, "Capture replay retains stable-ID journal deduplication.")
            let rows = f.transferPhases()?["watchEvents"] as? [[String: Any]] ?? []
            try check(rows.count == 1 && (rows.first?["refusal"] as? [String: Any])?["observationCount"] as? Int == 360,
                "Restored aggregate cannot double count or regress after late replay.")
            let url = f.phone.root.appendingPathComponent("ConnectivityDiagnostics/transfer-phases.json")
            let bytes = try Data(contentsOf: url)
            try check(bytes.count <= PhoneTransferPhaseDiagnostics.maximumBytes
                && !String(decoding: bytes, as: UTF8.self).contains("PRIVATE_ERROR_PATH"),
                "Only strict fixed metadata enters the bounded projection.")
        }
        await run("transfer_progress_cold_background_file_supersedes_pending_main_lease") { f in
            f.connectivity.observeApplicationForeground(false)
            f.lease.state.access { $0.hold = true; $0.incomingBypassesHold = true }
            // Cold activation can ask for ordinary maintenance while MainActor
            // is still constructing optional cloud/derived stores.
            f.connectivity.session(f.session, activationDidCompleteWith: .activated, error: nil)
            try await eventually("activation lease is pending without a foreground transition") { f.lease.beginCount == 1 }
            let manifest = try f.seal(1)
            try f.deliver(manifest)
            try await eventually("actual native callback persists and queues ACK with main lease still held") {
                f.session.receipts.contains { $0.segmentID == manifest.id }
                    && f.transferProgressCount("newIncomingCount") == 1
            }
            try check(try f.inbox.pendingIDs().isEmpty && f.lease.beginCount == 2,
                "New native opportunity owns one import grant and consumes its staged file without foreground.")
            let calls = f.validator.calls.current.count
            f.lease.release()
            _ = f.connectivity.currentState()
            try check(f.validator.calls.current.count == calls && f.session.receipts.count == 1,
                "A delayed old-generation grant cannot reimport or duplicate the native ACK.")
            try check(f.transferProgress()?["foreground"] as? Bool == false,
                "Background receipt proof cannot silently change the observed foreground state.")
        }
        await run("transfer_progress_per_source_phase_times_preserve_sixty_background_receipts") { f in
            f.connectivity.observeApplicationForeground(false)
            let manifests = try (1...60).map { try f.seal($0) }
            for manifest in manifests { try f.deliver(manifest) }
            let url = f.phone.root.appendingPathComponent("ConnectivityDiagnostics/transfer-phases.json")
            func report() -> [String: Any]? {
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            }
            try await eventually("all exact source phases retained beyond old six-event ring") {
                let rows = report()?["phoneReceives"] as? [[String: Any]] ?? []
                return rows.count == 60 && rows.allSatisfy { $0["ackQueuedAtMS"] != nil }
            }
            let rows = report()!["phoneReceives"] as! [[String: Any]]
            try check(Set(rows.compactMap { $0["segmentID"] as? String }.map { $0.lowercased() })
                == Set(manifests.map { $0.id.uuidString.lowercased() }), "Phase evidence retains every exact source identity.")
            for row in rows {
                let entered = row["firstDelegateEnteredAtMS"] as? Int64 ?? Int64.max
                let staged = row["stagedAtMS"] as? Int64 ?? 0
                // receivedAt is rounded when the receipt is created and may
                // predate commit. Compare the actual post-commit observation.
                let durable = row["durableObservedAtMS"] as? Int64 ?? 0
                let ack = row["ackQueuedAtMS"] as? Int64 ?? 0
                try check(entered <= staged && staged <= durable && durable <= ack,
                    "Every phase describes actual ordered callback, durable staging, receipt and native ACK enqueue.")
            }
            let first = rows.first!
            try f.restart()
            try await eventually("phase metadata survives connectivity observer restart") {
                (report()?["phoneReceives"] as? [[String: Any]])?.count == 60
            }
            let restored = (report()!["phoneReceives"] as! [[String: Any]]).first {
                $0["segmentID"] as? String == first["segmentID"] as? String
            }!
            try check(restored["firstDelegateEnteredAtMS"] as? Int64 == first["firstDelegateEnteredAtMS"] as? Int64,
                "Restart cannot replace actual delegate time with observation time.")
            let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            try check(!text.contains(f.root.path) && !text.contains("framework-") && !text.contains("error"),
                "Phase diagnostics contain no temporary paths or free-text failure content.")
        }
        await run("transfer_progress_incoming_callback_holds_runtime_until_import_lease_exists") { f in
            f.connectivity.observeApplicationForeground(false)
            let manifest = try f.seal(1)
            f.lease.state.access { $0.hold = true }
            try f.deliver(manifest)
            try await eventually("import grant is pending after native callback returned") { f.lease.beginCount == 1 }
            try check(PhoneIncomingCallbackLease.outstanding.current == 1,
                "Callback execution must remain asserted across the asynchronous import-lease handoff.")
            try check(f.validator.calls.current.isEmpty && f.session.receipts.isEmpty,
                "Holding runtime cannot fabricate import success or ACK before validation.")
            try await eventually("staging is visible independently of persistence") {
                let signals = f.transferProgress()?["incomingCallback"] as? [String: Any]
                let counts = signals?["counts"] as? [String: Int]
                return counts?["started"] == 1 && counts?["staged"] == 1
            }
            f.lease.release()
            try await eventually("durable import and assertion handoff complete") {
                f.transferProgressCount("newIncomingCount") == 1
                    && PhoneIncomingCallbackLease.outstanding.current == 0
            }
            let signals = f.transferProgress()?["incomingCallback"] as? [String: Any]
            let counts = signals?["counts"] as? [String: Int]
            try check(counts?["lease_handoff"] == 1 && counts?["stage_failed"] == 0,
                "The report distinguishes successful runtime handoff from staging failure.")
        }
        await run("transfer_progress_invalid_callback_releases_assertion_without_ack") { f in
            f.connectivity.session(f.session, didReceive: WCSessionFile(fileURL: f.phone.root.appendingPathComponent("absent.caf"), metadata: [:]))
            try await eventually("failed staging reported") {
                let signals = f.transferProgress()?["incomingCallback"] as? [String: Any]
                return (signals?["counts"] as? [String: Int])?["stage_failed"] == 1
            }
            try check(PhoneIncomingCallbackLease.outstanding.current == 0 && f.lease.beginCount == 0
                && f.session.receipts.isEmpty && f.validator.calls.current.isEmpty,
                "A rejected callback ends runtime and cannot import, ACK or start a maintenance lease.")
        }
        await run("transfer_progress_cold_background_observation_does_not_start_work") { f in
            f.connectivity.observeApplicationForeground(false)
            try await eventually("cold launch records observed background state") {
                f.transferProgress()?["foreground"] as? Bool == false
            }
            try check(f.validator.calls.current.isEmpty && f.lease.beginCount == 0
                && f.maintenanceRequests.current == 0 && f.session.outstandingUserInfoTransfers.isEmpty,
                "Observing cold background state cannot validate, schedule, or send a request.")
            let manifest = try f.seal(1)
            try f.deliver(manifest)
            let archive = SyncEvidenceArchive(root: f.phone.root, stream: "phone_receipts")
            try await eventually("actual incoming callback carries the observed state") {
                guard let snapshot = try? archive.load() else { return false }
                return snapshot.rows.first(where: { $0.segmentID == manifest.id })?.foreground == false
            }
            let row = try archive.load()!.rows.first { $0.segmentID == manifest.id }!
            try check(row.origin == "incoming_persisted" && row.receiptWasPresent == false,
                "Only the actual durable receive establishes source evidence.")
            f.connectivity.observeApplicationForeground(true)
            try await eventually("later lifecycle observation updates report only") {
                f.transferProgress()?["foreground"] as? Bool == true
            }
            try check(try archive.load()!.rows.first { $0.segmentID == manifest.id }!.foreground == false,
                "A later foreground state cannot rewrite the earlier receive context.")
        }
        await run("transfer_progress_durable_source_receipts_survive_ack_ring_and_restart") { f in
            let manifests = try (1...18).map { try f.seal($0) }
            for manifest in manifests { try f.deliver(manifest) }
            let archive = SyncEvidenceArchive(root: f.phone.root, stream: "phone_receipts")
            try await eventually("all source receipts are projected without ring eviction") {
                guard let snapshot = try? archive.load() else { return false }
                return snapshot.rows.count == 18 && snapshot.rows.allSatisfy { $0.firstObservedAtMS != nil && $0.receiptAtMS != nil }
            }
            let first = try archive.load()!
            try check(Set(first.rows.map(\.segmentID)) == Set(manifests.map(\.id)), "Every original source has durable identity evidence.")
            let calls = f.validator.calls.current.count
            for manifest in manifests { try FileManager.default.removeItem(at: f.phone.audioURL(for: manifest)) }
            try f.restart()
            try await eventually("historical receipt projection survives restart without audio") {
                guard let next = try? archive.load() else { return false }
                return next.index.generationID != first.index.generationID && next.rows == first.rows
            }
            try check(f.validator.calls.current.count == calls, "Metadata restore cannot invoke audio validation.")
            try check(try archive.load()!.rows.count == 18, "Native ACK churn and process restart do not evict source receipts.")
        }
        await run("transfer_progress_startup_is_small_private_and_observation_only") { f in
            try await eventually("initial independent progress report") { f.transferProgress() != nil }
            let report = f.transferProgress()!
            try check(report["schemaVersion"] as? Int == 1 && report["role"] as? String == "phone"
                && report["counterScope"] as? String == "observer_epoch", "The role and counter lifetime are explicit.")
            try check(UUID(uuidString: report["processRunID"] as? String ?? "") != nil
                && (report["processID"] as? Int ?? 0) > 0 && (report["reportSequence"] as? Int ?? 0) > 0
                && UUID(uuidString: report["observerEpochID"] as? String ?? "") != nil,
                "A report is bound to its process, observer epoch and monotonic epoch-local sequence.")
            try check((report["generatedAtMS"] as? Int64 ?? 0) >= (report["observerStartedAtMS"] as? Int64 ?? 1)
                && (report["uptimeMS"] as? Int64 ?? 0) > 0, "Report observation time is distinct from collector time.")
            try check(report["incomingPersistedCount"] as? Int == 0 && report["newIncomingCount"] as? Int == 0
                && report["ackBackgroundEnqueuedCount"] as? Int == 0 && report["ackNativeCompletedCount"] as? Int == 0,
                "Startup cannot invent a prior process's progress.")
            let attrs = try FileManager.default.attributesOfItem(atPath: f.transferProgressURL.path)
            try check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600
                && ((attrs[.size] as? NSNumber)?.intValue ?? 8_193) <= 8_192, "The fixed report is private and bounded.")
            try check(report["foreground"] == nil, "Startup cannot infer a lifecycle state or password-lock state.")
            try check(f.validator.calls.current.isEmpty && f.lease.beginCount == 0
                && f.maintenanceRequests.current == 0 && f.session.outstandingUserInfoTransfers.isEmpty,
                "Writing observation metadata cannot validate, schedule or send anything.")
            let old = f.phone.root.appendingPathComponent("ConnectivityDiagnostics/phone.json")
            try await eventually("original strict connection report remains available") { FileManager.default.fileExists(atPath: old.path) }
            let existing = try JSONSerialization.jsonObject(with: Data(contentsOf: old)) as! [String: Any]
            try check(existing["role"] as? String == "phone" && existing["incomingPersistedCount"] == nil
                && existing["processRunID"] == nil, "The old connection report retains its original schema.")
        }
        await run("transfer_progress_new_receive_duplicate_and_actual_ack_channels_are_distinct") { f in
            f.session.isReachable = true
            let manifest = try f.seal(1)
            try f.deliver(manifest)
            try await eventually("new receive has two actual ACK channel observations") {
                f.transferProgressCount("newIncomingCount") == 1
                    && f.transferProgressCount("ackBackgroundEnqueuedCount") == 1
                    && f.transferProgressCount("ackImmediateSentCount") == 1
            }
            try f.deliver(manifest)
            try await eventually("duplicate persisted receive is classified separately") {
                f.transferProgressCount("incomingPersistedCount") == 2
                    && f.transferProgressCount("existingIncomingCount") == 1
            }
            try check(f.transferProgressCount("newIncomingCount") == 1
                && f.transferProgressCount("unclassifiedIncomingCount") == 0,
                "An idempotent receive cannot become another new source.")
            try check(f.transferProgressCount("ackBackgroundEnqueuedCount") == 1 && f.session.receipts.count == 1,
                "An already queued exact ACK is not a new background enqueue.")
            try f.finishReceiptTransfer()
            try await eventually("native successful completion observed") { f.transferProgressCount("ackNativeCompletedCount") == 1 }
            let events = f.transferProgress()!["recentEvents"] as! [[String: Any]]
            try check(events.allSatisfy { ($0["segmentID"] as? String)?.lowercased() == manifest.id.uuidString.lowercased()
                && $0["sha256"] as? String == manifest.sha256 }, "Recent events bind only the exact supplied source identity.")
            try check(f.transferProgressCount("ackNativeFailedCount") == 0
                && f.transferProgressCount("newIncomingCount") == 1,
                "Native transport completion cannot invent new receives or claim Watch durability.")
        }
        await run("transfer_progress_history_and_native_failure_do_not_count_as_new_receives") { f in
            _ = try f.receiptHistory(2)
            f.begin()
            try await eventually("actual historical ACK enqueues observed") { f.transferProgressCount("ackBackgroundEnqueuedCount") == 2 }
            try check(f.transferProgressCount("incomingPersistedCount") == 0 && f.transferProgressCount("newIncomingCount") == 0,
                "Historical receipt verification is not a new WC incoming file.")
            try f.finishReceiptTransfer(error: NSError(domain: "WCErrorDomain", code: 7_007,
                userInfo: [NSLocalizedDescriptionKey: "PRIVATE_ERROR_TEXT"]))
            try await eventually("native failure counted independently") { f.transferProgressCount("ackNativeFailedCount") == 1 }
            try f.finishReceiptTransfer()
            try await eventually("native success counted independently") { f.transferProgressCount("ackNativeCompletedCount") == 1 }
            try check(f.transferProgressCount("incomingPersistedCount") == 0 && f.transferProgressCount("ackImmediateSentCount") == 0,
                "A native callback observes only its actual channel and outcome.")
            let text = String(decoding: try Data(contentsOf: f.transferProgressURL), as: UTF8.self)
            try check(!text.contains("PRIVATE_ERROR_TEXT") && !text.contains("durableACK") && !text.contains("recordingContent"),
                "No error body, recording content or remote durability claim enters the small report.")
        }
        let failSync = Locked(true)
        await run("transfer_progress_failed_persistence_never_claims_new_receive_or_ack", fault: {
            if case .afterReceiptWriteBeforeSync = $0, failSync.current { throw ProbeFailure.failed("synthetic sync failure") }
        }) { f in
            let manifest = try f.seal(1)
            f.lease.state.access { $0.hold = true }
            try f.deliver(manifest)
            f.begin()
            try await eventually("failed receive lease pending") { f.lease.beginCount == 1 }
            f.lease.release()
            try await eventually("actual persistence failure finished") { f.callbacks.current.count == 1 && f.transferProgress() != nil }
            try check(f.transferProgressCount("incomingPersistedCount") == 0
                && f.transferProgressCount("newIncomingCount") == 0 && f.transferProgressCount("ackBackgroundEnqueuedCount") == 0,
                "Visible pre-fsync metadata cannot authorize a successful receive counter or ACK.")
            try await eventually("failed fsync preserves only the completed staging phase") {
                let rows = f.transferPhases()?["phoneReceives"] as? [[String: Any]] ?? []
                return rows.count == 1 && rows[0]["stagedAtMS"] != nil
            }
            let phases = (f.transferPhases()!["phoneReceives"] as! [[String: Any]])[0]
            try check(phases["durableReceiptAtMS"] == nil && phases["ackQueuedAtMS"] == nil,
                "A visible receipt write before failed fsync cannot become durable or ACK phase evidence.")
            failSync.access { $0 = false }
            f.begin()
            try await eventually("later durable recovery is observed") { f.transferProgressCount("incomingPersistedCount") == 1 }
            try check(f.transferProgressCount("existingIncomingCount") == 1 && f.transferProgressCount("newIncomingCount") == 0,
                "The exact pre-existing receipt is conservatively classified as recovery, not new first storage.")
        }
        await run("transfer_progress_write_failure_cannot_block_durable_receive_and_ack") { f in
            try await eventually("initial report settled") { f.transferProgress() != nil }
            try FileManager.default.removeItem(at: f.transferProgressURL)
            try FileManager.default.createDirectory(at: f.transferProgressURL, withIntermediateDirectories: false)
            let manifest = try f.seal(1)
            try f.deliver(manifest)
            try await eventually("existing transport proceeds despite an unwritable report") {
                let empty = try f.inbox.pendingIDs().isEmpty
                return f.session.receipts.contains { $0.segmentID == manifest.id } && empty
            }
            try check(try f.phone.receipts().map(\.segmentID) == [manifest.id],
                "Diagnostic failure cannot change repository durability.")
            var isDirectory: ObjCBool = false
            try check(FileManager.default.fileExists(atPath: f.transferProgressURL.path, isDirectory: &isDirectory) && isDirectory.boolValue,
                "The observer fails closed without replacing an unexpected destination type.")
        }
        await run("transfer_progress_ring_restart_and_untrusted_callback_metadata_are_bounded") { f in
            _ = try f.receiptHistory(8)
            f.begin()
            try await eventually("ring filled from actual native sends") { f.transferProgressCount("ackBackgroundEnqueuedCount") == 8 }
            let oldRun = f.transferProgress()!["processRunID"] as! String
            let oldEpoch = f.transferProgress()!["observerEpochID"] as! String
            let events = f.transferProgress()!["recentEvents"] as! [[String: Any]]
            try check(events.count == 6 && Set(events.compactMap { $0["segmentID"] as? String }).count == 6,
                "A burst retains six supplied identities while counters retain the process total.")
            try f.restart()
            try await eventually("restart publishes its own counter scope") {
                guard let report = f.transferProgress() else { return false }
                return report["processRunID"] as? String == oldRun && report["observerEpochID"] as? String != oldEpoch
                    && report["ackBackgroundEnqueuedCount"] as? Int == 0
            }
            try f.finishReceiptTransfer()
            try await eventually("old native work completion belongs to new observer") { f.transferProgressCount("ackNativeCompletedCount") == 1 }
            try check(f.transferProgressCount("newIncomingCount") == 0 && f.transferProgressCount("ackBackgroundEnqueuedCount") == 0,
                "A post-restart callback does not import old counters or resend an empty sweep.")
            let unusual = try JSONSerialization.data(withJSONObject: ["segmentID": UUID().uuidString,
                "sha256": "PRIVATE_UNTRUSTED_HASH", "byteCount": 1, "receivedAt": 1.0e30])
            let transfer = WCSessionUserInfoTransfer([TransportCodec.receiptKey: unusual])
            f.connectivity.session(f.session, didFinish: transfer, error: nil)
            _ = f.connectivity.currentState()
            try await eventually("untrusted receipt date never traps observation") { f.transferProgressCount("ackNativeCompletedCount") == 2 }
            let last = (f.transferProgress()!["recentEvents"] as! [[String: Any]]).last!
            try check(last["sha256"] == nil && last["receiptReceivedAtMS"] == nil,
                "Unbounded native metadata is omitted instead of copied or converted unsafely.")
            try check(try Data(contentsOf: f.transferProgressURL).count <= 8_192, "Every successful write remains below the collector limit.")
        }
    }
}
