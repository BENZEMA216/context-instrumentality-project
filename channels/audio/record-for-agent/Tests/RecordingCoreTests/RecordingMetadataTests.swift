import XCTest
@testable import RecordingCore

final class RecordingMetadataTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_700_000_000.123)

    private func manifest(timeZoneIdentifier: String? = nil, location: SegmentLocation? = nil,
                          startedAt: Date? = nil, endedAt: Date? = nil) -> SegmentManifest {
        let id = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        return SegmentManifest(id: id, sessionID: UUID(), sequence: 0,
            startedAt: startedAt ?? instant, endedAt: endedAt ?? instant.addingTimeInterval(60),
            sampleRate: 16_000, frameCount: 960_000, fileName: id.uuidString.lowercased() + ".caf",
            byteCount: 1_024, sha256: String(repeating: "a", count: 64),
            timeZoneIdentifier: timeZoneIdentifier, location: location)
    }

    func testLegacyManifestAndExportDecodeWithoutInventingCaptureContext() throws {
        let source = manifest()
        let original = try TransportCodec.encode(source)
        let decoded = try TransportCodec.decode(SegmentManifest.self, from: original)
        XCTAssertNil(decoded.timeZoneIdentifier)
        XCTAssertNil(decoded.location)
        XCTAssertEqual(try TransportCodec.encode(decoded), original)
        let metadata = try AgentRecordingMetadata(manifest: decoded)
        XCTAssertEqual(metadata.startedAtISO8601, "2023-11-14T22:13:20.123Z")
        XCTAssertEqual(metadata.endedAtISO8601, "2023-11-14T22:14:20.123Z")
        XCTAssertEqual(metadata.timeZoneIdentifier, "UTC")
        XCTAssertEqual(metadata.timeZoneSource, "utc_fallback")
        XCTAssertNil(metadata.location)
        let sourceObject = try JSONSerialization.jsonObject(with: original)
        for version in [1, 2] {
            let oldEnvelope: [String: Any] = ["schemaVersion": version, "exportID": UUID().uuidString,
                "exportedAt": 1_700_000_000_123, "transcriptStatus": "not_generated",
                "segments": [["manifest": sourceObject, "audioPath": "audio/" + source.fileName]]]
            let old = try TransportCodec.decode(AgentExportManifest.self, from: JSONSerialization.data(withJSONObject: oldEnvelope))
            XCTAssertNil(old.segments.first?.metadata)
            XCTAssertEqual(old.segments.first?.manifest, source)
        }
    }

    func testRecordedZoneAndLocationCrossMidnightAndRoundTrip() throws {
        let location = SegmentLocation(latitude: 31.2304, longitude: 121.4737,
            horizontalAccuracy: 12, capturedAt: instant.addingTimeInterval(-2))
        let source = manifest(timeZoneIdentifier: "Asia/Shanghai", location: location)
        let roundTrip = try TransportCodec.decode(SegmentManifest.self, from: TransportCodec.encode(source))
        XCTAssertEqual(roundTrip, source)
        let metadata = try AgentRecordingMetadata(manifest: roundTrip)
        XCTAssertEqual(metadata.startedAtISO8601, "2023-11-15T06:13:20.123+08:00")
        XCTAssertEqual(metadata.endedAtISO8601, "2023-11-15T06:14:20.123+08:00")
        XCTAssertEqual(metadata.timeZoneSource, "recorded")
        XCTAssertEqual(metadata.location?.capturedAtISO8601, "2023-11-15T06:13:18.123+08:00")
        XCTAssertEqual(metadata.location?.horizontalAccuracy, 12)
    }

    func testDaylightSavingOffsetsAreComputedForEachBoundary() throws {
        let source = manifest(timeZoneIdentifier: "America/New_York",
            startedAt: Date(timeIntervalSince1970: 1_730_611_800.123),
            endedAt: Date(timeIntervalSince1970: 1_730_615_400.456))
        let metadata = try AgentRecordingMetadata(manifest: source)
        XCTAssertEqual(metadata.startedAtISO8601, "2024-11-03T01:30:00.123-04:00")
        XCTAssertEqual(metadata.endedAtISO8601, "2024-11-03T01:30:00.456-05:00")
    }

    func testValidIANAAliasesAndCalendarLimits() throws {
        for identifier in ["Etc/UTC", "Etc/GMT", "US/Eastern"] {
            let metadata = try AgentRecordingMetadata(manifest: manifest(timeZoneIdentifier: identifier))
            XCTAssertEqual(metadata.timeZoneIdentifier, identifier)
            XCTAssertEqual(metadata.timeZoneSource, "recorded")
        }
        XCTAssertThrowsError(try AgentRecordingMetadata(manifest: manifest(timeZoneIdentifier: "Asia/Shanghai",
            startedAt: Date(timeIntervalSince1970: 253_402_300_799.999),
            endedAt: Date(timeIntervalSince1970: 253_402_300_799.999))))
    }

    func testInvalidCaptureContextIsRejected() throws {
        for zone in ["", "Not/AZone", "../etc/localtime", String(repeating: "a", count: 129)] {
            XCTAssertThrowsError(try AgentRecordingMetadata(manifest: manifest(timeZoneIdentifier: zone)))
        }
        for location in [
            SegmentLocation(latitude: 91, longitude: 0, horizontalAccuracy: 1, capturedAt: instant),
            SegmentLocation(latitude: 0, longitude: -181, horizontalAccuracy: 1, capturedAt: instant),
            SegmentLocation(latitude: 0, longitude: 0, horizontalAccuracy: -1, capturedAt: instant),
            SegmentLocation(latitude: .nan, longitude: 0, horizontalAccuracy: 1, capturedAt: instant),
            SegmentLocation(latitude: 0, longitude: 0, horizontalAccuracy: .infinity, capturedAt: instant),
            SegmentLocation(latitude: 0, longitude: 0, horizontalAccuracy: 1, capturedAt: Date(timeIntervalSince1970: -1))
        ] {
            XCTAssertThrowsError(try AgentRecordingMetadata(manifest: manifest(location: location)))
        }
    }

    func testSealedContextSurvivesTransferAcknowledgementAndExport() throws {
        try checkSealedContextSurvivesTransferAndExport(using: .system)
    }

    func testSealedContextSurvivesTransferAcknowledgementAndExportWithoutSystemService() throws {
        try checkSealedContextSurvivesTransferAndExport(using: .commandLine)
    }

    private func checkSealedContextSurvivesTransferAndExport(using archiver: AgentExportTestArchive) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RecordingMetadata-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let watch = try RecordingRepository(root: directory.appendingPathComponent("watch"))
        let phone = try RecordingRepository(root: directory.appendingPathComponent("phone"))
        let id = UUID()
        try Data(repeating: 42, count: 1_024).write(to: watch.stagingURL(for: id))
        let location = SegmentLocation(latitude: 31.2304, longitude: 121.4737, horizontalAccuracy: 12, capturedAt: instant)
        let source = try watch.sealSegment(stagedURL: watch.stagingURL(for: id), id: id, sessionID: UUID(), sequence: 0,
            startedAt: instant, endedAt: instant.addingTimeInterval(60), sampleRate: 16_000, frameCount: 960_000,
            timeZoneIdentifier: "Asia/Shanghai", location: location)
        let receipt = try phone.acceptIncomingFile(at: watch.audioURL(for: source), manifest: source)
        try watch.acknowledge(receipt, pruneAudio: false)
        XCTAssertTrue(try watch.hasDurableAcknowledgement(for: source))
        let reopened = try RecordingRepository(root: directory.appendingPathComponent("phone"))
        XCTAssertEqual(try reopened.manifests(), [source])
        let archive = try archiver.createArchive(repository: reopened, selectedIDs: [source.id],
            destinationDirectory: directory.appendingPathComponent("exports"), now: instant)
        let extraction = directory.appendingPathComponent("extracted")
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", archive.path, "-d", extraction.path]
        try unzip.run(); unzip.waitUntilExit()
        XCTAssertEqual(unzip.terminationStatus, 0)
        let payload = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: extraction, includingPropertiesForKeys: nil).first)
        let envelope = try TransportCodec.decode(AgentExportManifest.self, from: Data(contentsOf: payload.appendingPathComponent("export.json")))
        XCTAssertEqual(envelope.schemaVersion, 3)
        XCTAssertEqual(envelope.segments.first?.manifest, source)
        XCTAssertEqual(envelope.segments.first?.metadata, try AgentRecordingMetadata(manifest: source))
        if case .system = archiver,
           let path = ProcessInfo.processInfo.environment["WR_SYNTHETIC_METADATA_EXPORT_FIXTURE"] {
            try FileManager.default.copyItem(at: archive, to: URL(fileURLWithPath: path))
        }
    }
}
