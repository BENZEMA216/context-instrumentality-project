import Foundation
import Darwin
import OSLog

/// A small process/lifecycle breadcrumb, independent of the recording repository.
/// It never opens a recording, reads an inventory, starts a transfer, or retries
/// work. A stale file is only the last successful write, not proof of no launch.
public final class WatchRuntimeDiagnostics: @unchecked Sendable {
    public enum Event: String, Codable, CaseIterable, Sendable {
        case observerStarted, appConstructed, delegateCreated, launchCallback
        case modelInitializing, transferInitializationStarted, transferInitializationSucceeded
        case transferInitializationFailed, becameActive, becameInactive, enteredBackground
        case connectivityTaskArrived, refreshTaskArrived, snapshotTaskArrived, otherTaskArrived
        case transferTaskCompleted, transferTaskExpired
        case refreshSchedulingStarted, refreshSchedulingSucceeded, refreshSchedulingFailed
        case backgroundReportWriteFailed
        case lifecycleObserved
    }

    public struct ErrorIdentity: Codable, Equatable, Sendable {
        public enum Domain: String, Codable, Sendable { case cocoa, posix, url, other }
        public let domain: Domain
        public let code: Int

        init(_ error: Error) {
            let value = error as NSError
            switch value.domain {
            case NSCocoaErrorDomain: domain = .cocoa
            case NSPOSIXErrorDomain: domain = .posix
            case NSURLErrorDomain: domain = .url
            default: domain = .other
            }
            code = value.code
        }
    }

    public struct Observation: Codable, Equatable, Sendable {
        public let sequence: UInt64
        public let event: Event
        public let observedAtMS: Int64
        public let uptimeMS: Int64
        public let error: ErrorIdentity?
        // Optional for schema-1 compatibility with all prior runtime reports.
        public let lifecycle: WatchLifecyclePolicy.Decision?
    }

    public struct WriteFailure: Codable, Equatable, Sendable {
        public let event: Event
        public let observedAtMS: Int64
        public let error: ErrorIdentity
    }

    /// System-log-only trace. The begin marker is emitted before waiting for the
    /// JSON lock; completion is emitted after releasing it. A last successful
    /// file therefore cannot hide entry into a blocked or failed later write.
    /// This does not change schema 1 or its finite event vocabulary.
    struct Trace: Equatable, Sendable {
        enum Phase: String, Sendable { case began, succeeded, failed }
        let event: Event
        let phase: Phase
        let entryUptimeMS: Int64
        let sequence: UInt64?
        let error: ErrorIdentity?
    }

    public struct Report: Codable, Equatable, Sendable {
        public let schemaVersion: Int
        public let build: String
        public let processRunID: UUID
        public let observerEpochID: UUID
        public let processID: Int32
        public var generatedAtMS: Int64
        public var writeAttemptCount: UInt64
        public var writeFailureCount: UInt64
        public var lastWriteFailure: WriteFailure?
        public var counts: [String: UInt64]
        public var recentEvents: [Observation]
    }

    public static let maximumBytes = 8_192
    public static let maximumEvents = 24
    public static let directoryName = "ConnectivityDiagnostics"
    public static let fileName = "watch-runtime.json"
    public static let shared = WatchRuntimeDiagnostics(
        root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
        build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")

    private let lock = NSLock()
    private var value: Report
    private let writer: (Data) throws -> Void
    private let failureSink: (Event, ErrorIdentity) -> Void
    private let traceSink: (Trace) -> Void
    private let observationDirectory: URL?
    private var observationPublisher: VerifiedObservationPublisher?
    private var lastPersistedBytes: Data?
    private let observationQueue: DispatchQueue
    private var observationPending = false
    private var observationRunning = false
    private var observationSourceChanged = false
    private var observationInvalidationPending = false
    private var observationThrottleFeedback: (@Sendable (Int) -> Void)?
    private static let logger = Logger(subsystem: "WristRecord", category: "watch-runtime")

    /// Other small observers can share the process identity while retaining
    /// their own observer epoch/counters. Neither accessor performs I/O.
    public var processRunID: UUID {
        lock.lock(); defer { lock.unlock() }; return value.processRunID
    }
    public var observerEpochID: UUID {
        lock.lock(); defer { lock.unlock() }; return value.observerEpochID
    }

    /// `root` is Application Support itself, never RecordingRepository.defaultRoot().
    /// The injectable writer is internal and used only with synthetic test data.
    public convenience init(root: URL, build: String) {
        self.init(build: build, observationDirectory: root.appendingPathComponent(Self.directoryName, isDirectory: true), writer: { try Self.persist($0, root: root) }, failureSink: { event, error in
            // Do not log arbitrary NSError domains/messages: they can contain
            // paths, account information, or recording identities.
            Self.logger.error("Runtime diagnostic write failed event=\(event.rawValue, privacy: .public) domain=\(error.domain.rawValue, privacy: .public) code=\(error.code, privacy: .public)")
        })
    }

    init(build: String, observationDirectory: URL? = nil, writer: @escaping (Data) throws -> Void,
         failureSink: @escaping (Event, ErrorIdentity) -> Void = { _, _ in },
         traceSink: ((Trace) -> Void)? = nil,
         observationMinimumIntervalMS: Int64 = 30_000,
         observationQueue: DispatchQueue = DispatchQueue(label: "WristRecord.watch.runtime-observation", qos: .utility)) {
        self.observationQueue = observationQueue
        self.writer = writer
        self.observationDirectory = observationDirectory
        self.failureSink = failureSink
        self.traceSink = traceSink ?? Self.logTrace
        // A build is a bounded, numeric bundle value. No caller-supplied text is
        // admitted into this file; malformed bundle metadata is simply unknown.
        let safeBuild = !build.isEmpty && build.utf8.count <= 20
            && build.utf8.allSatisfy({ (48...57).contains($0) }) ? build : "unknown"
        self.value = Report(schemaVersion: 1, build: safeBuild, processRunID: UUID(),
            observerEpochID: UUID(), processID: getpid(), generatedAtMS: 0,
            writeAttemptCount: 0, writeFailureCount: 0, lastWriteFailure: nil,
            counts: [:], recentEvents: [])
        if let observationDirectory, let number = Int(safeBuild), number >= 87 {
            observationPublisher = VerifiedObservationPublisher(directory: observationDirectory,
                reportKind: "watch_runtime", build: safeBuild, processRunID: value.processRunID,
                minimumIntervalMS: observationMinimumIntervalMS)
        }
        record(.observerStarted)
    }

    /// Synchronously commits at lifecycle boundaries so a subsequent repository
    /// initialization failure or suspension cannot leave the breadcrumb queued.
    /// Failure never prevents the real application callback from proceeding.
    @discardableResult
    public func record(_ event: Event, error: Error? = nil,
                       lifecycle: WatchLifecyclePolicy.Decision? = nil) -> Bool {
        let entryUptimeMS = Int64(ProcessInfo.processInfo.systemUptime * 1_000)
        // Do not read value/processRunID here: either requires this same lock.
        traceSink(Trace(event: event, phase: .began, entryUptimeMS: entryUptimeMS,
                        sequence: nil, error: nil))
        lock.lock()
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        value.generatedAtMS = now
        value.writeAttemptCount &+= 1
        value.counts[event.rawValue, default: 0] &+= 1
        value.recentEvents.append(Observation(sequence: value.writeAttemptCount, event: event,
            observedAtMS: now, uptimeMS: Int64(ProcessInfo.processInfo.systemUptime * 1_000),
            error: error.map(ErrorIdentity.init), lifecycle: lifecycle))
        value.recentEvents = Array(value.recentEvents.suffix(Self.maximumEvents))
        do {
            var bytes = try JSONEncoder().encode(value)
            // Rich lifecycle inputs are bounded enums, but can make an event
            // larger. Keep cumulative counts and a shorter ordered tail rather
            // than losing the whole report to its fixed 8 KiB limit.
            while bytes.count > Self.maximumBytes, value.recentEvents.count > 1 {
                value.recentEvents.removeFirst()
                bytes = try JSONEncoder().encode(value)
            }
            guard !bytes.isEmpty, bytes.count <= Self.maximumBytes else { throw POSIXError(.EFBIG) }
            try writer(bytes)
            lastPersistedBytes = bytes
            enqueueObservationLocked(sourceDidChange: true)
            let sequence = value.writeAttemptCount
            lock.unlock()
            traceSink(Trace(event: event, phase: .succeeded, entryUptimeMS: entryUptimeMS,
                            sequence: sequence, error: nil))
            return true
        } catch {
            let identity = ErrorIdentity(error)
            observationInvalidationPending = true
            enqueueObservationLocked(sourceDidChange: false)
            lastPersistedBytes = nil
            value.writeFailureCount &+= 1
            value.lastWriteFailure = WriteFailure(event: event, observedAtMS: now, error: identity)
            let sequence = value.writeAttemptCount
            lock.unlock()
            traceSink(Trace(event: event, phase: .failed, entryUptimeMS: entryUptimeMS,
                            sequence: sequence, error: identity))
            // The last successful file remains intact. This independent system
            // log is available even if this diagnostic directory is unwritable;
            // a later successful record also persists the failure count/code.
            failureSink(event, identity)
            return false
        }
    }

    /// Revalidate only the last real runtime write. No lifecycle event, counter,
    /// source timestamp, transfer work or discovery is manufactured by preparation.
    /// The return value means queued; completion is represented by the index.
    @discardableResult public func prepareObservationSnapshot(onThrottle: (@Sendable (Int) -> Void)? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard observationPublisher != nil else { return false }
        if let onThrottle { observationThrottleFeedback = onThrottle }
        enqueueObservationLocked(sourceDidChange: false)
        return true
    }

    private func enqueueObservationLocked(sourceDidChange: Bool) {
        guard observationPublisher != nil else { return }
        observationPending = true
        observationSourceChanged = observationSourceChanged || sourceDidChange
        guard !observationRunning else { return }
        observationRunning = true
        observationQueue.async { [self] in drainObservations() }
    }

    private func drainObservations() {
        guard let publisher = observationPublisher else { return }
        while true {
            lock.lock()
            if observationInvalidationPending {
                observationInvalidationPending = false; lock.unlock()
                publisher.invalidate()
                continue
            }
            guard observationPending else { observationRunning = false; lock.unlock(); return }
            observationPending = false
            let changed = observationSourceChanged; observationSourceChanged = false
            let onThrottle = observationThrottleFeedback; observationThrottleFeedback = nil
            lock.unlock()
            publisher.observe(sourceDidChange: changed, onThrottle: onThrottle) {
                // Only the bounded 8 KiB read/capture needs the source lock.
                // Copying, fsync, hashing and generation GC run after unlocking.
                lock.lock(); defer { lock.unlock() }
                guard let directory = observationDirectory, let bytes = lastPersistedBytes,
                      try Self.readRuntime(directory) == bytes else {
                    throw VerifiedObservationPublisher.Failure.invalidSource
                }
                let report = try JSONDecoder().decode(Report.self, from: bytes)
                guard report == value, report.generatedAtMS > 0, report.writeAttemptCount > 0 else {
                    throw VerifiedObservationPublisher.Failure.invalidSource
                }
                return VerifiedObservationSource(sourceGeneratedAtMS: report.generatedAtMS,
                    identity: ["processRunID": report.processRunID.uuidString.lowercased(),
                        "observerEpochID": report.observerEpochID.uuidString.lowercased(),
                        "writeAttemptCount": String(report.writeAttemptCount)],
                    files: [VerifiedObservationFile(name: Self.fileName, bytes: bytes)],
                    snapshotFiles: [Self.fileName: bytes])
            }
        }
    }

    /// Internal synchronization point for synthetic tests, never a lifecycle call.
    func drainObservationQueue() { observationQueue.sync {} }

    private static func readRuntime(_ directory: URL) throws -> Data {
        let parent = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard parent >= 0 else { throw posixFailure() }; defer { Darwin.close(parent) }
        let file = Darwin.openat(parent, fileName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard file >= 0 else { throw posixFailure() }; defer { Darwin.close(file) }
        var before = stat()
        guard Darwin.fstat(file, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == getuid(), before.st_nlink == 1, before.st_size > 0,
              before.st_size <= maximumBytes else { throw POSIXError(.EINVAL) }
        var bytes = Data(count: Int(before.st_size))
        try bytes.withUnsafeMutableBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.read(file, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(.EIO) }; offset += count
            }
        }
        var after = stat(), current = stat()
        guard Darwin.fstat(file, &after) == 0,
              Darwin.fstatat(parent, fileName, &current, AT_SYMLINK_NOFOLLOW) == 0,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              current.st_ino == after.st_ino, current.st_dev == after.st_dev else { throw POSIXError(.ESTALE) }
        return bytes
    }

    private static func logTrace(_ trace: Trace) {
        // Bounded enums/numbers only; no NSError text, paths, source identities,
        // account identifiers, or recording data enter the independent log.
        logger.notice("Runtime write event=\(trace.event.rawValue, privacy: .public) phase=\(trace.phase.rawValue, privacy: .public) pid=\(getpid(), privacy: .public) entryUptimeMS=\(trace.entryUptimeMS, privacy: .public) sequence=\(trace.sequence ?? 0, privacy: .public) errorDomain=\(trace.error?.domain.rawValue ?? "none", privacy: .public) errorCode=\(trace.error?.code ?? 0, privacy: .public)")
    }

    private static func persist(_ bytes: Data, root: URL) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let parent = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard parent >= 0 else { throw posixFailure() }
        defer { Darwin.close(parent) }
        if Darwin.mkdirat(parent, directoryName, 0o700) != 0, errno != EEXIST { throw posixFailure() }
        let directory = Darwin.openat(parent, directoryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard directory >= 0 else { throw posixFailure() }
        defer { Darwin.close(directory) }
        var info = stat()
        guard Darwin.fstat(directory, &info) == 0 else { throw posixFailure() }
        guard info.st_uid == getuid() else { throw POSIXError(.EACCES) }
        guard Darwin.fchmod(directory, 0o700) == 0 else { throw posixFailure() }
        let temporary = ".watch-runtime-\(UUID().uuidString).tmp"
        let descriptor = Darwin.openat(directory, temporary,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw posixFailure() }
        defer { Darwin.close(descriptor); Darwin.unlinkat(directory, temporary, 0) }
        #if os(watchOS)
        let directoryURL = root.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directoryURL.path)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directoryURL.appendingPathComponent(temporary).path)
        #endif
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { throw POSIXError(.EINVAL) }
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw posixFailure() }
                offset += count
            }
        }
        var existing = stat()
        if Darwin.fstatat(directory, fileName, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard existing.st_mode & S_IFMT == S_IFREG, existing.st_nlink == 1,
                  existing.st_uid == getuid() else { throw POSIXError(.EINVAL) }
        } else if errno != ENOENT { throw posixFailure() }
        guard Darwin.fsync(descriptor) == 0 else { throw posixFailure() }
        guard Darwin.renameat(directory, temporary, directory, fileName) == 0 else { throw posixFailure() }
        guard Darwin.fsync(directory) == 0 else { throw posixFailure() }
    }

    private static func posixFailure() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
