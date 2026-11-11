import XCTest
import Darwin
@testable import RecordingCore

final class RecordingMetadataSnapshotTests: XCTestCase {
    private var directory: URL!
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    private func fixture() throws -> (RecordingRepository, SegmentManifest, SegmentReceipt, RecordingEvent) {
        let watch = try RecordingRepository(root: directory.appendingPathComponent("watch"))
        let phone = try RecordingRepository(root: directory.appendingPathComponent("phone"))
        let id = UUID(), staged = watch.stagingURL(for: id)
        try Data(repeating: 0x61, count: 8192).write(to: staged)
        let manifest = try watch.sealSegment(stagedURL: staged, id: id, sessionID: UUID(), sequence: 0,
            startedAt: instant, endedAt: instant.addingTimeInterval(60), sampleRate: 16000, frameCount: 960000)
        let receipt = try phone.acceptIncomingFile(at: watch.audioURL(for: manifest), manifest: manifest)
        let event = RecordingEvent(kind: "fixture", detail: "synthetic metadata", timestamp: instant)
        try phone.appendEvent(event)
        return (phone, manifest, receipt, event)
    }

    private struct MetadataState: Equatable {
        let bytes: Data?
        let modified: Date?
        let inode: UInt64?
        let permissions: Int?
    }

    /// Inspect only fixture metadata, including inode and directory timestamps:
    /// rewriting identical JSON atomically must not pass as a read-only export.
    private func metadataState(_ repository: RecordingRepository) throws -> [String: MetadataState] {
        var values: [String: MetadataState] = [:]
        for name in ["sessions", "manifests", "receipts", "acknowledgements", "events"] {
            let folder = repository.root.appendingPathComponent(name)
            for url in [folder] + (try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                values[name + "/" + url.lastPathComponent] = MetadataState(
                    bytes: url == folder ? nil : try Data(contentsOf: url),
                    modified: attributes[.modificationDate] as? Date,
                    inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
                    permissions: (attributes[.posixPermissions] as? NSNumber)?.intValue)
            }
        }
        return values
    }

    private func assertSnapshot(_ repository: RecordingRepository, manifest: SegmentManifest,
                                receipt: SegmentReceipt, event: RecordingEvent,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let before = try metadataState(repository)
        let snapshot = try repository.metadataSnapshot()
        XCTAssertEqual(snapshot.manifests, [manifest], file: file, line: line)
        XCTAssertEqual(snapshot.receipts, [receipt], file: file, line: line)
        XCTAssertEqual(snapshot.events, [event], file: file, line: line)
        XCTAssertEqual(try metadataState(repository), before, "Metadata export rewrote stored state", file: file, line: line)
    }

    func testSnapshotDoesNotRequireExistingAudioAndDoesNotWeakenACKReplay() throws {
        let (phone, manifest, receipt, event) = try fixture()
        try FileManager.default.removeItem(at: phone.audioURL(for: manifest))
        try assertSnapshot(phone, manifest: manifest, receipt: receipt, event: event)
        XCTAssertThrowsError(try phone.receipts()) { XCTAssertEqual($0 as? RepositoryError, .missingAudio) }
    }

    func testSnapshotDoesNotOpenUnreadableAudio() throws {
        let (phone, manifest, receipt, event) = try fixture()
        let audio = phone.audioURL(for: manifest)
        let permissions = try FileManager.default.attributesOfItem(atPath: audio.path)[.posixPermissions]!
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: audio.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: audio.path) }
        // This is a real unreadable fixture, not a mocked file reader.
        XCTAssertThrowsError(try Data(contentsOf: audio))
        try assertSnapshot(phone, manifest: manifest, receipt: receipt, event: event)
    }

    func testSnapshotDoesNotHashChangedAudioAndDoesNotWeakenACKReplay() throws {
        let (phone, manifest, receipt, event) = try fixture()
        // Same length makes this distinguish hashing from a cheap size check.
        let changed = Data(repeating: 0x62, count: Int(manifest.byteCount))
        try changed.write(to: phone.audioURL(for: manifest))
        try assertSnapshot(phone, manifest: manifest, receipt: receipt, event: event)
        XCTAssertEqual(try Data(contentsOf: phone.audioURL(for: manifest)), changed)
        XCTAssertThrowsError(try phone.receipts()) { XCTAssertEqual($0 as? RepositoryError, .checksumMismatch) }
    }

    func testSnapshotWorksWhenMetadataCannotBeWritten() throws {
        let (phone, manifest, receipt, event) = try fixture()
        var permissions: [(URL, Any)] = []
        for name in ["manifests", "receipts", "events"] {
            let folder = phone.root.appendingPathComponent(name)
            for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                permissions.append((url, try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]!))
                try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: url.path)
            }
            permissions.append((folder, try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions]!))
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder.path)
        }
        defer { for (url, value) in permissions.reversed() { try? FileManager.default.setAttributes([.posixPermissions: value], ofItemAtPath: url.path) } }
        try assertSnapshot(phone, manifest: manifest, receipt: receipt, event: event)
    }

    func testCorruptMetadataRejectsEntireSnapshotWithoutRepair() throws {
        let (phone, manifest, _, _) = try fixture()
        let path = phone.root.appendingPathComponent("manifests/" + manifest.id.uuidString.lowercased() + ".json")
        try Data("{broken".utf8).write(to: path)
        let before = try metadataState(phone)
        XCTAssertThrowsError(try phone.metadataSnapshot())
        XCTAssertEqual(try metadataState(phone), before)
    }

    func testMismatchingReceiptRejectsEntireSnapshotWithoutRepair() throws {
        let (phone, manifest, receipt, _) = try fixture()
        let bad = SegmentReceipt(segmentID: receipt.segmentID, sha256: String(repeating: "0", count: 64),
                                 byteCount: receipt.byteCount, receivedAt: receipt.receivedAt)
        try TransportCodec.encode(bad).write(to: phone.root.appendingPathComponent("receipts/" + manifest.id.uuidString.lowercased() + ".json"))
        let before = try metadataState(phone)
        XCTAssertThrowsError(try phone.metadataSnapshot()) { XCTAssertEqual($0 as? RepositoryError, .receiptMismatch) }
        XCTAssertEqual(try metadataState(phone), before)
    }

    func testOrphanReceiptIsRejectedInsteadOfSilentlyOmitted() throws {
        let (phone, manifest, _, _) = try fixture()
        try FileManager.default.removeItem(at: phone.root.appendingPathComponent("manifests/" + manifest.id.uuidString.lowercased() + ".json"))
        let before = try metadataState(phone)
        XCTAssertThrowsError(try phone.metadataSnapshot()) { XCTAssertEqual($0 as? RepositoryError, .receiptMismatch) }
        XCTAssertEqual(try metadataState(phone), before)
    }

    func testIdentityBearingFilenameMustMatchDecodedMetadata() throws {
        let (phone, manifest, _, _) = try fixture()
        let original = phone.root.appendingPathComponent("manifests/" + manifest.id.uuidString.lowercased() + ".json")
        try FileManager.default.moveItem(at: original, to: original.deletingLastPathComponent().appendingPathComponent(UUID().uuidString.lowercased() + ".json"))
        let before = try metadataState(phone)
        XCTAssertThrowsError(try phone.metadataSnapshot()) {
            XCTAssertEqual($0 as? RepositoryError, .invalidManifest("元数据文件名与标识不一致"))
        }
        XCTAssertEqual(try metadataState(phone), before)
    }

    func testMetadataAliasCannotRedirectSnapshotToAudio() throws {
        let (phone, manifest, _, _) = try fixture()
        let path = phone.root.appendingPathComponent("manifests/" + manifest.id.uuidString.lowercased() + ".json")
        try FileManager.default.removeItem(at: path)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: phone.audioURL(for: manifest))
        XCTAssertThrowsError(try phone.metadataSnapshot())
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: path.path), phone.audioURL(for: manifest).path)
    }

    func testMetadataFIFOIsRejectedWithoutWaitingForAWriter() throws {
        let (phone, manifest, _, _) = try fixture()
        let path = phone.root.appendingPathComponent("receipts/" + manifest.id.uuidString.lowercased() + ".json")
        try FileManager.default.removeItem(at: path)
        XCTAssertEqual(Darwin.mkfifo(path.path, 0o600), 0)
        let finished = expectation(description: "metadata FIFO rejected without blocking")
        DispatchQueue.global().async {
            do {
                _ = try phone.metadataSnapshot()
                XCTFail("A FIFO was accepted as metadata")
            } catch {
                XCTAssertEqual(error as? RepositoryError, .invalidManifest("诊断元数据不是独立普通文件"))
            }
            finished.fulfill()
        }
        let result = XCTWaiter.wait(for: [finished], timeout: 1)
        if result != .completed {
            // A regression must fail promptly rather than leave a blocked reader.
            let writer = Darwin.open(path.path, O_WRONLY | O_NONBLOCK)
            if writer >= 0 { Darwin.close(writer) }
        }
        XCTAssertEqual(result, .completed)
    }

    func testMetadataLargerThanOneMiBIsRejectedWithoutRewriting() throws {
        let (phone, manifest, _, _) = try fixture()
        let path = phone.root.appendingPathComponent("receipts/" + manifest.id.uuidString.lowercased() + ".json")
        var bytes = try Data(contentsOf: path)
        bytes.append(Data(repeating: 0x20, count: 1_048_577 - bytes.count))
        try bytes.write(to: path)
        let before = try metadataState(phone)
        XCTAssertThrowsError(try phone.metadataSnapshot()) {
            XCTAssertEqual($0 as? RepositoryError, .invalidManifest("诊断元数据文件超过大小限制或为空"))
        }
        XCTAssertEqual(try metadataState(phone), before)
    }

    func testMetadataAtOneMiBBoundaryCanStillBeRead() throws {
        let (phone, manifest, receipt, event) = try fixture()
        let path = phone.root.appendingPathComponent("receipts/" + manifest.id.uuidString.lowercased() + ".json")
        var bytes = try Data(contentsOf: path)
        bytes.append(Data(repeating: 0x20, count: 1_048_576 - bytes.count))
        try bytes.write(to: path)
        try assertSnapshot(phone, manifest: manifest, receipt: receipt, event: event)
    }
}
