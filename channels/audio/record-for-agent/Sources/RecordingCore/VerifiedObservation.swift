import Foundation
import CryptoKit
import Darwin
import OSLog

/// Hashes metadata bytes only. A receipt never changes business progress or its timestamps.
public struct VerifiedObservationFile: Codable, Equatable, Sendable {
    public let name: String
    public let sha256: String
    public let byteCount: Int
    public init(name: String, bytes: Data) {
        self.name = name; sha256 = VerifiedObservationPublisher.digest(bytes); byteCount = bytes.count
    }
}

public struct VerifiedObservationSource: Sendable {
    public let sourceGeneratedAtMS: Int64
    public let identity: [String: String]
    public let files: [VerifiedObservationFile]
    /// Exact metadata bytes already read and validated by the source owner.
    /// Build 87 packages these bytes; it never reopens arbitrary source paths.
    public let snapshotFiles: [String: Data]?
    public init(sourceGeneratedAtMS: Int64, identity: [String: String], files: [VerifiedObservationFile],
                snapshotFiles: [String: Data]? = nil) {
        self.sourceGeneratedAtMS = sourceGeneratedAtMS; self.identity = identity; self.files = files
        self.snapshotFiles = snapshotFiles
    }
}

/// Call on the source owner's serial queue, after normal publication has drained.
/// Validation must read all bounded metadata, check its semantics, and reread the
/// source bytes before returning. This writer never opens audio or business files.
public final class VerifiedObservationPublisher: @unchecked Sendable {
    public static let schemaVersion = 2
    /// Darwin CLOCK_MONOTONIC includes system sleep; CLOCK_UPTIME_RAW does not.
    public static let clockName = "CLOCK_MONOTONIC"
    public static let fileName = "verified-observation.json"
    public static let statusName = "verified-observation-status.json"
    public static let maximumBytes = 262_144
    public static let processRunID = UUID()
    public struct Receipt: Codable, Equatable, Sendable {
        public let schemaVersion: Int
        public let reportKind: String
        public let build: String
        public let observerProcessRunID: UUID
        public let sequence: UInt64
        public let observedAtMS: Int64
        public let continuousTimeMS: Int64
        public let clockName: String
        public let sourceGeneratedAtMS: Int64
        public let identity: [String: String]
        public let files: [VerifiedObservationFile]
        public let audioRead: Bool
        public let includesAudio: Bool
    }
    public struct Status: Codable, Equatable, Sendable {
        public let schemaVersion: Int
        public let reportKind: String
        public let build: String
        public let observerProcessRunID: UUID
        public let sequence: UInt64
        public let observedAtMS: Int64
        public let continuousTimeMS: Int64
        public let clockName: String
        public let available: Bool
        public let observationSHA256: String?
        public let failureCode: String?
    }
    public enum Failure: Error, Equatable { case invalidSource, unsafePath, unavailable, clockDiscontinuity }
    private static let logger = Logger(subsystem: "WristRecord", category: "verified-observation")
    private let lock = NSLock()
    private let reportKind: String
    private let build: String
    private let process: UUID
    private let interval: Int64
    private let clock: () -> (wall: Int64, continuous: Int64)
    private let writer: (Data, String) throws -> Void
    private let failureSink: (String) -> Void
    private let snapshotPublisher: ImmutableObservationSnapshotPublisher?
    private var sequence: UInt64 = 0
    // A failed invalidation remains blocked until a later caller persists it.
    private var pendingFailureStatus: Status?
    private var lastAttempt: (wall: Int64, continuous: Int64)?
    private var lastSnapshotPublication: (wall: Int64, continuous: Int64)?
    private var pacesSnapshots: Bool { (UInt64(build) ?? 0) >= 88 }
    private var publicationInterval: Int64 {
        pacesSnapshots ? max(interval, snapshotPublisher?.recommendedPublicationIntervalMS ?? 30_000) : interval
    }

    public convenience init(directory: URL, reportKind: String, build: String, processRunID: UUID,
                            minimumIntervalMS: Int64 = 30_000) {
        self.init(reportKind: reportKind, build: build, processRunID: processRunID,
                  minimumIntervalMS: minimumIntervalMS,
                  clock: { (Int64(Date().timeIntervalSince1970 * 1_000), Self.continuousMilliseconds()) },
                  writer: { try Self.persist($0, name: $1, directory: directory) },
                  snapshotPublisher: Self.requiresSnapshot(build) ? ImmutableObservationSnapshotPublisher(
                    directory: directory, reportKind: reportKind, build: build, processRunID: processRunID) : nil)
    }
    init(reportKind: String, build: String, processRunID: UUID, minimumIntervalMS: Int64 = 30_000,
         clock: @escaping () -> (wall: Int64, continuous: Int64),
         writer: @escaping (Data, String) throws -> Void, failureSink: ((String) -> Void)? = nil,
         snapshotPublisher: ImmutableObservationSnapshotPublisher? = nil) {
        self.reportKind = reportKind; self.build = build; process = processRunID
        interval = max(0, minimumIntervalMS); self.clock = clock; self.writer = writer
        self.snapshotPublisher = snapshotPublisher
        self.failureSink = failureSink ?? { code in
            Self.logger.error("Verified metadata observation failed code=\(code, privacy: .public)")
        }
        if let snapshotPublisher {
            do { try snapshotPublisher.invalidate(sequence: 0, time: clock(), code: "observer_startup") }
            catch { self.failureSink("snapshot_startup_fence_write_failed") }
        }
    }
    @discardableResult public func observe(sourceDidChange: Bool = false, onThrottle: ((Int) -> Void)? = nil,
                                          validate: () throws -> VerifiedObservationSource) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let pending = pendingFailureStatus {
            do {
                try writer(try Self.encode(pending), Self.statusName)
                pendingFailureStatus = nil
            } catch {
                failureSink("failure_status_write_failed")
                return false
            }
        }
        let start = clock()
        let clockIsContinuous = lastAttempt.map { Self.consistentElapsed(from: $0, to: start) } ?? true
        // Reversal/jump must be rejected even inside the ordinary throttle.
        // Changed sources still validate immediately. Only successful immutable
        // publication moves the build-88 throttle anchor; frequent worker events
        // cannot postpone a due generation or recovery after a real failure.
        let throttleAnchor = pacesSnapshots ? lastSnapshotPublication : lastAttempt
        if !sourceDidChange, clockIsContinuous, let previous = throttleAnchor,
           start.continuous - previous.continuous < publicationInterval {
            let remaining = publicationInterval - (start.continuous - previous.continuous)
            onThrottle?(Int((remaining + 999) / 1_000))
            return false
        }
        let previous = lastAttempt; lastAttempt = start
        guard sequence < UInt64.max else { failureSink("sequence_exhausted"); return false }
        sequence += 1
        func status(_ available: Bool, _ digest: String?, _ code: String?, _ time: (wall: Int64, continuous: Int64)) throws {
            try writer(try Self.encode(Status(schemaVersion: Self.schemaVersion, reportKind: reportKind, build: build,
                observerProcessRunID: process, sequence: sequence, observedAtMS: time.wall, continuousTimeMS: time.continuous, clockName: Self.clockName,
                available: available, observationSHA256: digest, failureCode: code)), Self.statusName)
        }
        do {
            if Self.requiresSnapshot(build) {
                guard let snapshotPublisher else { throw Failure.invalidSource }
                try snapshotPublisher.begin(sequence: sequence, time: start,
                    minimumPublicationIntervalMS: pacesSnapshots && lastSnapshotPublication != nil ? publicationInterval : 0)
            }
            // A later failed attempt invalidates an earlier receipt without rewriting it.
            try status(false, nil, "validation_pending", start)
            guard ["watch_backlog", "watch_runtime", "phone_receipts", "google_drive", "icloud_drive", "google_drive_worker"].contains(reportKind),
                  !build.isEmpty, build.count <= 20, build.utf8.allSatisfy({ (48...57).contains($0) }),
                  start.wall > 0, start.continuous >= 0 else { throw Failure.invalidSource }
            if let previous {
                guard Self.consistentElapsed(from: previous, to: start) else { throw Failure.clockDiscontinuity }
            }
            let source = try validate()
            let end = clock()
            guard Self.consistentElapsed(from: start, to: end),
                  end.continuous - start.continuous <= 30_000 else { throw Failure.clockDiscontinuity }
            guard source.sourceGeneratedAtMS > 0, source.sourceGeneratedAtMS <= end.wall,
                  !source.identity.isEmpty, source.identity.count <= 16,
                  source.identity.allSatisfy({ !$0.key.isEmpty && $0.key.count <= 64 && !$0.value.isEmpty && $0.value.utf8.count <= 256 }),
                  !source.files.isEmpty, source.files.count <= 512,
                  Set(source.files.map(\.name)).count == source.files.count,
                  source.files.allSatisfy({ Self.safeRelative($0.name) && $0.byteCount > 0 && $0.byteCount <= 8 * 1_024 * 1_024 })
            else { throw Failure.invalidSource }
            let receipt = Receipt(schemaVersion: Self.schemaVersion, reportKind: reportKind, build: build,
                observerProcessRunID: process, sequence: sequence, observedAtMS: end.wall, continuousTimeMS: end.continuous, clockName: Self.clockName,
                sourceGeneratedAtMS: source.sourceGeneratedAtMS, identity: source.identity,
                files: source.files.sorted { $0.name < $1.name }, audioRead: false, includesAudio: false)
            let bytes = try Self.encode(receipt)
            guard bytes.count <= Self.maximumBytes else { throw Failure.invalidSource }
            let completedStatus = Status(schemaVersion: Self.schemaVersion, reportKind: reportKind, build: build,
                observerProcessRunID: process, sequence: sequence, observedAtMS: end.wall,
                continuousTimeMS: end.continuous, clockName: Self.clockName,
                available: true, observationSHA256: Self.digest(bytes), failureCode: nil)
            let statusBytes = try Self.encode(completedStatus)
            try writer(bytes, Self.fileName)
            try writer(statusBytes, Self.statusName)
            let disposition = try snapshotPublisher?.commit(source: source, receipt: receipt,
                receiptBytes: bytes, statusBytes: statusBytes)
            if disposition == .published { lastSnapshotPublication = end }
            return true
        } catch {
            lastSnapshotPublication = nil
            let code: String
            if error as? Failure == .clockDiscontinuity { code = "clock_discontinuity" }
            else if case ImmutableObservationSnapshotPublisher.Failure.lowSpace = error { code = "snapshot_low_space" }
            else if pacesSnapshots, let failure = error as? ImmutableObservationSnapshotPublisher.Failure {
                switch failure {
                case .capacity: code = "snapshot_capacity_exceeded"
                case .unavailable: code = "snapshot_io_unavailable"
                case .unsafePath: code = "snapshot_unsafe_path"
                case .invalidSource: code = "snapshot_source_invalid"
                case .concurrentWriter: code = "snapshot_concurrent_writer"
                case .lowSpace: code = "snapshot_low_space"
                }
            }
            else { code = "validation_or_write_failed" }
            let failedAt = clock()
            let failed = Status(schemaVersion: Self.schemaVersion, reportKind: reportKind, build: build,
                observerProcessRunID: process, sequence: sequence, observedAtMS: failedAt.wall,
                continuousTimeMS: failedAt.continuous, clockName: Self.clockName,
                available: false, observationSHA256: nil, failureCode: code)
            pendingFailureStatus = failed
            do { try snapshotPublisher?.invalidate(sequence: sequence, time: failedAt, code: code) }
            catch { failureSink("snapshot_failure_fence_write_failed") }
            do {
                try writer(try Self.encode(failed), Self.statusName)
                pendingFailureStatus = nil
            } catch {
                // Fixed category, independent of the filesystem; retain the
                // blocked state and retry this invalidation before new work.
                failureSink("failure_status_write_failed")
            }
            failureSink(code)
            return false
        }
    }
    /// Called by a source owner when its real publication failed. This invalidates
    /// earlier snapshots without changing source events or manufacturing progress.
    public func invalidate() {
        lock.lock(); defer { lock.unlock() }
        lastSnapshotPublication = nil
        if sequence < UInt64.max { sequence += 1 }
        let now = clock(); lastAttempt = now
        let failed = Status(schemaVersion: Self.schemaVersion, reportKind: reportKind, build: build,
            observerProcessRunID: process, sequence: sequence, observedAtMS: now.wall,
            continuousTimeMS: now.continuous, clockName: Self.clockName,
            available: false, observationSHA256: nil, failureCode: "source_publication_failed")
        pendingFailureStatus = failed
        do { try snapshotPublisher?.invalidate(sequence: sequence, time: now, code: "source_publication_failed") }
        catch { failureSink("snapshot_failure_fence_write_failed") }
        do { try writer(try Self.encode(failed), Self.statusName); pendingFailureStatus = nil }
        catch { failureSink("failure_status_write_failed") }
    }
    static func requiresSnapshot(_ build: String) -> Bool {
        guard let value = UInt64(build) else { return false }
        return value >= 87
    }
    static func continuousMilliseconds(readNanoseconds: () -> UInt64 = { clock_gettime_nsec_np(CLOCK_MONOTONIC) }) -> Int64 {
        let nanoseconds = readNanoseconds()
        // Darwin returns zero on failure; never attest an unavailable clock.
        return nanoseconds == 0 ? -1 : Int64(nanoseconds / 1_000_000)
    }
    private static func consistentElapsed(from a: (wall: Int64, continuous: Int64),
                                          to b: (wall: Int64, continuous: Int64)) -> Bool {
        guard a.wall >= 0, a.continuous >= 0, b.wall >= a.wall, b.continuous >= a.continuous else { return false }
        return abs(Double(b.wall - a.wall) - Double(b.continuous - a.continuous)) <= 2_000
    }
    public static func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    private static func safeRelative(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 256 && !name.hasPrefix("/") && name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }
        }
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private static func persist(_ bytes: Data, name: String, directory: URL) throws {
        guard [fileName, statusName].contains(name), bytes.count <= maximumBytes else { throw Failure.invalidSource }
        let parent = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard parent >= 0 else { throw Failure.unavailable }; defer { Darwin.close(parent) }
        var info = stat()
        guard Darwin.fstat(parent, &info) == 0, info.st_uid == getuid() else { throw Failure.unsafePath }
        if Darwin.fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_uid == getuid() else { throw Failure.unsafePath }
        } else if errno != ENOENT { throw Failure.unavailable }
        let temporary = ".verified-observation-" + UUID().uuidString + ".tmp"
        let fd = Darwin.openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw Failure.unavailable }
        defer { Darwin.close(fd); Darwin.unlinkat(parent, temporary, 0) }
        #if os(iOS) || os(watchOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.appendingPathComponent(temporary).path)
        #endif
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: bytes)
        guard Darwin.fsync(fd) == 0, Darwin.renameat(parent, temporary, parent, name) == 0,
              Darwin.fsync(parent) == 0 else { throw Failure.unavailable }
    }
}
