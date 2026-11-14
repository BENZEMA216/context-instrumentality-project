import Darwin
import Foundation
import RecordingCore

struct ProbeFailure: Error { let message: String }
func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw ProbeFailure(message: message) }
}
@MainActor final class Clock {
    var time: TimeInterval = 1_000
}
@MainActor final class Fault {
    var persistFailures = 0, readFailures = 0
    var onPersist: (() -> Void)?
    func inject(_ phase: GoogleDriveBackgroundUploads.MetadataOperation) throws {
        if phase == .persist { onPersist?() }
        if phase == .persist && persistFailures > 0 { persistFailures -= 1; throw GoogleDriveMetadataIOError(code: EIO) }
        if phase == .recoveryRead && readFailures > 0 { readFailures -= 1; throw GoogleDriveMetadataIOError(code: EACCES) }
    }
}
@MainActor final class Native: GoogleDriveUploadTransport {
    var identifier = "", infos: [GoogleDriveUploadTaskInfo] = []
    var enumerations = 0, creates = 0, resumes = 0, cancels = 0, invalidations = 0
    var onEnumeration: (() -> Void)?
    var hold = false, waiting: CheckedContinuation<Void, Never>?
    var completion: (@Sendable (GoogleDriveUploadCompletion) -> Void)?
    func tasks() async -> [GoogleDriveUploadTaskInfo] {
        enumerations += 1; onEnumeration?()
        if hold { await withCheckedContinuation { waiting = $0 } }
        return infos
    }
    func release() { hold = false; waiting?.resume(); waiting = nil }
    func create(_ request: URLRequest, file: URL, nonce: String) throws -> Int {
        creates += 1; throw ProbeFailure(message: "Metadata recovery attempted native upload creation")
    }
    func resume(_ taskID: Int) { resumes += 1 }
    func cancel(_ taskIDs: Set<Int>) async { cancels += taskIDs.count }
    func invalidateAndCancel() async { invalidations += 1 }
    var factory: GoogleDriveBackgroundUploads.Factory {
        { [self] identifier, completion, _ in
            self.identifier = identifier; self.completion = completion; return self
        }
    }
}

// UIKit and BG scheduling are intentionally synthetic. These APIs cannot open a
// session or schedule OS work. The actual Library method bodies are inserted
// below verbatim (only private visibility is widened by the probe generator).
@MainActor final class GoogleDriveExecutionLease {
    static var latest: GoogleDriveExecutionLease?
    let isSystemGranted: Bool
    let deadline: TimeInterval
    var expired = false, ended = false
    init(systemGranted: Bool, maximumDeadline: TimeInterval?) {
        isSystemGranted = systemGranted
        deadline = min(ProcessInfo.processInfo.systemUptime + (systemGranted ? 120 : 19), maximumDeadline ?? .greatestFiniteMagnitude)
    }
    static func begin(systemGranted: Bool, maximumDeadline: TimeInterval?, onExpire: @escaping () -> Void) -> GoogleDriveExecutionLease {
        let lease = GoogleDriveExecutionLease(systemGranted: systemGranted, maximumDeadline: maximumDeadline)
        latest = lease; return lease
    }
    func check() throws {
        if expired || ended || ProcessInfo.processInfo.systemUptime >= deadline { throw CancellationError() }
    }
    func end() { ended = true }
}
@MainActor final class NetworkMonitor { func settingsDidChange() {} }
@MainActor final class Tokens { var hasCredential = true }
@MainActor final class PhoneBackgroundSync {
    static let shared = PhoneBackgroundSync()
    func schedule(earliestBeginDate: Date) {}
    static var notes = 0
    static func noteNewWork() { notes += 1 }
}
@MainActor final class GoogleDriveLibrary {
    var ledger: GoogleDriveLibraryLedger
    let directory: URL, ledgerURL: URL
    let metadataRecovery: GoogleDriveMetadataRecovery
    var metadataLoaded = true, ledgerUnavailable = false, isEnabled = true, isBusy = false, isConnected = true
    var work: Task<Void, Never>?, retry: Task<Void, Never>?, backgroundEventHandoff: Task<Void, Never>?
    var isConfigured = true
    var networkRecoveryRequested = false, foregroundRecoveryAwaitingPath = false
    var networkPath = GoogleDriveNetworkPath.unknown
    var allowsCellularAccess = false
    var networkMonitor: NetworkMonitor?
    var networkRecoveryRetry: Task<Void, Never>?
    var networkRecoveryRetryAt: Date?
    var ordinaryRetryAt: Date?
    var generation: UInt64 = 0
    var executionLease: GoogleDriveExecutionLease?, executionID: UUID?
    var workCancellation: @Sendable () -> Bool = { false }
    var backgroundUploads: GoogleDriveBackgroundUploads?
    var preflightStore: GoogleDrivePreflightPinStore?
    var progress = GoogleDriveSyncProgress()
    // The attribution state is production code. Only the diagnostic sink is
    // synthetic here; writer IO is covered by PhoneGoogleDriveProbe.
    var workerDiagnosticState = GoogleDriveWorkerDiagnosticState()
    var workerEvents: [GoogleDriveWorkerReport.Event] = []
    var lastWorkerCancellationReason: GoogleDriveWorkerReport.CancellationReason?
    var lastWorkerExecution: GoogleDriveWorkerReport.Execution?
    var roundSequence: UInt64 = 0, workerReportSequence: UInt64 = 0
    var roundStartedAt: TimeInterval = 0
    var nativeRegisteredThisRound = 0, scanVisitedThisRound = 0
    var currentPhase: GoogleDrivePreflightPhase = .idle
    let oauth = Tokens()
    var scheduled = 0, retryScheduled = 0, recoveredDiagnostics = 0
    var lastScheduledDeadline: TimeInterval?
    var activity = ""
    init(directory: URL, ledger: GoogleDriveLibraryLedger, background: GoogleDriveBackgroundUploads, clock: Clock) throws {
        self.directory = directory; ledgerURL = directory.appendingPathComponent("ledger.json")
        self.ledger = ledger; backgroundUploads = background
        metadataRecovery = GoogleDriveMetadataRecovery(now: { clock.time })
        preflightStore = try GoogleDrivePreflightPinStore(directory: directory)
    }
    var hasPendingWork: Bool { ledger.hasPendingFiles || progress.hasWork }
    func publish() { isEnabled = !ledgerUnavailable && ledger.enabled }
    func recordDiagnostic(_ kind: String, _ fields: String) {
        if kind == "metadata_revalidated" { recoveredDiagnostics += 1 }
        let event: GoogleDriveWorkerReport.Event?
        switch kind {
        case "round_started": event = .roundStarted
        case "round_finished": event = .roundFinished
        case "round_failed": event = .roundFailed
        case "lease_expired": event = .leaseExpired
        default: event = nil
        }
        if let event { recordWorker(event) }
    }
    func recordWorker(_ event: GoogleDriveWorkerReport.Event) {
        workerReportSequence &+= 1
        workerEvents.append(event)
        lastWorkerCancellationReason = workerDiagnosticState.cancellationReason
        lastWorkerExecution = workerDiagnosticState.snapshot(leasePresent: executionLease != nil,
            leaseCheckSucceeded: executionLease.map { (try? $0.check()) != nil } ?? false,
            finished: event == .roundFinished)
        if event == .roundFinished, let id = lastWorkerExecution?.id { workerDiagnosticState.finish(id: id) }
    }
    func setPhase(_ phase: GoogleDrivePreflightPhase) { currentPhase = phase }
    static func fixedFailure(_ error: Error) -> String { "synthetic_failure" }
    func change(_ mutation: (inout GoogleDriveLibraryLedger) throws -> Void) throws { try mutation(&ledger) }
    func schedule(isCancelled: @escaping @Sendable () -> Bool = { false }, systemGranted: Bool = false, maximumDeadline: TimeInterval? = nil) {
        if !isCancelled() { scheduled += 1; lastScheduledDeadline = maximumDeadline }
    }
    func scheduleRetry(at: Date) { retryScheduled += 1 }
    // PRODUCTION_LIBRARY_METHODS
}

struct Pipeline: Codable { let schemaVersion: Int; let records: [GoogleDriveBackgroundUploads.Record] }
@MainActor final class Fixture {
    let clock = Clock(), fault = Fault(), native = Native()
    var library: GoogleDriveLibrary!
    let pipeline: URL
    let originalLedger: Data
    var transportDiagnostics: [GoogleDriveTransportDiagnostic] = []
    var diagnosticCorrelations: [(String, GoogleDriveUploadCorrelation?)] = []
    var changeCorrelations: [GoogleDriveUploadCorrelation?] = []
    init(root: URL) throws {
        let directory = root.appendingPathComponent(UUID().uuidString).appendingPathComponent("GoogleDriveLibrary")
        let queue = directory.appendingPathComponent("background-uploads")
        try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let start = Date(timeIntervalSince1970: 1_700_000_000), id = UUID()
        let manifest = SegmentManifest(id: id, sessionID: UUID(), sequence: 1, startedAt: start,
            endedAt: start.addingTimeInterval(30), sampleRate: 16_000, frameCount: 480_000,
            fileName: id.uuidString.lowercased() + ".caf", byteCount: 8, sha256: String(repeating: "1", count: 64))
        var ledger = GoogleDriveLibraryLedger()
        try ledger.bind(accountID: "synthetic-owner", label: "Offline metadata recovery")
        try ledger.authorize(.existingAndFuture, knownIDs: [], at: start)
        try ledger.discover(manifests: [manifest], receivedIDs: [id]); try ledger.allocateFolder("synthetic-folder")
        let key = ledger.jobs[0].artifacts[0].key
        try ledger.allocateFile(segmentID: id, key: key, fileID: "synthetic-audio")
        try ledger.recordSession(segmentID: id, key: key, url: "https://www.googleapis.com/upload/drive/v3/files?upload_id=offline-metadata")
        let context = try GoogleDriveUploadContext(ledger: ledger, manifest: manifest, artifact: ledger.jobs[0].artifacts[0])
        let record = GoogleDriveBackgroundUploads.Record(schemaVersion: 1, nonce: UUID(), context: context,
            offset: 0, bodyByteCount: 8, bodySHA256: String(repeating: "1", count: 64), taskID: 1)
        pipeline = queue.appendingPathComponent("pipeline.json")
        try TransportCodec.encode(Pipeline(schemaVersion: 2, records: [record])).write(to: pipeline)
        originalLedger = try TransportCodec.encode(ledger)
        try originalLedger.write(to: directory.appendingPathComponent("ledger.json"))
        native.infos = [.init(id: 1, nonce: record.nonce.uuidString.lowercased(), url: context.artifact.uploadURL,
            method: "PUT", contentRange: record.contentRange)]
        let background = try GoogleDriveBackgroundUploads(directory: queue, libraryID: ledger.libraryID,
            changed: { [weak self] in self?.changeCorrelations.append(GoogleDriveUploadTrace.current) }, finishedEvents: { _ in },
            diagnostic: { [weak self] event, _ in self?.diagnosticCorrelations.append((event, GoogleDriveUploadTrace.current)) },
            transportDiagnostic: { [weak self] in self?.transportDiagnostics.append($0) },
            metadataFault: { [fault] in try fault.inject($0) }, factory: native.factory)
        library = try GoogleDriveLibrary(directory: directory, ledger: ledger, background: background, clock: clock)
    }
    func fail() { library.failClosed(GoogleDriveMetadataIOError(code: EIO)) }
    func finish() async { if let task = library.work { await task.value }; await Task.yield() }
    func assertNoUpload() throws {
        try require(native.creates == 0 && native.resumes == 0 && native.invalidations == 0 && native.cancels == 0,
            "Recovery created/resumed/cancelled native work")
        try require(library.ledger.savedAudioCount == 0, "Metadata recovery fabricated remote verification")
    }
}

@main struct Main {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), filter = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : ""
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var cases = 0, failures: [String] = []
        func test(_ name: String, _ body: @MainActor () async throws -> Void) async {
            guard filter.isEmpty || name.contains(filter) else { return }
            cases += 1
            do { try await body() } catch { failures.append(name + ": " + String(describing: error)) }
        }
        await test("P-59 native callback recovers correlation from durable job metadata") {
            let f = try Fixture(root: root), background = f.library.backgroundUploads!
            let otherJob = GoogleDriveUploadCorrelation(segmentID: UUID(), kind: .manifest, manifestSHA256: String(repeating: "f", count: 64))
            await GoogleDriveUploadTrace.$current.withValue(otherJob) { await background.recover(in: f.library.ledger) }
            f.changeCorrelations.removeAll()
            let saved = background.records[0], task = f.native.infos[0]
            let callback = GoogleDriveTransportDiagnostic.capture(error: URLError(.timedOut),
                request: URLRequest(url: URL(string: saved.context.artifact.uploadURL!)!), phase: .nativeUpload,
                origin: .natural, uploadCorrelation: .shared)
            f.native.completion?(.init(task: task, responseURL: nil, status: nil, transportFailed: true,
                diagnostic: callback))
            // This synthetic native boundary waits for the real event consumer.
            try await background.handoffForPendingEvents()
            try require(f.transportDiagnostics.count == 1
                && f.transportDiagnostics[0].uploadCorrelation == saved.context.uploadCorrelation
                && f.transportDiagnostics[0].origin == .natural && background.records[0].completed,
                "Native callback retained unrelated task attribution instead of its durable job key")
            try require(f.diagnosticCorrelations.filter { $0.0 == "http_completion" }.map { $0.1 } == [saved.context.uploadCorrelation]
                && !f.changeCorrelations.isEmpty && f.changeCorrelations.allSatisfy { $0 == nil },
                "Native worker text or subsequent work inherited the job that first opened the session")
            try require(f.library.ledger.savedAudioCount == 0,
                "Native completion was incorrectly promoted to remote verification")
        }
        await test("actual stop preserves recovery lock while closing diagnostic execution") {
            let f = try Fixture(root: root); f.fail()
            let id = UUID(), before = f.library.generation
            let lease = GoogleDriveExecutionLease.begin(systemGranted: true, maximumDeadline: nil, onExpire: {})
            f.library.executionLease = lease; f.library.executionID = id
            f.library.workerDiagnosticState.begin(id: id, roundSequence: 7, systemGranted: true,
                parentDeadline: nil, leaseDeadline: lease.deadline, generation: before)
            f.library.stopWork()
            try require(f.library.workerEvents == [.cancelled, .roundFinished] &&
                f.library.lastWorkerCancellationReason == .stopRequested && f.library.workerDiagnosticState.execution == nil,
                "Actual stop omitted cancellation attribution or retained the old diagnostic execution")
            try require(lease.ended && f.library.executionLease == nil && f.library.executionID == nil &&
                f.library.generation == before + 1 && f.library.ledgerUnavailable && f.library.metadataRecovery.canRetry,
                "Diagnostic compatibility changed stop/recovery authority")
            let actual = try Data(contentsOf: f.library.ledgerURL)
            try require(actual == f.originalLedger,
                "Diagnostic stop rewrote the durable authorization")
            try f.assertNoUpload()
        }
        await test("P-60 actual stop publishes terminal progress without losing lease expiration attribution") {
            let f = try Fixture(root: root), id = UUID(), before = f.library.generation
            let lease = GoogleDriveExecutionLease.begin(systemGranted: true, maximumDeadline: nil, onExpire: {})
            f.library.executionLease = lease; f.library.executionID = id
            f.library.workerDiagnosticState.begin(id: id, roundSequence: 8, systemGranted: true,
                parentDeadline: lease.deadline, leaseDeadline: lease.deadline, generation: before)
            f.library.workerDiagnosticState.didProgress(phase: .strictVerify)
            f.library.workerDiagnosticState.noteCancellation(.leaseExpirationObserved, generation: before)
            lease.expired = true
            f.library.stopWork()
            let terminal = f.library.lastWorkerExecution
            try require(f.library.workerEvents == [.cancelled, .roundFinished] && terminal?.id == id
                && terminal?.systemGranted == true && terminal?.leaseState == .finished && terminal?.finishedAtMS != nil
                && terminal?.progressedItems == 1 && terminal?.firstProgressPhase == .strictVerify
                && f.library.lastWorkerCancellationReason == .leaseExpirationObserved
                && f.library.workerDiagnosticState.execution == nil,
                "Actual stop lost durable progress, the terminal timestamp, or the observed system expiry")
            let next = UUID()
            f.library.workerDiagnosticState.begin(id: next, roundSequence: 9, systemGranted: true,
                parentDeadline: nil, leaseDeadline: lease.deadline + 13, generation: f.library.generation)
            try require(f.library.workerDiagnosticState.execution?.id == next
                && f.library.workerDiagnosticState.execution?.progressedItems == 0
                && f.library.workerDiagnosticState.execution?.firstProgressPhase == nil
                && f.library.workerDiagnosticState.execution?.finishedAtMS == nil
                && f.library.workerDiagnosticState.cancellationReason == nil,
                "A later opportunity inherited the previous round's progress or cancellation")
            try f.assertNoUpload()
        }
        await test("one temporary metadata failure recovers at actual resume without uploading") {
            let f = try Fixture(root: root); f.fail()
            try require(f.library.ledgerUnavailable && f.library.metadataRecovery.canRetry, "Failure was not held for strict recovery")
            f.library.resume(); await f.finish()
            try require(!f.library.ledgerUnavailable && f.native.enumerations == 1 && f.library.scheduled == 1,
                "Actual production resume did not revalidate the existing queue")
            let actual = try Data(contentsOf: f.library.ledgerURL)
            try require(actual == f.originalLedger, "Recovery rewrote the grant/receipts")
            try require(f.library.lastScheduledDeadline != nil && f.library.recoveredDiagnostics == 1, "Continuation renewed the lease or omitted recovery evidence")
            try f.assertNoUpload()
        }
        await test("metadata recovery write failure keeps its round attribution through a later recovery") {
            let f = try Fixture(root: root); f.fail(); f.fault.persistFailures = 1
            let deadline = ProcessInfo.processInfo.systemUptime + 90
            f.library.startMetadataRecoveryAtOpportunity(systemGranted: true, maximumDeadline: deadline,
                continueAfterRecovery: false)
            let firstID = f.library.executionID
            try require(firstID != nil && f.library.roundSequence == 1, "Recovery did not begin a numbered execution")
            await f.finish()
            let failure = f.library.workerDiagnosticState.lastFailureContext
            try require(failure?.executionID == firstID && failure?.roundSequence == 1,
                "Actual metadata write failure lost the recovery execution attribution")
            try require(f.library.lastWorkerExecution?.id == firstID &&
                f.library.lastWorkerExecution?.systemGranted == true &&
                f.library.lastWorkerExecution?.kind == .metadataRecovery &&
                f.library.workerDiagnosticState.execution == nil &&
                f.library.workerEvents.suffix(3) == [.roundStarted, .roundFailed, .roundFinished],
                "Recovery diagnostic lifecycle omitted its kind, parent grant, failure or finish")
            f.clock.time += 31
            f.library.resume(); await f.finish()
            try require(!f.library.ledgerUnavailable && f.library.roundSequence == 2 &&
                f.library.lastWorkerExecution?.id != firstID && f.library.lastWorkerExecution?.roundSequence == 2 &&
                f.library.workerDiagnosticState.execution == nil && f.library.recoveredDiagnostics == 1,
                "A later recovery did not report a distinct completed diagnostic round")
            try require(f.library.workerDiagnosticState.lastFailureContext == failure,
                "A later recovery reassigned the prior failure to its new execution")
            try f.assertNoUpload()
        }
        await test("actual coordinator persist EIO recovers next opportunity") {
            let f = try Fixture(root: root); f.fault.persistFailures = 1
            await f.library.backgroundUploads!.recover(in: f.library.ledger)
            try require(f.library.backgroundUploads!.isUnavailable && f.library.backgroundUploads!.canRecoverMetadata,
                "Production coordinator did not retain the temporary failure class")
            f.library.failClosed(f.library.backgroundUploads!.metadataFailure!)
            f.library.resume(); await f.finish()
            try require(!f.library.ledgerUnavailable && !f.library.backgroundUploads!.isUnavailable && f.native.enumerations == 2,
                "Same durable pipeline did not recover")
            try f.assertNoUpload()
        }
        for invalid in ["bad_json", "different_grant", "revoked", "uncertain_commit", "missing_ledger", "corrupt_pipeline", "missing_pipeline", "unknown_native", "suspended_native", "symlink_ledger", "hardlink_ledger", "symlink_queue"] {
            await test("strict recovery refuses " + invalid) {
                let f = try Fixture(root: root); f.fail()
                switch invalid {
                case "bad_json": try Data("bad json".utf8).write(to: f.library.ledgerURL)
                case "different_grant": try TransportCodec.encode(GoogleDriveLibraryLedger()).write(to: f.library.ledgerURL)
                case "revoked": var changed = f.library.ledger; changed.revoke(); try TransportCodec.encode(changed).write(to: f.library.ledgerURL)
                case "uncertain_commit": var changed = f.library.ledger; changed.recordFailure(); try TransportCodec.encode(changed).write(to: f.library.ledgerURL)
                case "missing_ledger": try FileManager.default.removeItem(at: f.library.ledgerURL)
                case "corrupt_pipeline": try Data("{}".utf8).write(to: f.pipeline)
                case "missing_pipeline": try FileManager.default.removeItem(at: f.pipeline)
                case "unknown_native": f.native.infos.append(.init(id: 2, nonce: "unrelated", url: "https://www.googleapis.com/upload/drive/v3/files?upload_id=foreign", method: "PUT", contentRange: "bytes 0-7/8"))
                case "suspended_native": let old = f.native.infos[0]; f.native.infos = [.init(id: old.id, nonce: old.nonce, url: old.url, method: old.method, contentRange: old.contentRange, isSuspended: true)]
                case "symlink_ledger", "hardlink_ledger":
                    let other = f.library.directory.appendingPathComponent("other-metadata.json")
                    try FileManager.default.moveItem(at: f.library.ledgerURL, to: other)
                    if invalid == "symlink_ledger" { try FileManager.default.createSymbolicLink(at: f.library.ledgerURL, withDestinationURL: other) }
                    else { try FileManager.default.linkItem(at: other, to: f.library.ledgerURL) }
                default:
                    let queue = f.pipeline.deletingLastPathComponent(), other = f.library.directory.appendingPathComponent("other-queue")
                    try FileManager.default.moveItem(at: queue, to: other)
                    try FileManager.default.createSymbolicLink(at: queue, withDestinationURL: other)
                }
                f.library.resume(); await f.finish()
                try require(f.library.ledgerUnavailable && !f.library.metadataRecovery.canRetry && f.library.scheduled == 0,
                    "A changed or unsafe authority cleared the storage lock")
                try f.assertNoUpload()
            }
        }
        await test("cooldown and three attempts do not spin or cancel native uploads") {
            let f = try Fixture(root: root); f.fail(); f.fault.readFailures = 10
            for attempt in 0..<3 {
                f.library.resume(); await f.finish()
                let count = f.fault.readFailures
                f.library.resume(); await f.finish()
                try require(f.fault.readFailures == count, "Immediate callback retried metadata without cooldown")
                f.clock.time += 31
                try require(f.library.ledgerUnavailable && f.native.enumerations == 0, "Failed metadata validation reached native tasks")
                if attempt < 2 { try require(f.library.metadataRecovery.canRetry, "Temporary error became an identity failure") }
            }
            try require(!f.library.metadataRecovery.canRetry && f.fault.readFailures == 7, "Per-episode attempt budget was unbounded")
            f.fail(); try f.assertNoUpload()
        }
        for interruption in ["cancelled_parent", "expired_lease", "revoked_during_await", "ledger_changed_during_await"] {
            await test("actual parent rejects " + interruption) {
                let f = try Fixture(root: root); f.fail()
                if interruption == "cancelled_parent" {
                    _ = await f.library.prepareBackgroundDelivery(isCancelled: { true })
                } else {
                    f.native.onEnumeration = {
                        if interruption == "expired_lease" { GoogleDriveExecutionLease.latest?.expired = true }
                        else if interruption == "revoked_during_await" { f.library.ledger.revoke(); f.library.stopWork() }
                        else { try! TransportCodec.encode(GoogleDriveLibraryLedger()).write(to: f.library.ledgerURL) }
                    }
                    _ = await f.library.prepareBackgroundDelivery(isCancelled: { false })
                }
                await f.finish()
                try require(f.library.ledgerUnavailable && f.library.scheduled == 0, "Interrupted recovery cleared storage failure")
                try f.assertNoUpload()
            }
        }
        await test("actual parent revalidates within one original deadline") {
            let f = try Fixture(root: root); f.fail()
            let before = ProcessInfo.processInfo.systemUptime
            let ok = await f.library.prepareBackgroundDelivery(isCancelled: { false })
            try require(ok && !f.library.ledgerUnavailable && f.native.enumerations == 1 && f.library.scheduled == 1,
                "Actual BG parent did not consume one bounded recovery then continuation")
            try require(f.library.lastScheduledDeadline! <= before + 120.01, "Recovery renewed BG parent budget")
            try f.assertNoUpload()
        }
        await test("reentrant resume does not duplicate a held enumeration") {
            let f = try Fixture(root: root); f.fail(); f.native.hold = true
            f.library.resume()
            for _ in 0..<100 where f.native.waiting == nil { await Task.yield() }
            try require(f.native.waiting != nil, "Synthetic native enumeration was not reached")
            f.library.resume(); f.library.continueSync()
            try require(f.native.enumerations == 1, "Concurrent lifecycle events reentered recovery")
            f.native.release(); await f.finish()
            try require(!f.library.ledgerUnavailable && f.native.enumerations == 1, "Held recovery did not finish once")
            try f.assertNoUpload()
        }
        await test("queue persisted before outer expiry does not clear Library unavailable") {
            let f = try Fixture(root: root); f.fail(); f.native.infos = []
            f.fault.onPersist = { GoogleDriveExecutionLease.latest?.expired = true }
            f.library.resume(); await f.finish()
            try require(f.library.backgroundUploads!.records[0].completed && !f.library.backgroundUploads!.isUnavailable,
                "Synthetic expiry did not reach the real queue's persisted candidate boundary")
            try require(f.library.ledgerUnavailable && f.library.scheduled == 0 && f.library.recoveredDiagnostics == 0,
                "An inner queue commit bypassed the Library's final cancellation fence")
            try f.assertNoUpload()
        }
        await test("metadata IO classifier does not retry unsafe paths or network errors") {
            for code in [EINTR, EAGAIN, EIO, EBUSY, EMFILE, ENFILE, ENOSPC, EDQUOT, EACCES, EPERM] {
                try require(GoogleDriveMetadataIOError(code: code).isTemporary, "Missing explicit temporary errno")
                do { try GoogleDriveMetadataIO.perform { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) } }
                catch let error as GoogleDriveMetadataIOError { try require(error.code == code, "Filesystem errno was discarded"); continue }
                throw ProbeFailure(message: "Filesystem error was swallowed")
            }
            for code in [ENOENT, ELOOP, ENOTDIR, EINVAL] {
                try require(!GoogleDriveMetadataIOError(code: code).isTemporary, "Unsafe/missing object was treated as a temporary permission")
            }
            do { try GoogleDriveMetadataIO.perform { throw URLError(.timedOut) } }
            catch is GoogleDriveMetadataIOError { throw ProbeFailure(message: "Network timeout became a local metadata error") }
            catch { }
        }
        await test("unanchored cold state and permanent errors remain blocked") {
            for error in [GoogleDriveLibraryError.invalidState as Error, GoogleDriveMetadataIOError(code: ENOENT), URLError(.timedOut)] {
                let f = try Fixture(root: root); f.library.failClosed(error)
                try require(!f.library.metadataRecovery.canRetry, "Permanent/non-metadata error received recovery permission")
            }
            let f = try Fixture(root: root); f.library.metadataLoaded = false; f.fail()
            f.library.resume(); await f.finish()
            try require(f.library.ledgerUnavailable && f.native.enumerations == 0 && !f.library.metadataRecovery.canRetry,
                "Cold missing trust anchor was silently reconstructed")
        }
        await GoogleDriveHTTPRecoveryCases.run(test: test)
        if cases == 0 { failures.append("No test selected") }
        let result: [String: Any] = ["status": failures.isEmpty ? "passed" : "failed", "caseCount": cases,
            "failures": failures, "deviceAccess": false, "networkAccess": false, "audioAccess": false,
            "scope": "Actual Library recovery/resume/BG methods, metadata gate and persisted queue plus real HTTP/OAuth recovery; synthetic UIKit lease/native transport, URLProtocol replies and JSON only."]
        let out = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try out.write(to: root.appendingPathComponent("report.json")); print(String(data: out, encoding: .utf8)!)
        if !failures.isEmpty { throw ProbeFailure(message: "Offline recovery regressions failed") }
    }
}
