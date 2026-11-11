import AVFoundation
import Foundation
import RecordingCore

enum IncomingAudioValidator {
    enum ValidationError: LocalizedError {
        case invalidManifest, emptyAudio, unexpectedFrames, unexpectedSampleRate, unreadableAudio

        var errorDescription: String? {
            switch self {
            case .invalidManifest: return "片段清单中的音频参数无效。"
            case .emptyAudio: return "收到的音频没有可播放的采样。"
            case .unexpectedFrames: return "音频采样数量与清单不一致。"
            case .unexpectedSampleRate: return "音频采样率与清单不一致。"
            case .unreadableAudio: return "音频无法完整读取，未发送接收确认。"
            }
        }
    }

    /// Must run while WCSession's temporary file is still valid.
    static func validate(_ url: URL, against manifest: SegmentManifest) throws {
        guard manifest.frameCount > 0, manifest.sampleRate.isFinite, manifest.sampleRate > 0 else {
            throw ValidationError.invalidManifest
        }
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0 else { throw ValidationError.emptyAudio }
        guard file.length == manifest.frameCount else { throw ValidationError.unexpectedFrames }
        guard abs(file.processingFormat.sampleRate - manifest.sampleRate) < 0.01 else {
            throw ValidationError.unexpectedSampleRate
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_192) else {
            throw ValidationError.unreadableAudio
        }
        var readFrames: Int64 = 0
        while readFrames < file.length {
            let requested = AVAudioFrameCount(min(Int64(buffer.frameCapacity), file.length - readFrames))
            try file.read(into: buffer, frameCount: requested)
            guard buffer.frameLength > 0 else { throw ValidationError.unreadableAudio }
            readFrames += Int64(buffer.frameLength)
        }
        guard readFrames == manifest.frameCount else { throw ValidationError.unexpectedFrames }
    }
}
