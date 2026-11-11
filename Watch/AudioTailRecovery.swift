import AVFoundation
import CryptoKit
import Darwin
import Foundation

/// Makes a verified, closed CAF from the complete PCM frames physically present in
/// an interrupted segment. The caller owns journal lookup and durable publication.
/// This helper never changes or removes the source and never invents missing audio.
enum AudioTailRecovery {
    enum PCMFormat: String, Sendable {
        case float32, float64, int16, int32

        fileprivate var bits: UInt32 {
            switch self {
            case .float32, .int32: return 32
            case .float64: return 64
            case .int16: return 16
            }
        }
        fileprivate var isFloat: Bool { self == .float32 || self == .float64 }
    }

    struct Metadata: Sendable {
        let id: UUID
        let sessionID: UUID
        let sequence: Int
        let startedAt: Date
        let sampleRate: Double
        let channelCount: UInt32
        let pcmFormat: PCMFormat
        /// The original input-buffer layout; CAF PCM on disk is interleaved.
        let interleaved: Bool
        let timeZoneIdentifier: String?
    }

    struct Candidate: Sendable {
        let candidateURL: URL
        let frameCount: Int64
        let startedAt: Date
        let endedAt: Date
        let sampleRate: Double
        let channelCount: UInt32
        let sourceByteCount: Int64
        let copiedPCMByteCount: Int64
        let discardedPartialFrameBytes: Int64
    }

    enum RecoveryError: Error, LocalizedError, Equatable {
        case invalidMetadata
        case invalidSource
        case unsupportedFormat
        case malformedCAF
        case ambiguousDataLength
        case noCompleteFrames
        case resourceLimit
        case candidateExists
        case sourceChanged
        case verificationFailed

        var errorDescription: String? {
            switch self {
            case .invalidMetadata: return "尾段日志与音频身份或格式不匹配，原文件已保留。"
            case .invalidSource: return "尾段不是可安全读取的普通文件，原文件已保留。"
            case .unsupportedFormat: return "尾段音频格式暂不支持恢复，原文件已保留。"
            case .malformedCAF: return "尾段音频结构损坏，原文件已保留。"
            case .ambiguousDataLength: return "无法确定尾段音频数据范围，原文件已保留。"
            case .noCompleteFrames: return "尾段中没有可验证的完整音频帧，原文件已保留。"
            case .resourceLimit: return "尾段超出安全恢复范围，原文件已保留。"
            case .candidateExists: return "尾段恢复候选已存在，未覆盖文件。"
            case .sourceChanged: return "尾段恢复期间原文件发生变化，未提交恢复结果。"
            case .verificationFailed: return "尾段恢复候选未通过音频校验，原文件已保留。"
            }
        }
    }

    private static let maximumSourceBytes: Int64 = 64 * 1_024 * 1_024
    private static let maximumNonAudioBytes: Int64 = 1 * 1_024 * 1_024
    private static let copyChunkBytes = 256 * 1_024

    static func prepareCandidate(sourceURL: URL, candidateURL: URL, metadata: Metadata) throws -> Candidate {
        guard metadata.sequence >= 0, metadata.startedAt.timeIntervalSince1970.isFinite,
              metadata.sampleRate.isFinite, metadata.sampleRate > 0, metadata.sampleRate <= 384_000,
              (1...8).contains(metadata.channelCount),
              sourceURL.pathExtension.lowercased() == "caf",
              UUID(uuidString: sourceURL.deletingPathExtension().lastPathComponent) == metadata.id,
              sourceURL.standardizedFileURL != candidateURL.standardizedFileURL,
              metadata.timeZoneIdentifier.map({ TimeZone(identifier: $0) != nil }) ?? true else {
            throw RecoveryError.invalidMetadata
        }
        let sourceFD = Darwin.open(sourceURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard sourceFD >= 0 else { throw RecoveryError.invalidSource }
        defer { Darwin.close(sourceFD) }
        let before = try fileState(sourceFD)
        guard before.st_size <= maximumSourceBytes else { throw RecoveryError.resourceLimit }
        let source = FileHandle(fileDescriptor: sourceFD, closeOnDealloc: false)
        let layout = try parse(source, size: before.st_size, metadata: metadata)
        let completeBytes = layout.pcmBytes - layout.pcmBytes % layout.bytesPerFrame
        let frames = completeBytes / layout.bytesPerFrame
        guard frames > 0 else { throw RecoveryError.noCompleteFrames }
        // Normal segments are at most 60 seconds. A generous bound also permits
        // one oversized input buffer while rejecting corrupt timestamps/lengths.
        guard Double(frames) / metadata.sampleRate <= 120 else { throw RecoveryError.resourceLimit }
        let endedAt = metadata.startedAt.addingTimeInterval(Double(frames) / metadata.sampleRate)
        guard endedAt.timeIntervalSince1970.isFinite else { throw RecoveryError.invalidMetadata }

        let candidateFD = Darwin.open(candidateURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard candidateFD >= 0 else {
            if errno == EEXIST { throw RecoveryError.candidateExists }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let output = FileHandle(fileDescriptor: candidateFD, closeOnDealloc: false)
        var succeeded = false
        defer {
            Darwin.close(candidateFD)
            if !succeeded { try? FileManager.default.removeItem(at: candidateURL) }
        }
        var header = Data("caff".utf8)
        appendBE(UInt16(1), to: &header)
        appendBE(UInt16(0), to: &header)
        header.append(Data("desc".utf8))
        appendBE(UInt64(32), to: &header)
        header.append(layout.description)
        header.append(Data("data".utf8))
        appendBE(UInt64(completeBytes + 4), to: &header)
        appendBE(UInt32(0), to: &header)
        try output.write(contentsOf: header)
        try source.seek(toOffset: UInt64(layout.pcmOffset))
        var remaining = completeBytes
        var sourceHash = SHA256()
        while remaining > 0 {
            let copied: Int = try autoreleasepool {
                let part = try readExactly(source, count: min(copyChunkBytes, Int(remaining)))
                sourceHash.update(data: part)
                try output.write(contentsOf: part)
                return part.count
            }
            remaining -= Int64(copied)
        }
        try output.synchronize()
        guard sameFile(before, try fileState(sourceFD)) else { throw RecoveryError.sourceChanged }
        try verify(candidateURL, pcmOffset: header.count, pcmBytes: completeBytes,
                   expectedHash: Data(sourceHash.finalize()), frames: frames, metadata: metadata)
        guard sameFile(before, try fileState(sourceFD)) else { throw RecoveryError.sourceChanged }
        succeeded = true
        return Candidate(candidateURL: candidateURL, frameCount: frames,
                         startedAt: metadata.startedAt, endedAt: endedAt,
                         sampleRate: metadata.sampleRate, channelCount: metadata.channelCount,
                         sourceByteCount: before.st_size, copiedPCMByteCount: completeBytes,
                         discardedPartialFrameBytes: layout.pcmBytes - completeBytes)
    }

    private struct Layout {
        let description: Data
        let bytesPerFrame: Int64
        let pcmOffset: Int64
        let pcmBytes: Int64
    }

    private static func parse(_ file: FileHandle, size: Int64, metadata: Metadata) throws -> Layout {
        guard size >= 8 else { throw RecoveryError.malformedCAF }
        let header = try readExactly(file, count: 8)
        guard Array(header.prefix(4)) == Array("caff".utf8), unsigned(header, 4, 2) == 1,
              unsigned(header, 6, 2) == 0 else { throw RecoveryError.malformedCAF }
        var offset: Int64 = 8
        var chunks = 0
        var nonAudioBytes: Int64 = 8
        var description: Data?
        var bytesPerFrame: Int64 = 0
        var audioRange: (offset: Int64, count: Int64)?
        while offset < size {
            chunks += 1
            guard chunks <= 64, nonAudioBytes <= maximumNonAudioBytes else { throw RecoveryError.resourceLimit }
            guard size - offset >= 12 else { throw RecoveryError.malformedCAF }
            try file.seek(toOffset: UInt64(offset))
            let chunk = try readExactly(file, count: 12)
            let kind = String(decoding: chunk.prefix(4), as: UTF8.self)
            let length = Int64(bitPattern: unsigned(chunk, 4, 8))
            offset += 12
            nonAudioBytes += 12
            guard length >= 0 || (length == -1 && kind == "data") else { throw RecoveryError.malformedCAF }
            if chunks == 1 && kind != "desc" { throw RecoveryError.malformedCAF }
            if kind == "desc" {
                guard description == nil, length == 32, size - offset >= 32 else { throw RecoveryError.malformedCAF }
                let data = try readExactly(file, count: 32)
                let rate = Double(bitPattern: unsigned(data, 0, 8))
                let flags = UInt32(unsigned(data, 12, 4))
                let packetBytes = unsigned(data, 16, 4)
                let framesPerPacket = unsigned(data, 20, 4)
                let channels = unsigned(data, 24, 4)
                let bits = unsigned(data, 28, 4)
                guard String(decoding: data[8..<12], as: UTF8.self) == "lpcm",
                      flags & ~UInt32(3) == 0, framesPerPacket == 1,
                      packetBytes > 0, packetBytes == channels * (bits / 8),
                      bits == 16 || bits == 32 || bits == 64 else { throw RecoveryError.unsupportedFormat }
                // CAF flags are float=1/little-endian=2, not ASBD format flags.
                guard rate == metadata.sampleRate, channels == UInt64(metadata.channelCount),
                      bits == UInt64(metadata.pcmFormat.bits), (flags & 1 != 0) == metadata.pcmFormat.isFloat else {
                    throw RecoveryError.invalidMetadata
                }
                description = data
                bytesPerFrame = Int64(packetBytes)
                nonAudioBytes += length
                offset += length
            } else if kind == "data" {
                guard description != nil, audioRange == nil else { throw RecoveryError.malformedCAF }
                // A zero/empty declared extent with extra physical data cannot
                // distinguish stale PCM from subsequent CAF chunks safely.
                if (length == 0 || length == 4) && size - offset > length {
                    throw RecoveryError.ambiguousDataLength
                }
                guard length == -1 || length >= 4, size - offset >= 4 else { throw RecoveryError.malformedCAF }
                // CAF's edit counter is not an encoding flag or PCM length.
                // AVAudioFile increments it on close, so a crash after close but
                // before manifest commit legitimately leaves a nonzero value.
                _ = try readExactly(file, count: 4)
                nonAudioBytes += 4
                guard length <= maximumSourceBytes else { throw RecoveryError.resourceLimit }
                // For -1, CAF defines this last chunk as extending to EOF. A
                // finite extent truncated by process death is bounded by EOF.
                let available = length == -1 ? size - offset : min(length, size - offset)
                audioRange = (offset + 4, available - 4)
                if length == -1 || length > size - offset { offset = size }
                else { offset += length }
            } else {
                guard length >= 0, length <= size - offset else { throw RecoveryError.malformedCAF }
                nonAudioBytes += length
                guard nonAudioBytes <= maximumNonAudioBytes else { throw RecoveryError.resourceLimit }
                offset += length
            }
        }
        guard let description, let audioRange, bytesPerFrame > 0 else { throw RecoveryError.malformedCAF }
        return Layout(description: description, bytesPerFrame: bytesPerFrame,
                      pcmOffset: audioRange.offset, pcmBytes: audioRange.count)
    }

    private static func verify(_ url: URL, pcmOffset: Int, pcmBytes: Int64, expectedHash: Data,
                               frames: Int64, metadata: Metadata) throws {
        let file = try AVAudioFile(forReading: url)
        defer { file.close() }
        guard file.length == frames, file.fileFormat.sampleRate == metadata.sampleRate,
              file.fileFormat.channelCount == metadata.channelCount,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096) else {
            throw RecoveryError.verificationFailed
        }
        var remaining = frames
        while remaining > 0 {
            let count = AVAudioFrameCount(min(4_096, remaining))
            try autoreleasepool { try file.read(into: buffer, frameCount: count) }
            guard buffer.frameLength == count else { throw RecoveryError.verificationFailed }
            remaining -= Int64(count)
        }
        let bytes = try FileHandle(forReadingFrom: url)
        defer { try? bytes.close() }
        guard try bytes.seekToEnd() == UInt64(pcmOffset) + UInt64(pcmBytes) else {
            throw RecoveryError.verificationFailed
        }
        try bytes.seek(toOffset: UInt64(pcmOffset))
        var hash = SHA256()
        var bytesRemaining = pcmBytes
        while bytesRemaining > 0 {
            let count = min(copyChunkBytes, Int(bytesRemaining))
            try autoreleasepool { hash.update(data: try readExactly(bytes, count: count)) }
            bytesRemaining -= Int64(count)
        }
        guard Data(hash.finalize()) == expectedHash else { throw RecoveryError.verificationFailed }
    }

    private static func fileState(_ fd: Int32) throws -> stat {
        var result = stat()
        guard fstat(fd, &result) == 0, (result.st_mode & S_IFMT) == S_IFREG, result.st_size >= 0 else {
            throw RecoveryError.invalidSource
        }
        return result
    }

    private static func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }

    private static func readExactly(_ file: FileHandle, count: Int) throws -> Data {
        let result = try file.read(upToCount: count) ?? Data()
        guard result.count == count else { throw RecoveryError.malformedCAF }
        return result
    }

    private static func unsigned(_ data: Data, _ offset: Int, _ count: Int) -> UInt64 {
        data[offset..<(offset + count)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    private static func appendBE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }
}
