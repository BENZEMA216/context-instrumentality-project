import AVFoundation
import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import WatchAudio

/// Only synthetic PCM in an isolated directory. No microphone, devices, user
/// recordings, journal publication or repository mutation is used here.
final class AudioTailRecoveryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func metadata(format: AudioTailRecovery.PCMFormat = .float32, channels: UInt32 = 1,
                          interleaved: Bool = false, rate: Double = 48_000) -> AudioTailRecovery.Metadata {
        AudioTailRecovery.Metadata(id: UUID(), sessionID: UUID(), sequence: 7,
                                   startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                                   sampleRate: rate, channelCount: channels, pcmFormat: format,
                                   interleaved: interleaved, timeZoneIdentifier: "Asia/Shanghai")
    }

    private func source(_ metadata: AudioTailRecovery.Metadata) -> URL {
        root.appendingPathComponent(metadata.id.uuidString).appendingPathExtension("caf")
    }

    private func candidate() -> URL {
        root.appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
    }

    private func appendBE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var value = value.bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private func appendLE<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var value = value.littleEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    private func pcm(_ metadata: AudioTailRecovery.Metadata, frames: Int) -> Data {
        var data = Data()
        for sample in 0..<(frames * Int(metadata.channelCount)) {
            // Nonconstant samples catch offset, interleaving and copy mistakes.
            let sign: Float = sample.isMultiple(of: 2) ? 1 : -1
            switch metadata.pcmFormat {
            case .float32: appendLE((sign * 0.25).bitPattern, to: &data)
            case .float64: appendLE(Double(sign * 0.25).bitPattern, to: &data)
            case .int16: appendLE(Int16(sign * 1_024), to: &data)
            case .int32: appendLE(Int32(sign * 1_048_576), to: &data)
            }
        }
        return data
    }

    private func chunk(_ name: String, data: Data, length: Int64? = nil) -> Data {
        var bytes = Data(name.utf8)
        appendBE(UInt64(bitPattern: length ?? Int64(data.count)), to: &bytes)
        bytes.append(data)
        return bytes
    }

    private func caf(_ metadata: AudioTailRecovery.Metadata, payload: Data,
                     declaredLength: Int64 = -1, suffix: Data = Data(), flags: UInt32? = nil) -> Data {
        let bits: UInt32
        switch metadata.pcmFormat {
        case .float32, .int32: bits = 32
        case .float64: bits = 64
        case .int16: bits = 16
        }
        var desc = Data()
        appendBE(metadata.sampleRate.bitPattern, to: &desc)
        desc.append(Data("lpcm".utf8))
        let floating = metadata.pcmFormat == .float32 || metadata.pcmFormat == .float64
        appendBE(flags ?? (floating ? UInt32(3) : UInt32(2)), to: &desc)
        appendBE(bits / 8 * metadata.channelCount, to: &desc)
        appendBE(UInt32(1), to: &desc)
        appendBE(metadata.channelCount, to: &desc)
        appendBE(bits, to: &desc)
        var bytes = Data("caff".utf8)
        appendBE(UInt16(1), to: &bytes)
        appendBE(UInt16(0), to: &bytes)
        bytes.append(chunk("desc", data: desc))
        var audio = Data(repeating: 0, count: 4)
        audio.append(payload)
        bytes.append(chunk("data", data: audio, length: declaredLength))
        bytes.append(suffix)
        return bytes
    }

    private func reject(_ bytes: Data, metadata: AudioTailRecovery.Metadata,
                        error: AudioTailRecovery.RecoveryError? = nil,
                        file: StaticString = #filePath, line: UInt = #line) throws {
        let src = source(metadata), destination = candidate()
        try bytes.write(to: src)
        XCTAssertThrowsError(try AudioTailRecovery.prepareCandidate(sourceURL: src, candidateURL: destination,
                                                                   metadata: metadata), file: file, line: line) {
            if let error { XCTAssertEqual($0 as? AudioTailRecovery.RecoveryError, error, file: file, line: line) }
        }
        XCTAssertEqual(try Data(contentsOf: src), bytes, file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), file: file, line: line)
    }

    func testSupportedPCMFormatsRecoverOnlyActualFramesAndPreservePCMBytes() throws {
        for format: AudioTailRecovery.PCMFormat in [.float32, .float64, .int16, .int32] {
            for channels: UInt32 in [1, 2] {
                let meta = metadata(format: format, channels: channels)
                let payload = pcm(meta, frames: 137)
                let original = caf(meta, payload: payload)
                try original.write(to: source(meta))
                let result = try AudioTailRecovery.prepareCandidate(sourceURL: source(meta), candidateURL: candidate(), metadata: meta)
                XCTAssertEqual(result.frameCount, 137)
                XCTAssertEqual(result.startedAt, meta.startedAt)
                XCTAssertEqual(result.endedAt.timeIntervalSince(result.startedAt), 137 / 48_000.0, accuracy: 0.000_001)
                XCTAssertEqual(result.sourceByteCount, Int64(original.count))
                XCTAssertEqual(result.copiedPCMByteCount, Int64(payload.count))
                XCTAssertEqual(result.discardedPartialFrameBytes, 0)
                XCTAssertEqual(try Data(contentsOf: result.candidateURL).dropFirst(68), payload)
                XCTAssertEqual(try Data(contentsOf: source(meta)), original)
                XCTAssertEqual(try AVAudioFile(forReading: result.candidateURL).length, 137)
            }
        }
    }

    func testDropsOnlyPartialFrameWithoutPaddingOrChangingTimestamp() throws {
        let meta = metadata(channels: 2)
        let payload = pcm(meta, frames: 17)
        let original = caf(meta, payload: payload + Data([0xAA, 0xBB, 0xCC]))
        try original.write(to: source(meta))
        let result = try AudioTailRecovery.prepareCandidate(sourceURL: source(meta), candidateURL: candidate(), metadata: meta)
        XCTAssertEqual(result.frameCount, 17)
        XCTAssertEqual(result.discardedPartialFrameBytes, 3)
        XCTAssertEqual(result.copiedPCMByteCount, 17 * 8)
        XCTAssertEqual(try Data(contentsOf: result.candidateURL).dropFirst(68), payload)
        XCTAssertEqual(try Data(contentsOf: source(meta)), original)
    }

    func testFiniteDataExtentExcludesFollowingChunks() throws {
        let meta = metadata(), payload = pcm(meta, frames: 123)
        let original = caf(meta, payload: payload, declaredLength: Int64(payload.count + 4),
                           suffix: chunk("free", data: Data(repeating: 0xAB, count: 19)))
        try original.write(to: source(meta))
        let result = try AudioTailRecovery.prepareCandidate(sourceURL: source(meta), candidateURL: candidate(), metadata: meta)
        XCTAssertEqual(result.frameCount, 123)
        XCTAssertEqual(try Data(contentsOf: result.candidateURL).dropFirst(68), payload)
    }

    func testFiniteDeclaredDataTruncatedAtEOFKeepsCompletePhysicalFrames() throws {
        let meta = metadata(), payload = pcm(meta, frames: 50)
        let original = caf(meta, payload: payload + Data([7]), declaredLength: 4_004)
        try original.write(to: source(meta))
        let result = try AudioTailRecovery.prepareCandidate(sourceURL: source(meta), candidateURL: candidate(), metadata: meta)
        XCTAssertEqual(result.frameCount, 50)
        XCTAssertEqual(result.discardedPartialFrameBytes, 1)
        XCTAssertEqual(try Data(contentsOf: result.candidateURL).dropFirst(68), payload)
    }

    func testEmptyAndPartialOnlyAudioRemainUntouched() throws {
        for length: Int64 in [-1, 4] {
            let meta = metadata()
            try reject(caf(meta, payload: Data(), declaredLength: length), metadata: meta, error: .noCompleteFrames)
        }
        let meta = metadata(channels: 2)
        try reject(caf(meta, payload: Data([1, 2, 3])), metadata: meta, error: .noCompleteFrames)
    }

    func testZeroOrEmptyDeclaredDataWithExtraBytesIsAmbiguous() throws {
        for length: Int64 in [0, 4] {
            let meta = metadata()
            try reject(caf(meta, payload: pcm(meta, frames: 100), declaredLength: length),
                       metadata: meta, error: .ambiguousDataLength)
        }
    }

    func testBadHeaderLengthsAndDuplicateAudioCannotCreateCandidate() throws {
        let meta = metadata(), payload = pcm(meta, frames: 8)
        var badMagic = caf(meta, payload: payload)
        badMagic[0] = 0
        try reject(badMagic, metadata: meta, error: .malformedCAF)
        try reject(Data("caff".utf8), metadata: meta, error: .malformedCAF)
        try reject(caf(meta, payload: payload, declaredLength: -2), metadata: meta, error: .malformedCAF)
        try reject(caf(meta, payload: payload, declaredLength: Int64.max), metadata: meta, error: .resourceLimit)
        let duplicate = chunk("data", data: Data(repeating: 0, count: 8))
        try reject(caf(meta, payload: payload, declaredLength: Int64(payload.count + 4), suffix: duplicate),
                   metadata: meta, error: .malformedCAF)
        try reject(caf(meta, payload: payload, declaredLength: Int64(payload.count + 4), suffix: Data([1])),
                   metadata: meta, error: .malformedCAF)
    }

    func testFormatAndIdentityMismatchFailClosed() throws {
        let meta = metadata()
        var wrongRate = caf(meta, payload: pcm(meta, frames: 32))
        var encodedRate = Data()
        appendBE(Double(44_100).bitPattern, to: &encodedRate)
        wrongRate.replaceSubrange(20..<28, with: encodedRate)
        try reject(wrongRate, metadata: meta, error: .invalidMetadata)
        try reject(caf(meta, payload: pcm(meta, frames: 32), flags: 2), metadata: meta, error: .invalidMetadata)
        try reject(caf(meta, payload: pcm(meta, frames: 32), flags: 0x8000_0003), metadata: meta, error: .unsupportedFormat)
        let wrongPath = root.appendingPathComponent(UUID().uuidString).appendingPathExtension("caf")
        let bytes = caf(meta, payload: pcm(meta, frames: 32))
        try bytes.write(to: wrongPath)
        XCTAssertThrowsError(try AudioTailRecovery.prepareCandidate(sourceURL: wrongPath, candidateURL: candidate(), metadata: meta)) {
            XCTAssertEqual($0 as? AudioTailRecovery.RecoveryError, .invalidMetadata)
        }
        XCTAssertEqual(try Data(contentsOf: wrongPath), bytes)
    }

    func testJournalInputInterleavingDoesNotChangeCAFStorageInterpretation() throws {
        let meta = metadata(channels: 2, interleaved: false)
        let payload = pcm(meta, frames: 113)
        try caf(meta, payload: payload).write(to: source(meta))
        let result = try AudioTailRecovery.prepareCandidate(sourceURL: source(meta), candidateURL: candidate(), metadata: meta)
        XCTAssertEqual(result.frameCount, 113)
        XCTAssertEqual(try Data(contentsOf: result.candidateURL).dropFirst(68), payload)
    }

    func testExistingCandidateCannotBeOverwrittenOrDeletedOnFailure() throws {
        let meta = metadata(), bytes = caf(meta, payload: pcm(meta, frames: 16))
        try bytes.write(to: source(meta))
        let destination = candidate(), sentinel = Data("keep existing candidate".utf8)
        try sentinel.write(to: destination)
        XCTAssertThrowsError(try AudioTailRecovery.prepareCandidate(sourceURL: source(meta), candidateURL: destination, metadata: meta)) {
            XCTAssertEqual($0 as? AudioTailRecovery.RecoveryError, .candidateExists)
        }
        XCTAssertEqual(try Data(contentsOf: destination), sentinel)
        XCTAssertEqual(try Data(contentsOf: source(meta)), bytes)
    }

    func testSourceSymlinkIsRejectedAndTargetUnchanged() throws {
        let meta = metadata(), bytes = caf(meta, payload: pcm(meta, frames: 16))
        let real = root.appendingPathComponent("real.caf")
        try bytes.write(to: real)
        try FileManager.default.createSymbolicLink(at: source(meta), withDestinationURL: real)
        XCTAssertThrowsError(try AudioTailRecovery.prepareCandidate(sourceURL: source(meta), candidateURL: candidate(), metadata: meta)) {
            XCTAssertEqual($0 as? AudioTailRecovery.RecoveryError, .invalidSource)
        }
        XCTAssertEqual(try Data(contentsOf: real), bytes)
    }

    func testNonRegularSourceIsRejectedWithoutWaitingForAWriter() throws {
        let meta = metadata(), destination = candidate()
        XCTAssertEqual(mkfifo(source(meta).path, 0o600), 0)
        XCTAssertThrowsError(try AudioTailRecovery.prepareCandidate(sourceURL: source(meta), candidateURL: destination, metadata: meta)) {
            XCTAssertEqual($0 as? AudioTailRecovery.RecoveryError, .invalidSource)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: source(meta).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testSuccessfulCandidateCannotBeRecoveredAgainToSamePath() throws {
        let meta = metadata(), bytes = caf(meta, payload: pcm(meta, frames: 16))
        try bytes.write(to: source(meta))
        let destination = candidate()
        _ = try AudioTailRecovery.prepareCandidate(sourceURL: source(meta), candidateURL: destination, metadata: meta)
        let first = try Data(contentsOf: destination)
        XCTAssertThrowsError(try AudioTailRecovery.prepareCandidate(sourceURL: source(meta), candidateURL: destination, metadata: meta)) {
            XCTAssertEqual($0 as? AudioTailRecovery.RecoveryError, .candidateExists)
        }
        XCTAssertEqual(try Data(contentsOf: destination), first)
        XCTAssertEqual(try Data(contentsOf: source(meta)), bytes)
    }

    #if os(macOS)
    func testRealAVAudioFileAbruptProcessExitRecoversPhysicalFramesOnly() throws {
        let meta = metadata(channels: 2)
        let script = root.appendingPathComponent("abrupt-writer.swift")
        try """
        import AVFoundation
        import Darwin
        import Foundation
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let file = try AVAudioFile(forWriting: URL(fileURLWithPath: CommandLine.arguments[1]),
                                   settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16387)!
        buffer.frameLength = 16387
        for channel in 0..<2 {
            buffer.floatChannelData![channel].initialize(repeating: channel == 0 ? 0.25 : -0.5, count: 16387)
        }
        try file.write(from: buffer)
        // Bypasses AVAudioFile destruction and close/header finalization.
        _exit(0)
        """.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swift", script.path, source(meta).path]
        let stderr = root.appendingPathComponent("child-stderr.txt")
        _ = FileManager.default.createFile(atPath: stderr.path, contents: nil)
        let errors = try FileHandle(forWritingTo: stderr)
        defer { try? errors.close() }
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        let exited = expectation(description: "synthetic child exited without closing CAF")
        process.terminationHandler = { _ in exited.fulfill() }
        try process.run()
        let waitResult = XCTWaiter.wait(for: [exited], timeout: 45)
        if waitResult != .completed {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            XCTFail("Synthetic child timed out")
            return
        }
        let childErrors = String(data: try Data(contentsOf: stderr), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, childErrors)
        let original = try Data(contentsOf: source(meta))
        let beforeHash = SHA256.hash(data: original)
        // Read chunk structure independently to calculate actually persisted PCM.
        var offset = 8, pcmOffset: Int?
        func number(_ offset: Int) -> UInt64 {
            original[offset..<(offset + 8)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }
        while offset + 12 <= original.count {
            let kind = String(decoding: original[offset..<(offset + 4)], as: UTF8.self)
            let length = Int64(bitPattern: number(offset + 4))
            if kind == "data" {
                XCTAssertEqual(length, -1, "Fixture must be an unclosed CAF")
                pcmOffset = offset + 16
                break
            }
            guard length >= 0, length <= Int64(original.count - offset - 12) else {
                XCTFail("Unexpected synthetic CAF chunk")
                return
            }
            offset += 12 + Int(length)
        }
        let start = try XCTUnwrap(pcmOffset)
        let persistedFrames = (original.count - start) / 8
        XCTAssertGreaterThan(persistedFrames, 0)
        XCTAssertLessThanOrEqual(persistedFrames, 16387)
        let result = try AudioTailRecovery.prepareCandidate(sourceURL: source(meta), candidateURL: candidate(), metadata: meta)
        XCTAssertEqual(result.frameCount, Int64(persistedFrames))
        XCTAssertEqual(result.copiedPCMByteCount, Int64(persistedFrames * 8))
        XCTAssertEqual(try Data(contentsOf: result.candidateURL).dropFirst(68), original[start..<(start + persistedFrames * 8)])
        XCTAssertEqual(Data(SHA256.hash(data: try Data(contentsOf: source(meta)))), Data(beforeHash))
        let file = try AVAudioFile(forReading: result.candidateURL)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(persistedFrames)))
        try file.read(into: buffer, frameCount: AVAudioFrameCount(persistedFrames))
        XCTAssertEqual(buffer.frameLength, AVAudioFrameCount(persistedFrames))
        XCTAssertEqual(buffer.floatChannelData?[0][0], 0.25)
        XCTAssertEqual(buffer.floatChannelData?[1][persistedFrames - 1], -0.5)
    }
    #endif
}
