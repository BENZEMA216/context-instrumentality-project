import AVFoundation
import Foundation
import RecordingCore
import Speech

/// Uses only installed Apple on-device models. Downloading is a separate, explicit operation.
/// This actor never starts microphone capture, changes Watch receipts, or sends audio to a server.
actor OnDeviceTranscriber {
    enum ModelStatus: Equatable, Sendable {
        case unsupportedOS
        case deviceUnavailable
        case unsupportedLocale
        case notInstalled(locale: String)
        case downloading(locale: String)
        case ready(locale: String)
    }

    enum Failure: LocalizedError, Equatable, Sendable {
        case unsupportedOS, deviceUnavailable, unsupportedLocale
        case modelNotInstalled, modelDownloading, modelPreparationFailed
        case busy, invalidAudio, audioMismatch

        var errorDescription: String? {
            switch self {
            case .unsupportedOS: return "本机转写需要 iOS 26 / macOS 26 或更高版本，原录音仍可播放。"
            case .deviceUnavailable: return "这台设备暂不支持本机语音转写，原录音仍保留。"
            case .unsupportedLocale: return "本机转写暂不支持所选语言。"
            case .modelNotInstalled: return "请先下载本机转写模型，再开始转写。"
            case .modelDownloading: return "本机转写模型正在下载，请完成后重试。"
            case .modelPreparationFailed: return "本机转写模型尚未准备好，请稍后重试。"
            case .busy: return "已有转写或模型下载任务正在进行。"
            case .invalidAudio: return "录音文件或采样信息无效，未开始转写。"
            case .audioMismatch: return "录音内容与片段清单不一致，未开始转写。"
            }
        }
    }

    /// Contains timing only: never speech text, a path or framework userInfo.
    struct InvalidResultRange: LocalizedError, Sendable {
        let index: Int
        let start: Double
        let end: Double
        let manifestDuration: Double
        let frameCount: Int64
        let sampleRate: Double
        let startValue: Int64
        let startTimescale: Int32
        let endValue: Int64
        let endTimescale: Int32
        let rangeDurationValue: Int64
        let rangeDurationTimescale: Int32

        var errorDescription: String? {
            SegmentTranscriptValidationError.invalidSpan(index: index).errorDescription
        }

        /// JSON permits finite numbers only. Exact CMTime rationals remain integers.
        var numericDiagnostics: [String: Any] {
            var fields: [String: Any] = [
                "spanIndex": index, "frameCount": frameCount,
                "startValue": startValue, "startTimescale": startTimescale,
                "endValue": endValue, "endTimescale": endTimescale,
                "rangeDurationValue": rangeDurationValue, "rangeDurationTimescale": rangeDurationTimescale,
                "startIsFinite": start.isFinite, "endIsFinite": end.isFinite,
            ]
            if start.isFinite { fields["startSeconds"] = start }
            if end.isFinite { fields["endSeconds"] = end }
            if manifestDuration.isFinite { fields["manifestDuration"] = manifestDuration }
            if sampleRate.isFinite { fields["sampleRate"] = sampleRate }
            return fields
        }
    }

    /// Adapts only an exact nearest-grid SDK endpoint back to the source frame
    /// endpoint. Persisted transcript bounds remain strict; no text is dropped.
    static func validatedResultRange(_ range: CMTimeRange, manifest: SegmentManifest,
                                     index: Int) throws -> (start: Double, end: Double) {
        let endTime = CMTimeRangeGetEnd(range)
        let start = CMTimeGetSeconds(range.start)
        let rawEnd = CMTimeGetSeconds(endTime)
        let end = sourceBoundedEnd(endTime, manifest: manifest)
        guard range.isValid, range.start.isNumeric, range.duration.isNumeric,
              range.duration.value >= 0, start.isFinite, rawEnd.isFinite,
              start >= 0, end >= start, end <= manifest.duration else {
            throw InvalidResultRange(index: index, start: start, end: rawEnd,
                manifestDuration: manifest.duration, frameCount: manifest.frameCount,
                sampleRate: manifest.sampleRate,
                startValue: range.start.value, startTimescale: range.start.timescale,
                endValue: endTime.value, endTimescale: endTime.timescale,
                rangeDurationValue: range.duration.value, rangeDurationTimescale: range.duration.timescale)
        }
        return (start, end)
    }

    private static func sourceBoundedEnd(_ endTime: CMTime, manifest: SegmentManifest) -> Double {
        let rawEnd = CMTimeGetSeconds(endTime)
        guard rawEnd.isFinite, rawEnd > manifest.duration,
              manifest.frameCount > 0,
              let sourceScale = Int32(exactly: manifest.sampleRate), sourceScale > 0,
              endTime.isNumeric, endTime.epoch == 0, endTime.timescale > 0 else { return rawEnd }
        let sourceEnd = CMTime(value: manifest.frameCount, timescale: sourceScale)
        let roundedEnd = CMTimeConvertScale(sourceEnd, timescale: endTime.timescale,
                                            method: .roundHalfAwayFromZero)
        guard roundedEnd.isNumeric, CMTimeCompare(endTime, roundedEnd) == 0,
              CMTimeCompare(endTime, sourceEnd) > 0 else { return rawEnd }

        // Exact integer bound: (end - sourceEnd) <= half an SDK time-grid unit.
        // Refuse overflow instead of introducing a floating-point tolerance.
        let rawProduct = endTime.value.multipliedReportingOverflow(by: Int64(sourceScale))
        let sourceProduct = manifest.frameCount.multipliedReportingOverflow(by: Int64(endTime.timescale))
        guard !rawProduct.overflow, !sourceProduct.overflow else { return rawEnd }
        let delta = rawProduct.partialValue.subtractingReportingOverflow(sourceProduct.partialValue)
        guard !delta.overflow, delta.partialValue > 0,
              delta.partialValue <= Int64(sourceScale) / 2 else { return rawEnd }
        return manifest.duration
    }

    private var isBusy = false

    /// Read-only model inspection; this does not reserve or download a model.
    func modelStatus(localeIdentifier: String = "zh-CN") async -> ModelStatus {
        guard #available(iOS 26.0, macOS 26.0, *) else { return .unsupportedOS }
        guard SpeechTranscriber.isAvailable else { return .deviceUnavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeIdentifier)) else {
            return .unsupportedLocale
        }
        return await Self.status(for: Self.makeTranscriber(locale: locale), locale: locale)
    }

    /// The caller must expose this as an explicit model download action.
    @discardableResult
    func prepareModel(localeIdentifier: String = "zh-CN") async throws -> ModelStatus {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw Failure.unsupportedOS }
        guard !isBusy else { throw Failure.busy }
        isBusy = true
        defer { isBusy = false }
        try Task.checkCancellation()
        let locale = try await Self.resolveLocale(localeIdentifier)
        let transcriber = Self.makeTranscriber(locale: locale)
        switch await Self.status(for: transcriber, locale: locale) {
        case .ready: return .ready(locale: locale.identifier)
        case .downloading: throw Failure.modelDownloading
        case .notInstalled: break
        case .deviceUnavailable: throw Failure.deviceUnavailable
        case .unsupportedLocale: throw Failure.unsupportedLocale
        case .unsupportedOS: throw Failure.unsupportedOS
        }
        try Task.checkCancellation()
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await request.downloadAndInstall()
            } onCancel: {
                request.progress.cancel()
            }
        }
        try Task.checkCancellation()
        let status = await Self.status(for: transcriber, locale: locale)
        guard case .ready = status else { throw Failure.modelPreparationFailed }
        return status
    }

    func transcribe(audioURL: URL, manifest: SegmentManifest,
                    localeIdentifier: String = "zh-CN") async throws -> SegmentTranscript {
        guard #available(iOS 26.0, macOS 26.0, *) else { throw Failure.unsupportedOS }
        guard !isBusy else { throw Failure.busy }
        isBusy = true
        defer { isBusy = false }
        try Task.checkCancellation()
        let locale = try await Self.resolveLocale(localeIdentifier)
        let transcriber = Self.makeTranscriber(locale: locale)
        switch await Self.status(for: transcriber, locale: locale) {
        case .ready: break
        case .notInstalled: throw Failure.modelNotInstalled
        case .downloading: throw Failure.modelDownloading
        case .deviceUnavailable: throw Failure.deviceUnavailable
        case .unsupportedLocale: throw Failure.unsupportedLocale
        case .unsupportedOS: throw Failure.unsupportedOS
        }
        try Task.checkCancellation()

        // Analyze a verified snapshot so replacing the original during an await cannot
        // silently attach text to a different digest. The source file is never modified.
        let snapshot = try Self.makeSnapshot(audioURL: audioURL, manifest: manifest)
        defer { try? FileManager.default.removeItem(at: snapshot.deletingLastPathComponent()) }
        let audioFile = try AVAudioFile(forReading: snapshot, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard audioFile.length == manifest.frameCount,
              abs(audioFile.processingFormat.sampleRate - manifest.sampleRate) < 0.01 else {
            throw Failure.audioMismatch
        }
        try Task.checkCancellation()
        try Self.rejectDigitalSilence(in: audioFile)
        let analyzer = SpeechAnalyzer(modules: [transcriber],
            options: .init(priority: .utility, modelRetention: .whileInUse))
        let spans = try await Self.analyze(audioFile: audioFile, manifest: manifest,
                                         transcriber: transcriber, analyzer: analyzer)
        try Task.checkCancellation()
        let transcript = SegmentTranscript(segmentID: manifest.id, audioSHA256: manifest.sha256,
            locale: locale.identifier, engine: "apple-speech-transcriber",
            text: spans.map(\.text).joined(separator: " "), spans: spans)
        // Includes the explicit noSpeech result, rather than saving an empty success.
        try transcript.validate(against: manifest)
        return transcript
    }

    /// Only exact digital silence is rejected. Even the smallest nonzero decoded
    /// sample is retained; this is not a loudness threshold or a speech detector.
    static func rejectDigitalSilence(in audioFile: AVAudioFile) throws {
        audioFile.framePosition = 0
        defer { audioFile.framePosition = 0 }
        try Task.checkCancellation()
        let format = audioFile.processingFormat
        guard audioFile.length > 0, format.channelCount > 0,
              format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384) else {
            throw Failure.invalidAudio
        }
        var hasNonzeroSample = false
        var decodedFrames: AVAudioFramePosition = 0
        while decodedFrames < audioFile.length {
            try Task.checkCancellation()
            try audioFile.read(into: buffer)
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData,
                  AVAudioFramePosition(buffer.frameLength) <= audioFile.length - decodedFrames else {
                throw Failure.invalidAudio
            }
            for channel in 0..<Int(format.channelCount) {
                for frame in 0..<Int(buffer.frameLength) {
                    let sample = channels[channel][frame]
                    guard sample.isFinite else { throw Failure.invalidAudio }
                    if sample != 0 { hasNonzeroSample = true }
                }
            }
            decodedFrames += AVAudioFramePosition(buffer.frameLength)
        }
        try Task.checkCancellation()
        guard hasNonzeroSample else { throw SegmentTranscriptValidationError.noSpeech }
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func resolveLocale(_ identifier: String) async throws -> Locale {
        guard SpeechTranscriber.isAvailable else { throw Failure.deviceUnavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
            throw Failure.unsupportedLocale
        }
        try Task.checkCancellation()
        return locale
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [],
                          attributeOptions: [.audioTimeRange])
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func status(for transcriber: SpeechTranscriber, locale: Locale) async -> ModelStatus {
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed: return .ready(locale: locale.identifier)
        case .supported: return .notInstalled(locale: locale.identifier)
        case .downloading: return .downloading(locale: locale.identifier)
        case .unsupported: return .deviceUnavailable
        @unknown default: return .deviceUnavailable
        }
    }

    private static func makeSnapshot(audioURL: URL, manifest: SegmentManifest) throws -> URL {
        guard audioURL.isFileURL, manifest.schemaVersion == 1, manifest.byteCount > 0,
              manifest.frameCount > 0, manifest.sampleRate.isFinite,
              manifest.sampleRate > 0, manifest.sampleRate <= 384_000,
              manifest.duration.isFinite, manifest.duration > 0,
              manifest.sha256.count == 64,
              manifest.sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw Failure.invalidAudio
        }
        let fm = FileManager.default
        let sourceAttributes = try fm.attributesOfItem(atPath: audioURL.path)
        guard sourceAttributes[.type] as? FileAttributeType == .typeRegular else { throw Failure.invalidAudio }
        let directory = fm.temporaryDirectory.appendingPathComponent("WristRecord-transcribe-" + UUID().uuidString,
                                                                    isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false,
                               attributes: [.posixPermissions: 0o700])
        do {
            let snapshot = directory.appendingPathComponent("audio.caf")
            try fm.copyItem(at: audioURL, to: snapshot)
            let attributes = try fm.attributesOfItem(atPath: snapshot.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw Failure.invalidAudio }
            #if os(iOS)
            try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                 ofItemAtPath: snapshot.path)
            #endif
            let fingerprint = try RecordingRepository.fingerprint(of: snapshot)
            guard fingerprint.byteCount == manifest.byteCount, fingerprint.sha256 == manifest.sha256 else {
                throw Failure.audioMismatch
            }
            return snapshot
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
    }

    @available(iOS 26.0, macOS 26.0, *)
    private static func analyze(audioFile: AVAudioFile, manifest: SegmentManifest,
                                transcriber: SpeechTranscriber,
                                analyzer: SpeechAnalyzer) async throws -> [SegmentTranscript.Span] {
        try await collectAnalyzerResults(produce: {
            try Task.checkCancellation()
            guard try await analyzer.analyzeSequence(from: audioFile) != nil else {
                throw SegmentTranscriptValidationError.noSpeech
            }
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        }, consume: {
            var spans: [SegmentTranscript.Span] = []
            var textBytes = 0
            for try await result in transcriber.results {
                try Task.checkCancellation()
                guard result.isFinal else { continue }
                let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let (start, end) = try validatedResultRange(result.range, manifest: manifest, index: spans.count)
                textBytes += text.utf8.count + (spans.isEmpty ? 0 : 1)
                guard text.utf8.count <= 8 * 1_024, textBytes <= 256 * 1_024,
                      spans.count < 10_000 else {
                    throw SegmentTranscriptValidationError.limitExceeded
                }
                spans.append(.init(start: start, end: end, text: text))
            }
            return spans
        }, cancel: {
            await analyzer.cancelAndFinishNow()
        })
    }

    /// Shares the production task coordination with synthetic concurrency probes.
    /// The closures separate input, output and cleanup without changing validation.
    static func collectAnalyzerResults(
        produce: @escaping @Sendable () async throws -> Void,
        consume: @escaping @Sendable () async throws -> [SegmentTranscript.Span],
        cancel: @escaping @Sendable () async -> Void
    ) async throws -> [SegmentTranscript.Span] {
        try await withTaskCancellationHandler {
            // Producer and result consumer must run concurrently: either stream can
            // otherwise wait for the other. Only the parent initiates error cleanup:
            // cancelling the peer before publishing an error can hide its cause.
            try await withThrowingTaskGroup(of: [SegmentTranscript.Span]?.self) { group in
                group.addTask {
                    try await produce()
                    return nil
                }
                group.addTask {
                    try await consume()
                }
                var spans: [SegmentTranscript.Span] = []
                var failure: Error?
                var cleanupStarted = false
                while !group.isEmpty {
                    do {
                        if let result = try await group.next(), let result { spans = result }
                    } catch {
                        if failure == nil {
                            failure = error
                        } else if let previous = failure, previous is CancellationError,
                                  !(error is CancellationError) {
                            // SpeechAnalyzer may send cancellation to one stream
                            // before delivering the real error to the other.
                            failure = error
                        }
                        if !cleanupStarted {
                            cleanupStarted = true
                            group.cancelAll()
                            await cancel()
                        }
                    }
                }
                // Explicit caller cancellation still prevents publishing a result.
                try Task.checkCancellation()
                if let failure { throw failure }
                return spans
            }
        } onCancel: {
            Task { await cancel() }
        }
    }
}
