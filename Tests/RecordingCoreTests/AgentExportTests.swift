import XCTest
@testable import RecordingCore

final class AgentExportTests: XCTestCase {
    private var directory: URL!
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AgentExportTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    private func seal(_ repository: RecordingRepository, sequence: Int, bytes: UInt8) throws -> SegmentManifest {
        let id = UUID()
        try Data(repeating: bytes, count: 1_024).write(to: repository.stagingURL(for: id))
        return try repository.sealSegment(stagedURL: repository.stagingURL(for: id), id: id,
            sessionID: UUID(), sequence: sequence, startedAt: instant, endedAt: instant.addingTimeInterval(60),
            sampleRate: 16_000, frameCount: 960_000)
    }

    func testArchiveContainsOnlySelectedAudioAndPreservesExactManifest() throws {
        try checkSelectedAudioAndManifest(using: .system)
    }

    func testArchiveContainsOnlySelectedAudioAndPreservesExactManifestWithoutSystemService() throws {
        try checkSelectedAudioAndManifest(using: .commandLine)
    }

    private func checkSelectedAudioAndManifest(using archiver: AgentExportTestArchive) throws {
        let repository = try RecordingRepository(root: directory.appendingPathComponent("repository"))
        let selected = try seal(repository, sequence: 4, bytes: 42)
        let unselected = try seal(repository, sequence: 5, bytes: 81)
        // Unselected audio must not be read or verified at all.
        try FileManager.default.removeItem(at: repository.audioURL(for: unselected))
        let archive = try archiver.createArchive(repository: repository, selectedIDs: [selected.id],
            destinationDirectory: directory.appendingPathComponent("exports"), now: instant)
        let extraction = directory.appendingPathComponent("extracted")
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", archive.path, "-d", extraction.path]
        try unzip.run(); unzip.waitUntilExit()
        XCTAssertEqual(unzip.terminationStatus, 0)
        let roots = try FileManager.default.contentsOfDirectory(at: extraction, includingPropertiesForKeys: nil)
        XCTAssertEqual(roots.count, 1)
        let payload = try XCTUnwrap(roots.first)
        let manifest = try TransportCodec.decode(AgentExportManifest.self,
            from: Data(contentsOf: payload.appendingPathComponent("export.json")))
        XCTAssertEqual(manifest.schemaVersion, 3)
        XCTAssertEqual(manifest.transcriptStatus, "not_generated")
        XCTAssertEqual(manifest.exportedAt, instant)
        XCTAssertEqual(manifest.segments.count, 1)
        XCTAssertEqual(manifest.segments.first?.manifest, selected)
        XCTAssertEqual(manifest.segments.first?.metadata, try AgentRecordingMetadata(manifest: selected))
        let audio = try FileManager.default.contentsOfDirectory(at: payload.appendingPathComponent("audio"), includingPropertiesForKeys: nil)
        XCTAssertEqual(audio.map(\.lastPathComponent), [selected.fileName])
        XCTAssertEqual(try Data(contentsOf: audio[0]), Data(repeating: 42, count: 1_024))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.audioURL(for: selected).path))
        XCTAssertEqual(try repository.manifests().count, 2)
        XCTAssertTrue(try repository.receivedSegmentIDs().isEmpty)
        // Keep a copy only when this test is explicitly asked for a synthetic
        // cross-language compatibility fixture. Never exports real recordings.
        if case .system = archiver,
           let path = ProcessInfo.processInfo.environment["WR_SYNTHETIC_EXPORT_FIXTURE"] {
            try FileManager.default.copyItem(at: archive, to: URL(fileURLWithPath: path))
        }
    }

    func testCorruptSelectedAudioIsRejectedWithoutAnArchiveOrSourceMutation() throws {
        let repository = try RecordingRepository(root: directory.appendingPathComponent("repository"))
        let selected = try seal(repository, sequence: 0, bytes: 42)
        let changed = Data(repeating: UInt8(11), count: 1_024)
        try changed.write(to: repository.audioURL(for: selected))
        let destination = directory.appendingPathComponent("exports")
        XCTAssertThrowsError(try AgentExportBuilder.createArchive(repository: repository,
            selectedIDs: [selected.id], destinationDirectory: destination))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
        XCTAssertEqual(try Data(contentsOf: repository.audioURL(for: selected)), changed)
        XCTAssertEqual(try repository.manifests(), [selected])
    }

    func testVersionThreeCarriesOnlySelectedHashBoundTranscriptAndMetadata() throws {
        try checkSelectedTranscriptAndMetadata(using: .system)
    }

    func testVersionThreeCarriesOnlySelectedHashBoundTranscriptAndMetadataWithoutSystemService() throws {
        try checkSelectedTranscriptAndMetadata(using: .commandLine)
    }

    private func checkSelectedTranscriptAndMetadata(using archiver: AgentExportTestArchive) throws {
        let repository = try RecordingRepository(root: directory.appendingPathComponent("repository"))
        let selected = try seal(repository, sequence: 0, bytes: 42)
        let unselected = try seal(repository, sequence: 1, bytes: 31)
        func transcript(_ source: SegmentManifest, text: String) -> SegmentTranscript {
            SegmentTranscript(segmentID: source.id, audioSHA256: source.sha256, locale: "zh-CN",
                              engine: "synthetic-test", createdAt: instant,
                              text: text, spans: [.init(start: 0, end: 1, text: text)])
        }
        let selectedText = transcript(selected, text: "允许导出的合成文字")
        let archive = try archiver.createArchive(repository: repository, selectedIDs: [selected.id],
            destinationDirectory: directory.appendingPathComponent("exports"), now: instant,
            transcripts: [selected.id: selectedText, unselected.id: transcript(unselected, text: "未选择的合成文字")])
        let extraction = directory.appendingPathComponent("extracted")
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", archive.path, "-d", extraction.path]
        try unzip.run(); unzip.waitUntilExit()
        XCTAssertEqual(unzip.terminationStatus, 0)
        let payload = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: extraction,
            includingPropertiesForKeys: nil).first)
        let data = try Data(contentsOf: payload.appendingPathComponent("export.json"))
        let envelope = try TransportCodec.decode(AgentExportManifest.self, from: data)
        XCTAssertEqual(envelope.schemaVersion, 3)
        XCTAssertEqual(envelope.transcriptStatus, "ready")
        XCTAssertEqual(envelope.segments.count, 1)
        XCTAssertEqual(envelope.segments[0].transcript, selectedText)
        XCTAssertEqual(envelope.segments[0].metadata?.timeZoneSource, "utc_fallback")
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("未选择的合成文字"))
    }

    func testArchiveWriterFailureRemovesPartialOutputAndAllowsRetry() throws {
        let repository = try RecordingRepository(root: directory.appendingPathComponent("repository"))
        let selected = try seal(repository, sequence: 0, bytes: 42)
        let destination = directory.appendingPathComponent("exports")
        let failure = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        var writerCalled = false
        XCTAssertThrowsError(try AgentExportBuilder.createArchive(repository: repository,
            selectedIDs: [selected.id], destinationDirectory: destination, archiveWriter: { _, result in
                writerCalled = true
                try Data("partial synthetic archive".utf8).write(to: result)
                throw failure
            })) { error in
                XCTAssertEqual((error as NSError).domain, failure.domain)
                XCTAssertEqual((error as NSError).code, failure.code)
            }
        XCTAssertTrue(writerCalled)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
        XCTAssertEqual(try Data(contentsOf: repository.audioURL(for: selected)), Data(repeating: 42, count: 1_024))
        XCTAssertEqual(try repository.manifests(), [selected])
        XCTAssertTrue(try repository.receivedSegmentIDs().isEmpty)

        let archive = try AgentExportBuilder.createArchive(repository: repository,
            selectedIDs: [selected.id], destinationDirectory: destination,
            archiveWriter: AgentExportTestArchive.writeZIP)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-tq", archive.path]
        try unzip.run(); unzip.waitUntilExit()
        XCTAssertEqual(unzip.terminationStatus, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [archive.lastPathComponent])
        XCTAssertEqual(try repository.manifests(), [selected])
    }

    func testArchiveWriterWithoutOutputIsRejectedAndStagingRemoved() throws {
        let repository = try RecordingRepository(root: directory.appendingPathComponent("repository"))
        let selected = try seal(repository, sequence: 0, bytes: 42)
        let destination = directory.appendingPathComponent("exports")
        XCTAssertThrowsError(try AgentExportBuilder.createArchive(repository: repository,
            selectedIDs: [selected.id], destinationDirectory: destination, archiveWriter: { _, _ in })) { error in
                guard case AgentExportError.archiveUnavailable = error else {
                    return XCTFail("Expected archiveUnavailable, got \(error)")
                }
            }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
        XCTAssertEqual(try Data(contentsOf: repository.audioURL(for: selected)), Data(repeating: 42, count: 1_024))
        XCTAssertEqual(try repository.manifests(), [selected])
    }

    func testTranscriptForDifferentAudioIsRejectedBeforeExport() throws {
        let repository = try RecordingRepository(root: directory.appendingPathComponent("repository"))
        let selected = try seal(repository, sequence: 0, bytes: 42)
        let wrong = SegmentTranscript(segmentID: selected.id, audioSHA256: String(repeating: "a", count: 64),
            locale: "zh-CN", engine: "synthetic-test", text: "与音频不匹配的合成文字", spans: [])
        let destination = directory.appendingPathComponent("exports")
        XCTAssertThrowsError(try AgentExportBuilder.createArchive(repository: repository, selectedIDs: [selected.id],
            destinationDirectory: destination, transcripts: [selected.id: wrong]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try repository.manifests(), [selected])
    }

    func testMissingSelectionFailsInsteadOfSilentlyExportingASubset() throws {
        let repository = try RecordingRepository(root: directory.appendingPathComponent("repository"))
        let selected = try seal(repository, sequence: 0, bytes: 42)
        XCTAssertThrowsError(try AgentExportBuilder.createArchive(repository: repository,
            selectedIDs: [selected.id, UUID()], destinationDirectory: directory.appendingPathComponent("exports")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("exports").path))
    }

    func testSelectedSymlinkIsRejectedEvenWhenTargetBytesMatch() throws {
        let repository = try RecordingRepository(root: directory.appendingPathComponent("repository"))
        let selected = try seal(repository, sequence: 0, bytes: 42)
        let source = repository.audioURL(for: selected)
        let outside = directory.appendingPathComponent("outside.caf")
        let payload = Data(repeating: UInt8(42), count: 1_024)
        try payload.write(to: outside)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
        let destination = directory.appendingPathComponent("exports")
        XCTAssertThrowsError(try AgentExportBuilder.createArchive(repository: repository,
            selectedIDs: [selected.id], destinationDirectory: destination))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])
        XCTAssertEqual(try Data(contentsOf: outside), payload)
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink)
    }
}
