import Foundation
import RecordingCore

/// Metadata-only fixtures; no audio file exists, is opened, or is hashed.
enum GoogleDriveProgressFirstCases {
    private struct Failure: Error { let message: String }
    private static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message: message) }
    }
    @MainActor static func run(root: URL) async throws {
        let repository = try RecordingRepository(root: root.appendingPathComponent("repository"),
            recoverTransactionsOnInitialization: false)
        let directory = root.appendingPathComponent("drive")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var ledger = GoogleDriveLibraryLedger()
        try ledger.bind(accountID: "synthetic-p60", label: "Synthetic")
        try ledger.authorize(.existingAndFuture, knownIDs: [], at: start)
        func add(_ sequence: Int) throws -> SegmentManifest {
            let id = UUID(), at = start.addingTimeInterval(Double(sequence) * 30)
            let manifest = SegmentManifest(id: id, sessionID: UUID(), sequence: sequence,
                startedAt: at, endedAt: at.addingTimeInterval(30), sampleRate: 16_000, frameCount: 480_000,
                fileName: id.uuidString.lowercased() + ".caf", byteCount: 8, sha256: String(repeating: "a", count: 64))
            try TransportCodec.encode(manifest).write(to: repository.root.appendingPathComponent("manifests")
                .appendingPathComponent(id.uuidString.lowercased() + ".json"), options: .atomic)
            let receipt = SegmentReceipt(segmentID: id, sha256: manifest.sha256, byteCount: 8, receivedAt: at)
            try TransportCodec.encode(receipt).write(to: repository.root.appendingPathComponent("receipts")
                .appendingPathComponent(id.uuidString.lowercased() + ".json"), options: .atomic)
            return manifest
        }
        for index in 1...8 { _ = try add(index) }
        let first = GoogleDriveSourceSnapshotProbe(repository: repository, directory: directory, ledger: ledger)
        first.cancelOnCheck = 5
        do { try await first.discoverSources(token: 0); throw Failure(message: "Synthetic cancellation did not stop snapshot") }
        catch is CancellationError { }
        let cursorFile = directory.appendingPathComponent("source-snapshot-cursor.json")
        let cursor = try TransportCodec.decode(GoogleDriveSourceSnapshotCursor.self, from: Data(contentsOf: cursorFile))
        let durable = try TransportCodec.decode(GoogleDriveLibraryLedger.self,
            from: Data(contentsOf: directory.appendingPathComponent("ledger.json")))
        try require(cursor.position == 2 && durable.jobs.count == 2 && first.progress.needsSnapshot,
            "Cancelled production snapshot lost durable admissions or advanced coverage")
        let new = try add(9)
        let reloaded = try GoogleDriveSourceSnapshotCursor.loadOrCreate(file: cursorFile, repository: repository, ledger: durable,
            write: { try GoogleDriveLocalFiles.write($0, to: cursorFile) })
        try require(reloaded.position == 2 && reloaded.nextID == new.id,
            "Restart reset completed cursor work or hid a source arriving between leases")
        var failedWriteCursor = reloaded
        do {
            try failedWriteCursor.advance(after: new.id, write: { _ in throw Failure(message: "Injected cursor persistence failure") })
            throw Failure(message: "Cursor persistence failure was swallowed")
        } catch let failure as Failure where failure.message == "Injected cursor persistence failure" { }
        try require(failedWriteCursor.position == reloaded.position, "Cursor advanced without durable persistence")
        let resumed = GoogleDriveSourceSnapshotProbe(repository: repository, directory: directory, ledger: durable)
        try await resumed.discoverSources(token: 0)
        try require(resumed.ledger.jobs.count == 9 && resumed.persisted == 7 && !resumed.progress.needsSnapshot,
            "Resumed production snapshot rescanned/recommitted the completed prefix or missed new metadata")
        let segmentFiles = try FileManager.default.contentsOfDirectory(atPath: repository.root.appendingPathComponent("segments").path)
        try require(!FileManager.default.fileExists(atPath: cursorFile.path) && segmentFiles.isEmpty,
            "Completed cursor was not retired or test touched audio")
        // Deleting an unvisited manifest during suspension must not leave a
        // permanently failing cursor head that prevents later admissions.
        let deletionDirectory = root.appendingPathComponent("deleted-source")
        try FileManager.default.createDirectory(at: deletionDirectory, withIntermediateDirectories: true)
        let deletionCursorFile = deletionDirectory.appendingPathComponent("source-snapshot-cursor.json")
        let beforeDeletion = GoogleDriveSourceSnapshotProbe(repository: repository, directory: deletionDirectory, ledger: ledger)
        beforeDeletion.cancelOnCheck = 5
        do { try await beforeDeletion.discoverSources(token: 0); throw Failure(message: "Expected cancellation before source deletion") }
        catch is CancellationError { }
        let suspended = try TransportCodec.decode(GoogleDriveSourceSnapshotCursor.self, from: Data(contentsOf: deletionCursorFile))
        let deletionLedger = try TransportCodec.decode(GoogleDriveLibraryLedger.self,
            from: Data(contentsOf: deletionDirectory.appendingPathComponent("ledger.json")))
        let deletedID = suspended.nextID!
        let deletedFile = repository.root.appendingPathComponent("manifests")
            .appendingPathComponent(deletedID.uuidString.lowercased() + ".json")
        let deletedBytes = try Data(contentsOf: deletedFile)
        try FileManager.default.removeItem(at: deletedFile)
        let pruned = try GoogleDriveSourceSnapshotCursor.loadOrCreate(file: deletionCursorFile,
            repository: repository, ledger: deletionLedger,
            write: { try GoogleDriveLocalFiles.write($0, to: deletionCursorFile) })
        let durablePruned = try TransportCodec.decode(GoogleDriveSourceSnapshotCursor.self, from: Data(contentsOf: deletionCursorFile))
        try require(pruned.position == 2 && pruned.ids.count == 8 && !pruned.ids.contains(deletedID)
            && pruned.previousIDs == suspended.previousIDs && durablePruned.ids == pruned.ids
            && durablePruned.position == pruned.position,
            "Cold cursor did not durably prune a deleted source while preserving completed work")
        let afterDeletion = GoogleDriveSourceSnapshotProbe(repository: repository, directory: deletionDirectory, ledger: deletionLedger)
        try await afterDeletion.discoverSources(token: 0)
        try require(afterDeletion.ledger.jobs.count == 8 && afterDeletion.persisted == 6
            && !afterDeletion.ledger.jobs.contains { $0.id == deletedID }
            && !afterDeletion.progress.needsSnapshot
            && !FileManager.default.fileExists(atPath: deletionCursorFile.path),
            "Deleted cursor head blocked the remaining sources after a cold restart")
        try deletedBytes.write(to: deletedFile, options: .atomic)
        // A manifest without its receipt is not a permanent visited source:
        // the receipt may commit during suspension before the next process.
        let lateDirectory = root.appendingPathComponent("late-receipt")
        try FileManager.default.createDirectory(at: lateDirectory, withIntermediateDirectories: true)
        let lateCursorFile = lateDirectory.appendingPathComponent("source-snapshot-cursor.json")
        let initialCursor = try GoogleDriveSourceSnapshotCursor.loadOrCreate(file: lateCursorFile,
            repository: repository, ledger: ledger, write: { try GoogleDriveLocalFiles.write($0, to: lateCursorFile) })
        let lateID = initialCursor.nextID!
        let receiptFile = repository.root.appendingPathComponent("receipts").appendingPathComponent(lateID.uuidString.lowercased() + ".json")
        let receiptBytes = try Data(contentsOf: receiptFile)
        try FileManager.default.removeItem(at: receiptFile)
        let beforeReceipt = GoogleDriveSourceSnapshotProbe(repository: repository, directory: lateDirectory, ledger: ledger)
        beforeReceipt.cancelOnCheck = 3
        do { try await beforeReceipt.discoverSources(token: 0); throw Failure(message: "Expected cancellation after absent receipt") }
        catch is CancellationError { }
        let waiting = try TransportCodec.decode(GoogleDriveSourceSnapshotCursor.self, from: Data(contentsOf: lateCursorFile))
        try require(waiting.position == 1 && waiting.awaitingReceiptIDs == [lateID] && beforeReceipt.ledger.jobs.isEmpty,
            "Receipt absence fabricated an authorized source or lost its deferred identity")
        try receiptBytes.write(to: receiptFile, options: .atomic)
        let afterReceipt = GoogleDriveSourceSnapshotProbe(repository: repository, directory: lateDirectory, ledger: ledger)
        try await afterReceipt.discoverSources(token: 0)
        try require(afterReceipt.ledger.jobs.count == 9 && afterReceipt.ledger.jobs.contains { $0.id == lateID },
            "Cold resumed cursor permanently skipped a receipt committed during suspension")
        // Reject aliased manifest metadata before decoding the target. No payload
        // reader is allowed to follow a manifest filename into another file.
        let manifestFile = repository.root.appendingPathComponent("manifests").appendingPathComponent(lateID.uuidString.lowercased() + ".json")
        let retained = root.appendingPathComponent("retained-synthetic-manifest.json")
        try FileManager.default.moveItem(at: manifestFile, to: retained)
        try FileManager.default.createSymbolicLink(at: manifestFile, withDestinationURL: retained)
        var aliasRejected = false
        do { _ = try GoogleDriveSourceSnapshotCursor.readSource(lateID, repository: repository) }
        catch { aliasRejected = true }
        try require(aliasRejected, "Snapshot followed a symlink instead of refusing aliased metadata")
        try FileManager.default.removeItem(at: manifestFile)
        try FileManager.default.moveItem(at: retained, to: manifestFile)
        // Do not let counters from a prior opportunity leak into another round.
        var state = GoogleDriveWorkerDiagnosticState()
        let id = UUID()
        state.begin(id: id, roundSequence: 1, systemGranted: true, parentDeadline: 13, leaseDeadline: 13)
        try require(state.execution?.progressedItems == 0 && state.execution?.firstProgressPhase == nil,
            "New round fabricated progress")
        state.didProgress(phase: .nativeStage)
        try require(state.execution?.progressedItems == 0, "Native registration was misreported as cloud verification")
        state.didProgress(phase: .strictVerify)
        let finishMS = (state.execution?.startedAtMS ?? 0) + 12_000
        let completed = state.snapshot(leasePresent: false, leaseCheckSucceeded: false, finished: true, atMS: finishMS)
        try require(completed?.id == id && completed?.progressedItems == 1 && completed?.firstProgressPhase == .strictVerify
            && completed?.finishedAtMS == finishMS && completed?.systemGranted == true,
            "Progress lost its P-56 execution attribution on completion")
        let decoded = try TransportCodec.decode(GoogleDriveWorkerReport.Execution.self, from: TransportCodec.encode(completed!))
        try require(decoded == completed, "Per-round progress did not survive evidence serialization")
        state.finish(id: id)
        state.begin(id: UUID(), roundSequence: 2, systemGranted: true, parentDeadline: 26, leaseDeadline: 26)
        try require(state.execution?.progressedItems == 0 && state.execution?.firstProgressPhase == nil,
            "Prior progress concealed a later zero-progress opportunity")
        var legacy = try JSONSerialization.jsonObject(with: TransportCodec.encode(completed!)) as! [String: Any]
        for key in ["progressedItems", "firstProgressPhase", "startedAtMS", "finishedAtMS"] { legacy.removeValue(forKey: key) }
        let old = try TransportCodec.decode(GoogleDriveWorkerReport.Execution.self, from: JSONSerialization.data(withJSONObject: legacy))
        try require(old.progressedItems == nil && old.startedAtMS == nil && old.finishedAtMS == nil,
            "Legacy execution invented zero-progress evidence")
    }
}
