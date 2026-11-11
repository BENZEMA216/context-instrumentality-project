import Foundation
import RecordingCore

extension Fixture {
    var backlogURL: URL { phone.root.appendingPathComponent("phone-watch-backlog-evidence.json") }
    var snapshotURL: URL { phone.root.appendingPathComponent("phone-watch-snapshot.json") }

    func persistedBacklog() throws -> Bool? {
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: backlogURL)) as? [String: Any]
        return value?["hasBacklog"] as? Bool
    }

    func persistedSnapshot() throws -> RecorderSnapshot {
        try TransportCodec.decode(RecorderSnapshot.self, from: Data(contentsOf: snapshotURL))
    }

    func legacySnapshotData(pending: Int, at seconds: TimeInterval) throws -> Data {
        let snapshot = RecorderSnapshot(state: .paused, sessionID: recordingSession.id,
            observedAt: Date(timeIntervalSince1970: seconds), pendingCount: pending)
        var value = try JSONSerialization.jsonObject(with: TransportCodec.encode(snapshot)) as! [String: Any]
        value.removeValue(forKey: "pendingCountIsKnown")
        return try JSONSerialization.data(withJSONObject: value)
    }

    func hasBacklogFailure(_ fragment: String) throws -> Bool {
        try phone.events().contains {
            $0.kind == "phone.watch_backlog_evidence_failed" && $0.detail.contains(fragment)
        }
    }
}

extension Probe {
    private func maintenance(_ fixture: Fixture) async throws -> PhoneBackgroundMaintenanceResult {
        let expected = fixture.maintenanceResults.current.count + 1
        fixture.begin()
        try await eventually("controlled backlog maintenance finishes") {
            fixture.maintenanceResults.current.count == expected
        }
        return fixture.maintenanceResults.current[expected - 1]
    }

    func runBacklogPersistenceScenarios() async {
        await run("unknown_zero_without_positive_evidence_does_not_request_work") { f in
            try f.reportSnapshot(pending: 0, known: false, at: 1_800_000_100)
            try self.check(f.maintenanceRequests.current == 0, "Unknown zero must not itself request maintenance.")
            try self.check(!FileManager.default.fileExists(atPath: f.backlogURL.path),
                "Unknown zero alone must not invent a positive-evidence ledger.")
            try f.restart()
            let result = try await self.maintenance(f)
            try self.check(result.succeeded && !result.needsMore, "An otherwise empty restarted worker must finish.")
        }
        await run("unknown_zero_display_write_failure_does_not_preserve_empty_fallback", backlogFault: {
            if case .beforeSnapshotWrite = $0 { throw ProbeFailure.failed("display-only write failure") }
        }) { f in
            try f.reportSnapshot(pending: 0, known: false, at: 1_800_000_100)
            try self.check(f.maintenanceRequests.current == 0, "A failed unknown display update creates no new work.")
            try self.check(try f.hasBacklogFailure("retained_positive=false"), "Storage failure must remain diagnosable.")
            let result = try await self.maintenance(f)
            try self.check(result.succeeded && !result.needsMore,
                "A display-only write failure must still allow the empty fallback to be cancelled.")
        }
        await run("unknown_positive_and_legacy_zero_require_explicit_known_zero_to_clear") { f in
            try f.reportSnapshot(pending: 2, known: false, at: 1_800_000_100)
            try self.check(try f.persistedBacklog() == true, "Any reported positive count is durable scheduling evidence.")
            f.connectivity.session(f.session, didReceiveApplicationContext: [
                TransportCodec.snapshotKey: try f.legacySnapshotData(pending: 0, at: 1_800_000_101)])
            _ = f.connectivity.currentState()
            let retained = try await self.maintenance(f)
            try self.check(retained.succeeded && retained.needsMore, "Legacy zero defaults to unknown and retains evidence.")
            // A refined count can use the same observation timestamp.
            try f.reportSnapshot(pending: 0, known: true, at: 1_800_000_101)
            try f.restart()
            let cleared = try await self.maintenance(f)
            try self.check(try f.persistedBacklog() == false, "Explicit known zero must durably clear the hint.")
            try self.check(cleared.succeeded && !cleared.needsMore, "Successful clear must survive restart.")
        }
        await run("older_zero_and_older_positive_cannot_reverse_newer_evidence") { f in
            try f.reportSnapshot(pending: 4, known: true, at: 1_800_000_200)
            let positiveRequests = f.maintenanceRequests.current
            try f.reportSnapshot(pending: 0, known: true, at: 1_800_000_199)
            try self.check(try f.persistedBacklog() == true, "An older known zero cannot erase newer positive evidence.")
            try f.reportSnapshot(pending: 0, known: true, at: 1_800_000_201)
            try f.restart()
            try f.reportSnapshot(pending: 9, known: true, at: 1_800_000_200)
            try self.check(try f.persistedBacklog() == false, "An older positive cannot resurrect cleared work after restart.")
            try self.check(f.maintenanceRequests.current == positiveRequests, "Rejected stale positives must not schedule.")
            let result = try await self.maintenance(f)
            try self.check(result.succeeded && !result.needsMore, "Newest known-zero observation remains authoritative.")
        }
        await run("legacy_migration_failure_preserves_original_positive_snapshot") { f in
            let legacy = try f.legacySnapshotData(pending: 5, at: 1_800_000_100)
            try legacy.write(to: f.snapshotURL)
            try FileManager.default.createDirectory(at: f.backlogURL, withIntermediateDirectories: false)
            try f.restart()
            try f.reportSnapshot(pending: 0, known: false, at: 1_800_000_101)
            try self.check(try Data(contentsOf: f.snapshotURL) == legacy,
                "Unknown zero must not overwrite the only durable positive source when migration fails.")
            let result = try await self.maintenance(f)
            try self.check(!result.succeeded && result.needsMore, "Migration failure keeps the existing fallback and evidence.")
            try self.check(try f.hasBacklogFailure("operation=migrate"), "Initialization failures must reach diagnostics after start.")
            try FileManager.default.removeItem(at: f.backlogURL)
            try f.restart()
            try self.check(try f.persistedBacklog() == true, "A later startup retries migration from the preserved source.")
        }
        await run("first_positive_ledger_failure_uses_durable_snapshot_backup") { f in
            try FileManager.default.createDirectory(at: f.backlogURL, withIntermediateDirectories: false)
            try f.reportSnapshot(pending: 3, known: true, at: 1_800_000_100)
            try self.check(try f.persistedSnapshot().pendingCount == 3,
                "A first positive must still attempt its separate snapshot path when the ledger is unwritable.")
            try self.check(f.maintenanceRequests.current > 0, "Persistence failure must still request the fallback.")
            try self.check(try f.hasBacklogFailure("positive_snapshot_durable=true"), "Successful backup must be explicit.")
            let result = try await self.maintenance(f)
            try self.check(!result.succeeded && result.needsMore, "The current worker retains and reports the ledger failure.")
            try FileManager.default.removeItem(at: f.backlogURL)
            try f.restart()
            try self.check(try f.persistedBacklog() == true, "Restart must migrate the durable first-positive backup.")
        }
        await run("both_positive_metadata_paths_fail_without_claiming_durability", backlogFault: {
            switch $0 {
            case .beforeEvidenceWrite, .beforeSnapshotWrite: throw ProbeFailure.failed("both metadata paths unavailable")
            default: break
            }
        }) { f in
            try f.reportSnapshot(pending: 3, known: true, at: 1_800_000_100)
            try self.check(!FileManager.default.fileExists(atPath: f.backlogURL.path)
                && !FileManager.default.fileExists(atPath: f.snapshotURL.path), "Both injected paths must remain unwritten.")
            try self.check(try f.hasBacklogFailure("positive_snapshot_durable=false"), "No durability claim is allowed.")
            let result = try await self.maintenance(f)
            try self.check(!result.succeeded && result.needsMore, "In-memory evidence and fallback survive the storage outage.")
        }
        for afterWrite in [false, true] {
            let failClear = Locked(false)
            await run("known_zero_ledger_\(afterWrite ? "postwrite_sync" : "prewrite")_failure_retains_positive",
                backlogFault: { point in
                    guard failClear.current else { return }
                    switch point {
                    case .beforeEvidenceWrite(false) where !afterWrite,
                         .afterEvidenceWriteBeforeSynchronization(false) where afterWrite:
                        throw ProbeFailure.failed("known-zero ledger commit failure")
                    default: break
                    }
                }) { f in
                    try f.reportSnapshot(pending: 4, known: true, at: 1_800_000_100)
                    failClear.access { $0 = true }
                    try f.reportSnapshot(pending: 0, known: true, at: 1_800_000_101)
                    try self.check(try f.persistedBacklog() == true,
                        "A failed clear must retain or restore the durable positive ledger, including after visible replacement.")
                    let failed = try await self.maintenance(f)
                    try self.check(!failed.succeeded && failed.needsMore, "Failed clear cannot authorize empty cancellation.")
                    failClear.access { $0 = false }
                    try f.restart()
                    let restored = try await self.maintenance(f)
                    try self.check(restored.needsMore, "A restart must preserve the repaired positive ledger.")
                    try f.reportSnapshot(pending: 0, known: true, at: 1_800_000_102)
                    try f.restart()
                    let recovered = try await self.maintenance(f)
                    try self.check(recovered.succeeded && !recovered.needsMore, "A later explicit zero must recover a failed clear.")
                }
        }
        for afterWrite in [false, true] {
            let failSnapshot = Locked(false)
            await run("known_zero_snapshot_\(afterWrite ? "postwrite_sync" : "prewrite")_failure_retains_positive",
                backlogFault: { point in
                    guard failSnapshot.current else { return }
                    switch point {
                    case .beforeSnapshotWrite where !afterWrite,
                         .afterSnapshotWriteBeforeSynchronization where afterWrite:
                        throw ProbeFailure.failed("snapshot clear failure")
                    default: break
                    }
                }) { f in
                    try f.reportSnapshot(pending: 2, known: true, at: 1_800_000_100)
                    failSnapshot.access { $0 = true }
                    try f.reportSnapshot(pending: 0, known: true, at: 1_800_000_101)
                    try self.check(try f.persistedBacklog() == true, "Snapshot failure must precede any evidence clear.")
                    let failed = try await self.maintenance(f)
                    try self.check(!failed.succeeded && failed.needsMore, "Snapshot failure cannot erase the fallback.")
                    failSnapshot.access { $0 = false }
                    try f.restart()
                    let restored = try await self.maintenance(f)
                    try self.check(restored.needsMore, "Both snapshot failure boundaries retain durable evidence on restart.")
                }
        }
        for afterWrite in [false, true] {
            let failSnapshot = Locked(false)
            await run("positive_ledger_watermark_survives_snapshot_\(afterWrite ? "postwrite_sync" : "prewrite")_failure",
                backlogFault: { point in
                    guard failSnapshot.current else { return }
                    switch point {
                    case .beforeSnapshotWrite where !afterWrite,
                         .afterSnapshotWriteBeforeSynchronization where afterWrite:
                        throw ProbeFailure.failed("positive display snapshot failure")
                    default: break
                    }
                }) { f in
                    try f.reportSnapshot(pending: 0, known: true, at: 1_800_000_100)
                    failSnapshot.access { $0 = true }
                    try f.reportSnapshot(pending: 6, known: true, at: 1_800_000_200)
                    try self.check(try f.persistedBacklog() == true, "The positive ledger commits before display metadata.")
                    failSnapshot.access { $0 = false }
                    try f.restart()
                    try f.reportSnapshot(pending: 0, known: true, at: 1_800_000_150)
                    try self.check(try f.persistedBacklog() == true, "Restart must recover the newer ledger ordering watermark.")
                    let result = try await self.maintenance(f)
                    try self.check(result.needsMore, "An old display timestamp cannot admit a stale zero after restart.")
                }
        }
        await run("corrupt_ledger_does_not_invent_positive_work_and_explicit_zero_repairs_it") { f in
            try Data("broken evidence".utf8).write(to: f.backlogURL)
            try f.restart()
            try f.reportSnapshot(pending: 0, known: false, at: 1_800_000_100)
            try self.check(f.maintenanceRequests.current == 0, "Unreadable evidence plus unknown zero must not invent new work.")
            let uncertain = try await self.maintenance(f)
            try self.check(!uncertain.succeeded && !uncertain.needsMore,
                "Unreadable existing evidence preserves a fallback through failure without inventing a positive count.")
            try f.reportSnapshot(pending: 0, known: true, at: 1_800_000_101)
            try f.restart()
            let repaired = try await self.maintenance(f)
            try self.check(repaired.succeeded && !repaired.needsMore, "An explicit known zero can repair corrupted scheduling state.")
            try self.check(try f.persistedBacklog() == false, "The repaired record must be a durable explicit clear.")
        }
        await run("unreadable_legacy_snapshot_without_ledger_cannot_be_erased_by_unknown_zero") { f in
            let original = Data("unreadable legacy snapshot".utf8)
            try original.write(to: f.snapshotURL)
            try f.restart()
            try f.reportSnapshot(pending: 0, known: false, at: 1_800_000_100)
            try self.check(try Data(contentsOf: f.snapshotURL) == original,
                "Unknown zero cannot replace a legacy source that has not been read or migrated.")
            try self.check(f.maintenanceRequests.current == 0, "Read uncertainty must not fabricate new positive work.")
            try f.restart()
            let uncertain = try await self.maintenance(f)
            try self.check(!uncertain.succeeded && !uncertain.needsMore,
                "Unreadable existing state must survive unknown-zero delivery and restart without authorizing cancellation.")
            try self.check(try f.hasBacklogFailure("operation=restore_snapshot"), "Startup read failure must be recorded.")
            try f.reportSnapshot(pending: 0, known: true, at: 1_800_000_101)
            try f.restart()
            let repaired = try await self.maintenance(f)
            try self.check(repaired.succeeded && !repaired.needsMore,
                "An explicit known-zero observation must repair the unreadable legacy state.")
        }
        let failPositiveLedger = Locked(false)
        await run("older_false_ledger_cannot_erase_unreadable_newer_positive_snapshot",
            backlogFault: { point in
                if case .beforeEvidenceWrite(true) = point, failPositiveLedger.current {
                    throw ProbeFailure.failed("newer positive ledger path unavailable")
                }
            }) { f in
                try f.reportSnapshot(pending: 0, known: true, at: 1_800_000_100)
                try self.check(try f.persistedBacklog() == false, "The fixture must begin with a valid cleared ledger.")
                failPositiveLedger.access { $0 = true }
                try f.reportSnapshot(pending: 3, known: true, at: 1_800_000_200)
                try self.check(try f.persistedBacklog() == false, "The failed positive commit must leave the older false ledger.")
                try self.check(try f.persistedSnapshot().pendingCount == 3,
                    "The newer positive snapshot must have been durably saved as the separate backup.")
                try self.check(try f.hasBacklogFailure("positive_snapshot_durable=true"),
                    "The concrete failure trajectory must include a durable positive backup.")
                let unreadable = Data("unreadable newer positive snapshot backup".utf8)
                try unreadable.write(to: f.snapshotURL)
                failPositiveLedger.access { $0 = false }
                try f.restart()
                let requestsBeforeUnknownZero = f.maintenanceRequests.current
                try f.reportSnapshot(pending: 0, known: false, at: 1_800_000_300)
                try self.check(try Data(contentsOf: f.snapshotURL) == unreadable,
                    "A valid older false ledger cannot authorize overwriting an unreadable newer positive backup.")
                try self.check(f.maintenanceRequests.current == requestsBeforeUnknownZero,
                    "Preserving read uncertainty must not invent a positive work request.")
                try f.restart()
                let uncertain = try await self.maintenance(f)
                try self.check(!uncertain.succeeded && !uncertain.needsMore,
                    "Unknown zero and restart must retain uncertainty despite the valid older false ledger.")
                try f.reportSnapshot(pending: 0, known: true, at: 1_800_000_301)
                try f.restart()
                let repaired = try await self.maintenance(f)
                try self.check(repaired.succeeded && !repaired.needsMore,
                    "An explicit known zero must still repair the uncertain snapshot and allow empty completion.")
            }
    }
}
