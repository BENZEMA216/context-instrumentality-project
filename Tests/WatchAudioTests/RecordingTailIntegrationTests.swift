import AVFoundation
import Darwin
import XCTest
import RecordingCore
@testable import WatchAudio

/// Real AVAudioFile fixtures exercise the repository, tail recovery, and writer together.
/// These tests use private temporary directories and never start a microphone.
final class RecordingTailIntegrationTests: XCTestCase {
    private var root: URL!
    private var repository: RecordingRepository!
    private var writer: AudioSegmentWriter?
    private var observations: Observations!
    private let sampleRate: Double = 16_000

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        repository = try RecordingRepository(root: root, recoveryFailureHandling: .preserveAndReport)
        observations = Observations()
    }

    override func tearDownWithError() throws {
        writer?.disableInput()
        if writer != nil { drainWriter() }
        writer = nil
        repository = nil
        try FileManager.default.removeItem(at: root)
    }

    func testLoadRecoversActualFramesAndGapStartsAfterRecoveredAudio() throws {
        let frames: UInt32 = 48_037
        let draft = try makeTail(frames: frames, grouped: true)
        let original = try RecordingRepository.fingerprint(of: repository.stagingURL(for: draft.id))
        let writer = makeWriter()
        writer.load()
        drainWriter()

        let manifest = try onlyManifest(for: draft.id)
        XCTAssertEqual(manifest.frameCount, Int64(frames))
        XCTAssertEqual(manifest.sequence, draft.sequence)
        XCTAssertEqual(manifest.startedAt, draft.startedAt)
        XCTAssertEqual(manifest.endedAt.timeIntervalSince(draft.startedAt), Double(frames) / sampleRate, accuracy: 0.000_51)
        XCTAssertEqual(manifest.timeZoneIdentifier, "Asia/Shanghai")
        XCTAssertNotNil(draft.recordingGroup)
        XCTAssertEqual(manifest.recordingGroup, draft.recordingGroup)
        try assertAudio(manifest, expectedFrames: Int64(frames))
        let archived = try RecordingRepository.fingerprint(of: repository.preservedOriginalURL(for: draft.id))
        XCTAssertEqual(archived.sha256, original.sha256)
        XCTAssertEqual(archived.byteCount, original.byteCount)
        XCTAssertFalse(exists(repository.stagingURL(for: draft.id)))
        XCTAssertFalse(exists(repository.openSegmentURL(for: draft.id)))

        let session = try XCTUnwrap(repository.recordingInventory().sessions.first { $0.id == draft.sessionID })
        XCTAssertEqual(session.state, .interrupted)
        XCTAssertEqual(session.lastAudioAt, manifest.endedAt, "A stale heartbeat must not extend recovered audio")
        XCTAssertEqual(session.lastSealedAt, manifest.endedAt)
        XCTAssertNil(session.currentSegmentStartedAt)
        let gaps = try repository.events().filter { $0.sessionID == draft.sessionID && $0.kind == "recovered_unknown_interval" }
        XCTAssertEqual(gaps.count, 1)
        XCTAssertEqual(gaps.first?.intervalStart, manifest.endedAt)
        XCTAssertGreaterThan(try XCTUnwrap(gaps.first?.intervalEnd), manifest.endedAt)
        XCTAssertFalse(observations.statuses.contains { $0.session?.state == .recording })
        XCTAssertTrue(observations.failures.isEmpty)
    }

    func testLoadRecoversClosedCAFBeforeSealAndPreservesOriginal() throws {
        let frames: UInt32 = 40_019
        let draft = try makeTail(frames: frames, unclosedLength: false)
        let original = try RecordingRepository.fingerprint(of: repository.stagingURL(for: draft.id))
        let writer = makeWriter()
        writer.load()
        drainWriter()

        let manifest = try onlyManifest(for: draft.id)
        XCTAssertEqual(manifest.sessionID, draft.sessionID)
        XCTAssertEqual(manifest.sequence, draft.sequence)
        XCTAssertEqual(manifest.startedAt, draft.startedAt)
        XCTAssertEqual(manifest.endedAt.timeIntervalSince(draft.startedAt), Double(frames) / sampleRate, accuracy: 0.000_51)
        try assertAudio(manifest, expectedFrames: Int64(frames))
        let archived = try RecordingRepository.fingerprint(of: repository.preservedOriginalURL(for: draft.id))
        XCTAssertEqual(archived.sha256, original.sha256)
        XCTAssertEqual(archived.byteCount, original.byteCount)
        XCTAssertFalse(exists(repository.stagingURL(for: draft.id)))
        XCTAssertFalse(exists(repository.openSegmentURL(for: draft.id)))
        XCTAssertEqual(try repository.recordingInventory().sessions.first { $0.id == draft.sessionID }?.lastAudioAt,
                       manifest.endedAt)
        XCTAssertFalse(observations.statuses.contains { $0.session?.state == .recording })
        XCTAssertTrue(observations.failures.isEmpty)
    }

    func testRepeatedLoadIsIdempotentAndExplicitResumeUsesNextSequence() throws {
        let draft = try makeTail(frames: 32_003)
        let writer = makeWriter()
        writer.load()
        drainWriter()
        let recovered = try onlyManifest(for: draft.id)
        let original = try Data(contentsOf: repository.preservedOriginalURL(for: draft.id))
        let gapsBefore = try repository.events().filter { $0.kind == "recovered_unknown_interval" }.count

        writer.load()
        drainWriter()
        let report = try RecordingTailRecovery.recover(repository: repository)
        XCTAssertEqual(report.recoveredCount, 0)
        XCTAssertEqual(try onlyManifest(for: draft.id), recovered)
        XCTAssertEqual(try Data(contentsOf: repository.preservedOriginalURL(for: draft.id)), original)
        XCTAssertEqual(try repository.events().filter { $0.kind == "tail_recovered" }.count, 1)
        XCTAssertEqual(try repository.events().filter { $0.kind == "recovered_unknown_interval" }.count, gapsBefore)
        XCTAssertFalse(observations.statuses.contains { $0.session?.state == .recording })

        // load/recover must not silently reopen input or start a new segment.
        writer.receive(try pcm(frames: 8_000), at: timestamp())
        drainWriter()
        XCTAssertEqual(try repository.recordingInventory().manifests, [recovered])
        XCTAssertTrue(try repository.openAudioSegments().segments.isEmpty)

        try prepareWriter()
        writer.receive(try pcm(frames: 16_037), at: timestamp())
        finishWriter()
        let manifests = try repository.recordingInventory().manifests.filter { $0.sessionID == draft.sessionID }
            .sorted { $0.sequence < $1.sequence }
        XCTAssertEqual(manifests.map(\.sequence), [0, 1])
        XCTAssertEqual(manifests.map(\.frameCount), [32_003, 16_037])
        XCTAssertEqual(manifests.first, recovered)
        try assertAudio(try XCTUnwrap(manifests.last), expectedFrames: 16_037)
        XCTAssertTrue(try repository.openAudioSegments().segments.isEmpty)
        XCTAssertTrue(observations.failures.isEmpty)
    }

    func testDamagedAndUntrackedTailsDoNotBlockGoodRecoveryOrNewCapture() throws {
        let good = try makeTail(frames: 24_017)
        let brokenAudio = try makeTail(frames: 8_000)
        let brokenAudioBytes = Data("invalid CAF tail".utf8)
        try brokenAudioBytes.write(to: repository.stagingURL(for: brokenAudio.id))
        let brokenJournal = try makeTail(frames: 8_011)
        let brokenJournalBytes = Data("invalid open-segment journal".utf8)
        try brokenJournalBytes.write(to: repository.openSegmentURL(for: brokenJournal.id))
        let journalAudioBefore = try RecordingRepository.fingerprint(of: repository.stagingURL(for: brokenJournal.id))
        let legacyID = UUID()
        try writeCAF(at: repository.stagingURL(for: legacyID), frames: 8_019, unclosedLength: true)
        let legacyBefore = try RecordingRepository.fingerprint(of: repository.stagingURL(for: legacyID))

        let writer = makeWriter()
        writer.load()
        drainWriter()
        try assertAudio(onlyManifest(for: good.id), expectedFrames: 24_017)
        XCTAssertFalse(try repository.recordingInventory().manifests.contains { $0.id == brokenAudio.id || $0.id == brokenJournal.id || $0.id == legacyID })
        XCTAssertNotNil(observations.statuses.last?.recoveryMessage)
        try prepareWriter()
        writer.receive(try pcm(frames: 16_029), at: timestamp())
        finishWriter()
        let new = try XCTUnwrap(repository.recordingInventory().manifests.first { $0.id != good.id })
        XCTAssertFalse([good.sessionID, brokenAudio.sessionID, brokenJournal.sessionID].contains(new.sessionID))
        XCTAssertEqual(new.sequence, 0)
        try assertAudio(new, expectedFrames: 16_029)

        XCTAssertEqual(try Data(contentsOf: repository.stagingURL(for: brokenAudio.id)), brokenAudioBytes)
        XCTAssertEqual(try Data(contentsOf: repository.openSegmentURL(for: brokenJournal.id)), brokenJournalBytes)
        XCTAssertEqual(try RecordingRepository.fingerprint(of: repository.stagingURL(for: brokenJournal.id)).sha256, journalAudioBefore.sha256)
        XCTAssertEqual(try RecordingRepository.fingerprint(of: repository.stagingURL(for: legacyID)).sha256, legacyBefore.sha256)
        XCTAssertEqual(try repository.openAudioSegments().untrackedAudioCount, 1)
        XCTAssertFalse(exists(repository.openSegmentURL(for: new.id)))
        XCTAssertTrue(observations.failures.isEmpty)
    }

    func testCorruptHistoricalManifestAndSessionArePreservedWhileNewSessionRecords() throws {
        var old = try repository.createSession(at: Date().addingTimeInterval(-300))
        old.state = .ended
        old.endedAt = old.startedAt
        try repository.saveSession(old)
        let badManifest = root.appendingPathComponent("manifests/\(UUID().uuidString.lowercased()).json")
        let badSession = root.appendingPathComponent("sessions/\(UUID().uuidString.lowercased()).json")
        let manifestBytes = Data("unreadable historical manifest".utf8)
        let sessionBytes = Data("unreadable historical session".utf8)
        try manifestBytes.write(to: badManifest)
        try sessionBytes.write(to: badSession)
        let writer = makeWriter()
        writer.load()
        drainWriter()
        try prepareWriter()
        writer.receive(try pcm(frames: 16_043), at: timestamp())
        finishWriter()

        let inventory = try repository.recordingInventory()
        let manifest = try XCTUnwrap(inventory.manifests.first)
        XCTAssertEqual(inventory.manifests.count, 1)
        XCTAssertNotEqual(manifest.sessionID, old.id)
        XCTAssertEqual(manifest.sequence, 0)
        try assertAudio(manifest, expectedFrames: 16_043)
        XCTAssertEqual(try Data(contentsOf: badManifest), manifestBytes)
        XCTAssertEqual(try Data(contentsOf: badSession), sessionBytes)
        XCTAssertTrue(inventory.issues.contains { $0.fileName == "manifests/" + badManifest.lastPathComponent })
        XCTAssertTrue(inventory.issues.contains { $0.fileName == "sessions/" + badSession.lastPathComponent })
        XCTAssertTrue(observations.failures.isEmpty)
    }

    func testNormalWriterHasOpenJournalAndRemovesItAfterBoundaryAndFinish() throws {
        let writer = makeWriter()
        try prepareWriter()
        let origin = mach_absolute_time()
        writer.receive(try pcm(frames: 8_000), at: timestamp(from: origin))
        drainWriter()
        let open = try repository.openAudioSegments()
        let firstDraft = try XCTUnwrap(open.segments.first)
        XCTAssertEqual(open.segments.count, 1)
        XCTAssertEqual(firstDraft.sequence, 0)
        XCTAssertEqual(firstDraft.startedAt.timeIntervalSince(try XCTUnwrap(observations.statuses.last?.session?.currentSegmentStartedAt)), 0, accuracy: 0.000_51)
        XCTAssertTrue(exists(repository.openSegmentURL(for: firstDraft.id)))
        XCTAssertTrue(exists(repository.stagingURL(for: firstDraft.id)))

        writer.receive(try pcm(frames: 952_123, phase: 8_000), at: timestamp(offset: 0.5, from: origin))
        drainWriter()
        let boundary = try repository.openAudioSegments()
        XCTAssertFalse(exists(repository.openSegmentURL(for: firstDraft.id)))
        XCTAssertEqual(boundary.segments.map(\.sequence), [1])
        XCTAssertTrue(exists(repository.stagingURL(for: try XCTUnwrap(boundary.segments.first?.id))))
        finishWriter()

        let manifests = try repository.recordingInventory().manifests.sorted { $0.sequence < $1.sequence }
        XCTAssertEqual(manifests.map(\.frameCount), [960_000, 123])
        XCTAssertEqual(manifests.map(\.sequence), [0, 1])
        try assertAudio(try XCTUnwrap(manifests.first), expectedFrames: 960_000)
        try assertAudio(try XCTUnwrap(manifests.last), expectedFrames: 123, phase: 960_000)
        XCTAssertTrue(try repository.openAudioSegments().segments.isEmpty)
        XCTAssertTrue(try repository.openAudioSegments().issues.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("open-segments"), includingPropertiesForKeys: nil).isEmpty)
        XCTAssertTrue(observations.failures.isEmpty)
    }

    func testResidualSidecarAfterPhoneACKDoesNotResurrectPrunedAudio() throws {
        let draft = try makeTail(frames: 16_013, unclosedLength: false)
        let manifest = try repository.sealSegment(stagedURL: repository.stagingURL(for: draft.id),
            id: draft.id, sessionID: draft.sessionID, sequence: draft.sequence,
            startedAt: draft.startedAt, endedAt: draft.startedAt.addingTimeInterval(16_013 / sampleRate),
            sampleRate: sampleRate, frameCount: 16_013, timeZoneIdentifier: draft.timeZoneIdentifier)
        try repository.acknowledge(SegmentReceipt(segmentID: manifest.id, sha256: manifest.sha256, byteCount: manifest.byteCount))
        let acknowledgement = root.appendingPathComponent("acknowledgements/\(draft.id.uuidString.lowercased()).json")
        let ackBytes = try Data(contentsOf: acknowledgement)
        XCTAssertFalse(exists(repository.audioURL(for: manifest)))
        XCTAssertTrue(exists(repository.openSegmentURL(for: draft.id)))

        let writer = makeWriter()
        writer.load()
        drainWriter()
        XCTAssertEqual(try onlyManifest(for: draft.id), manifest)
        XCTAssertFalse(exists(repository.audioURL(for: manifest)))
        XCTAssertFalse(exists(repository.stagingURL(for: draft.id)))
        XCTAssertFalse(exists(repository.recoveryCandidateURL(for: draft.id)))
        XCTAssertFalse(exists(repository.openSegmentURL(for: draft.id)))
        XCTAssertEqual(try Data(contentsOf: acknowledgement), ackBytes)
        XCTAssertTrue(try repository.pendingSegments().isEmpty)
        XCTAssertEqual(try RecordingTailRecovery.recover(repository: repository).recoveredCount, 0)
        XCTAssertFalse(exists(repository.audioURL(for: manifest)))
        XCTAssertTrue(observations.failures.isEmpty)
    }

    func testLoadCompletesRecoveryAfterAudioCommitFaultWithSameIdentity() throws {
        try checkCommitFaultRecovery(at: .afterAudioCommit)
    }

    func testLoadCompletesRecoveryAfterManifestCommitFaultWithSameIdentity() throws {
        try checkCommitFaultRecovery(at: .afterManifestCommit)
    }

    func testWarmStartRecoversInterruptedTailCommitBeforeOpeningNextRecording() throws {
        let failure = OneShotCommitFault(.afterAudioCommit)
        repository = try RecordingRepository(root: root, faultInjector: { try failure.visit($0) },
                                             recoveryFailureHandling: .preserveAndReport)
        let writer = makeWriter()
        writer.load()
        drainWriter()
        try prepareWriter()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        buffer.frameLength = 16_000
        buffer.floatChannelData![0].update(repeating: 0.25, count: 16_000)
        writer.receive(buffer, at: AVAudioTime(hostTime: mach_absolute_time()))
        drainWriter()
        let openTail = try XCTUnwrap(repository.openAudioSegments().segments.first)
        finishWriter()
        XCTAssertTrue(failure.fired)
        XCTAssertEqual(observations.failures.count, 1)

        try prepareWriter()
        let recovered = try onlyManifest(for: openTail.id)
        XCTAssertEqual(recovered.frameCount, 16_000)
        XCTAssertFalse(exists(repository.openSegmentURL(for: openTail.id)))
        writer.receive(buffer, at: AVAudioTime(hostTime: mach_absolute_time()))
        finishWriter()
        let manifests = try repository.recordingInventory().manifests
        XCTAssertEqual(manifests.count, 2)
        XCTAssertEqual(manifests.reduce(Int64(0)) { $0 + $1.frameCount }, 32_000)
        XCTAssertEqual(observations.failures.count, 1)
    }

    private func checkCommitFaultRecovery(at point: RepositoryFaultPoint) throws {
        let draft = try makeTail(frames: 24_031)
        let original = try RecordingRepository.fingerprint(of: repository.stagingURL(for: draft.id))
        let failure = OneShotCommitFault(point)
        repository = try RecordingRepository(root: root, faultInjector: { try failure.visit($0) },
                                             recoveryFailureHandling: .preserveAndReport)
        let interrupted = try RecordingTailRecovery.recover(repository: repository)
        XCTAssertTrue(failure.fired, interrupted.message ?? "Recovery returned no diagnostic")
        let pending = root.appendingPathComponent("staging/\(draft.id.uuidString.lowercased()).pending.json")
        let frozen = try TransportCodec.decode(SegmentManifest.self, from: Data(contentsOf: pending))
        XCTAssertEqual(frozen.id, draft.id)
        XCTAssertTrue(exists(repository.openSegmentURL(for: draft.id)))
        XCTAssertEqual(try RecordingRepository.fingerprint(of: repository.stagingURL(for: draft.id)).sha256, original.sha256)

        let writer = makeWriter()
        writer.load()
        drainWriter()
        let committed = try onlyManifest(for: draft.id)
        XCTAssertEqual(committed, frozen)
        try assertAudio(committed, expectedFrames: 24_031)
        XCTAssertEqual(try RecordingRepository.fingerprint(of: repository.audioURL(for: committed)).sha256, frozen.sha256)
        XCTAssertEqual(try RecordingRepository.fingerprint(of: repository.preservedOriginalURL(for: draft.id)).sha256, original.sha256)
        XCTAssertFalse(exists(pending))
        XCTAssertFalse(exists(repository.openSegmentURL(for: draft.id)))
        writer.load()
        drainWriter()
        XCTAssertEqual(try onlyManifest(for: draft.id), frozen)
        XCTAssertEqual(try repository.recordingInventory().manifests.count, 1)
        XCTAssertTrue(observations.failures.isEmpty)
    }

    @discardableResult
    private func makeWriter() -> AudioSegmentWriter {
        let value = AudioSegmentWriter(repository: repository, root: root)
        let observations = observations!
        value.onStatus = { observations.status($0) }
        value.onFailure = { observations.failure($0) }
        writer = value
        return value
    }

    private func prepareWriter() throws {
        let writer = try XCTUnwrap(writer)
        let ready = expectation(description: "writer prepared")
        let result = PreparationResult()
        writer.prepare { value in result.set(value); ready.fulfill() }
        wait(for: [ready], timeout: 10)
        try XCTUnwrap(result.value).get()
        writer.enableInput()
    }

    private func finishWriter() {
        let finished = expectation(description: "writer finished")
        writer?.finish(state: .ended, detail: nil) { finished.fulfill() }
        wait(for: [finished], timeout: 10)
    }

    private func drainWriter() {
        let drained = expectation(description: "writer queue drained")
        writer?.inspectAudioFreshness { _, _ in drained.fulfill() }
        wait(for: [drained], timeout: 10)
    }

    private func makeTail(frames: UInt32, unclosedLength: Bool = true, grouped: Bool = false) throws -> OpenAudioSegment {
        var session = try repository.createSession(at: Date().addingTimeInterval(-300))
        if grouped {
            session.recordingGroup = RecordingGroup(startedAt: session.startedAt,
                timeZone: TimeZone(secondsFromGMT: 8 * 3600)!, firstSequence: 0)
        }
        let draft = OpenAudioSegment(id: UUID(), sessionID: session.id, sequence: 0,
            startedAt: session.startedAt, sampleRate: sampleRate, channelCount: 1,
            pcmFormat: .float32, interleaved: false, timeZoneIdentifier: "Asia/Shanghai",
            recordingGroup: session.recordingGroup)
        try repository.beginAudioSegment(draft)
        try writeCAF(at: repository.stagingURL(for: draft.id), frames: frames, unclosedLength: unclosedLength)
        session.state = .recording
        session.currentSegmentStartedAt = draft.startedAt
        // Deliberately stale evidence must not extend the recovered CAF's actual samples.
        session.lastAudioAt = draft.startedAt.addingTimeInterval(Double(frames) / sampleRate + 7)
        try repository.saveSession(session)
        return draft
    }

    private func writeCAF(at url: URL, frames: UInt32, unclosedLength: Bool) throws {
        let buffer = try pcm(frames: frames)
        let file = try AVAudioFile(forWriting: url, settings: buffer.format.settings,
            commonFormat: buffer.format.commonFormat, interleaved: buffer.format.isInterleaved)
        try file.write(from: buffer)
        file.close()
        guard unclosedLength else { return }
        var bytes = try Data(contentsOf: url)
        var offset = 8
        while offset + 12 <= bytes.count {
            let kind = String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
            let length = bytes[(offset + 4)..<(offset + 12)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            guard length <= UInt64(bytes.count - offset - 12) else {
                throw NSError(domain: "TailIntegrationFixture", code: 1)
            }
            if kind == "data" {
                XCTAssertGreaterThanOrEqual(length, 4)
                // A -1 data chunk extends to EOF. Remove any later metadata chunks
                // before simulating the unclosed header; do not reinterpret them as PCM.
                let end = offset + 12 + Int(length)
                bytes.removeSubrange(end..<bytes.count)
                bytes.replaceSubrange((offset + 4)..<(offset + 12), with: repeatElement(UInt8(0xFF), count: 8))
                try bytes.write(to: url)
                return
            }
            offset += 12 + Int(length)
        }
        throw NSError(domain: "TailIntegrationFixture", code: 2)
    }

    private func pcm(frames: UInt32, phase: Int = 0) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData?[0])
        for index in 0..<Int(frames) { samples[index] = sample(at: phase + index) }
        return buffer
    }

    private func sample(at index: Int) -> Float { Float(index % 97 - 48) / 128 }

    private func assertAudio(_ manifest: SegmentManifest, expectedFrames: Int64, phase: Int = 0) throws {
        XCTAssertEqual(manifest.frameCount, expectedFrames)
        let file = try AVAudioFile(forReading: repository.audioURL(for: manifest))
        defer { file.close() }
        XCTAssertEqual(file.length, expectedFrames)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096))
        var read = 0
        while file.framePosition < file.length {
            try file.read(into: buffer)
            XCTAssertGreaterThan(buffer.frameLength, 0)
            guard buffer.frameLength > 0 else { break }
            let samples = try XCTUnwrap(buffer.floatChannelData?[0])
            let matches = (0..<Int(buffer.frameLength)).allSatisfy { abs(samples[$0] - sample(at: phase + read + $0)) < 0.00001 }
            XCTAssertTrue(matches, "Recovered PCM values differ from the original synthetic samples")
            read += Int(buffer.frameLength)
        }
        XCTAssertEqual(Int64(read), expectedFrames)
        XCTAssertEqual(try RecordingRepository.fingerprint(of: repository.audioURL(for: manifest)).sha256, manifest.sha256)
    }

    private func onlyManifest(for id: UUID) throws -> SegmentManifest {
        let matching = try repository.recordingInventory().manifests.filter { $0.id == id }
        XCTAssertEqual(matching.count, 1, observations.statuses.last?.recoveryMessage ?? "Recovery returned no diagnostic")
        return try XCTUnwrap(matching.first)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func timestamp(offset: TimeInterval = 0, from origin: UInt64 = mach_absolute_time()) -> AVAudioTime {
        AVAudioTime(hostTime: origin + AVAudioTime.hostTime(forSeconds: offset))
    }

    private final class PreparationResult: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Result<Void, Error>?
        func set(_ value: Result<Void, Error>) { lock.lock(); defer { lock.unlock() }; result = value }
        var value: Result<Void, Error>? { lock.lock(); defer { lock.unlock() }; return result }
    }

    private final class Observations: @unchecked Sendable {
        private let lock = NSLock()
        private var savedStatuses: [WatchRecordingStatus] = []
        private var savedFailures: [String] = []
        func status(_ value: WatchRecordingStatus) { lock.lock(); defer { lock.unlock() }; savedStatuses.append(value) }
        func failure(_ value: String) { lock.lock(); defer { lock.unlock() }; savedFailures.append(value) }
        var statuses: [WatchRecordingStatus] { lock.lock(); defer { lock.unlock() }; return savedStatuses }
        var failures: [String] { lock.lock(); defer { lock.unlock() }; return savedFailures }
    }

    private final class OneShotCommitFault: @unchecked Sendable {
        private let point: RepositoryFaultPoint
        private(set) var fired = false
        init(_ point: RepositoryFaultPoint) { self.point = point }
        func visit(_ actual: RepositoryFaultPoint) throws {
            guard !fired else { return }
            switch (point, actual) {
            case (.afterAudioCommit, .afterAudioCommit), (.afterManifestCommit, .afterManifestCommit):
                fired = true
                throw RepositoryError.persistenceFailure("synthetic commit interruption")
            default: return
            }
        }
    }
}
