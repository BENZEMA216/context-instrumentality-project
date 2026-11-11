import Foundation
import Darwin
import RecordingCore

extension Probe {
    @MainActor func runStatusDiagnosticScenarios() async {
        await run("status_journal_correlated_failure_recovery_and_private_payload_excluded") { f in
            let intent = UUID(), failed = UUID(), recovery = UUID()
            let calls = Locked(0), wireIDs = Locked<[UUID]>([])
            f.session.isReachable = true
            f.session.messageHandler = { payload, reply, error in
                let request = try! TransportCodec.decode(RecorderStatusRequest.self,
                    from: payload[TransportCodec.statusRequestKey] as! Data)
                wireIDs.access { $0.append(request.requestID) }
                let index = calls.access { $0 += 1; return $0 }
                if index == 1 {
                    error?(NSError(domain: "WCErrorDomain", code: 7007,
                        userInfo: [NSLocalizedDescriptionKey: "PRIVATE_FAILURE_DESCRIPTION"]))
                } else {
                    let snapshot = RecorderSnapshot(state: .paused, sessionID: UUID(), detail: "PRIVATE_SNAPSHOT_DETAIL")
                    reply?([TransportCodec.statusResponseKey: try! TransportCodec.encode(
                        RecorderStatusResponse(requestID: request.requestID, snapshot: snapshot))])
                }
            }
            let completed = Locked(0)
            f.connectivity.requestStatus(intentID: intent, attemptID: failed) { _ in completed.access { $0 += 1 } }
            try await eventually("failed query terminal") { completed.current == 1 }
            f.connectivity.requestStatus(intentID: intent, attemptID: recovery, isRecoveryRetry: true) { _ in completed.access { $0 += 1 } }
            try await eventually("recovery query terminal") { completed.current == 2 }
            let value = f.connectivity.statusDiagnosticSnapshot()
            try check(wireIDs.current == [failed, recovery], "Store attempt IDs must be the actual echoed wire request IDs.")
            try check(value.faults.count == 1 && value.faults[0].failure.intentID == intent
                && value.faults[0].failure.attemptID == failed && value.faults[0].failure.outcome == .failed,
                "The original failure survives a later success under the same UI intent.")
            try check(value.faults[0].recovery?.attemptID == recovery && value.faults[0].recovery?.outcome == .received,
                "Recovery belongs to its new attempt, with the original UI intent retained.")
            try check(value.recentEvents.filter { $0.attemptID == recovery }.map(\.stage)
                == [.queued, .workerStarted, .sent, .validated, .terminal], "Success requires the full dedicated-query path.")
            try check(value.faults[0].failure.error?.code == 7007 && value.faults[0].failure.error?.domain == .watchConnectivity,
                "Only the enumerated error family and numeric code are retained.")
            let bytes = try JSONEncoder().encode(value), text = String(decoding: bytes, as: UTF8.self)
            try check(!text.contains("PRIVATE_") && !text.contains("snapshot") && !text.contains("sessionID")
                && !value.includesRecordingContent && !value.remoteHistoryObserved && !value.realtimeStatusClaimed,
                "No free error, response body or recording identifier enters the metadata envelope.")
            try check(f.validator.calls.current.isEmpty && f.session.receipts.isEmpty && f.maintenanceRequests.current == 0,
                "Query logging does not request audio validation, ACK or maintenance.")
        }
        await run("status_journal_blocked_worker_timeout_and_memory_export") { f in
            let queue = Mirror(reflecting: f.connectivity).children.first { $0.label == "work" }!.value as! DispatchQueue
            let gate = DispatchSemaphore(value: 0), entered = Locked(false)
            queue.async { entered.access { $0 = true }; _ = gate.wait(timeout: .now() + 5) }
            defer { gate.signal() }
            try await eventually("worker held") { entered.current }
            let id = UUID()
            f.connectivity.requestStatus(intentID: UUID(), attemptID: id) { _ in }
            let queued = f.connectivity.statusDiagnosticSnapshot()
            try check(queued.recentEvents.last?.stage == .queued && f.session.sentMessages.current.isEmpty,
                "An accepted API entry is not a worker or send event.")
            f.connectivity.cancelStatusRequest(diagnosticOutcome: .timeout)
            let ended = f.connectivity.statusDiagnosticSnapshot()
            try check(ended.recentEvents.last?.outcome == .timeout && ended.activeAttempts.isEmpty,
                "A UI deadline can persist its actual terminal reason without waiting for the blocked worker.")
            try check(!ended.recentEvents.contains { $0.stage == .sent || $0.stage == .validated }, "No send or reply is fabricated.")
            let file = f.phone.root.appendingPathComponent("ConnectivityDiagnostics/status-history.json")
            try await eventually("independent log persistence") { !f.connectivity.statusDiagnosticSnapshot().persistencePending && FileManager.default.fileExists(atPath: file.path) }
            let before = try Data(contentsOf: file)
            for _ in 0..<20 { _ = f.connectivity.statusDiagnosticSnapshot() }
            try check(try Data(contentsOf: file) == before && f.session.sentMessages.current.isEmpty,
                "Default report snapshots use memory, perform no persistence, and never call WC.")
        }
        await run("status_journal_cancel_late_reply_is_not_success") { f in
            let callback = Locked<(([String: Any]) -> Void)?>(nil), request = Locked<RecorderStatusRequest?>(nil)
            f.session.isReachable = true
            f.session.messageHandler = { payload, reply, _ in
                request.access { $0 = try! TransportCodec.decode(RecorderStatusRequest.self,
                    from: payload[TransportCodec.statusRequestKey] as! Data) }
                callback.access { $0 = reply }
            }
            f.connectivity.requestStatus { _ in }
            try await eventually("sent before cancel") { callback.current != nil }
            f.connectivity.cancelStatusRequest()
            callback.current?([TransportCodec.statusResponseKey: try TransportCodec.encode(
                RecorderStatusResponse(requestID: request.current!.requestID, snapshot: RecorderSnapshot(state: .paused)))])
            try await Task.sleep(nanoseconds: 80_000_000)
            let value = f.connectivity.statusDiagnosticSnapshot()
            try check(value.recentEvents.last?.outcome == .cancelled && !value.recentEvents.contains { $0.stage == .validated },
                "A late reply after synchronous cancellation cannot rewrite the terminal result.")
        }
        await run("status_journal_restart_marks_unfinished_interrupted_and_matches_permissions") { f in
            let base = f.root.appendingPathComponent("journal"), intent = UUID(), attempt = UUID()
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let first = PhoneStatusDiagnostics(root: base, build: "58", runID: UUID())
            first.begin(intentID: intent, attemptID: attempt, recovery: false, connection: nil)
            first.stage(.workerStarted, attemptID: attempt)
            try await eventually("first run persisted") { !first.snapshot().persistencePending }
            let second = PhoneStatusDiagnostics(root: base, build: "59", runID: UUID())
            let restored = second.snapshot()
            try check(restored.restoreState == .restored && restored.interruptedAttempts == 1 && restored.activeAttempts.isEmpty,
                "A prior run's unfinished query becomes interrupted, never implicitly recovered.")
            try check(restored.faults.last?.failure.outcome == .interrupted && restored.faults.last?.failure.elapsedMS == nil,
                "Restart does not subtract monotonic clocks across process runs.")
            try await eventually("interruption persisted") { !second.snapshot().persistencePending }
            let directory = base.appendingPathComponent("ConnectivityDiagnostics"), file = directory.appendingPathComponent("status-history.json")
            let dm = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
            let fm = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
            try check(dm?.intValue == 0o700 && fm?.intValue == 0o600, "The journal and its directory remain private.")
            try check(try Data(contentsOf: file).count <= 65_536, "The full persistent envelope stays within 64 KiB.")
        }
        await run("status_journal_bounded_context_and_delayed_recovery_preserves_failure") { f in
            let clock = Locked((wall: 1_800_000_000.0, mono: 100.0))
            let base = f.root.appendingPathComponent("journal")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let journal = PhoneStatusDiagnostics(root: base, build: "58",
                now: { Date(timeIntervalSince1970: clock.current.wall) }, uptime: { clock.current.mono })
            let intent = UUID(), failure = UUID()
            journal.begin(intentID: intent, attemptID: failure, recovery: false, connection: nil)
            journal.terminal(attemptID: failure, outcome: .unreachable)
            clock.access { $0.wall += 70; $0.mono += 70 }
            let retry = UUID()
            journal.begin(intentID: intent, attemptID: retry, recovery: true, connection: nil)
            journal.stage(.workerStarted, attemptID: retry); journal.stage(.sent, attemptID: retry)
            journal.stage(.validated, attemptID: retry); journal.terminal(attemptID: retry, outcome: .received)
            let recovered = journal.snapshot()
            try check(recovered.faults[0].window == .windowElapsed && recovered.faults[0].after.isEmpty
                && recovered.faults[0].recovery?.outcome == .received,
                "The context window can end without losing a later request-bound recovery terminal.")
            for _ in 0..<24 {
                let id = UUID(); journal.begin(intentID: UUID(), attemptID: id, recovery: false, connection: nil)
                journal.stage(.workerStarted, attemptID: id); journal.stage(.sent, attemptID: id)
                journal.terminal(attemptID: id, outcome: .staleReport)
            }
            let bounded = journal.snapshot()
            try check(bounded.recentEvents.count <= 24 && bounded.faults.count <= 3
                && bounded.faults.allSatisfy { $0.before.count <= 8 && $0.after.count <= 12 }
                && bounded.truncated && bounded.droppedEvents > 0 && bounded.droppedFaults > 0,
                "Eviction and scope limits are explicit, with bounded before and after contexts.")
            try check(try JSONEncoder().encode(bounded).count <= 65_536, "The exported memory envelope has the same full byte limit.")
        }
        await run("status_journal_failed_persistence_is_sticky_after_later_success") { f in
            let base = f.root.appendingPathComponent("journal"), directory = base.appendingPathComponent("ConnectivityDiagnostics")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let journal = PhoneStatusDiagnostics(root: base, build: "58")
            try check(journal.snapshot().restoreState == .absent, "The test begins before an actual write failure.")
            try FileManager.default.removeItem(at: directory)
            try Data().write(to: directory)
            let failed = UUID(); journal.begin(intentID: UUID(), attemptID: failed, recovery: false, connection: nil)
            journal.terminal(attemptID: failed, outcome: .failed)
            try await eventually("write error visible") { journal.snapshot().persistenceFailureObserved }
            try FileManager.default.removeItem(at: directory)
            let later = UUID(); journal.begin(intentID: UUID(), attemptID: later, recovery: false, connection: nil)
            journal.terminal(attemptID: later, outcome: .cancelled)
            try await eventually("later write completed") { !journal.snapshot().persistencePending }
            let restored = PhoneStatusDiagnostics(root: base, build: "58", runID: UUID()).snapshot()
            try check(restored.persistenceFailureObserved && restored.storageState == .unavailable,
                "A successful later write cannot hide the previously observed persistence gap.")
        }
        await run("status_journal_restored_recovery_requires_complete_attempt_evidence") { f in
            let base = f.root.appendingPathComponent("journal")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let journal = PhoneStatusDiagnostics(root: base, build: "58")
            let intent = UUID(), failure = UUID(), recovery = UUID()
            journal.begin(intentID: intent, attemptID: failure, recovery: false, connection: nil)
            journal.terminal(attemptID: failure, outcome: .unreachable)
            journal.begin(intentID: intent, attemptID: recovery, recovery: true, connection: nil)
            journal.stage(.workerStarted, attemptID: recovery); journal.stage(.sent, attemptID: recovery)
            journal.stage(.validated, attemptID: recovery); journal.terminal(attemptID: recovery, outcome: .received)
            for _ in 0..<6 {
                let id = UUID(); journal.begin(intentID: UUID(), attemptID: id, recovery: false, connection: nil)
                journal.stage(.workerStarted, attemptID: id); journal.stage(.sent, attemptID: id)
                journal.stage(.validated, attemptID: id); journal.terminal(attemptID: id, outcome: .received)
            }
            try await eventually("complete recovery persisted") { !journal.snapshot().persistencePending }
            let restored = PhoneStatusDiagnostics(root: base, build: "58", runID: UUID()).snapshot()
            try check(restored.restoreState == .restored && restored.faults[0].recovery?.events.map(\.stage)
                == [.queued, .workerStarted, .sent, .validated, .terminal],
                "Recovery keeps its bounded evidence after it has left recent events.")
            try check(restored.faults[0].window == .truncated && restored.faults[0].droppedContext > 0,
                "More than twelve after-events makes context truncation explicit.")
            let file = base.appendingPathComponent("ConnectivityDiagnostics/status-history.json")
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
            var faults = object["faults"] as! [[String: Any]]
            var proof = faults[0]["recovery"] as! [String: Any]
            var events = proof["events"] as! [[String: Any]]
            events.remove(at: 3); proof["events"] = events; faults[0]["recovery"] = proof; object["faults"] = faults
            try JSONSerialization.data(withJSONObject: object).write(to: file)
            let invalid = PhoneStatusDiagnostics(root: base, build: "58", runID: UUID()).snapshot()
            try check(invalid.restoreState == .rejected && invalid.persistenceFailureObserved,
                "A schema-valid received marker without the bound validated stage is rejected.")
        }
        await run("status_journal_rejects_bad_schema_sequence_oversize_aliases_and_fifo") { f in
            for mode in ["schema", "sequence", "counter", "oversize", "symlink", "hardlink", "fifo", "directory-alias"] {
                let base = f.root.appendingPathComponent(mode), directory = base.appendingPathComponent("ConnectivityDiagnostics")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent("status-history.json")
                if mode == "oversize" { try Data(repeating: 32, count: 65_537).write(to: file) }
                else if mode == "symlink" || mode == "hardlink" {
                    let other = base.appendingPathComponent("other"); try Data("{}".utf8).write(to: other)
                    if mode == "symlink" { try FileManager.default.createSymbolicLink(at: file, withDestinationURL: other) }
                    else { try check(link(other.path, file.path) == 0, "Create a synthetic hardlink fixture.") }
                } else if mode == "fifo" {
                    try check(mkfifo(file.path, 0o600) == 0, "Create a synthetic FIFO fixture.")
                } else if mode == "directory-alias" {
                    try FileManager.default.removeItem(at: directory)
                    let outside = base.appendingPathComponent("outside")
                    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
                    try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)
                } else {
                    var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(PhoneStatusDiagnosticSnapshot(build: "58", runID: UUID(), observedAtMS: 0))) as! [String: Any]
                    if mode == "sequence" { object["lastPersistedSequence"] = NSNumber(value: UInt64.max) }
                    else if mode == "counter" { object["droppedEvents"] = -1 }
                    else { object["schemaVersion"] = 2 }
                    try JSONSerialization.data(withJSONObject: object).write(to: file)
                }
                let journal = PhoneStatusDiagnostics(root: base, build: "58"), value = journal.snapshot()
                try check(value.restoreState == .rejected || value.restoreState == .unavailable,
                    "Invalid persisted input must not be accepted as valid prior evidence: " + mode)
                try check(value.persistenceFailureObserved, "Restoration failure remains visible.")
                if mode == "directory-alias" {
                    let id = UUID(); journal.begin(intentID: UUID(), attemptID: id, recovery: false, connection: nil)
                    journal.terminal(attemptID: id, outcome: .cancelled)
                    try await Task.sleep(nanoseconds: 100_000_000)
                    try check(!FileManager.default.fileExists(atPath: base.appendingPathComponent("outside/status-history.json").path),
                        "The writer does not follow the fixed diagnostic directory alias.")
                }
            }
            let base = f.root.appendingPathComponent("unverified")
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let journal = PhoneStatusDiagnostics(root: base, build: "PRIVATE_BUILD")
            let id = UUID(); journal.begin(intentID: UUID(), attemptID: id, recovery: true, connection: nil)
            journal.terminal(attemptID: id, outcome: .received)
            try check(journal.snapshot().build == "unknown" && journal.snapshot().recentEvents.last?.outcome == .unverifiedReply,
                "Unvalidated replies and untyped build strings cannot become successful diagnostic evidence.")
        }
    }
}
