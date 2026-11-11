import XCTest
@testable import RecordingCore

final class TranscriptRepositoryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("TranscriptRepositoryTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func manifest(id: UUID = UUID(), hash: String = String(repeating: "a", count: 64)) -> SegmentManifest {
        SegmentManifest(id: id, sessionID: UUID(), sequence: 0,
                        startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                        endedAt: Date(timeIntervalSince1970: 1_800_000_060),
                        sampleRate: 16_000, frameCount: 960_000,
                        fileName: id.uuidString.lowercased() + ".caf", byteCount: 1_920_000, sha256: hash)
    }

    private func transcript(_ manifest: SegmentManifest) -> SegmentTranscript {
        SegmentTranscript(segmentID: manifest.id, audioSHA256: manifest.sha256, locale: "zh-CN",
                          engine: "synthetic-test", createdAt: Date(timeIntervalSince1970: 1_800_001_000),
                          text: "合成转写测试", spans: [.init(start: 0, end: 2, text: "合成转写测试")])
    }

    func testSaveSurvivesReopenAndDoesNotCreateAudioReceipts() throws {
        let source = manifest()
        let value = transcript(source)
        let store = try TranscriptRepository(root: root)
        XCTAssertNil(try store.transcript(for: source))
        try store.save(value, for: source)
        try store.save(value, for: source)
        XCTAssertEqual(try TranscriptRepository(root: root).transcript(for: source), value)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["transcripts"])
    }

    func testSaveIfAbsentKeepsEveryExistingValidVersionAndSurvivesReopen() throws {
        let source = manifest(), value = transcript(source)
        let store = try TranscriptRepository(root: root)
        XCTAssertTrue(try store.saveIfAbsent(value, for: source))
        let replacement = SegmentTranscript(segmentID: source.id, audioSHA256: source.sha256, locale: "zh-CN",
            engine: "synthetic-other-version", createdAt: value.createdAt.addingTimeInterval(60),
            text: "另一份合成文字，不能覆盖已有版本。", spans: [])
        XCTAssertFalse(try store.saveIfAbsent(replacement, for: source))
        XCTAssertFalse(try store.saveIfAbsent(value, for: source))
        XCTAssertEqual(try TranscriptRepository(root: root).transcript(for: source), value)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["transcripts"])
    }

    func testSaveIfAbsentRejectsDamagedChangedSourceAndEmptyResultsWithoutOverwriting() throws {
        let source = manifest(), value = transcript(source)
        let store = try TranscriptRepository(root: root)
        let target = root.appendingPathComponent("transcripts/" + source.id.uuidString.lowercased() + ".json")
        let damaged = Data("damaged derived text".utf8)
        try damaged.write(to: target)
        XCTAssertThrowsError(try store.saveIfAbsent(value, for: source))
        XCTAssertEqual(try Data(contentsOf: target), damaged)
        try FileManager.default.removeItem(at: target)
        let empty = SegmentTranscript(segmentID: source.id, audioSHA256: source.sha256, locale: "zh-CN",
            engine: "synthetic-no-speech", text: "", spans: [])
        XCTAssertThrowsError(try store.saveIfAbsent(empty, for: source))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        try store.save(value, for: source)
        let changed = manifest(id: source.id, hash: String(repeating: "b", count: 64))
        XCTAssertThrowsError(try store.saveIfAbsent(transcript(changed), for: changed))
        XCTAssertEqual(try store.transcript(for: source), value)
    }

    func testConcurrentSaveIfAbsentCommitsExactlyOneVersion() throws {
        let source = manifest(), store = try TranscriptRepository(root: root)
        let values = (0..<20).map { index in
            SegmentTranscript(segmentID: source.id, audioSHA256: source.sha256, locale: "zh-CN",
                engine: "synthetic-race", text: "合成并发版本 \(index)", spans: [])
        }
        let results = TranscriptSaveResults()
        DispatchQueue.concurrentPerform(iterations: values.count) { index in
            do { results.append(try store.saveIfAbsent(values[index], for: source)) }
            catch { results.recordFailure() }
        }
        XCTAssertEqual(results.failures, 0)
        XCTAssertEqual(results.saved, 1)
        XCTAssertTrue(values.contains(try XCTUnwrap(store.transcript(for: source))))
    }

    func testReadingChangedSourceFailsInsteadOfReturningStaleText() throws {
        let source = manifest()
        let store = try TranscriptRepository(root: root)
        try store.save(transcript(source), for: source)
        let changed = manifest(id: source.id, hash: String(repeating: "b", count: 64))
        XCTAssertThrowsError(try store.transcript(for: changed))
        XCTAssertThrowsError(try store.save(transcript(changed), for: changed))
        XCTAssertEqual(try store.transcript(for: source), transcript(source))
    }

    func testSelectedReadIgnoresDamagedUnselectedTranscript() throws {
        let selected = manifest()
        let unselected = manifest()
        let store = try TranscriptRepository(root: root)
        try store.save(transcript(selected), for: selected)
        let bad = root.appendingPathComponent("transcripts/" + unselected.id.uuidString.lowercased() + ".json")
        try Data("broken".utf8).write(to: bad)
        XCTAssertEqual(try store.transcripts(for: [selected]), [selected.id: transcript(selected)])
        XCTAssertThrowsError(try store.transcripts(for: [selected, unselected]))
    }

    func testSymlinkTranscriptCannotBeReadOrOverwritten() throws {
        let source = manifest()
        let store = try TranscriptRepository(root: root)
        let outside = root.appendingPathComponent("outside.json")
        let original = try TransportCodec.encode(transcript(source))
        try original.write(to: outside)
        let target = root.appendingPathComponent("transcripts/" + source.id.uuidString.lowercased() + ".json")
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        XCTAssertThrowsError(try store.transcript(for: source))
        XCTAssertThrowsError(try store.save(transcript(source), for: source))
        XCTAssertThrowsError(try store.saveIfAbsent(transcript(source), for: source))
        XCTAssertEqual(try Data(contentsOf: outside), original)
    }

    func testLibraryReadIsolatesCorruptionAndHashMismatchWithoutChangingStrictExport() throws {
        let healthy = manifest()
        let damaged = manifest()
        let stale = manifest()
        let absent = manifest()
        let store = try TranscriptRepository(root: root)
        try store.save(transcript(healthy), for: healthy)
        try store.save(transcript(stale), for: stale)
        let bad = root.appendingPathComponent("transcripts/" + damaged.id.uuidString.lowercased() + ".json")
        let corruptBytes = Data("broken".utf8)
        try corruptBytes.write(to: bad)
        let changed = manifest(id: stale.id, hash: String(repeating: "b", count: 64))
        let selection = [healthy, damaged, changed, absent]
        let result = store.availableTranscripts(for: selection)
        XCTAssertEqual(result.transcripts, [healthy.id: transcript(healthy)])
        XCTAssertEqual(Set(result.issues.keys), [damaged.id, stale.id])
        XCTAssertNil(result.issues[absent.id])
        XCTAssertThrowsError(try store.transcripts(for: selection))
        XCTAssertEqual(try Data(contentsOf: bad), corruptBytes)
        XCTAssertEqual(try store.transcript(for: stale), transcript(stale))
    }
}

private final class TranscriptSaveResults: @unchecked Sendable {
    private let lock = NSLock()
    private var savedCount = 0
    private var failureCount = 0
    var saved: Int { lock.lock(); defer { lock.unlock() }; return savedCount }
    var failures: Int { lock.lock(); defer { lock.unlock() }; return failureCount }
    func append(_ saved: Bool) { lock.lock(); defer { lock.unlock() }; if saved { savedCount += 1 } }
    func recordFailure() { lock.lock(); failureCount += 1; lock.unlock() }
}
