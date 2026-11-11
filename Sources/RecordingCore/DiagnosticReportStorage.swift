import Foundation
import Darwin

/// Only this dedicated export directory is managed. Existing files are never
/// reused as a successful result after a failed generation.
public enum DiagnosticReportStorage {
    public static let maximumReportBytes = 2_097_152
    public static let maximumLifecycleBytes = 4_096
    public static let maximumReportCount = 10
    public static let maximumTotalBytes = 20_971_520
    public static let retentionSeconds: TimeInterval = 7 * 86_400
    private static let directoryName = "RedactedDiagnosticExports"
    private static let lock = NSLock()
    public enum Failure: Error { case directoryUnavailable, invalidFile, tooLarge, retentionLimit, writeFailed }

    @discardableResult
    public static func writeReport(_ data: Data, issueID: UUID, root: URL, at date: Date = Date()) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        guard !data.isEmpty, data.count <= maximumReportBytes else { throw Failure.tooLarge }
        let fd = try directory(root)
        defer { Darwin.close(fd) }
        let name = "report-\(issueID.uuidString.lowercased()).json"
        // A report is immutable. A repeated issue ID cannot replace a file that
        // may already have been handed to an activity controller. Reject it
        // before retention can remove either this report or unrelated exports.
        var info = stat()
        guard Darwin.fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else { throw Failure.invalidFile }
        try prune(fd, at: date, addingBytes: data.count, addingReport: true, preserving: nil)
        try atomicWrite(data, name: name, in: fd)
        return root.appendingPathComponent(directoryName, isDirectory: true).appendingPathComponent(name)
    }

    public static func writeLifecycle(_ value: DiagnosticShareLifecycle, root: URL, at date: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        let data = try TransportCodec.encode(value)
        guard data.count <= maximumLifecycleBytes else { throw Failure.tooLarge }
        let fd = try directory(root)
        defer { Darwin.close(fd) }
        let id = value.issueID.uuidString.lowercased()
        let report = "report-\(id).json", name = "lifecycle-\(id).json"
        var reportInfo = stat()
        guard Darwin.fstatat(fd, report, &reportInfo, AT_SYMLINK_NOFOLLOW) == 0,
              reportInfo.st_mode & S_IFMT == S_IFREG, reportInfo.st_nlink == 1 else { throw Failure.invalidFile }
        // Reject aliases before rename as well; a lifecycle path must always be
        // owned by this exporter, never a caller-supplied URL.
        var existing = stat()
        var replacedBytes = 0
        if Darwin.fstatat(fd, name, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
            guard existing.st_mode & S_IFMT == S_IFREG, existing.st_nlink == 1 else { throw Failure.invalidFile }
            replacedBytes = Int(existing.st_size)
        } else if errno != ENOENT { throw Failure.invalidFile }
        try prune(fd, at: date, addingBytes: max(0, data.count - replacedBytes), addingReport: false, preserving: id)
        try atomicWrite(data, name: name, in: fd)
    }

    private static func directory(_ root: URL) throws -> Int32 {
        let parent = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw Failure.directoryUnavailable }
        defer { Darwin.close(parent) }
        if Darwin.mkdirat(parent, directoryName, 0o700) != 0, errno != EEXIST { throw Failure.directoryUnavailable }
        let fd = Darwin.openat(parent, directoryName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw Failure.directoryUnavailable }
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0, info.st_uid == getuid(), Darwin.fchmod(fd, 0o700) == 0 else {
            Darwin.close(fd); throw Failure.directoryUnavailable
        }
        return fd
    }

    private struct Entry { let name: String; let id: String; let report: Bool; let bytes: Int; let modified: Date }
    private static func entries(_ fd: Int32) throws -> [Entry] {
        let duplicate = Darwin.dup(fd)
        guard duplicate >= 0 else { throw Failure.directoryUnavailable }
        guard let directory = Darwin.fdopendir(duplicate) else { Darwin.close(duplicate); throw Failure.directoryUnavailable }
        defer { Darwin.closedir(directory) }
        var result: [Entry] = [], count = 0
        while true {
            errno = 0
            guard let entry = Darwin.readdir(directory) else {
                guard errno == 0 else { throw Failure.directoryUnavailable }; break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            count += 1
            guard count <= 256 else { throw Failure.retentionLimit }
            if name.hasPrefix(".pending-"),
               let id = UUID(uuidString: String(name.dropFirst(9))), name == ".pending-" + id.uuidString.lowercased() {
                var pending = stat()
                guard Darwin.fstatat(fd, name, &pending, AT_SYMLINK_NOFOLLOW) == 0,
                      pending.st_mode & S_IFMT == S_IFREG, pending.st_nlink == 1,
                      pending.st_uid == getuid(), Darwin.unlinkat(fd, name, 0) == 0 else { throw Failure.invalidFile }
                continue
            }
            let report = name.hasPrefix("report-"), prefix = report ? "report-" : "lifecycle-"
            // Do not traverse/delete unfamiliar entries, and do not silently
            // omit their size from the directory's retention accounting.
            guard name.hasPrefix(prefix), name.hasSuffix(".json"),
                  let id = UUID(uuidString: String(name.dropFirst(prefix.count).dropLast(5))),
                  name == prefix + id.uuidString.lowercased() + ".json" else { throw Failure.invalidFile }
            var info = stat()
            guard Darwin.fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_uid == getuid(),
                  info.st_size >= 0, info.st_size <= (report ? maximumReportBytes : maximumLifecycleBytes) else {
                throw Failure.invalidFile
            }
            result.append(.init(name: name, id: id.uuidString.lowercased(), report: report,
                bytes: Int(info.st_size), modified: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec))))
        }
        return result
    }

    private static func prune(_ fd: Int32, at now: Date, addingBytes: Int, addingReport: Bool,
                              preserving: String?) throws {
        var values = try entries(fd)
        func remove(_ id: String) throws {
            for entry in values where entry.id == id {
                guard Darwin.unlinkat(fd, entry.name, 0) == 0 else { throw Failure.writeFailed }
            }
            values.removeAll { $0.id == id }
        }
        let expired = Set(values.filter { now.timeIntervalSince($0.modified) > retentionSeconds && $0.id != preserving }.map(\.id))
        for id in expired { try remove(id) }
        // Orphaned receipts cannot count as retained reports indefinitely.
        let reports = Set(values.filter(\.report).map(\.id))
        let orphans = Set(values.filter { !$0.report && !reports.contains($0.id) && $0.id != preserving }.map(\.id))
        for id in orphans { try remove(id) }
        while values.filter(\.report).count + (addingReport ? 1 : 0) > maximumReportCount ||
              values.reduce(0, { $0 + $1.bytes }) + addingBytes > maximumTotalBytes {
            guard let oldest = values.filter({ $0.report && $0.id != preserving }).min(by: { $0.modified < $1.modified }) else {
                throw Failure.retentionLimit
            }
            try remove(oldest.id)
        }
    }

    private static func atomicWrite(_ data: Data, name: String, in fd: Int32) throws {
        let temporary = ".pending-\(UUID().uuidString.lowercased())"
        let file = Darwin.openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard file >= 0 else { throw Failure.writeFailed }
        var installed = false, succeeded = false
        defer {
            Darwin.close(file)
            if !succeeded {
                Darwin.unlinkat(fd, temporary, 0)
                if installed { Darwin.unlinkat(fd, name, 0) }
            }
        }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { throw Failure.writeFailed }
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(file, base.advanced(by: offset), data.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw Failure.writeFailed }
                offset += count
            }
        }
        guard Darwin.fchmod(file, 0o600) == 0, Darwin.fsync(file) == 0,
              Darwin.renameat(fd, temporary, fd, name) == 0 else { throw Failure.writeFailed }
        installed = true
        guard Darwin.fsync(fd) == 0 else { throw Failure.writeFailed }
        succeeded = true
    }
}
