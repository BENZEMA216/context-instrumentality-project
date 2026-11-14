import Foundation

public enum SegmentTranscriptValidationError: LocalizedError, Equatable, Sendable {
    case unsupportedSchema
    case segmentMismatch
    case invalidAudioSHA256
    case audioMismatch
    case invalidDuration
    case missingLocale
    case missingEngine
    case invalidCreationDate
    case noSpeech
    case limitExceeded
    case invalidSpan(index: Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema: return "不支持这份转写记录的版本。"
        case .segmentMismatch: return "转写记录不属于当前录音片段。"
        case .invalidAudioSHA256: return "转写记录的音频校验值无效。"
        case .audioMismatch: return "转写记录与当前录音内容不一致，请重新转写。"
        case .invalidDuration: return "录音片段的有效时长无效，无法核对转写时间。"
        case .missingLocale: return "转写记录缺少语言信息。"
        case .missingEngine: return "转写记录缺少来源信息。"
        case .invalidCreationDate: return "转写记录的创建时间无效。"
        case .noSpeech: return "未识别到可转写的语音，原录音仍保留。"
        case .limitExceeded: return "转写记录超出容量限制，未保存。"
        case .invalidSpan: return "转写时间或内容无效，请重新转写。"
        }
    }
}

/// A transcript is bound to one exact audio digest, not just a recording UUID.
/// After decoding, call `validate(against:)` before displaying or persisting it.
/// An empty recognition result is `noSpeech`, never a successful text transcript.
public struct SegmentTranscript: Codable, Equatable, Sendable {
    public struct Span: Codable, Equatable, Sendable {
        /// Seconds relative to the start of this audio segment (not wall time).
        public let start: TimeInterval
        public let end: TimeInterval
        public let text: String

        public init(start: TimeInterval, end: TimeInterval, text: String) {
            self.start = start
            self.end = end
            self.text = text
        }
    }

    public let schemaVersion: Int
    public let segmentID: UUID
    public let audioSHA256: String
    public let locale: String
    public let engine: String
    public let createdAt: Date
    public let text: String
    public let spans: [Span]

    public init(segmentID: UUID, audioSHA256: String, locale: String, engine: String,
                createdAt: Date = Date(), text: String, spans: [Span], schemaVersion: Int = 1) {
        self.schemaVersion = schemaVersion
        self.segmentID = segmentID
        self.audioSHA256 = audioSHA256
        self.locale = locale
        self.engine = engine
        // Match the millisecond date representation used by TransportCodec.
        self.createdAt = Date(timeIntervalSince1970: (createdAt.timeIntervalSince1970 * 1_000).rounded() / 1_000)
        self.text = text
        self.spans = spans
    }

    /// A manifest must come from the recording repository, not from the transcript.
    /// This verifies metadata binding; the transcriber separately checks audio bytes.
    public func validate(against manifest: SegmentManifest) throws {
        guard schemaVersion == 1 else { throw SegmentTranscriptValidationError.unsupportedSchema }
        guard segmentID == manifest.id else { throw SegmentTranscriptValidationError.segmentMismatch }
        guard audioSHA256.count == 64,
              audioSHA256.allSatisfy({ "0123456789abcdef".contains($0) }) else {
            throw SegmentTranscriptValidationError.invalidAudioSHA256
        }
        guard audioSHA256 == manifest.sha256 else { throw SegmentTranscriptValidationError.audioMismatch }
        guard manifest.schemaVersion == 1, manifest.frameCount > 0,
              manifest.sampleRate.isFinite, manifest.sampleRate > 0,
              manifest.sampleRate <= 384_000, manifest.duration.isFinite,
              manifest.duration > 0 else { throw SegmentTranscriptValidationError.invalidDuration }
        guard !locale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SegmentTranscriptValidationError.missingLocale
        }
        guard !engine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SegmentTranscriptValidationError.missingEngine
        }
        guard locale.utf8.count <= 128, engine.utf8.count <= 128,
              text.utf8.count <= 256 * 1_024, spans.count <= 10_000 else {
            throw SegmentTranscriptValidationError.limitExceeded
        }
        let milliseconds = createdAt.timeIntervalSince1970 * 1_000
        // Bound the timestamp before TransportCodec converts it to an Int64.
        guard milliseconds.isFinite, milliseconds >= 0, milliseconds <= 253_402_300_799_999 else {
            throw SegmentTranscriptValidationError.invalidCreationDate
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SegmentTranscriptValidationError.noSpeech
        }
        for (index, span) in spans.enumerated() {
            guard span.text.utf8.count <= 8 * 1_024 else {
                throw SegmentTranscriptValidationError.limitExceeded
            }
            guard span.start.isFinite, span.end.isFinite,
                  span.start >= 0, span.end >= span.start, span.end <= manifest.duration,
                  !span.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SegmentTranscriptValidationError.invalidSpan(index: index)
            }
        }
    }
}
