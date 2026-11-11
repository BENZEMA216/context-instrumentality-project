import Foundation
import RecordingCore

/// Only synthetic manifests and durable receipts exist. There are no media
/// files, credentials, network requests or native upload sessions in this probe.
enum GoogleDriveDiscoveryFailureCases {
    private struct Failure: Error { let message: String }
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }

    @MainActor private static func fixture(root: URL) throws -> GoogleDriveDiscoveryFailureProbe {
        let repository = try RecordingRepository(root: root.appendingPathComponent("repository"),
            recoverTransactionsOnInitialization: false)
        let directory = root.appendingPathComponent("drive")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let authorizedAt = Date(timeIntervalSince1970: 1_700_000_000)
        var ledger = GoogleDriveLibraryLedger()
        try ledger.bind(accountID: "synthetic-rec36", label: "Synthetic")
        try ledger.authorize(.existingAndFuture, knownIDs: [], at: authorizedAt)
        for sequence in 0..<3 {
            let id = UUID(), startedAt = authorizedAt.addingTimeInterval(Double(sequence) * 30)
            let manifest = SegmentManifest(id: id, sessionID: UUID(), sequence: sequence,
                startedAt: startedAt, endedAt: startedAt.addingTimeInterval(30), sampleRate: 16_000,
                frameCount: 480_000, fileName: id.uuidString.lowercased() + ".caf", byteCount: 8,
                sha256: String(repeating: "a", count: 64))
            let name = id.uuidString.lowercased() + ".json"
            try TransportCodec.encode(manifest).write(to: repository.root.appendingPathComponent("manifests").appendingPathComponent(name))
            try TransportCodec.encode(SegmentReceipt(segmentID: id, sha256: manifest.sha256,
                byteCount: manifest.byteCount, receivedAt: startedAt)).write(to:
                    repository.root.appendingPathComponent("receipts").appendingPathComponent(name))
            if sequence == 0 { try ledger.discover(manifests: [manifest], receivedIDs: [id]) }
        }
        let original = ledger.jobs[0]
        let audio = original.artifacts.first { $0.kind == .audio }!
        try ledger.allocateFile(segmentID: original.id, key: audio.key, fileID: "synthetic-preserved-file")
        try ledger.recordSession(segmentID: original.id, key: audio.key,
            url: "https://www.googleapis.com/upload/drive/v3/files?upload_id=synthetic-preserved-session")
        let source = GoogleDriveSourceSnapshotProbe(repository: repository, directory: directory, ledger: ledger)
        return GoogleDriveDiscoveryFailureProbe(source: source)
    }

    @MainActor static func run(root: URL) async throws {
        for failReadback in [true, false] {
            for failure in [URLError(.timedOut) as Error, GoogleDriveError.http(503)] {
                let probe = try fixture(root: root.appendingPathComponent(UUID().uuidString))
                let original = probe.source.ledger, oldJob = original.jobs[0]
                probe.failReadback = failReadback; probe.advanceFailure = failure
                do {
                    try await GoogleDriveProgressFirstRound.run(background: true,
                        check: { try probe.checkWork(0) },
                        advance: { try await probe.advanceKnownItems(token: 0, lease: probe.lease, discoverAfterFailure: true) },
                        discover: { try await probe.discoverLocal(token: 0) })
                    throw Failure(message: "Transport failure was swallowed after local admission")
                } catch let error as URLError {
                    try require((failure as? URLError)?.code == error.code, "Natural timeout was reclassified")
                } catch GoogleDriveError.http(let status) {
                    try require(status == 503, "Temporary HTTP failure was reclassified")
                }
                let updated = probe.source.ledger
                try require(probe.calls == (failReadback ? ["readback", "discovery"] : ["readback", "delivery", "discovery"]),
                    "Live transport failure starved the bounded local discovery slice or repeated cloud work")
                try require(updated.jobs.count == 3 && !probe.source.progress.needsSnapshot
                    && probe.source.progress.needsDiscovery && probe.source.progress.remaining.count == 3,
                    "Local source admission did not finish honestly without inventing transcript coverage")
                try require(updated.jobs.first { $0.id == oldJob.id } == oldJob
                    && updated.libraryID == original.libraryID && updated.accountID == original.accountID
                    && updated.recordingScope == original.recordingScope && updated.authorizedAt == original.authorizedAt
                    && updated.baselineIDs == original.baselineIDs && updated.enabled == original.enabled
                    && updated.retryAfter == original.retryAfter && updated.failureCount == original.failureCount
                    && updated.savedAudioCount == 0 && updated.jobs.flatMap(\.artifacts).allSatisfy { $0.verifiedAt == nil },
                    "Metadata discovery changed grants, the prepared upload, backoff or cloud receipts")
                let durable = try TransportCodec.decode(GoogleDriveLibraryLedger.self,
                    from: Data(contentsOf: probe.source.directory.appendingPathComponent("ledger.json")))
                try require(durable == updated && probe.currentPhase == .tokenAccess,
                    "Admission was not durable or its snapshot phase concealed the original token failure")
                let media = try FileManager.default.contentsOfDirectory(atPath: probe.source.repository.root.appendingPathComponent("segments").path)
                try require(media.isEmpty, "Local recovery fixture unexpectedly created audio")
            }
        }

        let hardStops: [Error] = [CancellationError(), URLError(.cancelled), GoogleDriveError.needsSignIn,
            GoogleDriveError.http(401), GoogleDriveError.http(403), GoogleDriveLibraryError.changedAccount,
            GoogleDriveLibraryError.changedManifest, GoogleDriveLibraryError.invalidState,
            NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
                userInfo: [NSUnderlyingErrorKey: NSError(domain: "kCFErrorDomainSSL", code: -9806)])]
        for failure in hardStops {
            let probe = try fixture(root: root.appendingPathComponent(UUID().uuidString))
            let original = probe.source.ledger
            probe.advanceFailure = failure
            do { try await probe.advanceKnownItems(token: 0, lease: probe.lease, discoverAfterFailure: true)
                throw Failure(message: "Hard stop was swallowed") }
            catch let error as Failure { throw error }
            catch { }
            try require(probe.calls == ["readback"] && probe.source.ledger == original && probe.source.progress.needsSnapshot,
                "Cancellation or account/source failure performed local work after its stop fence")
        }

        let foreground = try fixture(root: root.appendingPathComponent("foreground-single-slice"))
        foreground.advanceFailure = URLError(.timedOut)
        do {
            try await GoogleDriveProgressFirstRound.run(background: false,
                check: { try foreground.checkWork(0) },
                advance: { try await foreground.advanceKnownItems(token: 0, lease: foreground.lease,
                    discoverAfterFailure: false) },
                discover: { try await foreground.discoverLocal(token: 0) })
            throw Failure(message: "Foreground transport failure was swallowed")
        } catch let error as URLError {
            try require(error.code == .timedOut, "Foreground transport failure was reclassified")
        }
        try require(foreground.calls == ["discovery", "readback"] && foreground.source.ledger.jobs.count == 3
            && foreground.currentPhase == .tokenAccess,
            "Foreground round repeated its completed local slice after a transport failure")

        let healthy = try fixture(root: root.appendingPathComponent("healthy-order"))
        try await GoogleDriveProgressFirstRound.run(background: true,
            check: { try healthy.checkWork(0) },
            advance: { try await healthy.advanceKnownItems(token: 0, lease: healthy.lease, discoverAfterFailure: true) },
            discover: { try await healthy.discoverLocal(token: 0) })
        try require(healthy.calls == ["readback", "delivery", "discovery"],
            "Local fallback displaced REC-1 known-item progress-first order")
    }

    enum RecoveryStop { case beforeDiscovery, duringDiscovery, afterDiscovery }

    /// Exercise both network operations and both retryable network errors at
    /// every boundary where the best-effort local slice can interrupt recovery.
    @MainActor static func runInterruptedRecovery(root: URL, stop: RecoveryStop) async throws {
        let localFailures: [Error] = stop == .duringDiscovery
            ? [CancellationError(), GoogleDriveLibraryError.invalidState] : [CancellationError()]
        for failReadback in [true, false] {
            for originalError in [URLError(.timedOut,
                userInfo: [NSLocalizedDescriptionKey: "Synthetic original network timeout"]) as Error,
                GoogleDriveError.http(503)] {
                for localError in localFailures {
                    let probe = try fixture(root: root.appendingPathComponent(UUID().uuidString))
                    let original = probe.source.ledger, oldJob = original.jobs[0]
                    probe.failReadback = failReadback; probe.advanceFailure = originalError
                    probe.cancelOnAdvance = stop == .beforeDiscovery
                    probe.cancelAfterDiscovery = stop == .afterDiscovery
                    if stop == .duringDiscovery { probe.localFailure = localError }
                    do {
                        try await probe.advanceKnownItems(token: 0, lease: probe.lease, discoverAfterFailure: true)
                        throw Failure(message: "Interrupted local recovery swallowed the network failure")
                    } catch let error as URLError {
                        try require((originalError as? URLError)?.code == error.code
                            && originalError.localizedDescription == error.localizedDescription,
                            "Local recovery replaced the original natural timeout")
                    } catch GoogleDriveError.http(let status) {
                        guard case GoogleDriveError.http(let originalStatus) = originalError else {
                            throw Failure(message: "Local recovery replaced the network error with an HTTP failure")
                        }
                        try require(status == originalStatus, "Local recovery changed the original HTTP failure")
                    }
                    let expectedCalls = (failReadback ? ["readback"] : ["readback", "delivery"])
                        + (stop == .beforeDiscovery ? [] : ["discovery"])
                    try require(probe.calls == expectedCalls && probe.currentPhase == .tokenAccess,
                        "Interrupted recovery repeated network work or hid the original failure phase")
                    if stop == .afterDiscovery {
                        let durable = try TransportCodec.decode(GoogleDriveLibraryLedger.self,
                            from: Data(contentsOf: probe.source.directory.appendingPathComponent("ledger.json")))
                        try require(durable == probe.source.ledger && durable.jobs.count == 3
                            && durable.jobs.first { $0.id == oldJob.id } == oldJob
                            && durable.savedAudioCount == 0 && !probe.source.progress.needsSnapshot,
                            "Lease expiration discarded durable local admission or invented a cloud receipt")
                    } else {
                        try require(probe.source.ledger == original && probe.source.progress.needsSnapshot,
                            "An interrupted local slice changed authorization, uploads or discovery coverage")
                    }
                }
            }
        }
    }
}
