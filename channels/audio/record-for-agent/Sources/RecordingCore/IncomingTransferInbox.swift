import Foundation
import Darwin

public enum IncomingTransferInboxFaultPoint: Sendable {
    case afterAudioCopyBeforeSync
    case afterAudioSyncBeforeManifest
    case afterManifestWriteBeforeSync
    case afterCompletionRenameBeforeSync
}

/// Retains framework-owned incoming files before the transfer callback returns.
/// Staging performs no audio decoding or hashing and never issues a receipt.
/// Import one entry at a time into RecordingRepository to establish its integrity.
public final class IncomingTransferInbox: @unchecked Sendable {
    public struct Entry: Sendable {
        public let id: UUID
        public let manifest: SegmentManifest
        public let audioURL: URL
    }

    public let root: URL
    private let lock = NSRecursiveLock()
    private let fm = FileManager.default
    private let faultInjector: ((IncomingTransferInboxFaultPoint) throws -> Void)?

    public init(root: URL,
                faultInjector: ((IncomingTransferInboxFaultPoint) throws -> Void)? = nil) throws {
        self.root = root.standardizedFileURL
        self.faultInjector = faultInjector
        try fm.createDirectory(at: self.root, withIntermediateDirectories: true)
        try applyFileProtection(self.root)
        try synchronizeDirectory(self.root)
        try synchronizeDirectory(self.root.deletingLastPathComponent())
    }

    /// Returns only after the private audio copy and manifest have been synced.
    /// A new transfer UUID prevents duplicate deliveries from overwriting each
    /// other. Failures preserve any partial copy; incomplete jobs are not pending.
    @discardableResult
    public func stage(fileURL: URL, manifest: SegmentManifest) throws -> UUID {
        try synchronized {
            try RecordingRepository.validateManifest(manifest)
            try requireRegularFile(fileURL)
            let id = UUID()
            let directory = jobDirectory(id)
            try fm.createDirectory(at: directory, withIntermediateDirectories: false)
            try applyFileProtection(directory)
            try synchronizeDirectory(root)
            let audio = directory.appendingPathComponent("audio.caf")
            try fm.copyItem(at: fileURL, to: audio)
            try applyFileProtection(audio)
            try faultInjector?(.afterAudioCopyBeforeSync)
            try synchronizeFile(audio)
            try synchronizeDirectory(directory)
            try faultInjector?(.afterAudioSyncBeforeManifest)

            // The manifest is the pending-work marker and is written last.
            let metadata = directory.appendingPathComponent("manifest.json")
            try TransportCodec.encode(manifest).write(to: metadata, options: .atomic)
            try applyFileProtection(metadata)
            try faultInjector?(.afterManifestWriteBeforeSync)
            try synchronizeFile(metadata)
            try synchronizeDirectory(directory)
            return id
        }
    }

    /// Stable transfer-UUID order without loading metadata or touching audio.
    /// Corrupt committed jobs remain listed so callers can report their own error
    /// and continue; a directory read failure is never treated as an empty inbox.
    public func pendingIDs() throws -> [UUID] {
        try synchronized {
            try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .compactMap { directory in
                    guard let id = UUID(uuidString: directory.lastPathComponent),
                          directory.lastPathComponent == id.uuidString.lowercased(),
                          fm.fileExists(atPath: directory.appendingPathComponent("manifest.json").path)
                    else { return nil }
                    return id
                }
        }
    }

    /// The returned file is owned by this inbox, not by WatchConnectivity.
    /// Callers must verify it through RecordingRepository before issuing an ACK.
    public func load(id: UUID) throws -> Entry {
        try synchronized {
            let directory = jobDirectory(id)
            let manifest = try loadManifest(in: directory)
            let audio = directory.appendingPathComponent("audio.caf")
            try requireRegularFile(audio)
            return Entry(id: id, manifest: manifest, audioURL: audio)
        }
    }

    /// Call only with the receipt returned by a successful durable repository
    /// import (or freshly verified replay). Validate its identity before cleanup.
    /// Rename first so an interrupted recursive delete cannot corrupt pending
    /// work. A repeated call can finish cleanup of that completed directory.
    public func complete(id: UUID, receipt: SegmentReceipt) throws {
        try synchronized {
            let pending = jobDirectory(id)
            let completed = completedDirectory(id)
            if fm.fileExists(atPath: pending.path) {
                let manifest = try loadManifest(in: pending)
                guard receipt.segmentID == manifest.id, receipt.sha256 == manifest.sha256,
                      receipt.byteCount == manifest.byteCount else {
                    throw RepositoryError.receiptMismatch
                }
                // Never overwrite an unexpected retained completion directory.
                guard !fm.fileExists(atPath: completed.path) else {
                    throw RepositoryError.persistenceFailure("待入库文件的完成标识已存在")
                }
                try fm.moveItem(at: pending, to: completed)
                try faultInjector?(.afterCompletionRenameBeforeSync)
            }
            if fm.fileExists(atPath: completed.path) {
                try requireDirectory(completed)
                // The rename itself proves cleanup was previously authorized.
                // Sync it before deleting any bytes, including on a retry.
                try synchronizeDirectory(root)
                try fm.removeItem(at: completed)
                try synchronizeDirectory(root)
            }
        }
    }

    private func jobDirectory(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    private func completedDirectory(_ id: UUID) -> URL {
        root.appendingPathComponent("completed-" + id.uuidString.lowercased(), isDirectory: true)
    }

    private func loadManifest(in directory: URL) throws -> SegmentManifest {
        try requireDirectory(directory)
        let metadata = directory.appendingPathComponent("manifest.json")
        try requireRegularFile(metadata)
        let manifest = try TransportCodec.decode(SegmentManifest.self, from: Data(contentsOf: metadata))
        try RecordingRepository.validateManifest(manifest)
        return manifest
    }

    private func requireDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw RepositoryError.persistenceFailure("待入库目录无效")
        }
    }

    private func requireRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw RepositoryError.persistenceFailure("待入库文件无效")
        }
    }

    private func applyFileProtection(_ url: URL) throws {
        #if os(iOS) || os(watchOS)
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                             ofItemAtPath: url.path)
        #endif
    }

    private func synchronizeFile(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private func synchronizeDirectory(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw RepositoryError.persistenceFailure(String(cString: strerror(errno)))
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw RepositoryError.persistenceFailure(String(cString: strerror(errno)))
        }
    }

    private func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
