import Darwin
import Foundation
import RecordingCore

/// Only the private Drive metadata boundary creates this error. Network and
/// recording-content errors must never opt into metadata recovery by errno.
struct GoogleDriveMetadataIOError: Error {
    let code: Int32
    var isTemporary: Bool {
        [EINTR, EAGAIN, EIO, EBUSY, EMFILE, ENFILE, ENOSPC, EDQUOT, EACCES, EPERM].contains(code)
    }
}

enum GoogleDriveMetadataIO {
    static func syscallFailure() -> GoogleDriveMetadataIOError { .init(code: errno) }

    static func perform<T>(_ operation: () throws -> T) throws -> T {
        do { return try operation() }
        catch let error as GoogleDriveMetadataIOError { throw error }
        catch {
            // Foundation may wrap a POSIX filesystem error. Do not classify an
            // arbitrary error or a URL loading failure as a retryable local IO.
            var current = error as NSError
            for _ in 0..<4 {
                if current.domain == NSPOSIXErrorDomain { throw GoogleDriveMetadataIOError(code: Int32(current.code)) }
                guard current.domain == NSCocoaErrorDomain else { throw error }
                if let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError { current = underlying; continue }
                switch current.code {
                case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                    throw GoogleDriveMetadataIOError(code: EACCES)
                case NSFileWriteOutOfSpaceError: throw GoogleDriveMetadataIOError(code: ENOSPC)
                default: throw error
                }
            }
            throw error
        }
    }

    static func validateDirectory(_ directory: URL) throws {
        var info = stat()
        guard Darwin.lstat(directory.path, &info) == 0 else { throw syscallFailure() }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == geteuid() else {
            throw GoogleDriveLibraryError.invalidState
        }
    }

    /// Reads only an explicitly named metadata leaf. The immediate managed
    /// directory and leaf cannot be links, and a file changing during the read
    /// is not accepted as an authority. No missing file is replaced by defaults.
    static func read(_ file: URL, maximum: Int) throws -> Data {
        let parent = Darwin.open(file.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard parent >= 0 else { throw syscallFailure() }
        defer { Darwin.close(parent) }
        var directoryInfo = stat()
        guard Darwin.fstat(parent, &directoryInfo) == 0 else { throw syscallFailure() }
        guard directoryInfo.st_mode & S_IFMT == S_IFDIR, directoryInfo.st_uid == geteuid() else {
            throw GoogleDriveLibraryError.invalidState
        }
        let fd = Darwin.openat(parent, file.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw syscallFailure() }
        defer { Darwin.close(fd) }
        var before = stat()
        guard Darwin.fstat(fd, &before) == 0 else { throw syscallFailure() }
        guard before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1, before.st_uid == geteuid(),
              before.st_size > 0, before.st_size <= maximum else { throw GoogleDriveLibraryError.invalidState }
        let bytes = try perform { try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: maximum + 1) }
        var after = stat()
        guard Darwin.fstat(fd, &after) == 0 else { throw syscallFailure() }
        guard let bytes, bytes.count == before.st_size, bytes.count <= maximum,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
              after.st_nlink == 1 else { throw GoogleDriveLibraryError.invalidState }
        return bytes
    }
}

/// A bounded, metadata-only revalidation at a *real* execution opportunity.
/// This is the production orchestration used by the Library and offline probe.
/// It never schedules itself, repairs a file, changes a grant or sends HTTP.
@MainActor
final class GoogleDriveMetadataRecovery {
    private var trustedLedger: GoogleDriveLibraryLedger?
    private var permanentlyBlocked = false
    private var revision: UInt64 = 0
    private var attempts = 0
    private var nextAttemptAt: TimeInterval = 0
    private var running = false
    private let now: () -> TimeInterval
    static let maximumAttempts = 3
    static let cooldown: TimeInterval = 30

    init(now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) { self.now = now }
    var canRetry: Bool { trustedLedger != nil && !permanentlyBlocked && attempts < Self.maximumAttempts }
    var isRecovering: Bool { running }
    var canStartAtOpportunity: Bool { canRetry && !running && now() >= nextAttemptAt }

    @discardableResult
    func block(_ error: Error, ledger: GoogleDriveLibraryLedger, hasTrustedQueue: Bool) -> Bool {
        revision &+= 1
        guard !permanentlyBlocked, hasTrustedQueue, let io = error as? GoogleDriveMetadataIOError, io.isTemporary,
              ledger.enabled, !ledger.revokedLocally, ledger.accountID != nil, ledger.recordingScope != nil,
              ledger.authorizedAt != nil, ledger.folderID != nil, (try? ledger.validate()) != nil else {
            permanentlyBlocked = true; trustedLedger = nil; return false
        }
        if let trustedLedger, trustedLedger != ledger {
            permanentlyBlocked = true; self.trustedLedger = nil; return false
        }
        if trustedLedger == nil { trustedLedger = ledger; attempts = 0; nextAttemptAt = now() }
        // Exhausting recovery attempts still must not cancel a native upload
        // merely because a *temporary* metadata failure remains unresolved.
        return true
    }

    /// Pause, revocation and expiry invalidate an awaited attempt. They do not
    /// grant another retry, extend its deadline or clear the storage failure.
    func cancel() { revision &+= 1 }

    func recover(currentLedger: @escaping @MainActor () -> GoogleDriveLibraryLedger,
                 readLedger: @MainActor () throws -> GoogleDriveLibraryLedger,
                 validateMetadata: @MainActor (GoogleDriveLibraryLedger) throws -> Void,
                 restoreNative: @MainActor (GoogleDriveLibraryLedger, @MainActor () throws -> Void) async throws -> Void,
                 check: @escaping @MainActor () throws -> Void,
                 onFailure: @MainActor (Error) -> Void = { _ in }) async -> Bool {
        guard canStartAtOpportunity, let trusted = trustedLedger else { return false }
        let token = revision
        running = true; attempts += 1; nextAttemptAt = now() + Self.cooldown
        defer { running = false }
        @MainActor func fence() throws {
            try Task.checkCancellation(); try check()
            guard revision == token else { throw CancellationError() }
            guard currentLedger() == trusted else { throw GoogleDriveLibraryError.notAuthorized }
        }
        do {
            try fence()
            let restored = try readLedger(); try restored.validate()
            guard restored == trusted else { throw GoogleDriveLibraryError.invalidState }
            try validateMetadata(restored); try fence()
            try await restoreNative(restored, fence)
            try fence()
            // An uncertain disk commit or grant change is never repaired from
            // memory. The original authority must still be exactly the same.
            guard try readLedger() == trusted else { throw GoogleDriveLibraryError.invalidState }
            try validateMetadata(trusted); try fence()
            trustedLedger = nil; attempts = 0; nextAttemptAt = 0
            return true
        } catch is CancellationError { onFailure(CancellationError()); return false }
        catch {
            onFailure(error)
            if (error as? GoogleDriveMetadataIOError)?.isTemporary != true {
                permanentlyBlocked = true; trustedLedger = nil
            }
            return false
        }
    }
}
