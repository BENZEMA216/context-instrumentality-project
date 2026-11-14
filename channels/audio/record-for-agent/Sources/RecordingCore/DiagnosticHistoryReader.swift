import Foundation
import Darwin

/// Explicit historical export reads only event metadata. Its bound and partial
/// coverage are part of the result; it never visits manifests/receipts/audio.
public enum DiagnosticHistoryReader {
    public static let maximumEvents = 2_000
    public static let maximumBytes = 4_194_304
    public static let maximumDirectoryEntries = 100_000
    public static let maximumFileBytes = 262_144
    public enum Failure: Error { case unavailable, invalidEvent, changedDuringRead }

    public static func read(root: URL, at now: Date = Date(),
                            while shouldContinue: () -> Bool = { true }) throws -> RedactedDiagnosticEventBatch {
        guard shouldContinue() else { throw CancellationError() }
        let parent = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw Failure.unavailable }
        defer { Darwin.close(parent) }
        let fd = Darwin.openat(parent, "events", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw Failure.unavailable }
        defer { Darwin.close(fd) }
        var before = stat()
        guard Darwin.fstat(fd, &before) == 0 else { throw Failure.unavailable }
        let duplicate = Darwin.dup(fd)
        guard duplicate >= 0 else { throw Failure.unavailable }
        guard let directory = Darwin.fdopendir(duplicate) else { Darwin.close(duplicate); throw Failure.unavailable }
        defer { Darwin.closedir(directory) }
        var heap = RecordingDiagnosticEventCandidateHeap(limit: maximumEvents)
        var total = 0, inspected = 0, limited = false
        while true {
            guard shouldContinue() else { throw CancellationError() }
            errno = 0
            guard let entry = Darwin.readdir(directory) else {
                guard errno == 0 else { throw Failure.unavailable }; break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard inspected < maximumDirectoryEntries else { limited = true; break }
            inspected += 1
            guard name.hasSuffix(".json") else { continue }
            guard let id = UUID(uuidString: String(name.dropLast(5))), name == id.uuidString.lowercased() + ".json" else {
                throw Failure.invalidEvent
            }
            var info = stat()
            guard Darwin.fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1 else { throw Failure.invalidEvent }
            total += 1
            heap.insert(.init(name: name, modifiedSeconds: Int64(info.st_mtimespec.tv_sec),
                modifiedNanoseconds: Int64(info.st_mtimespec.tv_nsec), byteCount: Int64(info.st_size), inode: UInt64(info.st_ino)))
        }
        // Decode a narrow projection, not RecordingEvent.detail/sessionID/id.
        struct Fields: Decodable { let timestamp: Date; let kind: String }
        var events: [RedactedDiagnosticEvent] = [], bytes = 0, byteLimited = false
        for candidate in heap.values.sorted(by: { $0.newer(than: $1) }) {
            guard shouldContinue() else { throw CancellationError() }
            guard candidate.byteCount > 0, candidate.byteCount <= maximumFileBytes else { throw Failure.invalidEvent }
            guard candidate.byteCount <= maximumBytes - bytes else { byteLimited = true; break }
            let file = Darwin.openat(fd, candidate.name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard file >= 0 else { throw Failure.invalidEvent }
            let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true)
            defer { try? handle.close() }
            var initial = stat()
            guard Darwin.fstat(file, &initial) == 0, initial.st_mode & S_IFMT == S_IFREG,
                  initial.st_nlink == 1, initial.st_ino == candidate.inode,
                  initial.st_size == candidate.byteCount,
                  initial.st_mtimespec.tv_sec == candidate.modifiedSeconds,
                  initial.st_mtimespec.tv_nsec == candidate.modifiedNanoseconds else { throw Failure.changedDuringRead }
            let data = try handle.read(upToCount: Int(initial.st_size)) ?? Data()
            var final = stat()
            guard Darwin.fstat(file, &final) == 0, data.count == Int(initial.st_size),
                  initial.st_ino == final.st_ino, initial.st_size == final.st_size,
                  sameTime(initial.st_mtimespec, final.st_mtimespec), sameTime(initial.st_ctimespec, final.st_ctimespec) else {
                throw Failure.changedDuringRead
            }
            let value = try TransportCodec.decode(Fields.self, from: data)
            guard value.timestamp.timeIntervalSince1970.isFinite else { throw Failure.invalidEvent }
            events.append(.init(timestamp: value.timestamp, category: .classify(value.kind), kind: .classify(value.kind)))
            bytes += data.count
        }
        guard shouldContinue() else { throw CancellationError() }
        var after = stat()
        guard Darwin.fstat(fd, &after) == 0 else { throw Failure.unavailable }
        let stable = before.st_ino == after.st_ino && sameTime(before.st_mtimespec, after.st_mtimespec) && sameTime(before.st_ctimespec, after.st_ctimespec)
        let truncated = limited || total > events.count || !stable
        return .init(availability: .observed, unavailableReason: nil,
            scope: .fullHistory, events: events.sorted { $0.timestamp < $1.timestamp },
            requestedStartAt: nil, requestedEndAt: now, bytesRead: bytes, decodedFileCount: events.count,
            totalEventFileCount: limited || !stable ? nil : total, truncated: truncated,
            completeHistoryObserved: !truncated, directoryStable: stable, enumerationLimitReached: limited,
            candidateLimitReached: total > maximumEvents, byteLimitReached: byteLimited,
            maximumEventCount: maximumEvents, maximumSourceBytes: maximumBytes)
    }

    private static func sameTime(_ lhs: timespec, _ rhs: timespec) -> Bool {
        lhs.tv_sec == rhs.tv_sec && lhs.tv_nsec == rhs.tv_nsec
    }
}
