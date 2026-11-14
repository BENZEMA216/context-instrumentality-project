import Foundation

public enum TranscriptRepositoryError: LocalizedError {
    case invalidFile, oversizedFile, sourceChanged

    public var errorDescription: String? {
        switch self {
        case .invalidFile: return "转写存储不可用，原录音仍保留。"
        case .oversizedFile: return "转写内容超过当前支持的大小。"
        case .sourceChanged: return "转写对应的原录音已变化，未覆盖已有文字。"
        }
    }
}

/// Derived transcripts are stored separately from audio and Watch receipts.
/// Reading or saving one never changes capture, transfer, or ACK state.
public final class TranscriptRepository: @unchecked Sendable {
    public struct AvailableTranscripts: Sendable {
        public let transcripts: [UUID: SegmentTranscript]
        public let issues: [UUID: String]
    }

    public static let maximumFileBytes = 4 * 1_024 * 1_024
    private let directory: URL
    private let lock = NSLock()

    public init(root: URL) throws {
        directory = root.appendingPathComponent("transcripts", isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.path) {
            let attributes = try fm.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw TranscriptRepositoryError.invalidFile
            }
        } else {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    public func transcript(for manifest: SegmentManifest) throws -> SegmentTranscript? {
        lock.lock(); defer { lock.unlock() }
        guard let value = try read(id: manifest.id) else { return nil }
        try value.validate(against: manifest)
        return value
    }

    public func transcripts(for manifests: [SegmentManifest]) throws -> [UUID: SegmentTranscript] {
        lock.lock(); defer { lock.unlock() }
        var values: [UUID: SegmentTranscript] = [:]
        for manifest in manifests {
            if let value = try read(id: manifest.id) {
                try value.validate(against: manifest)
                values[manifest.id] = value
            }
        }
        return values
    }

    /// Library browsing isolates damaged derived text to its recording. Strict
    /// selection export continues to use transcripts(for:) and fails closed.
    public func availableTranscripts(for manifests: [SegmentManifest]) -> AvailableTranscripts {
        lock.lock(); defer { lock.unlock() }
        var values: [UUID: SegmentTranscript] = [:]
        var issues: [UUID: String] = [:]
        for manifest in manifests {
            do {
                if let value = try read(id: manifest.id) {
                    try value.validate(against: manifest)
                    values[manifest.id] = value
                }
            } catch {
                issues[manifest.id] = "转写文件未通过核对，原录音仍保留。"
            }
        }
        return AvailableTranscripts(transcripts: values, issues: issues)
    }

    public func save(_ value: SegmentTranscript, for manifest: SegmentManifest) throws {
        lock.lock(); defer { lock.unlock() }
        try value.validate(against: manifest)
        if let existing = try read(id: manifest.id) {
            guard existing.segmentID == value.segmentID, existing.audioSHA256 == value.audioSHA256 else {
                throw TranscriptRepositoryError.sourceChanged
            }
            if existing == value { return }
        }
        try write(value, for: manifest)
    }

    /// Receiver ASR is supplementary. Check and commit under the same lock so a
    /// concurrent local result is never replaced by a returned, older version.
    /// Damaged or source-mismatched existing files also remain untouched.
    @discardableResult
    public func saveIfAbsent(_ value: SegmentTranscript, for manifest: SegmentManifest) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        try value.validate(against: manifest)
        if let existing = try read(id: manifest.id) {
            try existing.validate(against: manifest)
            return false
        }
        try write(value, for: manifest)
        return true
    }

    private func write(_ value: SegmentTranscript, for manifest: SegmentManifest) throws {
        let data = try TransportCodec.encode(value)
        guard data.count <= Self.maximumFileBytes else { throw TranscriptRepositoryError.oversizedFile }
        let target = url(id: manifest.id)
        try data.write(to: target, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                              ofItemAtPath: target.path)
        #endif
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private func url(id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString.lowercased() + ".json")
    }

    private func read(id: UUID) throws -> SegmentTranscript? {
        let target = url(id: id)
        let fm = FileManager.default
        let attributes: [FileAttributeKey: Any]
        do { attributes = try fm.attributesOfItem(atPath: target.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code) {
            return nil
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.referenceCount] as? NSNumber)?.intValue ?? 1) == 1 else {
            throw TranscriptRepositoryError.invalidFile
        }
        guard let size = attributes[.size] as? NSNumber, size.intValue <= Self.maximumFileBytes else {
            throw TranscriptRepositoryError.oversizedFile
        }
        let data = try Data(contentsOf: target)
        guard data.count <= Self.maximumFileBytes else { throw TranscriptRepositoryError.oversizedFile }
        return try TransportCodec.decode(SegmentTranscript.self, from: data)
    }
}
