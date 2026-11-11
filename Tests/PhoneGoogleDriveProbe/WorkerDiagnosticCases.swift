import Darwin
import Dispatch
import Foundation
import RecordingCore

/// Actual worker attribution and publication code with synthetic metadata only.
/// The injected writer never touches a recording, credential, device or network.
enum GoogleDriveWorkerDiagnosticCases {
    private struct Failure: Error { let message: String }
    private typealias Report = GoogleDriveWorkerReport
    private typealias State = GoogleDriveWorkerDiagnosticState
    private typealias Health = GoogleDriveWorkerWriterHealth

    private struct LoggedFailure: Sendable {
        let destination: GoogleDriveWorkerDiagnosticsWriter.Destination
        let sequence: UInt64
        let failure: Health.Failure
    }

    /// Only this synthetic persistence shell is substituted. The real writer
    /// owns ordering, coalescing, failure accounting and health publication.
    private final class WriteSink: @unchecked Sendable {
        let firstReportEntered = DispatchSemaphore(value: 0)
        let releaseFirstReport = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var reportAttempts = 0
        private var healthAttempts = 0
        private var logs: [LoggedFailure] = []
        private let privateMarker: String

        init(privateMarker: String) { self.privateMarker = privateMarker }

        func write(_ data: Data, to file: URL) throws {
            let isReport: Bool
            switch file.lastPathComponent {
            case "worker-status.json": isReport = true
            case "worker-health.json": isReport = false
            default: throw Failure(message: "Writer escaped its two fixed diagnostic leaves")
            }
            lock.lock()
            if isReport { reportAttempts += 1 } else { healthAttempts += 1 }
            let ordinal = isReport ? reportAttempts : healthAttempts
            lock.unlock()
            if isReport && ordinal == 1 {
                firstReportEntered.signal()
                guard releaseFirstReport.wait(timeout: .now() + 10) == .success else {
                    throw Failure(message: "Synthetic blocked write was not released")
                }
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
                    userInfo: [NSLocalizedDescriptionKey: privateMarker])
            }
            if !isReport && ordinal == 1 {
                throw NSError(domain: NSPOSIXErrorDomain, code: 28,
                    userInfo: [NSLocalizedDescriptionKey: privateMarker])
            }
            try data.write(to: file, options: .atomic)
        }

        func log(_ destination: GoogleDriveWorkerDiagnosticsWriter.Destination,
                 sequence: UInt64, failure: Health.Failure) {
            lock.lock(); defer { lock.unlock() }
            logs.append(.init(destination: destination, sequence: sequence, failure: failure))
        }

        func snapshot() -> (reports: Int, health: Int, logs: [LoggedFailure]) {
            lock.lock(); defer { lock.unlock() }
            return (reportAttempts, healthAttempts, logs)
        }
    }

    private static func observation(_ state: State, event: Report.Event, atMS: Int64,
                                    leasePresent: Bool = true, leaseCheckSucceeded: Bool = true,
                                    finished: Bool = false) -> Report.Observation {
        var value = Report.Observation(atMS: atMS, event: event, phase: .accountGet,
            roundSequence: state.execution?.roundSequence ?? 0, foreground: false,
            roundActive: leasePresent, remainingMS: leasePresent && leaseCheckSucceeded ? 5_000 : 0,
            pendingCount: 350, nativeCount: 2, readbackCount: 1)
        value.execution = state.snapshot(leasePresent: leasePresent,
            leaseCheckSucceeded: leaseCheckSucceeded, finished: finished)
        value.cancellationReason = state.cancellationReason
        return value
    }

    private static func report(processRunID: UUID, sequence: UInt64, state: State,
                               observations: [Report.Observation]) -> Report {
        var value = Report(schemaVersion: 1, processRunID: processRunID,
            build: String(repeating: "7", count: 32), generatedAtMS: observations.last!.atMS,
            sequence: sequence, enabled: true, ledgerAvailable: true,
            sourceSnapshotPending: false, discoveryComplete: false, discoveryRemaining: 622,
            authorizedSourceCount: 622, savedAudioCount: 450, pendingArtifactCount: 350,
            nativeCount: 2, readbackCount: 1, itemRetryCount: 3, retryAfterMS: nil,
            failureCount: 16, systemGranted: observations.last!.execution?.systemGranted ?? false,
            lastFailure: state.lastFailure, lastFailurePhase: state.lastFailurePhase,
            observations: observations)
        value.diagnosticsRevision = 3
        value.execution = observations.last!.execution
        value.lastFailureContext = state.lastFailureContext
        return value
    }

    @MainActor
    static func run(root: URL) async throws -> Int {
        var count = 0
        func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try condition() else { throw Failure(message: message) }
            count += 1
        }
        let processRunID = UUID(), firstID = UUID(), secondID = UUID()
        let at: Int64 = 1_800_000_000_000
        let privateMarker = "SYNTHETIC_PRIVATE_WORKER_DESCRIPTION_MUST_NOT_ESCAPE"
        let networkFailure = NSError(domain: NSURLErrorDomain, code: -1200,
            userInfo: [NSLocalizedDescriptionKey: privateMarker])
        var state = State()
        state.begin(id: firstID, roundSequence: 17, systemGranted: true,
            parentDeadline: 130, leaseDeadline: 120)
        state.failed(networkFailure, phase: .accountGet, atMS: at, reportSequence: 41)
        let firstFailureContext = state.lastFailureContext
        try require(state.lastFailure?.kind == .network && state.lastFailure?.code == -1200
            && firstFailureContext?.executionID == firstID && firstFailureContext?.roundSequence == 17
            && firstFailureContext?.reportSequence == 41 && firstFailureContext?.atMS == at,
            "Initial failure did not bind its exact worker observation")

        state.finish(id: firstID)
        state.begin(id: secondID, roundSequence: 18, systemGranted: false,
            parentDeadline: nil, leaseDeadline: 160)
        try require(state.execution?.id == secondID && state.lastFailureContext == firstFailureContext
            && state.lastFailurePhase == .accountGet,
            "Starting a new round rebound the retained failure")
        var ring: [Report.Observation] = []
        for offset in 0..<12 {
            ring.append(observation(state, event: .phaseChanged, atMS: at + Int64(offset + 1)))
            ring = Array(ring.suffix(Report.maximumObservations))
        }
        let rich = report(processRunID: processRunID, sequence: 53, state: state, observations: ring)
        let richBytes = try rich.encoded()
        let restored = try TransportCodec.decode(Report.self, from: richBytes)
        try require(restored.observations.count == 8
            && restored.observations.allSatisfy { $0.execution?.id == secondID }
            && restored.lastFailureContext == firstFailureContext
            && restored.lastFailureContext?.executionID != restored.execution?.id,
            "Evicting an old round from the ring rebound its retained failure")
        try require(restored.diagnosticsRevision == 3 && richBytes.count <= Report.maximumBytes
            && !String(decoding: richBytes, as: UTF8.self).contains(privateMarker),
            "Worker attribution exceeded its report cap or exposed a description")
        let reportText = String(decoding: richBytes, as: UTF8.self)
        try require(!reportText.contains("accountID") && !reportText.contains("uploadURL")
            && !reportText.contains("requestID") && !reportText.contains("segmentID"),
            "Worker attribution invented an account source or HTTP request binding")

        // Exercise synthesized decoding with the exact fields an old schema-1
        // report lacks, while a nearby new round and an old failure still exist.
        guard var legacyObject = try JSONSerialization.jsonObject(with: richBytes) as? [String: Any],
              var legacyObservations = legacyObject["observations"] as? [[String: Any]] else {
            throw Failure(message: "Synthetic worker JSON was not an object")
        }
        var revisionTwo = legacyObject
        revisionTwo["diagnosticsRevision"] = 2
        var previousExecution = revisionTwo["execution"] as! [String: Any]
        previousExecution.removeValue(forKey: "kind"); revisionTwo["execution"] = previousExecution
        revisionTwo["observations"] = legacyObservations.map { observation in
            var value = observation, execution = value["execution"] as! [String: Any]
            execution.removeValue(forKey: "kind"); value["execution"] = execution
            return value
        }
        let previousReport = try TransportCodec.decode(Report.self,
            from: JSONSerialization.data(withJSONObject: revisionTwo, options: [.sortedKeys]))
        try require(previousReport.execution?.kind == nil && previousReport.execution?.id == secondID
            && previousReport.observations.allSatisfy { $0.execution?.kind == nil && $0.execution?.id == secondID }
            && previousReport.lastFailureContext == firstFailureContext,
            "An older round without a kind was relabeled or lost its original failure attribution")
        for key in ["diagnosticsRevision", "execution", "lastFailureContext"] {
            legacyObject.removeValue(forKey: key)
        }
        for index in legacyObservations.indices {
            legacyObservations[index].removeValue(forKey: "execution")
            legacyObservations[index].removeValue(forKey: "cancellationReason")
        }
        legacyObject["observations"] = legacyObservations
        let legacyBytes = try JSONSerialization.data(withJSONObject: legacyObject, options: [.sortedKeys])
        let legacy = try TransportCodec.decode(Report.self, from: legacyBytes)
        try require(legacy.diagnosticsRevision == nil && legacy.execution == nil
            && legacy.lastFailureContext == nil && legacy.lastFailure?.kind == .network
            && legacy.observations.allSatisfy { $0.execution == nil && $0.cancellationReason == nil },
            "Legacy schema-1 decoding fabricated new attribution or health")
        for key in ["diagnosticsRevision", "execution", "lastFailureContext"] { legacyObject[key] = NSNull() }
        for index in legacyObservations.indices {
            legacyObservations[index]["execution"] = NSNull()
            legacyObservations[index]["cancellationReason"] = NSNull()
        }
        legacyObject["observations"] = legacyObservations
        let nullLegacy = try TransportCodec.decode(Report.self,
            from: JSONSerialization.data(withJSONObject: legacyObject, options: [.sortedKeys]))
        try require(nullLegacy.execution == nil && nullLegacy.lastFailureContext == nil
            && nullLegacy.observations.allSatisfy { $0.cancellationReason == nil },
            "Explicit null legacy fields became a current-round assertion")

        var granted = State()
        let grantedID = UUID()
        granted.begin(id: grantedID, roundSequence: 19, systemGranted: true,
            parentDeadline: 240, leaseDeadline: 230)
        granted.updateLeaseDeadline(220)
        granted.noteCancellation(.parentCancellationObserved)
        let finished = observation(granted, event: .roundFinished, atMS: at + 20,
            leasePresent: false, leaseCheckSucceeded: false, finished: true)
        try require(!finished.roundActive && finished.execution?.id == grantedID
            && finished.execution?.roundSequence == 19 && finished.execution?.systemGranted == true
            && finished.execution?.leaseState == .finished
            && finished.execution?.parentDeadlineUptimeMS == 240_000
            && finished.execution?.leaseDeadlineUptimeMS == 220_000
            && finished.cancellationReason == .parentCancellationObserved,
            "Finishing after lease cleanup lost the original round grant or cancellation signal")
        granted.finish(id: UUID())
        try require(granted.execution?.id == grantedID, "An unrelated finish cleared the current round")
        granted.finish(id: grantedID)
        let afterFinish = observation(granted, event: .callback, atMS: at + 21,
            leasePresent: false, leaseCheckSucceeded: false)
        try require(afterFinish.execution == nil && afterFinish.cancellationReason == nil
            && granted.execution == nil, "A later callback inherited a finished execution")
        let finishedBytes = try report(processRunID: processRunID, sequence: 54, state: granted,
            observations: [finished, afterFinish]).encoded()
        let finishedReport = try TransportCodec.decode(Report.self, from: finishedBytes)
        try require(finishedReport.execution == nil && !finishedReport.systemGranted
            && finishedReport.observations.first?.execution?.systemGranted == true,
            "A report's final grant flag rewrote its finished observation")

        for reason in [Report.CancellationReason.taskCancellationObserved, .parentCancellationObserved,
                       .deadlineReached, .leaseExpirationObserved] {
            var cancelled = State()
            let id = UUID()
            cancelled.begin(id: id, roundSequence: 20, systemGranted: false,
                parentDeadline: nil, leaseDeadline: 300)
            cancelled.noteCancellation(reason)
            let event: Report.Event = reason == .leaseExpirationObserved ? .leaseExpired : .cancelled
            let item = observation(cancelled, event: event, atMS: at + 30,
                leasePresent: true, leaseCheckSucceeded: false)
            let encoded = try report(processRunID: processRunID, sequence: 55,
                state: cancelled, observations: [item]).encoded()
            let decoded = try TransportCodec.decode(Report.self, from: encoded)
            try require(decoded.observations[0].cancellationReason == reason
                && decoded.observations[0].execution?.leaseState == .checkFailed
                && decoded.lastFailure == nil && decoded.lastFailureContext == nil,
                "A cancellation signal became an ordinary network failure")
        }
        var expiry = State()
        expiry.begin(id: UUID(), roundSequence: 21, systemGranted: true,
            parentDeadline: 330, leaseDeadline: 330)
        expiry.noteCancellation(.deadlineReached)
        expiry.noteCancellation(.taskCancellationObserved)
        try require(expiry.cancellationReason == .deadlineReached,
            "A task catch erased the earlier deadline observation")
        expiry.noteCancellation(.leaseExpirationObserved)
        expiry.noteCancellation(.parentCancellationObserved)
        expiry.noteCancellation(.taskCancellationObserved)
        try require(expiry.cancellationReason == .leaseExpirationObserved,
            "A delayed catch overwrote the explicit lease-expiration signal")
        expiry.failed(networkFailure, phase: .tokenAccess, atMS: at + 31, reportSequence: 56)
        expiry.noteCancellation(.taskCancellationObserved)
        try require(expiry.lastFailure?.kind == .network && expiry.lastFailure?.code == -1200
            && expiry.lastFailureContext?.phase == .tokenAccess
            && expiry.cancellationReason == .leaseExpirationObserved,
            "An independently observed network error and cancellation signal were merged")
        expiry.clearFailure()
        try require(expiry.lastFailure == nil && expiry.lastFailurePhase == nil
            && expiry.lastFailureContext == nil && expiry.cancellationReason == .leaseExpirationObserved,
            "Clearing an old failure cleared independent cancellation evidence")
        var generations = State()
        generations.begin(id: UUID(), roundSequence: 22, systemGranted: false,
            parentDeadline: nil, leaseDeadline: 360, generation: 2)
        generations.noteCancellation(.generationChanged, generation: 1)
        try require(generations.cancellationReason == nil,
            "An older task's cancellation polluted a newer worker generation")
        generations.noteCancellation(.parentCancellationObserved, generation: 2)
        try require(generations.cancellationReason == .parentCancellationObserved,
            "The current generation lost its actual cancellation signal")

        let metadata = Health.Failure(GoogleDriveMetadataIOError(code: 28))
        let cocoa = Health.Failure(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError,
            userInfo: [NSLocalizedDescriptionKey: privateMarker]))
        let posix = Health.Failure(NSError(domain: NSPOSIXErrorDomain, code: 28,
            userInfo: [NSLocalizedDescriptionKey: privateMarker]))
        let encoding = Health.Failure(EncodingError.invalidValue(privateMarker,
            .init(codingPath: [], debugDescription: privateMarker)))
        let other = Health.Failure(NSError(domain: privateMarker, code: 99,
            userInfo: [NSLocalizedDescriptionKey: privateMarker]))
        try require(metadata.kind == .metadata && metadata.code == 28
            && cocoa.kind == .cocoa && cocoa.code == NSFileWriteNoPermissionError
            && posix.kind == .posix && posix.code == 28
            && encoding.kind == .encoding && encoding.code == nil
            && other.kind == .other && other.code == nil,
            "Diagnostic publication failures escaped their fixed local categories")

        let directory = root.appendingPathComponent("worker-diagnostics-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let reportFile = directory.appendingPathComponent("worker-status.json")
        let healthFile = directory.appendingPathComponent("worker-health.json")
        let queue = DispatchQueue(label: "synthetic.worker-diagnostics.serial")
        let sink = WriteSink(privateMarker: privateMarker)
        let writer = GoogleDriveWorkerDiagnosticsWriter(file: reportFile, processRunID: processRunID, build: "756", queue: queue,
            write: { [sink] data, file in try sink.write(data, to: file) },
            failureLog: { [sink] destination, sequence, failure in
                sink.log(destination, sequence: sequence, failure: failure)
            })
        let empty = State()
        func publication(_ sequence: UInt64) -> Report {
            report(processRunID: processRunID, sequence: sequence, state: empty,
                observations: [observation(empty, event: .callback, atMS: at + Int64(sequence),
                    leasePresent: false, leaseCheckSucceeded: false)])
        }
        writer.submit(publication(1))
        defer { sink.releaseFirstReport.signal() }
        try require(sink.firstReportEntered.wait(timeout: .now() + 5) == .success,
            "Actual writer did not enter the controlled first report write")
        writer.recordWrite(.transportHistory, sequence: 2) {}
        writer.recordWrite(.syncEvidence, sequence: 2) {}
        writer.submit(publication(2))
        writer.submit(publication(3))
        sink.releaseFirstReport.signal()
        queue.sync { }
        let published = try TransportCodec.decode(Report.self, from: Data(contentsOf: reportFile))
        let healthBytes = try Data(contentsOf: healthFile)
        let health = try TransportCodec.decode(Health.self, from: healthBytes)
        let firstWrites = sink.snapshot()
        try require(published.sequence == 3 && firstWrites.reports == 2 && firstWrites.health == 2,
            "A failed blocked write lost or retried the newest coalesced report")
        try require(health.diagnosticsRevision == 3 && health.processRunID == processRunID
            && health.attemptCount == 2 && health.publishedCount == 1
            && health.failureCount == 1 && health.healthWriteFailureCount == 1
            && health.coalescedCount == 1 && health.lastAttemptSequence == 3
            && health.lastPublishedSequence == 3 && health.lastFailureSequence == 1
            && health.lastHealthFailureSequence == 1,
            "Recovered health lost cumulative failures or rebound them to a later report")
        try require(health.lastFailure?.kind == .cocoa && health.lastHealthFailure?.kind == .posix
            && health.lastFailureAtMS != nil && health.lastHealthFailureAtMS != nil
            && firstWrites.logs.count == 2
            && firstWrites.logs[0].destination == .report && firstWrites.logs[0].sequence == 1
            && firstWrites.logs[1].destination == .health && firstWrites.logs[1].sequence == 1,
            "A health write failure lacked its independent bounded failure log")
        try require(health.transportHistoryWrites?.attemptCount == 1
            && health.transportHistoryWrites?.publishedCount == 1
            && health.transportHistoryWrites?.lastPublishedSequence == 2
            && health.syncEvidenceWrites?.attemptCount == 1
            && health.syncEvidenceWrites?.publishedCount == 1
            && health.syncEvidenceWrites?.lastPublishedSequence == 2,
            "A blocked worker-status write overwrote concurrently recorded publication results")
        try require(healthBytes.count <= Health.maximumBytes
            && !String(decoding: healthBytes, as: UTF8.self).contains(privateMarker)
            && !String(decoding: try published.encoded(), as: UTF8.self).contains(privateMarker),
            "Recovered diagnostics exceeded their caps or serialized a local error description")
        writer.submit(publication(4))
        queue.sync { }
        let next = try TransportCodec.decode(Health.self, from: Data(contentsOf: healthFile))
        let nextWrites = sink.snapshot()
        try require(next.attemptCount == 3 && next.publishedCount == 2
            && next.lastPublishedSequence == 4 && next.failureCount == 1
            && next.healthWriteFailureCount == 1 && next.lastFailureSequence == 1
            && next.lastHealthFailureSequence == 1 && nextWrites.logs.count == 2
            && nextWrites.reports == 3 && nextWrites.health == 3,
            "A later success erased failure history or recursively retried diagnostic IO")

        // Compile and execute the Library's actual recovery entry, event mapper
        // and report body. The missing private synthetic directory forces the
        // real metadata read boundary to fail without touching a recording.
        var ledger = GoogleDriveLibraryLedger()
        try ledger.bind(accountID: "synthetic-worker-account", label: "Synthetic worker account")
        try ledger.authorize(.existingAndFuture, knownIDs: [], at: Date(timeIntervalSince1970: 1_800_000_000))
        try ledger.allocateFolder("synthetic-worker-folder")
        let boundaryRoot = root.appendingPathComponent("library-boundaries-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: boundaryRoot, withIntermediateDirectories: true)
        let boundaryQueue = DispatchQueue(label: "synthetic.worker-library.writer")
        let boundaryFile = boundaryRoot.appendingPathComponent("worker-status.json")
        let boundarySink = WriteSink(privateMarker: privateMarker)
        let boundaryWriter = GoogleDriveWorkerDiagnosticsWriter(file: boundaryFile,
            processRunID: processRunID, build: "756", queue: boundaryQueue,
            write: { data, file in try data.write(to: file, options: .atomic) },
            failureLog: { [boundarySink] destination, sequence, failure in
                boundarySink.log(destination, sequence: sequence, failure: failure)
            })
        let library = GoogleDriveWorkerLibraryProbe(ledger: ledger,
            directory: boundaryRoot.appendingPathComponent("missing-metadata", isDirectory: true),
            transportFile: boundaryRoot.appendingPathComponent("transport-diagnostics.json"),
            processRunID: processRunID, writer: boundaryWriter)
        try require(library.metadataRecovery.block(GoogleDriveMetadataIOError(code: 28),
            ledger: ledger, hasTrustedQueue: true), "Synthetic trusted metadata did not enter recovery")
        let parentDeadline = ProcessInfo.processInfo.systemUptime + 20
        library.startMetadataRecoveryAtOpportunity(systemGranted: true, maximumDeadline: parentDeadline)
        let recoveryID = library.executionID
        try require(recoveryID != nil && library.roundSequence == 1 && library.work != nil
            && library.workerDiagnosticState.execution?.id == recoveryID
            && library.workerDiagnosticState.execution?.kind == .metadataRecovery
            && library.workerDiagnosticState.execution?.systemGranted == true,
            "Actual metadata recovery entry did not begin its attributed diagnostic round")
        await library.work?.value
        boundaryQueue.sync {}
        let recoveryReport = try TransportCodec.decode(Report.self, from: Data(contentsOf: boundaryFile))
        let recoveryFailure = recoveryReport.observations.first { $0.event == .roundFailed }
        let recoveryFinish = recoveryReport.observations.last
        try require(recoveryFailure?.execution?.id == recoveryID
            && recoveryFailure?.roundSequence == 1 && recoveryFailure?.execution?.roundSequence == 1
            && recoveryFailure?.execution?.systemGranted == true && recoveryFailure?.execution?.kind == .metadataRecovery
            && recoveryReport.lastFailureContext?.executionID == recoveryID
            && recoveryReport.lastFailureContext?.roundSequence == 1
            && recoveryReport.lastFailureContext?.phase == .recovery,
            "Actual recovery read failure lost its round, execution or system grant attribution")
        try require(recoveryFinish?.event == .roundFinished && recoveryFinish?.execution?.id == recoveryID
            && recoveryFinish?.execution?.leaseState == .finished
            && recoveryFinish?.execution?.parentDeadlineUptimeMS == State.uptimeMS(parentDeadline)
            && library.workerDiagnosticState.execution == nil && library.executionID == nil
            && library.executionLease == nil && library.work == nil && !library.isBusy
            && library.ledgerUnavailable && library.normalSchedules == 0,
            "Failed metadata recovery did not finish and release its own round without scheduling normal work")
        library.recordWorker(.callback)
        boundaryQueue.sync {}
        let callbackReport = try TransportCodec.decode(Report.self, from: Data(contentsOf: boundaryFile))
        try require(callbackReport.execution == nil && !callbackReport.systemGranted
            && callbackReport.observations.last?.execution == nil
            && callbackReport.lastFailureContext == recoveryReport.lastFailureContext,
            "A later callback inherited the finished metadata recovery execution")
        let normalID = UUID()
        library.roundSequence += 1
        library.workerDiagnosticState.begin(id: normalID, roundSequence: library.roundSequence,
            systemGranted: false, parentDeadline: nil, leaseDeadline: ProcessInfo.processInfo.systemUptime + 20)
        library.recordWorker(.roundStarted)
        boundaryQueue.sync {}
        let normalReport = try TransportCodec.decode(Report.self, from: Data(contentsOf: boundaryFile))
        try require(normalReport.execution?.id == normalID && normalID != recoveryID
            && normalReport.execution?.roundSequence == 2 && normalReport.execution?.kind == .normal
            && normalReport.lastFailureContext == recoveryReport.lastFailureContext,
            "A later normal round rebound the earlier recovery failure to its new execution")

        // Publication failures must become health immediately, even if no
        // worker-status round ever follows. Both production publication call
        // sites are used, with independent later successes and retained errors.
        let publicationRoot = root.appendingPathComponent("external-writes-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: publicationRoot, withIntermediateDirectories: true)
        let publicationQueue = DispatchQueue(label: "synthetic.external-write.health")
        let publicationFile = publicationRoot.appendingPathComponent("worker-status.json")
        let publicationHealthFile = publicationRoot.appendingPathComponent("worker-health.json")
        let publicationSink = WriteSink(privateMarker: privateMarker)
        let publicationWriter = GoogleDriveWorkerDiagnosticsWriter(file: publicationFile,
            processRunID: processRunID, build: "756", queue: publicationQueue,
            write: { data, file in try data.write(to: file, options: .atomic) },
            failureLog: { [publicationSink] destination, sequence, failure in
                publicationSink.log(destination, sequence: sequence, failure: failure)
            })
        let publications = GoogleDriveWorkerLibraryProbe(ledger: ledger, directory: publicationRoot,
            transportFile: publicationRoot.appendingPathComponent("transport-diagnostics.json"),
            processRunID: processRunID, writer: publicationWriter)
        publications.workerReportSequence = 70
        try FileManager.default.createSymbolicLink(atPath: publications.transportFile.path,
            withDestinationPath: publicationRoot.appendingPathComponent(privateMarker).path)
        let request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files")!)
        publications.recordTransportDiagnostic(.capture(error: URLError(.secureConnectionFailed), request: request,
            phase: .apiRequest), freezeFault: false)
        publicationQueue.sync {}
        let historyFailureHealth = try TransportCodec.decode(Health.self, from: Data(contentsOf: publicationHealthFile))
        try require(historyFailureHealth.transportHistoryWrites?.failureCount == 1
            && historyFailureHealth.transportHistoryWrites?.attemptCount == 1
            && historyFailureHealth.transportHistoryWrites?.lastFailureSequence == 70
            && historyFailureHealth.transportHistoryWrites?.lastFailure?.kind == .metadata
            && historyFailureHealth.transportHistoryWrites?.lastFailure?.code == Int(EINVAL)
            && !FileManager.default.fileExists(atPath: publicationFile.path),
            "Actual transport-history failure was swallowed or depended on a later worker report")

        let evidenceRoot = publicationRoot.appendingPathComponent("synthetic-evidence-root")
        try Data("synthetic obstruction".utf8).write(to: evidenceRoot)
        let evidenceQueue = DispatchQueue(label: "synthetic.sync-evidence.writer")
        let evidenceWriter = GoogleDriveSyncEvidenceWriter(root: evidenceRoot,
            workerDiagnostics: publicationWriter, queue: evidenceQueue)
        evidenceWriter.submit(ledger: ledger, sourceSnapshotPending: false, discoveryComplete: true,
            discoveryRevision: 1, remainingDiscoveryCount: 0, failureCode: nil, workerReportSequence: 71)
        evidenceQueue.sync {}; publicationQueue.sync {}
        let failedHealthBytes = try Data(contentsOf: publicationHealthFile)
        let evidenceFailureHealth = try TransportCodec.decode(Health.self, from: failedHealthBytes)
        let failureLogs = publicationSink.snapshot().logs
        try require(evidenceFailureHealth.syncEvidenceWrites?.failureCount == 1
            && evidenceFailureHealth.syncEvidenceWrites?.lastFailureSequence == 71
            && evidenceFailureHealth.syncEvidenceWrites?.lastFailure?.kind == .syncEvidence
            && evidenceFailureHealth.syncEvidenceWrites?.lastFailure?.code == 1
            && evidenceFailureHealth.transportHistoryWrites?.failureCount == 1
            && failureLogs.count == 2 && failureLogs[0].destination == .transportHistory
            && failureLogs[0].sequence == 70 && failureLogs[1].destination == .syncEvidence
            && failureLogs[1].sequence == 71,
            "Actual sync-evidence failure lacked its independent bounded counter and fixed failure log")
        try FileManager.default.removeItem(at: publications.transportFile)
        publications.workerReportSequence = 72
        publications.recordTransportDiagnostic(.capture(error: nil, request: request,
            phase: .apiRecovery, httpStatus: 200), freezeFault: false)
        try FileManager.default.removeItem(at: evidenceRoot)
        evidenceWriter.submit(ledger: ledger, sourceSnapshotPending: false, discoveryComplete: true,
            discoveryRevision: 2, remainingDiscoveryCount: 0, failureCode: nil, workerReportSequence: 73)
        evidenceQueue.sync {}; publicationQueue.sync {}
        let recoveredHealthBytes = try Data(contentsOf: publicationHealthFile)
        let recoveredHealth = try TransportCodec.decode(Health.self, from: recoveredHealthBytes)
        try require(recoveredHealth.transportHistoryWrites?.attemptCount == 2
            && recoveredHealth.transportHistoryWrites?.publishedCount == 1
            && recoveredHealth.transportHistoryWrites?.failureCount == 1
            && recoveredHealth.transportHistoryWrites?.lastFailureSequence == 70
            && recoveredHealth.transportHistoryWrites?.lastPublishedSequence == 72
            && recoveredHealth.syncEvidenceWrites?.attemptCount == 2
            && recoveredHealth.syncEvidenceWrites?.publishedCount == 1
            && recoveredHealth.syncEvidenceWrites?.failureCount == 1
            && recoveredHealth.syncEvidenceWrites?.lastFailureSequence == 71
            && recoveredHealth.syncEvidenceWrites?.lastPublishedSequence == 73,
            "Later publication successes erased failure history or were not reported for both destinations")
        let persistedHistory = GoogleDriveTransportHistory.restored(from: try Data(contentsOf: publications.transportFile))
        let persistedEvidence = try SyncEvidenceArchive(root: evidenceRoot, stream: "google_drive").load()
        try require(persistedHistory?.failures.count == 1 && persistedHistory?.successes.count == 1
            && persistedEvidence?.context.counts["discovery_revision"] == 2
            && persistedEvidence?.rows.isEmpty == true && publications.ledger == ledger,
            "Recorded publication recovery was not backed by actual synthetic metadata or changed authority")
        try require(recoveredHealthBytes.count <= Health.maximumBytes && failedHealthBytes.count <= Health.maximumBytes
            && !String(decoding: recoveredHealthBytes, as: UTF8.self).contains(privateMarker)
            && !String(decoding: recoveredHealthBytes, as: UTF8.self).contains("synthetic-worker-account")
            && publicationSink.snapshot().logs.count == 2,
            "Publication recovery exposed a private description/account or recursively logged diagnostic writes")
        var oldHealthObject = try JSONSerialization.jsonObject(with: recoveredHealthBytes) as! [String: Any]
        oldHealthObject.removeValue(forKey: "transportHistoryWrites")
        oldHealthObject.removeValue(forKey: "syncEvidenceWrites")
        oldHealthObject["diagnosticsRevision"] = 2
        let oldHealth = try TransportCodec.decode(Health.self,
            from: JSONSerialization.data(withJSONObject: oldHealthObject, options: [.sortedKeys]))
        try require(oldHealth.transportHistoryWrites == nil && oldHealth.syncEvidenceWrites == nil,
            "Older worker health fabricated publication history for newly observed destinations")
        let maximumFailure = Health.Failure(NSError(domain: NSPOSIXErrorDomain, code: Int(Int32.max)))
        var saturated = Health.WriteHealth(attemptCount: .max, publishedCount: .max, failureCount: .max)
        saturated.record(sequence: .max, atMS: .max, failure: maximumFailure)
        saturated.record(sequence: .max, atMS: .max, failure: nil)
        var boundedHealth = Health(schemaVersion: 1, diagnosticsRevision: 3, processRunID: processRunID,
            build: String(repeating: "7", count: 32), generatedAtMS: .max)
        boundedHealth.attemptCount = .max; boundedHealth.publishedCount = .max
        boundedHealth.failureCount = .max; boundedHealth.healthWriteFailureCount = .max; boundedHealth.coalescedCount = .max
        boundedHealth.lastAttemptAtMS = .max; boundedHealth.lastAttemptSequence = .max
        boundedHealth.lastPublishedAtMS = .max; boundedHealth.lastPublishedSequence = .max
        boundedHealth.lastFailureAtMS = .max; boundedHealth.lastFailureSequence = .max; boundedHealth.lastFailure = maximumFailure
        boundedHealth.lastHealthFailureAtMS = .max; boundedHealth.lastHealthFailureSequence = .max
        boundedHealth.lastHealthFailure = maximumFailure
        boundedHealth.transportHistoryWrites = saturated; boundedHealth.syncEvidenceWrites = saturated
        try require(saturated.attemptCount == .max && saturated.publishedCount == .max && saturated.failureCount == .max
            && (try boundedHealth.encoded()).count <= Health.maximumBytes,
            "Long-running write failure counters wrapped or exceeded the fixed health byte budget")

        // A delayed callback must keep the failing job even while another job
        // owns the worker task. Execute the production callback and writer.
        let failedJob = GoogleDriveUploadCorrelation(segmentID: UUID(), kind: .audio,
            manifestSHA256: String(repeating: "a", count: 64))
        let otherJob = GoogleDriveUploadCorrelation(segmentID: UUID(), kind: .audio,
            manifestSHA256: String(repeating: "b", count: 64))
        let failedRequestID = UUID()
        let delayed = GoogleDriveTransportDiagnostic.capture(
            error: NSError(domain: NSURLErrorDomain, code: -1001,
                userInfo: [NSLocalizedDescriptionKey: privateMarker]), request: request,
            phase: .apiRequest, requestID: failedRequestID, origin: .natural,
            uploadCorrelation: failedJob)
        var correlatedLogs: [String] = []
        publications.diagnosticHandler = { event, detail in correlatedLogs.append(event + " " + detail) }
        GoogleDriveUploadTrace.$current.withValue(otherJob) {
            publications.recordTransportDiagnostic(delayed, freezeFault: false)
            publications.recordWorker(.requestCompleted, completion: .init(requestID: failedRequestID,
                origin: .natural, attemptCount: 2, outcome: .recoveryFailed, uploadCorrelation: failedJob))
            publications.recordDiagnostic("remote_verified", "synthetic=true")
        }
        publicationQueue.sync {}
        let correlatedBytes = try Data(contentsOf: publicationFile)
        let correlated = try TransportCodec.decode(Report.self, from: correlatedBytes)
        let failure = correlated.observations.first { $0.requestID == failedRequestID && $0.event == .requestObserved }
        let completion = correlated.observations.first { $0.requestID == failedRequestID && $0.event == .requestCompleted }
        try require(correlated.schemaVersion == 2 && correlated.diagnosticsRevision == 5
            && failure?.uploadCorrelation == failedJob && failure?.errorCode == -1001
            && failure?.origin == .natural && completion?.uploadCorrelation == failedJob
            && correlated.observations.last?.uploadCorrelation == otherJob,
            "Delayed failed request or completion was rebound to another job's remote verification")
        let encodedText = String(decoding: correlatedBytes, as: UTF8.self)
        let failedLog = correlatedLogs.first { $0.contains("phone.drive_background_request_failed") }
        try require(failedLog?.contains(failedJob.jobKey!) == true && failedLog?.contains(otherJob.jobKey!) == false,
            "Delayed request log mixed the failing job with another task's ambient upload identity")
        try require(!encodedText.contains(privateMarker) && !encodedText.contains("synthetic-worker-account")
            && !encodedText.contains("https://") && !encodedText.contains("segmentID")
            && correlatedBytes.count <= Report.maximumBytes,
            "Correlated worker evidence exposed sensitive input or exceeded its bound")
        var oldObject = try JSONSerialization.jsonObject(with: correlatedBytes) as! [String: Any]
        oldObject["schemaVersion"] = 1
        oldObject["observations"] = (oldObject["observations"] as! [[String: Any]]).map { value in
            var old = value; old.removeValue(forKey: "uploadCorrelation"); return old
        }
        let oldReport = try TransportCodec.decode(Report.self, from: JSONSerialization.data(withJSONObject: oldObject))
        try require(oldReport.observations.allSatisfy { $0.uploadCorrelation == nil },
            "Legacy worker evidence fabricated an upload job binding")
        count += try verifiedObservations(root: root)
        return count
    }
    /// Exercises the production full validator against stable and corrupted
    /// synthetic metadata. Observation itself must never re-date its sources.
    @MainActor
    private static func verifiedObservations(root: URL) throws -> Int {
        var count = 0
        func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try condition() else { throw Failure(message: message) }; count += 1
        }
        let directory = root.appendingPathComponent("verified-observation-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("worker-status.json"), healthFile = directory.appendingPathComponent("worker-health.json")
        let process = UUID(), at = Int64(Date().timeIntervalSince1970 * 1_000) - 10_000
        let observation = Report.Observation(atMS: at, event: .initialized, phase: .idle, roundSequence: 0,
            foreground: true, roundActive: false, remainingMS: 0, pendingCount: 0, nativeCount: 0, readbackCount: 0)
        let report = Report(schemaVersion: 2, processRunID: process, build: "86", generatedAtMS: at, sequence: 1,
            enabled: false, ledgerAvailable: true, sourceSnapshotPending: false, discoveryComplete: true,
            discoveryRemaining: 0, authorizedSourceCount: 0, savedAudioCount: 0, pendingArtifactCount: 0,
            nativeCount: 0, readbackCount: 0, itemRetryCount: 0, retryAfterMS: nil, failureCount: 0,
            systemGranted: false, lastFailure: nil, lastFailurePhase: nil, observations: [observation], diagnosticsRevision: 5)
        var health = Health(schemaVersion: 1, diagnosticsRevision: 3, processRunID: process, build: "86", generatedAtMS: at + 1)
        health.attemptCount = 1; health.publishedCount = 1
        health.lastAttemptAtMS = at + 1; health.lastAttemptSequence = 1
        health.lastPublishedAtMS = at + 1; health.lastPublishedSequence = 1
        let reportBytes = try report.encoded(), healthBytes = try health.encoded()
        try reportBytes.write(to: file); try healthBytes.write(to: healthFile)
        let source = try GoogleDriveWorkerVerifiedObservation.source(file: file, expectedProcessRunID: process, expectedBuild: "86")
        try require(source.sourceGeneratedAtMS == at + 1 && source.identity["sequence"] == "1"
            && source.identity["lastPublishedSequence"] == "1" && source.files.count == 2,
            "Verified worker observation lost exact source identity or health time")
        let publisher = VerifiedObservationPublisher(directory: directory, reportKind: "google_drive_worker", build: "86",
            processRunID: process, minimumIntervalMS: 0)
        func observe() -> Bool {
            publisher.observe {
                try GoogleDriveWorkerVerifiedObservation.source(file: file, expectedProcessRunID: process, expectedBuild: "86")
            }
        }
        try require(observe() && observe(), "Unchanged valid diagnostic sources could not be freshly observed")
        let receipt = try TransportCodec.decode(VerifiedObservationPublisher.Receipt.self,
            from: Data(contentsOf: directory.appendingPathComponent(VerifiedObservationPublisher.fileName)))
        try require(receipt.schemaVersion == 2 && receipt.clockName == "CLOCK_MONOTONIC" && receipt.continuousTimeMS >= 0
            && receipt.sequence == 2 && receipt.sourceGeneratedAtMS == at + 1 && !receipt.audioRead && !receipt.includesAudio,
            "Repeated observation lost its continuous-clock contract or invented source progress/audio access")
        try require(try Data(contentsOf: file) == reportBytes && Data(contentsOf: healthFile) == healthBytes,
            "Read-only observation rewrote a source timestamp or health counter")
        let validReport = try JSONSerialization.jsonObject(with: reportBytes) as! [String: Any]
        let validHealth = try JSONSerialization.jsonObject(with: healthBytes) as! [String: Any]
        func rejects(_ reportObject: [String: Any] = validReport, _ healthObject: [String: Any] = validHealth) throws {
            try JSONSerialization.data(withJSONObject: reportObject, options: [.sortedKeys]).write(to: file)
            try JSONSerialization.data(withJSONObject: healthObject, options: [.sortedKeys]).write(to: healthFile)
            try require(!observe(), "Corrupt worker pair received a verified observation")
            let status = try TransportCodec.decode(VerifiedObservationPublisher.Status.self,
                from: Data(contentsOf: directory.appendingPathComponent(VerifiedObservationPublisher.statusName)))
            try require(status.schemaVersion == 2 && status.clockName == "CLOCK_MONOTONIC" && status.continuousTimeMS >= 0
                && !status.available && status.observationSHA256 == nil,
                "Failed validation lost its continuous-clock contract or left its old observation available")
        }
        var changed = validReport
        changed["authorizedSourceCount"] = -1; try rejects(changed)
        changed = validReport; changed["observations"] = [["atMS": at, "event": "initialized"]]; try rejects(changed)
        changed = validReport
        var nested = (changed["observations"] as! [[String: Any]])[0]
        nested["remainingMS"] = -1; changed["observations"] = [nested]; try rejects(changed)
        changed = validReport; changed["generatedAtMS"] = at - 1; try rejects(changed)
        changed = validReport; changed["systemGranted"] = true; try rejects(changed)
        var brokenHealth = validHealth
        brokenHealth["lastPublishedSequence"] = 2; try rejects(validReport, brokenHealth)
        brokenHealth = validHealth; brokenHealth["processRunID"] = UUID().uuidString; try rejects(validReport, brokenHealth)
        brokenHealth = validHealth; brokenHealth["publishedCount"] = 2; try rejects(validReport, brokenHealth)
        brokenHealth = validHealth
        brokenHealth["syncEvidenceWrites"] = ["attemptCount": 1, "publishedCount": 1, "failureCount": 0]
        try rejects(validReport, brokenHealth)
        brokenHealth = validHealth; brokenHealth["healthWriteFailureCount"] = 1; try rejects(validReport, brokenHealth)
        changed = validReport; changed["diagnosticsRevision"] = 3; try rejects(changed)
        brokenHealth = validHealth
        brokenHealth["attemptCount"] = 2; brokenHealth["failureCount"] = 1
        brokenHealth["generatedAtMS"] = at + 3; brokenHealth["lastAttemptAtMS"] = at + 2
        brokenHealth["lastAttemptSequence"] = 2; brokenHealth["lastFailureSequence"] = 2
        brokenHealth["lastFailureAtMS"] = at + 2; brokenHealth["lastFailure"] = ["kind": "posix", "code": 28]
        try rejects(validReport, brokenHealth)
        brokenHealth["lastAttemptSequence"] = 1; brokenHealth["lastFailureSequence"] = 1
        try rejects(validReport, brokenHealth)
        brokenHealth = validHealth
        brokenHealth["lastAttemptSequence"] = 2; brokenHealth["lastAttemptAtMS"] = at + 2
        brokenHealth["generatedAtMS"] = at + 3; brokenHealth["healthWriteFailureCount"] = 1
        brokenHealth["lastHealthFailureSequence"] = 2; brokenHealth["lastHealthFailureAtMS"] = at + 2
        brokenHealth["lastHealthFailure"] = ["kind": "posix", "code": 28]
        try rejects(validReport, brokenHealth)
        // A retained execution cannot lose already reported strict receipts.
        let executionID = UUID().uuidString
        var execution: [String: Any] = ["id": executionID, "roundSequence": 1, "systemGranted": false,
            "leaseDeadlineUptimeMS": 300_000, "leaseState": "active", "kind": "normal",
            "progressedItems": 1, "firstProgressPhase": "strict_verify", "startedAtMS": at - 100]
        var first = (validReport["observations"] as! [[String: Any]])[0]
        first["roundSequence"] = 1; first["event"] = "remote_verified"; first["roundActive"] = true
        first["execution"] = execution
        var second = first; second["atMS"] = at + 1
        execution["progressedItems"] = 2; second["execution"] = execution
        var executing = validReport; executing["sequence"] = 2; executing["generatedAtMS"] = at + 1
        executing["observations"] = [first, second]; executing["execution"] = execution
        var executingHealth = validHealth; executingHealth["lastAttemptSequence"] = 2; executingHealth["lastPublishedSequence"] = 2
        try JSONSerialization.data(withJSONObject: executing).write(to: file)
        try JSONSerialization.data(withJSONObject: executingHealth).write(to: healthFile)
        try require(observe(), "Valid retained execution progress was rejected")
        execution["progressedItems"] = 0; execution.removeValue(forKey: "firstProgressPhase")
        second["execution"] = execution; executing["observations"] = [first, second]; executing["execution"] = execution
        try rejects(executing, executingHealth)
        try reportBytes.write(to: file); try healthBytes.write(to: healthFile)
        try require(observe(), "Restored unchanged sources could not recover observation availability")
        // Existing business files are not repaired, and unsafe leaves never gain authority.
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: healthFile)
        try require(!observe(), "A symlink diagnostic leaf was accepted")
        try FileManager.default.removeItem(at: file)
        try reportBytes.write(to: file)
        let linked = directory.appendingPathComponent("linked.json")
        try FileManager.default.linkItem(at: file, to: linked)
        try require(!observe(), "A hardlinked diagnostic leaf was accepted")
        try FileManager.default.removeItem(at: linked)
        try Data(repeating: 32, count: Report.maximumBytes + 1).write(to: file)
        try require(!observe(), "An oversized diagnostic leaf was accepted")
        try reportBytes.write(to: file)
        // Run the actual serial writer: a health-only result immediately refreshes
        // source digests even inside the ordinary 30-second foreground throttle.
        let queue = DispatchQueue(label: "synthetic.verified-observation.writer")
        let writer = GoogleDriveWorkerDiagnosticsWriter(file: file, processRunID: process, build: "86", queue: queue,
            write: { data, file in try data.write(to: file, options: .atomic) })
        writer.submit(report); queue.sync {}
        let firstReceipt = try Data(contentsOf: directory.appendingPathComponent(VerifiedObservationPublisher.fileName))
        writer.recordWrite(.syncEvidence, sequence: 1) {}
        queue.sync {}
        let nextReceipt = try Data(contentsOf: directory.appendingPathComponent(VerifiedObservationPublisher.fileName))
        let next = try TransportCodec.decode(VerifiedObservationPublisher.Receipt.self, from: nextReceipt)
        let actualHealth = try Data(contentsOf: healthFile)
        try require(firstReceipt != nextReceipt && next.files.first { $0.name == "worker-health.json" }?.sha256
            == VerifiedObservationPublisher.digest(actualHealth), "A later health-only publication left the old observation hash")
        try require(try Data(contentsOf: file) == reportBytes,
            "Worker observation refreshed the source report without a business publication")
        // Build 87 pins the exact pair. A copy crossing status 42 / health 46
        // must invalidate the package fence even if both JSON leaves are valid.
        let packageDirectory = root.appendingPathComponent("worker-package-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        let packageReport = packageDirectory.appendingPathComponent("worker-status.json")
        let packageHealth = packageDirectory.appendingPathComponent("worker-health.json")
        var report87 = validReport; report87["build"] = "87"; report87["sequence"] = 42
        var health87 = validHealth; health87["build"] = "87"
        health87["lastAttemptSequence"] = 42; health87["lastPublishedSequence"] = 42
        let original87 = try JSONSerialization.data(withJSONObject: report87, options: [.sortedKeys])
        try original87.write(to: packageReport)
        try JSONSerialization.data(withJSONObject: health87, options: [.sortedKeys]).write(to: packageHealth)
        let packagePublisher = VerifiedObservationPublisher(directory: packageDirectory,
            reportKind: "google_drive_worker", build: "87", processRunID: process, minimumIntervalMS: 0)
        func packageIndex() throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(contentsOf: packageDirectory.appendingPathComponent("snapshot-index.json"))) as! [String: Any]
        }
        func observePackage() -> Bool {
            packagePublisher.observe(sourceDidChange: true) {
                try GoogleDriveWorkerVerifiedObservation.source(file: packageReport,
                    expectedProcessRunID: process, expectedBuild: "87")
            }
        }
        try require(try packageIndex()["available"] as? Bool == false,
            "New worker observer left the prior process available before validation")
        try require(observePackage(), "Valid build 87 worker pair did not publish an immutable package")
        let firstPackage = try packageIndex()
        let firstGeneration = packageDirectory.appendingPathComponent("SnapshotGenerations")
            .appendingPathComponent(firstPackage["generationID"] as! String)
        try require(try Data(contentsOf: firstGeneration.appendingPathComponent("worker-status.json")) == original87,
            "Worker package did not preserve exact validated status bytes")
        health87["lastAttemptSequence"] = 46; health87["lastPublishedSequence"] = 46
        try JSONSerialization.data(withJSONObject: health87, options: [.sortedKeys]).write(to: packageHealth)
        try require(!observePackage(), "Mixed worker status 42 / health 46 received a package")
        let failedPackage = try packageIndex()
        try require(failedPackage["available"] as? Bool == false
            && failedPackage["fenceID"] as? String != firstPackage["fenceID"] as? String,
            "Mixed worker generation did not invalidate its durable failure fence")
        health87["lastAttemptSequence"] = 42; health87["lastPublishedSequence"] = 42
        try JSONSerialization.data(withJSONObject: health87, options: [.sortedKeys]).write(to: packageHealth)
        try require(observePackage(), "Valid restored worker pair could not recover package publication")
        try require(try packageIndex()["fenceID"] as? String == failedPackage["fenceID"] as? String,
            "Successful recovery erased the intervening worker failure fence")
        try require(try Data(contentsOf: firstGeneration.appendingPathComponent("worker-status.json")) == original87,
            "Later worker publications mutated a pinned generation")
        return count
    }

    @MainActor static func runNonBlockingInvalidation(root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let queue = DispatchQueue(label: "synthetic.worker-observation-contention")
        let writer = GoogleDriveWorkerDiagnosticsWriter(file: root.appendingPathComponent("worker-status.json"),
            processRunID: UUID(), build: "87", queue: queue,
            write: { data, file in try data.write(to: file, options: .atomic) }, failureLog: { _, _, _ in })
        func index() throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("snapshot-index.json"))) as! [String: Any]
        }
        // The missing report makes the first synthetic observation fail. A
        // second attempt reaches the real throttle callback under its lock.
        writer.observeVerifiedMetadata(); queue.sync {}
        let before = try index()
        let publisherLocked = DispatchSemaphore(value: 0), releasePublisher = DispatchSemaphore(value: 0)
        let failureReturned = DispatchSemaphore(value: 0)
        defer { releasePublisher.signal() }
        writer.observeVerifiedMetadata(onThrottle: { seconds in
            if (1...30).contains(seconds) { publisherLocked.signal() }
            _ = releasePublisher.wait(timeout: .now() + 10)
        })
        guard publisherLocked.wait(timeout: .now() + 5) == .success else {
            throw Failure(message: "Worker observation did not reach the controlled publisher lock")
        }
        DispatchQueue.global(qos: .userInitiated).async {
            writer.recordWrite(.syncEvidence, sequence: 1) { throw NSError(domain: NSPOSIXErrorDomain, code: 28) }
            failureReturned.signal()
        }
        let returnedWhileLocked = failureReturned.wait(timeout: .now() + 5) == .success
        releasePublisher.signal()
        if !returnedWhileLocked { _ = failureReturned.wait(timeout: .now() + 5) }
        queue.sync {}
        guard returnedWhileLocked else {
            throw Failure(message: "External write failure blocked on the observation publisher lock")
        }
        let after = try index()
        let health = try TransportCodec.decode(Health.self,
            from: Data(contentsOf: root.appendingPathComponent("worker-health.json")))
        guard after["available"] as? Bool == false, after["fenceID"] as? String != before["fenceID"] as? String,
              health.syncEvidenceWrites?.failureCount == 1, health.syncEvidenceWrites?.lastFailureSequence == 1 else {
            throw Failure(message: "Deferred invalidation lost its failure fence or external write health")
        }
    }
}
