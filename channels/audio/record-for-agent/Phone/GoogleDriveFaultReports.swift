import Foundation
import RecordingCore
import Darwin

/// These types intentionally cannot represent URLs, headers, identities, audio
/// or response/error text. UUIDs below are random local diagnostic identities.
struct GoogleDriveRequestCompletion: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case succeeded, recovered
        case httpFailure = "http_failure", notEligible = "not_eligible"
        case budgetExpired = "budget_expired", callerBudgetRejected = "caller_budget_rejected"
        case cancelled, recoveryFailed = "recovery_failed", invalidResponse = "invalid_response"
    }
    let requestID: UUID
    let origin: GoogleDriveTransportDiagnostic.Origin
    let attemptCount: Int
    let outcome: Outcome
    var uploadCorrelation: GoogleDriveUploadCorrelation? = nil
}

enum GoogleDriveFaultApplicationState: String, Codable, Sendable { case active, inactive, background, unknown }

struct GoogleDriveTransportFaultArchive: Codable, Equatable, Sendable {
    var schemaVersion: Int
    /// This is a bounded app-transport observation log, never a system log.
    let contextScope: ContextScope
    enum ContextScope: String, Codable, Sendable { case currentProcessTransport = "current_process_transport" }
    var evictedReportCount: Int
    var reports: [GoogleDriveTransportFaultReport]
}

struct GoogleDriveTransportFaultReport: Codable, Equatable, Sendable {
    enum State: String, Codable, Sendable {
        case collecting, windowElapsed = "window_elapsed", truncated, interrupted
    }
    enum Truncation: String, Codable, Sendable { case eventLimit = "event_limit", byteLimit = "byte_limit" }
    struct Event: Codable, Equatable, Sendable {
        enum Position: String, Codable, Sendable { case before, trigger, after }
        let timestamp: Date
        let build: Int
        let applicationState: GoogleDriveFaultApplicationState
        let position: Position
        let diagnostic: GoogleDriveTransportDiagnostic
    }
    let id: UUID
    let primaryRequestID: UUID?
    let correlationAvailable: Bool
    let origin: GoogleDriveTransportDiagnostic.Origin
    let triggeredAt: Date
    let windowEndsAt: Date
    var state: State
    var closedAt: Date?
    var truncation: Truncation?
    /// A terminal request result is independent of the context window state.
    var completion: GoogleDriveRequestCompletion?
    var completionObservedAt: Date?
    var completionApplicationState: GoogleDriveFaultApplicationState?
    var completionBuild: Int?
    var terminalObservedOutsideWindow: Bool
    /// The final recovery attempt is retained even after context collection
    /// stops; a full context window and a proven request result are distinct.
    var recoveryEvidence: Event?
    var events: [Event]
}

/// Synchronous callbacks freeze the initial failure before recovery can begin.
/// All I/O is a small bounded JSON file. No recording repository is referenced.
/// A failed atomic write throws and leaves the in-memory saved snapshot intact.
final class GoogleDriveTransportFaultRecorder: @unchecked Sendable {
    static let maximumArchiveBytes = 1_572_864
    static let maximumReportBytes = 131_072
    static let maximumReports = 10
    static let maximumBeforeEvents = 32
    static let maximumAfterEvents = 64
    static let observationWindow: TimeInterval = 60
    enum StorageError: Error { case invalidArchive, invalidObservation, capacity, unsafeFile, storageIO }
    private let lock = NSLock()
    private let storeURL: URL
    private var archive = GoogleDriveTransportFaultArchive(schemaVersion: 2, contextScope: .currentProcessTransport,
        evictedReportCount: 0, reports: [])
    private var ring: [GoogleDriveTransportFaultReport.Event] = []

    init(storeURL: URL, now: Date = Date()) throws {
        self.storeURL = storeURL
        guard Self.validTime(now, now: now) else { throw StorageError.invalidArchive }
        try Self.prepareDirectory(storeURL.deletingLastPathComponent())
        if let data = try Self.read(storeURL) {
            guard let decoded = try? TransportCodec.decode(GoogleDriveTransportFaultArchive.self, from: data),
                  Self.valid(decoded, now: now) else { throw StorageError.invalidArchive }
            archive = decoded
            var restored = archive
            for index in restored.reports.indices where restored.reports[index].state == .collecting {
                // A clock rollback must not produce a closedAt before the
                // trigger and poison an otherwise valid saved archive.
                guard now >= restored.reports[index].triggeredAt else { throw StorageError.invalidObservation }
                // A new process cannot claim it observed the missing interval.
                restored.reports[index].state = .interrupted
                restored.reports[index].closedAt = now
            }
            if restored != archive { try commit(restored) }
        }
    }

    func record(_ diagnostic: GoogleDriveTransportDiagnostic, at timestamp: Date = Date(), build: Int,
                applicationState: GoogleDriveFaultApplicationState) throws {
        lock.lock(); defer { lock.unlock() }
        // Controlled Debug probes cannot enter either natural context or faults.
        guard diagnostic.origin != .controlledFault else { return }
        guard GoogleDriveTransportHistory.validDiagnostic(diagnostic), Self.validTime(timestamp, now: timestamp),
              Self.validBuild(build) else { throw StorageError.invalidObservation }
        guard ring.last.map({ timestamp >= $0.timestamp }) ?? true,
              archive.reports.allSatisfy({ timestamp >= $0.triggeredAt }) else { throw StorageError.invalidObservation }
        let event = GoogleDriveTransportFaultReport.Event(timestamp: timestamp, build: build,
            applicationState: applicationState, position: .after, diagnostic: diagnostic)
        var next = archive
        Self.expire(&next, at: timestamp)
        if diagnostic.phase == .apiRecovery, let requestID = diagnostic.requestID {
            for index in next.reports.indices where next.reports[index].primaryRequestID == requestID {
                guard next.reports[index].origin == diagnostic.origin,
                      Self.uploadCorrelation(next.reports[index]) == diagnostic.uploadCorrelation else { throw StorageError.invalidObservation }
                next.reports[index].recoveryEvidence = event
            }
        }
        for index in next.reports.indices where next.reports[index].state == .collecting {
            let after = next.reports[index].events.filter { $0.position == .after }.count
            if after < Self.maximumAfterEvents { next.reports[index].events.append(event) }
            else {
                next.reports[index].state = .truncated; next.reports[index].truncation = .eventLimit
                next.reports[index].closedAt = timestamp
            }
        }
        // HTTP 308/404/409/410 can be normal Drive control flow. Transport
        // cannot infer the client's accepted statuses or business success.
        let failed = !diagnostic.errors.isEmpty
        let alreadyFrozen = diagnostic.requestID.map { id in next.reports.contains { $0.primaryRequestID == id } } ?? false
        if failed && !alreadyFrozen {
            let before = ring.suffix(Self.maximumBeforeEvents).map {
                GoogleDriveTransportFaultReport.Event(timestamp: $0.timestamp, build: $0.build,
                    applicationState: $0.applicationState, position: .before, diagnostic: $0.diagnostic)
            }
            let trigger = GoogleDriveTransportFaultReport.Event(timestamp: timestamp, build: build,
                applicationState: applicationState, position: .trigger, diagnostic: diagnostic)
            next.reports.append(.init(id: UUID(), primaryRequestID: diagnostic.requestID, correlationAvailable: diagnostic.requestID != nil,
                origin: diagnostic.origin ?? .legacyUnknown, triggeredAt: timestamp,
                windowEndsAt: timestamp.addingTimeInterval(Self.observationWindow), state: .collecting,
                closedAt: nil, truncation: nil, completion: nil, completionObservedAt: nil,
                completionApplicationState: nil, completionBuild: nil, terminalObservedOutsideWindow: false,
                recoveryEvidence: diagnostic.phase == .apiRecovery ? event : nil, events: before + [trigger]))
        }
        if next != archive { try commit(next) }
        ring.append(event); ring = Array(ring.suffix(Self.maximumBeforeEvents))
    }

    func finish(_ completion: GoogleDriveRequestCompletion, at timestamp: Date = Date(), build: Int,
                applicationState: GoogleDriveFaultApplicationState) throws {
        lock.lock(); defer { lock.unlock() }
        guard completion.origin != .controlledFault else { return }
        guard Self.validCompletion(completion), Self.validTime(timestamp, now: timestamp), Self.validBuild(build) else {
            throw StorageError.invalidObservation
        }
        var next = archive
        Self.expire(&next, at: timestamp)
        // UUID equality is the sole association rule. Endpoint/time proximity
        // and unrelated successes cannot establish recovery.
        guard next.reports.filter({ $0.primaryRequestID == completion.requestID }).allSatisfy({
            $0.origin == completion.origin && timestamp >= $0.triggeredAt
                && Self.uploadCorrelation($0) == completion.uploadCorrelation
        }) else {
            throw StorageError.invalidObservation
        }
        if completion.outcome == .recovered {
            guard next.reports.filter({ $0.primaryRequestID == completion.requestID }).allSatisfy({ Self.provesRecovery($0) }) else {
                throw StorageError.invalidObservation
            }
        }
        for index in next.reports.indices where next.reports[index].primaryRequestID == completion.requestID {
            guard next.reports[index].completion == nil else { continue }
            next.reports[index].completion = completion
            next.reports[index].completionObservedAt = timestamp
            next.reports[index].completionApplicationState = applicationState
            next.reports[index].completionBuild = build
            next.reports[index].terminalObservedOutsideWindow = next.reports[index].state != .collecting
        }
        if next != archive { try commit(next) }
    }

    /// Observe the last saved in-memory archive without expiring a window,
    /// accessing storage or committing state. A collecting window remains an
    /// explicitly unfinished observation, even if its wall-clock deadline passed.
    func observationSnapshot() -> GoogleDriveTransportFaultArchive {
        lock.lock(); defer { lock.unlock() }
        return archive
    }

    func snapshot(at timestamp: Date = Date()) throws -> GoogleDriveTransportFaultArchive {
        lock.lock(); defer { lock.unlock() }
        guard Self.validTime(timestamp, now: timestamp) else { throw StorageError.invalidObservation }
        var next = archive; Self.expire(&next, at: timestamp)
        if next != archive { try commit(next) }
        return archive
    }

    func encodedForExport(at timestamp: Date = Date()) throws -> Data {
        try TransportCodec.encode(snapshot(at: timestamp))
    }

    private static func expire(_ value: inout GoogleDriveTransportFaultArchive, at timestamp: Date) {
        for index in value.reports.indices where value.reports[index].state == .collecting
            && timestamp >= value.reports[index].windowEndsAt {
            value.reports[index].state = .windowElapsed
            value.reports[index].closedAt = value.reports[index].windowEndsAt
        }
    }

    private func commit(_ proposed: GoogleDriveTransportFaultArchive) throws {
        var bounded = proposed
        bounded.schemaVersion = 2
        for index in bounded.reports.indices {
            while try TransportCodec.encode(bounded.reports[index]).count > Self.maximumReportBytes {
                // Preserve the actual trigger and completion; identify omitted
                // context explicitly rather than exporting silent truncation.
                guard let remove = bounded.reports[index].events.firstIndex(where: { $0.position == .before })
                    ?? bounded.reports[index].events.firstIndex(where: { $0.position == .after }) else {
                    throw StorageError.capacity
                }
                bounded.reports[index].events.remove(at: remove)
                bounded.reports[index].state = .truncated; bounded.reports[index].truncation = .byteLimit
                bounded.reports[index].closedAt = bounded.reports[index].closedAt ?? bounded.reports[index].triggeredAt
            }
        }
        while bounded.reports.count > Self.maximumReports {
            bounded.reports.removeFirst(); bounded.evictedReportCount += 1
        }
        var bytes = try TransportCodec.encode(bounded)
        while bytes.count > Self.maximumArchiveBytes, bounded.reports.count > 1 {
            bounded.reports.removeFirst(); bounded.evictedReportCount += 1
            bytes = try TransportCodec.encode(bounded)
        }
        guard bytes.count <= Self.maximumArchiveBytes else { throw StorageError.capacity }
        try Self.write(bytes, to: storeURL)
        archive = bounded
    }

    private static func prepareDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw StorageError.unsafeFile }
        defer { close(fd) }
        guard fchmod(fd, 0o700) == 0 else { throw StorageError.storageIO }
    }

    /// Final-component no-follow, regular-file and single-link checks prevent
    /// archived JSON from turning this small diagnostic reader into a file tap.
    private static func read(_ url: URL) throws -> Data? {
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard parent >= 0 else { throw StorageError.unsafeFile }; defer { close(parent) }
        let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw StorageError.unsafeFile
        }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG, before.st_nlink == 1,
              before.st_size > 0, before.st_size <= maximumArchiveBytes else { throw StorageError.invalidArchive }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = Darwin.read(fd, &buffer, min(buffer.count, maximumArchiveBytes + 1 - data.count))
            if count < 0 { if errno == EINTR { continue }; throw StorageError.storageIO }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= maximumArchiveBytes else { throw StorageError.invalidArchive }
        }
        var after = stat()
        guard fstat(fd, &after) == 0, after.st_nlink == 1, after.st_size == before.st_size,
              data.count == Int(before.st_size), after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else { throw StorageError.invalidArchive }
        return data
    }

    private static func write(_ bytes: Data, to url: URL) throws {
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard parent >= 0 else { throw StorageError.unsafeFile }; defer { close(parent) }
        var destination = stat()
        if fstatat(parent, url.lastPathComponent, &destination, AT_SYMLINK_NOFOLLOW) == 0 {
            guard (destination.st_mode & S_IFMT) == S_IFREG, destination.st_nlink == 1 else { throw StorageError.unsafeFile }
        } else if errno != ENOENT { throw StorageError.storageIO }
        let temporary = ".fault-" + UUID().uuidString + ".tmp"
        let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw StorageError.storageIO }
        defer { close(fd); unlinkat(parent, temporary, 0) }
        guard fchmod(fd, 0o600) == 0 else { throw StorageError.storageIO }
        try bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { throw StorageError.storageIO }
            var written = 0
            while written < raw.count {
                let count = Darwin.write(fd, base.advanced(by: written), raw.count - written)
                if count < 0 { if errno == EINTR { continue }; throw StorageError.storageIO }
                guard count > 0 else { throw StorageError.storageIO }; written += count
            }
        }
        guard fsync(fd) == 0 else { throw StorageError.storageIO }
        // Recheck just before replacement, including malicious links installed
        // since the initial validation. The private directory is app-owned.
        if fstatat(parent, url.lastPathComponent, &destination, AT_SYMLINK_NOFOLLOW) == 0 {
            guard (destination.st_mode & S_IFMT) == S_IFREG, destination.st_nlink == 1 else { throw StorageError.unsafeFile }
        } else if errno != ENOENT { throw StorageError.storageIO }
        guard renameat(parent, temporary, parent, url.lastPathComponent) == 0, fsync(parent) == 0 else { throw StorageError.storageIO }
    }

    private static func validBuild(_ value: Int) -> Bool { (0...10_000_000).contains(value) }
    private static func validTime(_ value: Date, now: Date) -> Bool {
        let number = value.timeIntervalSince1970, reference = now.timeIntervalSince1970
        return number.isFinite && (0...32_503_680_000).contains(number) && reference.isFinite && number <= reference + 300
    }
    private static func validCompletion(_ value: GoogleDriveRequestCompletion) -> Bool {
        (0...2).contains(value.attemptCount)
            && (value.outcome != .recovered || value.attemptCount == 2)
            && (value.uploadCorrelation.map(\.isValid) ?? true)
    }
    private static func provesRecovery(_ report: GoogleDriveTransportFaultReport) -> Bool {
        guard let evidence = report.recoveryEvidence else { return false }
        return GoogleDriveRecoveryDecision.provesSameRequestRecovery(
            httpStatus: evidence.diagnostic.httpStatus,
            methodIsGET: evidence.diagnostic.method == .GET,
            endpointIsFileMetadata: evidence.diagnostic.endpoint == .driveFiles && evidence.diagnostic.method == .GET,
            phaseIsRecovery: evidence.diagnostic.phase == .apiRecovery,
            errorsEmpty: evidence.diagnostic.errors.isEmpty,
            sameRequestAndOrigin: evidence.diagnostic.requestID == report.primaryRequestID
                && evidence.diagnostic.origin == report.origin
                && evidence.diagnostic.uploadCorrelation == uploadCorrelation(report))
    }
    private static func uploadCorrelation(_ report: GoogleDriveTransportFaultReport) -> GoogleDriveUploadCorrelation? {
        report.events.first(where: { $0.position == .trigger })?.diagnostic.uploadCorrelation
    }
    private static func valid(_ value: GoogleDriveTransportFaultArchive, now: Date) -> Bool {
        guard [1, 2].contains(value.schemaVersion), value.reports.count <= maximumReports,
              value.evictedReportCount >= 0, value.evictedReportCount <= 1_000_000_000,
              Set(value.reports.map(\.id)).count == value.reports.count else { return false }
        return value.reports.allSatisfy { report in
            guard report.origin != .controlledFault, report.correlationAvailable == (report.primaryRequestID != nil),
                  validTime(report.triggeredAt, now: now),
                  report.windowEndsAt == report.triggeredAt.addingTimeInterval(observationWindow),
                  report.closedAt.map({ validTime($0, now: now) && $0 >= report.triggeredAt }) ?? (report.state == .collecting),
                  (report.state == .collecting) == (report.closedAt == nil),
                  (report.state == .truncated) == (report.truncation != nil),
                  report.events.count <= maximumBeforeEvents + maximumAfterEvents + 1,
                  report.events.filter({ $0.position == .trigger }).count == 1,
                  report.events.filter({ $0.position == .before }).count <= maximumBeforeEvents,
                  report.events.filter({ $0.position == .after }).count <= maximumAfterEvents,
                  (try? TransportCodec.encode(report).count).map({ $0 <= maximumReportBytes }) == true,
                  report.events.allSatisfy({ validTime($0.timestamp, now: now) && validBuild($0.build)
                      && $0.diagnostic.origin != .controlledFault
                      && GoogleDriveTransportHistory.validDiagnostic($0.diagnostic) }) else { return false }
            guard let trigger = report.events.first(where: { $0.position == .trigger }),
                  trigger.diagnostic.requestID == report.primaryRequestID, trigger.timestamp == report.triggeredAt,
                  (trigger.diagnostic.origin ?? .legacyUnknown) == report.origin,
                  !trigger.diagnostic.errors.isEmpty else { return false }
            if let evidence = report.recoveryEvidence {
                guard validTime(evidence.timestamp, now: now), evidence.timestamp >= report.triggeredAt,
                      validBuild(evidence.build), evidence.position == .after,
                      evidence.diagnostic.requestID == report.primaryRequestID,
                      evidence.diagnostic.uploadCorrelation == trigger.diagnostic.uploadCorrelation,
                      evidence.diagnostic.origin == report.origin, evidence.diagnostic.phase == .apiRecovery,
                      GoogleDriveTransportHistory.validDiagnostic(evidence.diagnostic) else { return false }
            }
            if let completion = report.completion {
                guard validCompletion(completion), completion.origin == report.origin,
                      completion.requestID == report.primaryRequestID,
                      completion.uploadCorrelation == trigger.diagnostic.uploadCorrelation,
                      report.completionObservedAt.map({ validTime($0, now: now) && $0 >= report.triggeredAt }) == true,
                      report.completionApplicationState != nil,
                      report.completionBuild.map(validBuild) == true,
                      completion.outcome != .recovered || provesRecovery(report) else { return false }
            } else if report.completionObservedAt != nil || report.completionApplicationState != nil || report.completionBuild != nil {
                return false
            }
            return true
        }
    }
}
