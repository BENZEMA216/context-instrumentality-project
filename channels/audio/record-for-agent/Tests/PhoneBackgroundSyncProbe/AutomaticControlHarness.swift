import Foundation
import RecordingCore

extension Fixture {
    var automaticControlURL: URL {
        phone.root.appendingPathComponent("ConnectivityDiagnostics/automatic-sync-control.json")
    }
    func automaticControlState() throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: automaticControlURL)) as! [String: Any]
    }
    func automaticControlCount(_ key: String) -> Int? {
        (transferProgress()?["control"] as? [String: Any])?["counts"].flatMap { $0 as? [String: Int] }?[key]
    }
}

extension Probe {
    func runAutomaticControlScenarios() async {
        for oldKind in ["legacy", "schema1"] {
            await run("automatic_control_superseded_\(oldKind)_cannot_starve_current_native_intent") { f in
                let start = Date()
                var old: [String: Any] = [TransportCodec.requestSyncKey: true]
                if oldKind == "schema1" {
                    old["automaticSyncSchemaVersion"] = 1
                    old["automaticSyncRequestID"] = UUID().uuidString
                    old["automaticSyncRequestedAtMS"] = Int64(start.addingTimeInterval(-1_800).timeIntervalSince1970 * 1_000)
                }
                let transfer = f.session.transferUserInfo(old)
                f.connectivity.probeRequestWatchSync(sendImmediate: false, now: start)
                _ = f.connectivity.currentState()
                try check(transfer.cancelCount == 1, "A superseded pure control must release its otherwise permanent native slot.")
                try check(f.session.outstandingUserInfoTransfers.count == 1
                    && (try f.automaticControlState())["nativeRetryPending"] as? Bool == true,
                    "Cancellation is asynchronous: retain the exact durable obligation and do not overfill the queue.")
                let currentID = try f.automaticControlState()["requestID"] as! String
                _ = f.session.removeControlTransfer()
                try f.restart()
                f.connectivity.probeRequestWatchSync(sendImmediate: false, now: start.addingTimeInterval(901))
                _ = f.connectivity.currentState()
                let queued = f.session.outstandingUserInfoTransfers
                try check(queued.count == 1 && queued[0].userInfo["automaticSyncRequestID"] as? String == currentID,
                    "The next genuine opportunity fills the released slot with the original current UUID after restart.")
                f.connectivity.session(f.session, didFinish: transfer, error: NSError(domain: "WCErrorDomain", code: 7_007))
                _ = f.connectivity.currentState()
                try check((try f.automaticControlState())["nativeRetryPending"] as? Bool == false,
                    "The cancelled older envelope cannot reopen the current queued intent.")
                try check(f.validator.calls.current.isEmpty && f.lease.beginCount == 0,
                    "Control replacement never examines recordings or starts maintenance itself.")
            }
        }
        await run("automatic_control_mixed_authority_is_never_cancelled_for_replacement") { f in
            let transfer = f.session.transferUserInfo([TransportCodec.requestSyncKey: true,
                TransportCodec.receiptKey: Data([1, 2, 3])])
            f.connectivity.probeRequestWatchSync(sendImmediate: false)
            _ = f.connectivity.currentState()
            try check(transfer.cancelCount == 0 && f.session.outstandingUserInfoTransfers.count == 1,
                "A mixed or unknown envelope remains owned by its original channel; only pure controls are replaceable.")
            try check((try f.automaticControlState())["nativeRetryPending"] as? Bool == true,
                "An occupied unknown slot never satisfies the exact current intent.")
        }
        await run("automatic_control_same_id_exact_envelope_across_channels_and_cooldown") { f in
            f.session.isReachable = true
            f.connectivity.probeRequestWatchSync()
            _ = f.connectivity.currentState()
            let context = f.session.updatedContexts.current
            let native = f.session.outstandingUserInfoTransfers.map(\.userInfo)
            let messages = f.session.sentMessages.current
            try check(context.count == 1 && native.count == 1 && messages.count == 1,
                "One actual automatic request uses context, deferred user-info and immediate delivery.")
            let expected = Set([TransportCodec.requestSyncKey, "automaticSyncSchemaVersion",
                "automaticSyncRequestID", "automaticSyncRequestedAtMS"])
            let id = context[0]["automaticSyncRequestID"] as? String
            try check(id.flatMap(UUID.init(uuidString:)) != nil, "The request has a real UUID.")
            for payload in [context[0], native[0], messages[0]] {
                try check(Set(payload.keys) == expected && payload[TransportCodec.requestSyncKey] as? Bool == true
                    && payload["automaticSyncSchemaVersion"] as? Int == 1,
                    "The automatic control envelope cannot carry status or receipt authority.")
                try check(payload["automaticSyncRequestID"] as? String == id
                    && payload["automaticSyncRequestedAtMS"] as? Int64 == context[0]["automaticSyncRequestedAtMS"] as? Int64,
                    "All channels reuse the same ID and original request time for Watch-side deduplication.")
            }
            let before = try Data(contentsOf: f.automaticControlURL)
            for _ in 0..<20 { f.connectivity.probeRequestWatchSync() }
            _ = f.connectivity.currentState()
            try check(f.session.contextAttemptPayloads.current.count == 1 && f.session.sentMessages.current.count == 1
                && f.session.outstandingUserInfoTransfers.count == 1,
                "Repeated lifecycle opportunities inside cooldown cannot spin or amplify the same request.")
            try check(try Data(contentsOf: f.automaticControlURL) == before, "No-op opportunities do not move durable dates.")
            try await eventually("actual control events reach the fixed report") {
                f.automaticControlCount("requested") == 1 && f.automaticControlCount("context_accepted") == 1
                    && f.automaticControlCount("native_enqueued") == 1
            }
            try check(f.lease.beginCount == 0 && f.validator.calls.current.isEmpty,
                "Control registration does not open or validate recording files.")
        }

        await run("automatic_control_context_failure_survives_restart_and_retries_same_id_at_15_minutes") { f in
            f.session.contextError = NSError(domain: "WCErrorDomain", code: 7_007)
            f.connectivity.probeRequestWatchSync(sendImmediate: false)
            _ = f.connectivity.currentState()
            try check(f.session.contextAttemptPayloads.current.count == 1 && f.session.updatedContexts.current.isEmpty
                && f.session.outstandingUserInfoTransfers.count == 1 && f.session.sentMessages.current.isEmpty,
                "A throwing context API still registers its deferred fallback without requiring reachability.")
            let first = try f.automaticControlState()
            let id = UUID(uuidString: first["requestID"] as! String)!
            let deadline = (first["retryAfter"] as! NSNumber).doubleValue / 1_000
            let initialTime = f.session.contextAttemptPayloads.current[0]["automaticSyncRequestedAtMS"] as! Int64
            try check(first["contextRetryPending"] as? Bool == true && first["nativeRetryPending"] as? Bool == false,
                "Only the failed context channel retains a retry obligation after native API enqueue.")
            try check(abs(deadline - (first["lastAttemptAt"] as! NSNumber).doubleValue / 1_000 - 900) < 0.002,
                "The retry deadline is fifteen minutes after the attempt.")
            try f.restart()
            f.connectivity.probeRequestWatchSync(sendImmediate: false)
            _ = f.connectivity.currentState()
            try check(f.session.contextAttemptPayloads.current.count == 1, "Restart cannot erase the saved cooldown.")
            let access = AutomaticSyncControlTestAccess(root: f.phone.root)
            try check(try access.prepare(hasBacklog: false, now: Date(timeIntervalSince1970: deadline - 0.01)) == nil,
                "The exact production helper refuses retry before its deadline.")
            let retry = try access.prepare(hasBacklog: false, now: Date(timeIntervalSince1970: deadline + 0.01))!
            try check(retry.id == id && retry.payload["automaticSyncRequestedAtMS"] as? Int64 == initialTime,
                "After fifteen minutes the retry retains the original UUID and semantic request time.")
            try access.localAttemptCompleted(contextAccepted: true)
            let restarted = AutomaticSyncControlTestAccess(root: f.phone.root)
            try check(try restarted.prepare(hasBacklog: false, now: Date(timeIntervalSince1970: deadline + 901)) == nil
                && !restarted.needsRetry, "Accepted control with no known backlog does not generate an endless empty loop.")
        }

        await run("automatic_control_native_actual_failure_reopens_durable_retry_and_observation") { f in
            f.connectivity.probeRequestWatchSync(sendImmediate: false)
            _ = f.connectivity.currentState()
            guard let transfer = f.session.removeControlTransfer() else { throw ProbeFailure.failed("Missing actual control transfer") }
            f.connectivity.session(f.session, didFinish: transfer, error: NSError(domain: "WCErrorDomain", code: 7_007))
            _ = f.connectivity.currentState()
            try check(try f.automaticControlState()["nativeRetryPending"] as? Bool == true,
                "A real native failure callback reopens the persisted obligation.")
            try await eventually("native failure observer records callback") { f.automaticControlCount("native_failed") == 1 }
            let before = f.session.contextAttemptPayloads.current.count
            f.connectivity.probeRequestWatchSync(sendImmediate: false)
            _ = f.connectivity.currentState()
            try check(f.session.contextAttemptPayloads.current.count == before && f.session.outstandingUserInfoTransfers.isEmpty,
                "Native failure requests a later system opportunity rather than immediate in-process retry.")
            try check(f.maintenanceRequests.current > 0 && f.validator.calls.current.isEmpty,
                "The callback asks for bounded maintenance without recording validation.")
        }

        for oldKind in ["legacy", "other_uuid"] {
            await run("automatic_control_\(oldKind)_slot_preserves_current_obligation_across_failure_and_restart") { f in
                let start = Date()
                var old: [String: Any] = [TransportCodec.requestSyncKey: true]
                if oldKind == "other_uuid" {
                    old["automaticSyncSchemaVersion"] = 1
                    old["automaticSyncRequestID"] = UUID().uuidString
                    old["automaticSyncRequestedAtMS"] = Int64(start.addingTimeInterval(-1_000).timeIntervalSince1970 * 1_000)
                }
                f.session.transferUserInfo(old)
                f.connectivity.probeRequestWatchSync(sendImmediate: false, now: start)
                _ = f.connectivity.currentState()
                let initial = try f.automaticControlState()
                let id = initial["requestID"] as! String
                let payload = f.session.updatedContexts.current[0]
                try check(initial["contextRetryPending"] as? Bool == false && initial["nativeRetryPending"] as? Bool == true,
                    "Accepted current context cannot discharge a native obligation occupied by a different or legacy request.")
                try check(f.session.outstandingUserInfoTransfers.count == 1
                    && (f.automaticControlCount("native_enqueued") ?? 0) == 0,
                    "The existing native control remains OS-owned; a full control slot cannot grow the queue.")
                let before = try Data(contentsOf: f.automaticControlURL)
                guard let oldTransfer = f.session.removeControlTransfer() else { throw ProbeFailure.failed("Missing older queued request") }
                f.connectivity.session(f.session, didFinish: oldTransfer, error: NSError(domain: "WCErrorDomain", code: 7_007))
                _ = f.connectivity.currentState()
                try check(try Data(contentsOf: f.automaticControlURL) == before,
                    "Failure of a different request cannot erase or postpone the already-pending current request.")
                try f.restart()
                f.connectivity.probeRequestWatchSync(sendImmediate: false, now: start.addingTimeInterval(899))
                _ = f.connectivity.currentState()
                try check(f.session.contextAttemptPayloads.current.count == 1 && f.session.outstandingUserInfoTransfers.isEmpty,
                    "A failure and process restart preserve cooldown and cannot create an immediate retry storm.")
                f.connectivity.probeRequestWatchSync(sendImmediate: false, now: start.addingTimeInterval(901))
                _ = f.connectivity.currentState()
                let current = try f.automaticControlState()
                let queued = f.session.outstandingUserInfoTransfers.map(\.userInfo)
                try check(current["requestID"] as? String == id && current["nativeRetryPending"] as? Bool == false
                    && current["contextRetryPending"] as? Bool == false && queued.count == 1,
                    "The next eligible opportunity registers the same exact current request in the freed native slot.")
                try check(queued[0]["automaticSyncRequestID"] as? String == id
                    && queued[0]["automaticSyncRequestedAtMS"] as? Int64 == payload["automaticSyncRequestedAtMS"] as? Int64,
                    "Native retry keeps the original UUID and semantic request time after restart.")
                try check(f.lease.beginCount == 0 && f.validator.calls.current.isEmpty,
                    "Control retry does not open a background lease or inspect recordings.")
            }
        }

        await run("automatic_control_exact_current_native_envelope_is_reused_without_duplicate") { f in
            let start = Date()
            f.session.contextError = NSError(domain: "WCErrorDomain", code: 7_007)
            f.connectivity.probeRequestWatchSync(sendImmediate: false, now: start)
            _ = f.connectivity.currentState()
            let first = try f.automaticControlState()
            f.session.contextError = nil
            f.connectivity.probeRequestWatchSync(sendImmediate: false, now: start.addingTimeInterval(901))
            _ = f.connectivity.currentState()
            let current = try f.automaticControlState()
            try check(current["requestID"] as? String == first["requestID"] as? String
                && current["nativeRetryPending"] as? Bool == false && current["contextRetryPending"] as? Bool == false,
                "Only the exact current native envelope can satisfy the existing native obligation.")
            try check(f.session.contextAttemptPayloads.current.count == 2 && f.session.outstandingUserInfoTransfers.count == 1,
                "Retrying a failed context reuses its native twin rather than creating another queued control.")
        }

        for malformedKind in ["wrong_time", "wrong_schema", "boolean_schema", "numeric_request", "extra_authority"] {
            await run("automatic_control_same_uuid_\(malformedKind)_cannot_discharge_current_native_obligation") { f in
                let start = Date()
                f.session.contextError = NSError(domain: "WCErrorDomain", code: 7_007)
                f.connectivity.probeRequestWatchSync(sendImmediate: false, now: start)
                _ = f.connectivity.currentState()
                guard let original = f.session.removeControlTransfer() else { throw ProbeFailure.failed("Missing current native request") }
                var malformed = original.userInfo
                switch malformedKind {
                case "wrong_time": malformed["automaticSyncRequestedAtMS"] = (malformed["automaticSyncRequestedAtMS"] as! Int64) + 1
                case "wrong_schema": malformed["automaticSyncSchemaVersion"] = 2
                case "boolean_schema": malformed["automaticSyncSchemaVersion"] = true
                case "numeric_request": malformed[TransportCodec.requestSyncKey] = NSNumber(value: 1)
                default: malformed[TransportCodec.statusRequestKey] = Data()
                }
                f.session.transferUserInfo(malformed)
                f.session.contextError = nil
                for index in 1...3 {
                    f.connectivity.probeRequestWatchSync(sendImmediate: false, now: start.addingTimeInterval(Double(index * 901)))
                    _ = f.connectivity.currentState()
                    let state = try f.automaticControlState()
                    try check(state["requestID"] as? String == original.userInfo["automaticSyncRequestID"] as? String
                        && state["nativeRetryPending"] as? Bool == true && state["contextRetryPending"] as? Bool == false,
                        "Matching UUID alone cannot satisfy a native packet with different semantics or extra authority.")
                    try check(f.session.outstandingUserInfoTransfers.count == 1,
                        "Repeated real opportunities keep an occupied control queue bounded while retaining the retry obligation.")
                }
                let before = try Data(contentsOf: f.automaticControlURL)
                guard let invalidTransfer = f.session.removeControlTransfer() else { throw ProbeFailure.failed("Missing malformed native request") }
                for error: Error? in [nil, NSError(domain: "WCErrorDomain", code: 7_007)] {
                    f.connectivity.session(f.session, didFinish: invalidTransfer, error: error)
                    _ = f.connectivity.currentState()
                    try check(try Data(contentsOf: f.automaticControlURL) == before,
                        "Neither successful nor failed transport of a semantically different packet can discharge or delay the current obligation.")
                }
            }
        }

        await run("automatic_control_old_and_nil_callbacks_cannot_delay_or_clear_new_id") { f in
            let access = AutomaticSyncControlTestAccess(root: f.phone.root)
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            let old = try access.prepare(hasBacklog: false, now: start)!
            try access.localAttemptCompleted(contextAccepted: true)
            let current = try access.prepare(hasBacklog: true, now: start.addingTimeInterval(901))!
            try access.localAttemptCompleted(contextAccepted: true)
            try check(old.id != current.id, "Confirmed backlog after fifteen minutes creates one new semantic request.")
            let before = try Data(contentsOf: f.automaticControlURL)
            for requestID in [old.id, nil] {
                try access.nativeCompleted(requestID: requestID, failed: true, now: start.addingTimeInterval(9_000))
                try access.nativeCompleted(requestID: requestID, failed: false, now: start.addingTimeInterval(9_001))
                try check(try Data(contentsOf: f.automaticControlURL) == before,
                    "A stale or legacy callback cannot overwrite, delay or clear the current intent.")
            }
            try access.nativeCompleted(requestID: current.id, failed: true, now: start.addingTimeInterval(2_000))
            try check(access.needsRetry, "Only failure of the current UUID reopens its native channel.")
            try check(try access.prepare(hasBacklog: true, now: start.addingTimeInterval(2_899)) == nil,
                "Current native failure preserves a fresh fifteen-minute backoff even with known backlog.")
            let retry = try access.prepare(hasBacklog: true, now: start.addingTimeInterval(2_901))!
            try check(retry.id == current.id && retry.payload["automaticSyncRequestedAtMS"] as? Int64
                == current.payload["automaticSyncRequestedAtMS"] as? Int64,
                "Retry never turns a failed delivery into apparent new progress.")
        }

        await run("automatic_control_restart_and_seven_day_expiry_are_opportunity_driven") { f in
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            let access = AutomaticSyncControlTestAccess(root: f.phone.root)
            let initial = try access.prepare(hasBacklog: false, now: start)!
            try access.localAttemptCompleted(contextAccepted: true)
            let restarted = AutomaticSyncControlTestAccess(root: f.phone.root)
            try check(try restarted.prepare(hasBacklog: false, now: start.addingTimeInterval(6 * 86_400)) == nil,
                "Loading a prior accepted intent does not itself schedule another request.")
            let renewed = try restarted.prepare(hasBacklog: false, now: start.addingTimeInterval(7 * 86_400 + 1))!
            try check(renewed.id != initial.id, "A seven-day stale intent is renewed only when a real caller asks.")
            let attrs = try FileManager.default.attributesOfItem(atPath: f.automaticControlURL.path)
            try check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600
                && (attrs[.size] as? NSNumber)?.intValue ?? 8_193 <= 8_192,
                "Durable scheduling metadata is fixed, private and bounded.")
        }

        await run("automatic_control_fractional_millisecond_identity_matches_persistence_and_restart") { f in
            for fraction in [0.0006, 0.1236, 0.9996] {
                let root = f.root.appendingPathComponent("rounded-\(fraction)")
                let start = Date(timeIntervalSince1970: 1_800_000_000 + fraction)
                let first = AutomaticSyncControlTestAccess(root: root)
                let original = try first.prepare(hasBacklog: false, now: start)!
                try first.localAttemptCompleted(contextAccepted: true, nativeQueued: false)
                let stored = try JSONSerialization.jsonObject(with: Data(contentsOf:
                    root.appendingPathComponent("ConnectivityDiagnostics/automatic-sync-control.json"))) as! [String: Any]
                let restarted = AutomaticSyncControlTestAccess(root: root)
                let retry = try restarted.prepare(hasBacklog: false, now: start.addingTimeInterval(901))!
                try check(original.payload["automaticSyncRequestedAtMS"] as? Int64 == (stored["requestedAt"] as! NSNumber).int64Value,
                    "The initial packet already uses the exact rounded millisecond value persisted by TransportCodec.")
                try check(retry.id == original.id && retry.payload["automaticSyncRequestedAtMS"] as? Int64
                    == original.payload["automaticSyncRequestedAtMS"] as? Int64,
                    "A fractional-millisecond timestamp cannot change the same intent's semantic identity on restart.")
            }
        }

        for kind in ["corrupt", "oversized", "directory", "symlink", "invalid_dates"] {
            await run("automatic_control_unreadable_\(kind)_preserves_bytes_and_recovers_without_default") { f in
                let start = Date(timeIntervalSince1970: 1_800_000_000)
                let initial = AutomaticSyncControlTestAccess(root: f.phone.root)
                let plan = try initial.prepare(hasBacklog: false, now: start)!
                let good = try Data(contentsOf: f.automaticControlURL)
                try FileManager.default.removeItem(at: f.automaticControlURL)
                let target = f.root.appendingPathComponent("private-sentinel.json")
                switch kind {
                case "corrupt": try Data("{not-json".utf8).write(to: f.automaticControlURL)
                case "oversized": try Data(repeating: 65, count: 8_193).write(to: f.automaticControlURL)
                case "directory": try FileManager.default.createDirectory(at: f.automaticControlURL, withIntermediateDirectories: false)
                case "symlink":
                    try good.write(to: target)
                    try FileManager.default.createSymbolicLink(at: f.automaticControlURL, withDestinationURL: target)
                default:
                    var bad = try JSONSerialization.jsonObject(with: good) as! [String: Any]
                    bad["retryAfter"] = 0
                    try JSONSerialization.data(withJSONObject: bad).write(to: f.automaticControlURL)
                }
                let damaged = kind == "directory" ? nil : try Data(contentsOf: f.automaticControlURL)
                let reader = AutomaticSyncControlTestAccess(root: f.phone.root)
                var threw = false
                do { _ = try reader.prepare(hasBacklog: true, now: start.addingTimeInterval(1_000)) } catch { threw = true }
                try check(threw && reader.needsRetry, "Unavailable or malformed metadata is an error, never an absent empty state.")
                if let damaged {
                    try check(try Data(contentsOf: f.automaticControlURL) == damaged, "Failed load cannot overwrite original metadata.")
                } else {
                    var isDirectory: ObjCBool = false
                    try check(FileManager.default.fileExists(atPath: f.automaticControlURL.path, isDirectory: &isDirectory)
                        && isDirectory.boolValue, "An unexpected directory is preserved.")
                }
                if kind == "symlink" { try check(try Data(contentsOf: target) == good, "A symlink's target is never overwritten.") }
                try FileManager.default.removeItem(at: f.automaticControlURL)
                try good.write(to: f.automaticControlURL)
                let recovered = try reader.prepare(hasBacklog: true, now: start.addingTimeInterval(1_000))!
                try check(recovered.id == plan.id, "The next valid opportunity rereads and resumes the exact pending UUID.")
            }
        }

        await run("automatic_control_status_and_diagnostic_reads_cannot_create_sync_intent") { f in
            f.session.isReachable = true
            f.session.messageHandler = { payload, reply, _ in
                guard let bytes = payload[TransportCodec.statusRequestKey] as? Data,
                      let request = try? TransportCodec.decode(RecorderStatusRequest.self, from: bytes) else { return }
                reply?([TransportCodec.statusResponseKey: try! TransportCodec.encode(
                    RecorderStatusResponse(requestID: request.requestID, snapshot: RecorderSnapshot(state: .paused)))])
            }
            for _ in 0..<10 { _ = f.connectivity.currentState(); _ = f.connectivity.statusDiagnosticSnapshot() }
            let results = Locked<[PhoneStatusRequestResult]>([])
            f.connectivity.requestStatus { result in results.access { $0.append(result) } }
            try await eventually("status reply arrives without automatic work") { results.current.count == 1 }
            try check(!FileManager.default.fileExists(atPath: f.automaticControlURL.path)
                && f.session.contextAttemptPayloads.current.isEmpty && f.session.outstandingUserInfoTransfers.isEmpty,
                "Read-only diagnostics and status cannot create a context or deferred sync control intent.")
            try check(f.session.sentMessages.current.count == 1 && f.session.sentMessages.current[0].count == 1
                && f.session.sentMessages.current[0][TransportCodec.statusRequestKey] is Data,
                "The live status request retains its separate, narrow envelope.")
            try check(f.lease.beginCount == 0 && f.maintenanceRequests.current == 0 && f.validator.calls.current.isEmpty,
                "Status observation has no background or recording-validation side effects.")
        }

        await run("automatic_control_error_domain_utf8_bound_preserves_scalars") { f in
            let root = f.root.appendingPathComponent("observer-errors")
            let access = TransferProgressMetadataTestAccess(root: root)
            let url = root.appendingPathComponent("ConnectivityDiagnostics/background-sync.json")
            for (domain, expected) in [(String(repeating: "a", count: 95) + "界", String(repeating: "a", count: 95)),
                (String(repeating: "界", count: 40), String(repeating: "界", count: 32)),
                (String(repeating: "😀", count: 40), String(repeating: "😀", count: 24))] {
                access.controlError(NSError(domain: domain, code: Int.max, userInfo: [NSLocalizedDescriptionKey: "PRIVATE_BODY_OMIT"]))
                await withCheckedContinuation { continuation in access.drain { continuation.resume() } }
                let bytes = try Data(contentsOf: url)
                let report = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
                let control = report["control"] as! [String: Any]
                let result = control["lastErrorDomain"] as! String
                try check(result == expected && result.utf8.count <= 96 && !result.contains("�"),
                    "UTF-8 truncation preserves full Unicode scalars and never expands replacement bytes.")
                try check(control["lastErrorCode"] as? Int == Int.max && control["lastErrorAtMS"] as? Int64 != nil,
                    "Only bounded domain, numeric code and observation time survive.")
                try check(!String(decoding: bytes, as: UTF8.self).contains("PRIVATE_BODY_OMIT"), "Error userInfo is not copied.")
            }
        }

        await run("automatic_control_maximal_expanded_report_is_actually_persisted_under_8192_bytes") { f in
            let root = f.root.appendingPathComponent("observer-max")
            let access = TransferProgressMetadataTestAccess(root: root)
            access.setForeground(true)
            let id = UUID()
            let controlKinds = ["requested", "context_accepted", "context_failed", "native_enqueued",
                "native_completed", "native_failed", "state_failed"]
            for kind in controlKinds { access.controlEvent(kind, requestID: id) }
            access.controlRetryPending(true)
            access.controlError(NSError(domain: String(repeating: "界", count: 40), code: Int.max,
                userInfo: [NSLocalizedDescriptionKey: "PRIVATE_ERROR_BODY_MUST_NOT_APPEAR"]))
            for (kind, detail) in [("phone.bg_register", " registered=true"), ("phone.bg_register", " registered=false"),
                ("phone.bg_submit", ""), ("phone.bg_request_pending", ""), ("phone.bg_task_started", ""),
                ("phone.bg_submit_failed", "PRIVATE_SCHEDULER_DETAIL_MUST_NOT_APPEAR")] {
                access.backgroundSchedulerEvent(kind: kind, detail: detail)
            }
            for index in 0..<8 {
                let receipt = SegmentReceipt(segmentID: UUID(), sha256: String(repeating: "a", count: 64),
                    byteCount: Int64.max, receivedAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(index)))
                access.incomingPersisted(receipt, receiptWasPresent: index % 3 == 0 ? nil : index % 3 == 1)
                access.receiptSent(receipt, immediate: false)
                access.receiptSent(receipt, immediate: true)
                access.nativeReceiptCompleted(receipt, succeeded: true)
                access.nativeReceiptCompleted(receipt, succeeded: false)
            }
            await withCheckedContinuation { continuation in access.drain { continuation.resume() } }
            let url = root.appendingPathComponent("ConnectivityDiagnostics/background-sync.json")
            let bytes = try Data(contentsOf: url)
            let report = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            let control = report["control"] as! [String: Any]
            let scheduler = report["backgroundScheduler"] as! [String: Any]
            let counts = control["counts"] as! [String: Int]
            let times = control["lastAtMS"] as! [String: Int64]
            let schedulerCounts = scheduler["counts"] as! [String: Int]
            try check(bytes.count <= 8_192 && bytes.count > 3_000, "The fully populated expanded report is actually on disk within its fixed byte bound.")
            try check(controlKinds.allSatisfy { counts[$0] == 1 && times[$0] != nil }
                && control["lastRequestID"] as? String == id.uuidString && control["retryPending"] as? Bool == true,
                "The persisted maximal snapshot contains every new control field, not a stale smaller report.")
            try check(control["lastErrorDomain"] as? String == String(repeating: "界", count: 32)
                && control["lastErrorCode"] as? Int == Int.max && control["lastErrorAtMS"] as? Int64 != nil,
                "The largest bounded multi-byte domain and error observation are present.")
            try check(["registered", "register_failed", "submitted", "pending", "started", "submit_failed"].allSatisfy {
                schedulerCounts[$0] == 1 && (scheduler["lastAtMS"] as! [String: Int64])[$0] != nil },
                "Every actual scheduler observation has a counter and timestamp.")
            try check((report["recentEvents"] as! [[String: Any]]).count == 6
                && report["incomingPersistedCount"] as? Int == 8 && report["newIncomingCount"] as? Int == 2
                && report["existingIncomingCount"] as? Int == 3 && report["unclassifiedIncomingCount"] as? Int == 3,
                "The six-event ring coexists with all classified cumulative receive totals.")
            for key in ["ackBackgroundEnqueuedCount", "ackImmediateSentCount", "ackNativeCompletedCount", "ackNativeFailedCount"] {
                try check(report[key] as? Int == 8, "The maximal report retains \(key).")
            }
            try check(report["foreground"] as? Bool == true && report["counterScope"] as? String == "observer_epoch"
                && UUID(uuidString: report["processRunID"] as? String ?? "") != nil
                && UUID(uuidString: report["observerEpochID"] as? String ?? "") != nil,
                "The snapshot keeps real context and explicit process/observer counter binding.")
            let text = String(decoding: bytes, as: UTF8.self)
            try check(!text.contains("PRIVATE_ERROR_BODY_MUST_NOT_APPEAR") && !text.contains("PRIVATE_SCHEDULER_DETAIL_MUST_NOT_APPEAR"),
                "The report stores no arbitrary error body or scheduler detail.")
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            try check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "The actual maximal report remains private.")
            access.publishMaximumCounterBoundary()
            await withCheckedContinuation { continuation in access.drain { continuation.resume() } }
            let maximumBytes = try Data(contentsOf: url)
            let maximum = try JSONSerialization.jsonObject(with: maximumBytes) as! [String: Any]
            let maxControl = maximum["control"] as! [String: Any]
            try check(maximumBytes.count <= 8_192 && maximumBytes.count > bytes.count
                && maximum["reportSequence"] as? Int == Int.max
                && maximum["incomingPersistedCount"] as? Int == Int.max,
                "Saturated counters and all maximum-width metadata are actually published, without dropping an oversized snapshot.")
            try check(maxControl["lastErrorDomain"] as? String == String(repeating: "\u{0}", count: 96)
                && maxControl["lastErrorCode"] as? Int == Int.min
                && (maxControl["lastAtMS"] as! [String: Int64]).values.allSatisfy { $0 == Int64.max },
                "The byte-bound fixture includes JSON-escaped domain bytes and maximum-width timestamps/codes.")
            try maximumBytes.write(to: f.root.appendingPathComponent("maximal-phone-background-sync-report.json"))
            try check(f.session.contextAttemptPayloads.current.isEmpty && f.session.outstandingUserInfoTransfers.isEmpty
                && f.lease.beginCount == 0 && f.validator.calls.current.isEmpty,
                "Feeding existing synthetic metadata to the real observer cannot initiate transport or audio work.")
        }
    }
}
