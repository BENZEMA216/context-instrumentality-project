import XCTest
@testable import RecordingCore

final class SegmentTranscriptTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)
    private let instant = Date(timeIntervalSince1970: 1_800_000_000.123)

    private func manifest(sampleRate: Double = 16_000, frameCount: Int64 = 160_000) -> SegmentManifest {
        let identifier = UUID()
        return SegmentManifest(id: identifier, sessionID: UUID(), sequence: 0,
            startedAt: instant, endedAt: instant.addingTimeInterval(30), sampleRate: sampleRate,
            frameCount: frameCount, fileName: identifier.uuidString.lowercased() + ".caf", byteCount: 320_000,
            sha256: digest)
    }

    private func transcript(for manifest: SegmentManifest, text: String = "会议决定下周继续。",
                            spans: [SegmentTranscript.Span]? = nil, hash: String? = nil,
                            segmentID: UUID? = nil, locale: String = "zh-CN",
                            engine: String = "synthetic-test", createdAt: Date? = nil,
                            schemaVersion: Int = 1) -> SegmentTranscript {
        SegmentTranscript(segmentID: segmentID ?? manifest.id, audioSHA256: hash ?? digest,
            locale: locale, engine: engine, createdAt: createdAt ?? instant, text: text,
            spans: spans ?? [.init(start: 0.5, end: 9.5, text: text)], schemaVersion: schemaVersion)
    }

    func testRoundTripKeepsExactAudioBindingAndRelativeTimes() throws {
        let source = manifest()
        let value = transcript(for: source)
        try value.validate(against: source)
        let decoded = try TransportCodec.decode(SegmentTranscript.self, from: TransportCodec.encode(value))
        try decoded.validate(against: source)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.spans[0].start, 0.5)
        XCTAssertEqual(decoded.spans[0].end, 9.5)
        XCTAssertEqual(decoded.audioSHA256, source.sha256)
    }

    func testDifferentAudioOrSegmentCannotReuseATranscript() {
        let source = manifest()
        for (value, expected) in [
            (transcript(for: source, segmentID: UUID()), SegmentTranscriptValidationError.segmentMismatch),
            (transcript(for: source, hash: String(repeating: "b", count: 64)), .audioMismatch),
            (transcript(for: source, hash: String(repeating: "A", count: 64)), .invalidAudioSHA256),
            (transcript(for: source, hash: "abc"), .invalidAudioSHA256)
        ] {
            XCTAssertThrowsError(try value.validate(against: source)) { error in
                XCTAssertEqual(error as? SegmentTranscriptValidationError, expected)
            }
        }
    }

    func testWhitespaceRecognitionIsAnExplicitNoSpeechOutcome() {
        let source = manifest()
        for text in ["", " \n\t", "\u{3000}"] {
            let value = transcript(for: source, text: text, spans: [])
            XCTAssertThrowsError(try value.validate(against: source)) { error in
                XCTAssertEqual(error as? SegmentTranscriptValidationError, .noSpeech)
            }
        }
    }

    func testInvalidSpanTimesAreRejectedWithoutClampingOrInventingAudio() {
        let source = manifest()
        let invalid: [(TimeInterval, TimeInterval)] = [
            (-0.01, 1), (1, 0.5), (0, 10.0001), (.nan, 1), (0, .infinity), (0, .nan)
        ]
        for (start, end) in invalid {
            let value = transcript(for: source, spans: [.init(start: start, end: end, text: "内容")])
            XCTAssertThrowsError(try value.validate(against: source)) { error in
                XCTAssertEqual(error as? SegmentTranscriptValidationError, .invalidSpan(index: 0))
            }
        }
        // Effective audio length is 10 seconds, even though wall-clock bounds span 30.
        let wallTime = transcript(for: source, spans: [.init(start: 0, end: 20, text: "内容")])
        XCTAssertThrowsError(try wallTime.validate(against: source))
        XCTAssertNoThrow(try transcript(for: source,
            spans: [.init(start: 0, end: 10, text: "内容")]).validate(against: source))
    }

    func testFullTextMayOmitTimingButPresentSpansCannotBeBlank() {
        let source = manifest()
        XCTAssertNoThrow(try transcript(for: source, spans: []).validate(against: source))
        let blankSpan = transcript(for: source, spans: [.init(start: 0, end: 1, text: " \n")])
        XCTAssertThrowsError(try blankSpan.validate(against: source)) { error in
            XCTAssertEqual(error as? SegmentTranscriptValidationError, .invalidSpan(index: 0))
        }
    }

    func testInvalidManifestDurationCannotAuthorizeTranscriptTimes() {
        for source in [manifest(sampleRate: 0), manifest(sampleRate: -.infinity),
                       manifest(sampleRate: .nan), manifest(sampleRate: .infinity),
                       manifest(frameCount: 0), manifest(frameCount: -1)] {
            XCTAssertThrowsError(try transcript(for: source).validate(against: source)) { error in
                XCTAssertEqual(error as? SegmentTranscriptValidationError, .invalidDuration)
            }
        }
    }

    func testMalformedDecodedMetadataCannotPassSourceValidation() throws {
        let source = manifest()
        for (value, expected) in [
            (transcript(for: source, locale: " "), SegmentTranscriptValidationError.missingLocale),
            (transcript(for: source, engine: "\n"), .missingEngine),
            (transcript(for: source, schemaVersion: 99), .unsupportedSchema),
            (transcript(for: source, createdAt: Date(timeIntervalSince1970: -1)), .invalidCreationDate)
        ] {
            let decoded = try TransportCodec.decode(SegmentTranscript.self, from: TransportCodec.encode(value))
            XCTAssertThrowsError(try decoded.validate(against: source)) { error in
                XCTAssertEqual(error as? SegmentTranscriptValidationError, expected)
            }
        }
    }

    func testNonfiniteCreationTimeIsRejectedBeforePersistence() {
        let source = manifest()
        for seconds in [TimeInterval.nan, .infinity, -.infinity] {
            let value = transcript(for: source, createdAt: Date(timeIntervalSince1970: seconds))
            XCTAssertThrowsError(try value.validate(against: source)) { error in
                XCTAssertEqual(error as? SegmentTranscriptValidationError, .invalidCreationDate)
            }
        }
    }

    func testUTF8ByteAndSpanCountLimitsMatchAgentExportProtocol() {
        let source = manifest()
        let values = [
            transcript(for: source, text: String(repeating: "中", count: 256 * 1_024 / 3 + 1), spans: []),
            transcript(for: source, locale: String(repeating: "中", count: 43)),
            transcript(for: source, engine: String(repeating: "a", count: 129)),
            transcript(for: source, spans: Array(repeating: .init(start: 0, end: 1, text: "字"), count: 10_001)),
            transcript(for: source, spans: [.init(start: 0, end: 1, text: String(repeating: "a", count: 8_193))])
        ]
        for value in values {
            XCTAssertThrowsError(try value.validate(against: source)) { error in
                XCTAssertEqual(error as? SegmentTranscriptValidationError, .limitExceeded)
            }
        }
        XCTAssertNoThrow(try transcript(for: source, text: String(repeating: "a", count: 256 * 1_024),
            spans: [], locale: String(repeating: "a", count: 128), engine: String(repeating: "a", count: 128))
            .validate(against: source))
    }
}
