import Foundation
import Darwin

enum PhoneStatusDiagnosticOutcome: String, Codable, Sendable {
    case received, noReport, staleReport, failed, timeout, unreachable, unsupported, unavailable
    case cancelled, interrupted, unverifiedReply
}

struct PhoneStatusDiagnosticSnapshot: Codable, Sendable {
    enum Scope: String, Codable, Sendable { case phoneStatusQueryMetadata = "phone_status_query_metadata" }
    enum Storage: String, Codable, Sendable { case pending, available, unavailable }
    enum Restore: String, Codable, Sendable { case absent, restored, rejected, unavailable }
    enum Trigger: String, Codable, Sendable { case manual, recovery }
    enum Stage: String, Codable, Sendable { case queued, workerStarted = "worker_started", sent, validated, terminal }
    enum Window: String, Codable, Sendable { case collecting, windowElapsed = "window_elapsed", truncated, interrupted }
    struct Connection: Codable, Sendable {
        let activated: Bool
        let paired: Bool
        let watchInstalled: Bool
        let reachable: Bool
    }
    struct NumericError: Codable, Sendable {
        enum Domain: String, Codable, Sendable { case watchConnectivity, other }
        let domain: Domain
        let code: Int
    }
    struct Event: Codable, Sendable {
        let sequence: UInt64
        let build: String
        let runID: UUID
        let observedAtMS: Int64
        let uptimeMS: Int64
        let intentID: UUID
        let attemptID: UUID
        let trigger: Trigger
        let stage: Stage
        let outcome: PhoneStatusDiagnosticOutcome?
        let connection: Connection?
        let error: NumericError?
        let elapsedMS: Int64?
    }
    struct Attempt: Codable, Sendable {
        let intentID: UUID
        let attemptID: UUID
        let trigger: Trigger
        let runID: UUID
        let startedUptimeMS: Int64
        var lastStage: Stage
        var validatedCurrentReply: Bool
    }
    struct Recovery: Codable, Sendable {
        let attemptID: UUID
        let stage: Stage
        let outcome: PhoneStatusDiagnosticOutcome?
        let observedAtMS: Int64
        let events: [Event]
    }
    struct Fault: Codable, Sendable {
        let failure: Event
        let before: [Event]
        var after: [Event]
        var window: Window
        var droppedContext: Int
        var recovery: Recovery?
    }
    var schemaVersion = 1
    var scope = Scope.phoneStatusQueryMetadata
    var build: String
    var runID: UUID
    var observedAtMS: Int64
    var includesRecordingContent = false
    var remoteHistoryObserved = false
    var realtimeStatusClaimed = false
    var storageState = Storage.pending
    var persistencePending = false
    var persistenceFailureObserved = false
    var restoreState = Restore.absent
    var interruptedAttempts = 0
    var truncated = false
    var droppedEvents = 0
    var droppedFaults = 0
    var lastPersistedSequence: UInt64 = 0
    var recentEvents: [Event] = []
    var faults: [Fault] = []
    var activeAttempts: [Attempt] = []
}

/// A bounded, typed phone-side account of dedicated status queries. The only
/// persistent input is this class's fixed small file; no library, snapshot,
/// recording identifier, error description, WC request or response is read here.
final class PhoneStatusDiagnostics: @unchecked Sendable {
    static let maximumBytes = 65_536
    static let maximumRecentEvents = 24
    static let maximumFaults = 3
    static let maximumBeforeEvents = 8
    static let maximumAfterEvents = 12
    private static let processRunID = UUID()
    private let lock = NSLock()
    private let io = DispatchQueue(label: "WristRecord.phone.status-diagnostics", qos: .utility)
    private let root: URL
    private let now: @Sendable () -> Date
    private let uptime: @Sendable () -> TimeInterval
    private var value: PhoneStatusDiagnosticSnapshot
    private var nextSequence: UInt64 = 1

    init(root: URL, build: String? = nil, runID: UUID? = nil,
         now: @escaping @Sendable () -> Date = { Date() },
         uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.root = root
        self.now = now
        self.uptime = uptime
        let candidate = build ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")
        let safeBuild = Self.validBuild(candidate) ? candidate : "unknown"
        value = .init(build: safeBuild, runID: runID ?? Self.processRunID,
                      observedAtMS: Self.milliseconds(now().timeIntervalSince1970))
        restore()
    }

    /// Only a short memory lock. In particular exporting never reads this file,
    /// obtains WC flags, renews a watch report or starts persistence.
    func snapshot() -> PhoneStatusDiagnosticSnapshot {
        lock.lock(); defer { lock.unlock() }
        var copy = value
        copy.observedAtMS = Self.milliseconds(now().timeIntervalSince1970)
        Self.expireWindows(&copy, at: copy.observedAtMS)
        return copy
    }

    func begin(intentID: UUID, attemptID: UUID, recovery: Bool,
               connection: PhoneStatusDiagnosticSnapshot.Connection?) {
        lock.lock(); defer { lock.unlock() }
        // A replacement remains explicit even if its predecessor never entered
        // the connectivity worker. This does not complete any UI callback.
        for attempt in value.activeAttempts {
            terminalLocked(attemptID: attempt.attemptID, outcome: .cancelled, connection: nil, error: nil)
        }
        value.activeAttempts = [.init(intentID: intentID, attemptID: attemptID,
            trigger: recovery ? .recovery : .manual, runID: value.runID,
            startedUptimeMS: Self.milliseconds(uptime()), lastStage: .queued, validatedCurrentReply: false)]
        appendLocked(attempt: value.activeAttempts[0], stage: .queued, connection: connection)
        persistLocked()
    }

    func stage(_ stage: PhoneStatusDiagnosticSnapshot.Stage, attemptID: UUID,
               connection: PhoneStatusDiagnosticSnapshot.Connection? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard let index = value.activeAttempts.firstIndex(where: { $0.attemptID == attemptID }),
              stage != .queued, stage != .terminal else { return }
        let previous = value.activeAttempts[index].lastStage
        let permitted = (stage == .workerStarted && previous == .queued)
            || (stage == .sent && previous == .workerStarted)
            || (stage == .validated && previous == .sent)
        guard permitted else { return }
        value.activeAttempts[index].lastStage = stage
        if stage == .validated { value.activeAttempts[index].validatedCurrentReply = true }
        appendLocked(attempt: value.activeAttempts[index], stage: stage, connection: connection)
        persistLocked()
    }

    func terminal(attemptID: UUID, outcome: PhoneStatusDiagnosticOutcome,
                  connection: PhoneStatusDiagnosticSnapshot.Connection? = nil,
                  error: PhoneStatusDiagnosticSnapshot.NumericError? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard terminalLocked(attemptID: attemptID, outcome: outcome, connection: connection, error: error) else { return }
        persistLocked()
    }

    @discardableResult private func terminalLocked(attemptID: UUID, outcome: PhoneStatusDiagnosticOutcome,
        connection: PhoneStatusDiagnosticSnapshot.Connection?, error: PhoneStatusDiagnosticSnapshot.NumericError?) -> Bool {
        guard let index = value.activeAttempts.firstIndex(where: { $0.attemptID == attemptID }) else { return false }
        let attempt = value.activeAttempts.remove(at: index)
        let verifiedOutcome: PhoneStatusDiagnosticOutcome = outcome == .received && !attempt.validatedCurrentReply
            ? .unverifiedReply : outcome
        appendLocked(attempt: attempt, stage: .terminal, outcome: verifiedOutcome, connection: connection, error: error)
        if verifiedOutcome != .received && verifiedOutcome != .cancelled,
           let failure = value.recentEvents.last {
            let before = Array(value.recentEvents.dropLast().suffix(Self.maximumBeforeEvents))
            value.faults.append(.init(failure: failure, before: before, after: [],
                                     window: verifiedOutcome == .interrupted ? .interrupted : .collecting,
                                     droppedContext: 0, recovery: nil))
            while value.faults.count > Self.maximumFaults {
                value.faults.removeFirst(); value.droppedFaults += 1; value.truncated = true
            }
        }
        return true
    }

    private func appendLocked(attempt: PhoneStatusDiagnosticSnapshot.Attempt,
        stage: PhoneStatusDiagnosticSnapshot.Stage, outcome: PhoneStatusDiagnosticOutcome? = nil,
        connection: PhoneStatusDiagnosticSnapshot.Connection? = nil,
        error: PhoneStatusDiagnosticSnapshot.NumericError? = nil) {
        let timestamp = Self.milliseconds(now().timeIntervalSince1970)
        let mono = Self.milliseconds(uptime())
        let event = PhoneStatusDiagnosticSnapshot.Event(sequence: nextSequence, build: value.build, runID: value.runID,
            observedAtMS: timestamp, uptimeMS: mono, intentID: attempt.intentID, attemptID: attempt.attemptID,
            trigger: attempt.trigger, stage: stage, outcome: outcome, connection: connection, error: error,
            elapsedMS: stage == .terminal && attempt.runID == value.runID ? max(0, mono - attempt.startedUptimeMS) : nil)
        nextSequence += 1
        Self.expireWindows(&value, at: timestamp)
        for index in value.faults.indices {
            if value.faults[index].window == .collecting {
                if value.faults[index].after.count < Self.maximumAfterEvents { value.faults[index].after.append(event) }
                else {
                    value.faults[index].window = .truncated
                    value.faults[index].droppedContext += 1
                    value.truncated = true
                }
            }
            // Recovery is associated by the local UI intent, independently of
            // the context window. A later success never erases its old failure.
            if attempt.trigger == .recovery, value.faults[index].failure.intentID == attempt.intentID,
               stage == .queued || stage == .terminal {
                value.faults[index].recovery = .init(attemptID: attempt.attemptID, stage: stage,
                    outcome: outcome, observedAtMS: timestamp,
                    events: Array((value.recentEvents.filter { $0.attemptID == attempt.attemptID } + [event]).suffix(5)))
            }
        }
        value.recentEvents.append(event)
        while value.recentEvents.count > Self.maximumRecentEvents {
            value.recentEvents.removeFirst(); value.droppedEvents += 1; value.truncated = true
        }
        value.observedAtMS = timestamp
    }

    private static func expireWindows(_ snapshot: inout PhoneStatusDiagnosticSnapshot, at time: Int64) {
        for index in snapshot.faults.indices where snapshot.faults[index].window == .collecting {
            if time - snapshot.faults[index].failure.observedAtMS >= 60_000 { snapshot.faults[index].window = .windowElapsed }
        }
    }

    private func persistLocked() {
        value.persistencePending = true
        if !value.persistenceFailureObserved { value.storageState = .pending }
        // The size cap is enforced on the actual full encoded envelope, rather
        // than on estimates of individual event sizes.
        while let data = try? JSONEncoder().encode(value), data.count > Self.maximumBytes {
            value.truncated = true
            if value.faults.count > 1 { value.faults.removeFirst(); value.droppedFaults += 1 }
            else if !value.recentEvents.isEmpty { value.recentEvents.removeFirst(); value.droppedEvents += 1 }
            else { value.storageState = .unavailable; value.persistenceFailureObserved = true; return }
        }
        let pending = value
        let sequence = nextSequence - 1
        io.async { [self] in
            var document = pending
            lock.lock()
            document.persistenceFailureObserved = document.persistenceFailureObserved || value.persistenceFailureObserved
            document.storageState = document.persistenceFailureObserved ? .unavailable : .available
            document.persistencePending = false
            document.lastPersistedSequence = sequence
            lock.unlock()
            let succeeded: Bool
            do { try write(document); succeeded = true } catch { succeeded = false }
            lock.lock(); defer { lock.unlock() }
            if succeeded { value.lastPersistedSequence = max(value.lastPersistedSequence, sequence) }
            else { value.persistenceFailureObserved = true }
            value.persistencePending = value.lastPersistedSequence < nextSequence - 1
            value.storageState = value.persistenceFailureObserved ? .unavailable : .available
        }
    }

    private func write(_ snapshot: PhoneStatusDiagnosticSnapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= Self.maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        let parent = try directoryDescriptor(create: true)
        defer { close(parent) }
        var existing = stat()
        if fstatat(parent, "status-history.json", &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard existing.st_mode & S_IFMT == S_IFREG, existing.st_nlink == 1,
                  existing.st_uid == getuid() else { throw POSIXError(.EINVAL) }
        } else if errno != ENOENT { throw POSIXError(.EIO) }
        let temporary = ".status-\(UUID().uuidString).tmp"
        let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        defer { close(fd); unlinkat(parent, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, base.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
        guard fchmod(fd, 0o600) == 0, fsync(fd) == 0,
              renameat(parent, temporary, parent, "status-history.json") == 0,
              fsync(parent) == 0 else { throw POSIXError(.EIO) }
    }

    private func restore() {
        let parent: Int32
        do { parent = try directoryDescriptor(create: false) }
        catch {
            if (error as? POSIXError)?.code != .ENOENT {
                value.restoreState = .unavailable; value.persistenceFailureObserved = true; value.storageState = .unavailable
            }
            return
        }
        defer { close(parent) }
        let fd = openat(parent, "status-history.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            if errno != ENOENT { value.restoreState = .unavailable; value.persistenceFailureObserved = true; value.storageState = .unavailable }
            return
        }
        defer { close(fd) }
        do {
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                  info.st_uid == getuid(),
                  info.st_size > 0, info.st_size <= Self.maximumBytes else { throw CocoaError(.fileReadCorruptFile) }
            let data = try FileHandle(fileDescriptor: fd, closeOnDealloc: false)
                .read(upToCount: Self.maximumBytes + 1) ?? Data()
            guard data.count <= Self.maximumBytes else { throw CocoaError(.fileReadCorruptFile) }
            var restored = try JSONDecoder().decode(PhoneStatusDiagnosticSnapshot.self, from: data)
            let priorEvents = restored.recentEvents + restored.faults.flatMap {
                [$0.failure] + $0.before + $0.after + ($0.recovery?.events ?? [])
            }
            guard restored.schemaVersion == 1, !restored.includesRecordingContent,
                  !restored.remoteHistoryObserved, !restored.realtimeStatusClaimed,
                  restored.observedAtMS >= 0, !restored.persistencePending,
                  Self.validBuild(restored.build), restored.recentEvents.count <= Self.maximumRecentEvents,
                  restored.faults.count <= Self.maximumFaults, restored.activeAttempts.count <= 1,
                  [restored.interruptedAttempts, restored.droppedEvents, restored.droppedFaults].allSatisfy({ (0...1_000_000_000).contains($0) }),
                  restored.lastPersistedSequence == UInt64(restored.droppedEvents + restored.recentEvents.count),
                  restored.lastPersistedSequence == (priorEvents.map(\.sequence).max() ?? 0),
                  Self.ordered(restored.recentEvents),
                  restored.activeAttempts.allSatisfy({ attempt in
                    attempt.startedUptimeMS >= 0 && attempt.lastStage != .terminal
                    && attempt.validatedCurrentReply == (attempt.lastStage == .validated)
                    && restored.recentEvents.last(where: { $0.attemptID == attempt.attemptID })?.stage == attempt.lastStage
                  }),
                  restored.faults.allSatisfy({ fault in
                    fault.before.count <= Self.maximumBeforeEvents && fault.after.count <= Self.maximumAfterEvents
                    && (0...1_000_000_000).contains(fault.droppedContext)
                    && fault.failure.stage == .terminal && fault.failure.outcome != nil
                    && fault.failure.outcome != .received && fault.failure.outcome != .cancelled
                    && Self.ordered(fault.before) && Self.ordered(fault.after)
                    && fault.before.allSatisfy({ $0.sequence < fault.failure.sequence })
                    && fault.after.allSatisfy({ $0.sequence > fault.failure.sequence })
                    && (fault.recovery.map({ Self.validRecovery($0, intentID: fault.failure.intentID) }) ?? true)
                  }),
                  priorEvents.allSatisfy({ Self.validBuild($0.build) && (1...1_000_000_024).contains($0.sequence)
                    && $0.observedAtMS >= 0 && $0.uptimeMS >= 0 && ($0.elapsedMS ?? 0) >= 0
                    && (($0.stage == .terminal) == ($0.outcome != nil))
                    && ($0.stage == .terminal || $0.elapsedMS == nil) })
            else { throw CocoaError(.fileReadCorruptFile) }
            let currentBuild = value.build, currentRunID = value.runID
            nextSequence = max(priorEvents.map(\.sequence).max() ?? 0, restored.lastPersistedSequence) + 1
            restored.build = currentBuild; restored.runID = currentRunID
            restored.restoreState = .restored; restored.persistencePending = false
            restored.storageState = restored.persistenceFailureObserved ? .unavailable : .available
            value = restored
            for index in value.faults.indices where value.faults[index].window == .collecting {
                value.faults[index].window = .interrupted
            }
            let unfinished = value.activeAttempts.filter { $0.runID != currentRunID }
            for attempt in unfinished {
                value.interruptedAttempts += 1
                terminalLocked(attemptID: attempt.attemptID, outcome: .interrupted, connection: nil, error: nil)
            }
            if !unfinished.isEmpty { persistLocked() }
        } catch {
            value.restoreState = .rejected; value.storageState = .unavailable; value.persistenceFailureObserved = true
        }
    }

    private static func validBuild(_ value: String) -> Bool {
        value == "unknown" || (!value.isEmpty && value.utf8.count <= 32 && value.utf8.allSatisfy { (48...57).contains($0) || $0 == 46 })
    }
    private static func ordered(_ events: [PhoneStatusDiagnosticSnapshot.Event]) -> Bool {
        zip(events, events.dropFirst()).allSatisfy { $0.sequence < $1.sequence }
    }
    private static func validRecovery(_ recovery: PhoneStatusDiagnosticSnapshot.Recovery, intentID: UUID) -> Bool {
        let events = recovery.events
        guard (1...5).contains(events.count), ordered(events),
              let first = events.first, let last = events.last,
              first.stage == .queued, last.stage == recovery.stage, last.outcome == recovery.outcome,
              last.observedAtMS == recovery.observedAtMS,
              events.allSatisfy({ $0.intentID == intentID && $0.attemptID == recovery.attemptID
                && $0.trigger == .recovery }),
              events.dropLast().allSatisfy({ $0.runID == first.runID }),
              last.runID == first.runID || (last.outcome == .interrupted && last.elapsedMS == nil) else { return false }
        if recovery.stage == .queued { return events.count == 1 && recovery.outcome == nil }
        guard recovery.stage == .terminal, recovery.outcome != nil else { return false }
        if recovery.outcome == .received {
            return events.map(\.stage) == [.queued, .workerStarted, .sent, .validated, .terminal]
        }
        let prefix: [PhoneStatusDiagnosticSnapshot.Stage] = [.queued, .workerStarted, .sent, .validated]
        return Array(prefix.prefix(events.count - 1)) == events.dropLast().map(\.stage)
    }
    /// Work exclusively through fixed names relative to verified directory FDs;
    /// never enumerate the directory or follow an alias to another location.
    private func directoryDescriptor(create: Bool) throws -> Int32 {
        let parent = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard parent >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(parent) }
        var parentInfo = stat()
        guard fstat(parent, &parentInfo) == 0, parentInfo.st_uid == getuid() else { throw POSIXError(.EACCES) }
        if create {
            if mkdirat(parent, "ConnectivityDiagnostics", 0o700) == 0 {
                guard fsync(parent) == 0 else { throw POSIXError(.EIO) }
            } else if errno != EEXIST { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        let fd = openat(parent, "ConnectivityDiagnostics", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), !create || fchmod(fd, 0o700) == 0 else {
            close(fd); throw POSIXError(.EACCES)
        }
        return fd
    }
    private static func milliseconds(_ seconds: TimeInterval) -> Int64 {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int64.max) / 1_000 else { return 0 }
        return Int64(seconds * 1_000)
    }
}
