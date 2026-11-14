import AVFoundation
import Darwin
import XCTest
import RecordingCore
@testable import WatchAudio

/// Real CAF writes in an isolated temporary repository; no microphone or device access.
final class RecordingSyncIsolationTests: XCTestCase {
    private var root: URL!
    private var repository: RecordingRepository!
    private var writer: AudioSegmentWriter!
    private var observations: Observations!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        repository = try RecordingRepository(root: root)
        observations = Observations()
        writer = AudioSegmentWriter(repository: repository, root: root)
        let observations = observations!
        writer.onStatus = { observations.status($0) }
        writer.onFailure = { observations.failure($0) }
        writer.onWarning = { observations.warning($0) }
    }

    override func tearDownWithError() throws {
        // Wait for the final coalesced sync observation before removing the fixture.
        if let writer {
            let revision = observations.statuses.last?.revision ?? 0
            writer.refreshStatus()
            _ = try waitForStatus(after: revision) { $0.pendingCountIsKnown }
        }
        writer = nil
        repository = nil
        try FileManager.default.removeItem(at: root)
    }

    func testCorruptHistoricalACKDoesNotStopNewSegmentsOrTail() throws {
        let historical = try seedHistoricalRecording()
        let ack = root.appendingPathComponent("acknowledgements/\(historical.id.uuidString.lowercased()).json")
        try Data("broken acknowledgement".utf8).write(to: ack)
        writer.load()
        let initial = try waitForStatus { !$0.pendingCountIsKnown && $0.syncWarning != nil }
        XCTAssertEqual(initial.pendingCount, 0) // Explicitly unknown; not a zero-count success.
        XCTAssertFalse(initial.snapshot.pendingCountIsKnown)
        XCTAssertNil(initial.detail)

        try prepare()
        let origin = mach_absolute_time()
        writer.receive(try pcm(frames: 976_000), at: timestamp(from: origin))
        let first = try waitForStatus { $0.session?.state == .recording && $0.effectiveDuration >= 61 && $0.syncWarning != nil }
        writer.receive(try pcm(frames: 980_000), at: timestamp(offset: 61, from: origin))
        let second = try waitForStatus(after: first.revision) { $0.session?.state == .recording && $0.effectiveDuration >= 122.25 }
        XCTAssertFalse(second.pendingCountIsKnown)
        XCTAssertNil(second.detail)
        finish()

        let new = try repository.manifests().filter { $0.sessionID != historical.sessionID }.sorted { $0.sequence < $1.sequence }
        XCTAssertEqual(new.map(\.frameCount), [960_000, 960_000, 36_000])
        XCTAssertEqual(new.map(\.sequence), [0, 1, 2])
        try assertAudio(new, expectedFrames: 1_956_000)
        XCTAssertTrue(observations.failures.isEmpty)

        let revision = observations.statuses.last?.revision ?? 0
        try FileManager.default.removeItem(at: ack)
        writer.refreshStatus()
        let recovered = try waitForStatus(after: revision) { $0.pendingCountIsKnown && $0.syncWarning == nil }
        XCTAssertEqual(recovered.pendingCount, 4)
        XCTAssertTrue(recovered.snapshot.pendingCountIsKnown)
        XCTAssertEqual(recovered.session?.state, .ended)
        XCTAssertTrue(observations.warningValues.contains { $0 != nil })
        let clearedWarning: String? = try XCTUnwrap(observations.warningValues.last)
        XCTAssertNil(clearedWarning)
    }

    func testMissingHistoricalAudioWarnsThenRecoversWhileNewAudioContinues() throws {
        let historical = try seedHistoricalRecording()
        let audio = repository.audioURL(for: historical)
        let held = root.appendingPathComponent("held-historical.caf")
        try FileManager.default.moveItem(at: audio, to: held)
        try prepare()
        _ = try waitForStatus { !$0.pendingCountIsKnown && $0.syncWarning != nil }
        let origin = mach_absolute_time()
        writer.receive(try pcm(frames: 976_000), at: timestamp(from: origin))
        let before = try waitForStatus { $0.session?.state == .recording && $0.effectiveDuration >= 61 }

        try FileManager.default.moveItem(at: held, to: audio)
        writer.refreshStatus()
        let recovered = try waitForStatus(after: before.revision) { $0.pendingCountIsKnown && $0.syncWarning == nil }
        XCTAssertEqual(recovered.pendingCount, 2)
        XCTAssertEqual(recovered.session?.state, .recording)
        XCTAssertNil(recovered.detail)
        writer.receive(try pcm(frames: 16_000), at: timestamp(offset: 61, from: origin))
        finish()
        let new = try repository.manifests().filter { $0.sessionID != historical.sessionID }.sorted { $0.sequence < $1.sequence }
        XCTAssertEqual(new.map(\.frameCount), [960_000, 32_000])
        try assertAudio(new, expectedFrames: 992_000)
        XCTAssertTrue(observations.failures.isEmpty)
    }

    func testKnownOnlyRefreshPreservesRecordingTimestampAndCount() throws {
        try prepare()
        writer.receive(try pcm(frames: 16_000), at: timestamp(from: mach_absolute_time()))
        let known = try waitForStatus {
            $0.session?.state == .recording && $0.session?.lastAudioAt != nil && $0.pendingCountIsKnown
        }
        XCTAssertEqual(known.pendingCount, 0)
        writer.refreshStatus()
        let unknown = try waitForStatus(after: known.revision) { !$0.pendingCountIsKnown }
        let refreshed = try waitForStatus(after: unknown.revision) { $0.pendingCountIsKnown }
        var cachedSnapshot = known.snapshot
        cachedSnapshot.pendingCountIsKnown = false
        XCTAssertEqual(unknown.snapshot, cachedSnapshot,
            "A count refresh must emit unknown provenance even when audio time and cached numeric count are unchanged.")
        XCTAssertEqual(refreshed.snapshot, known.snapshot,
            "The verified result must restore only count provenance without manufacturing newer audio evidence.")
        XCTAssertEqual(refreshed.pendingCount, 0)
        XCTAssertTrue(observations.failures.isEmpty)
        finish()
    }

    func testFailedRefreshRetainsPreviousCountButMarksItUnknown() throws {
        let historical = try seedHistoricalRecording()
        writer.load()
        let known = try waitForStatus { $0.pendingCountIsKnown && $0.pendingCount == 1 }
        let audio = repository.audioURL(for: historical)
        let held = root.appendingPathComponent("held-historical.caf")
        try FileManager.default.moveItem(at: audio, to: held)
        writer.refreshStatus()
        let unknown = try waitForStatus(after: known.revision) { !$0.pendingCountIsKnown && $0.syncWarning != nil }
        XCTAssertEqual(unknown.pendingCount, 1)
        XCTAssertFalse(unknown.snapshot.pendingCountIsKnown)
        XCTAssertEqual(unknown.snapshot.pendingCount, 1)
        XCTAssertEqual(unknown.session?.state, .ended)
        XCTAssertNil(unknown.detail)
        XCTAssertTrue(observations.failures.isEmpty)
        try FileManager.default.moveItem(at: held, to: audio)
        writer.retrySyncStatusIfNeeded()
        _ = try waitForStatus(after: unknown.revision) { $0.pendingCountIsKnown && $0.syncWarning == nil }
    }

    func testDiagnosticLogFailureIsNonfatalAndClearsAfterSuccessfulLog() throws {
        try prepare()
        let origin = mach_absolute_time()
        writer.receive(try pcm(frames: 16_000), at: timestamp(from: origin))
        let recording = try waitForStatus { $0.session?.state == .recording }
        let events = root.appendingPathComponent("events")
        let held = root.appendingPathComponent("held-events")
        try FileManager.default.moveItem(at: events, to: held)
        try Data("blocks diagnostic directory".utf8).write(to: events)
        writer.log(kind: "sync_diagnostic_probe", detail: "synthetic")
        let warning = try waitForStatus(after: recording.revision) { $0.syncWarning?.contains("诊断日志") == true }
        XCTAssertEqual(warning.session?.state, .recording)
        XCTAssertNil(warning.detail)
        XCTAssertTrue(observations.failures.isEmpty)
        // Existing open audio and session updates remain writable during the warning.
        writer.receive(try pcm(frames: 16_000), at: timestamp(offset: 1, from: origin))
        _ = try waitForStatus(after: warning.revision) { $0.effectiveDuration >= 2 }
        try FileManager.default.removeItem(at: events)
        try FileManager.default.moveItem(at: held, to: events)
        writer.log(kind: "sync_diagnostic_probe", detail: "restored")
        _ = try waitForStatus(after: warning.revision) { $0.syncWarning == nil }
        finish()
        try assertAudio(repository.manifests(), expectedFrames: 32_000)
        XCTAssertTrue(observations.failures.isEmpty)
    }

    func testCriticalCapturePersistenceFailureStillStopsInputAndKeepsItsDetail() throws {
        try prepare()
        let sessions = root.appendingPathComponent("sessions")
        let held = root.appendingPathComponent("held-sessions")
        try FileManager.default.moveItem(at: sessions, to: held)
        try Data("blocks critical session persistence".utf8).write(to: sessions)
        let origin = mach_absolute_time()
        writer.receive(try pcm(frames: 16_000), at: timestamp(from: origin))
        let failed = expectation(for: NSPredicate { [observations] _, _ in !observations!.failures.isEmpty }, evaluatedWith: nil)
        wait(for: [failed], timeout: 10)
        let failure = try XCTUnwrap(observations.failures.first)
        try FileManager.default.removeItem(at: sessions)
        try FileManager.default.moveItem(at: held, to: sessions)
        writer.refreshStatus()
        let checked = try waitForStatus { $0.pendingCountIsKnown && $0.detail == failure }
        XCTAssertNil(checked.syncWarning)
        writer.receive(try pcm(frames: 16_000), at: timestamp(offset: 1, from: origin))
        let drained = expectation(description: "writer queue drained after rejected input")
        writer.inspectAudioFreshness { _, _ in drained.fulfill() }
        wait(for: [drained], timeout: 10)
        XCTAssertEqual(observations.failures.count, 1)
        XCTAssertEqual(try repository.manifests().count, 0)
        finish(.failed, detail: failure)
        XCTAssertEqual(try repository.manifests().count, 0)
    }

    func testSlowPendingScanDoesNotBlockAudioAndDiscardsSupersededCount() throws {
        let started = expectation(description: "pending reader captured old zero count")
        let probe = PendingReadProbe(repository: repository, firstReadStarted: started)
        writer = AudioSegmentWriter(repository: repository, root: root, pendingCountProvider: { try probe.read() })
        let observed = observations!
        writer.onStatus = { observed.status($0) }
        writer.onFailure = { observed.failure($0) }
        writer.onWarning = { observed.warning($0) }
        defer { probe.release() }
        try prepare()
        wait(for: [started], timeout: 10)
        writer.receive(try pcm(frames: 976_000), at: timestamp(from: mach_absolute_time()))
        for _ in 0..<5 { writer.refreshStatus() }
        for _ in 0..<5 { writer.retrySyncStatusIfNeeded() }
        let drained = expectation(description: "audio writing progresses while sync scan is blocked")
        writer.inspectAudioFreshness { _, _ in drained.fulfill() }
        wait(for: [drained], timeout: 5)
        let whileBlocked = try XCTUnwrap(observations.statuses.last)
        XCTAssertEqual(whileBlocked.session?.state, .recording)
        XCTAssertEqual(whileBlocked.effectiveDuration, 61, accuracy: 0.0001)
        XCTAssertEqual(whileBlocked.sealedCount, 1)
        XCTAssertFalse(whileBlocked.pendingCountIsKnown)
        XCTAssertFalse(whileBlocked.snapshot.pendingCountIsKnown)
        XCTAssertEqual(probe.reads, 1)

        probe.release()
        _ = try waitForStatus(after: whileBlocked.revision) { $0.pendingCountIsKnown && $0.pendingCount == 1 }
        XCTAssertEqual(probe.reads, 2, "overlapping refreshes must coalesce into one follow-up scan")
        XCTAssertFalse(observations.statuses.contains { $0.revision > whileBlocked.revision && $0.pendingCountIsKnown && $0.pendingCount == 0 })
        XCTAssertTrue(observations.failures.isEmpty)
        finish()
        try assertAudio(repository.manifests(), expectedFrames: 976_000)
    }

    func testPriorityBoundaryFailureKeepsAudioCapturingAndFreshStateUnknown() throws {
        repository = try RecordingRepository(root: root, faultInjector: { point in
            if case .beforeFreshCaptureCommit = point { throw RepositoryError.persistenceFailure("synthetic priority boundary failure") }
        })
        writer = AudioSegmentWriter(repository: repository, root: root)
        let observations = observations!
        writer.onStatus = { observations.status($0) }
        writer.onFailure = { observations.failure($0) }
        writer.onWarning = { observations.warning($0) }
        try prepare()
        let origin = mach_absolute_time()
        writer.receive(try pcm(frames: 976_000), at: timestamp(from: origin))
        _ = try waitForStatus { $0.session?.state == .recording && $0.effectiveDuration >= 61 && $0.syncWarning != nil }
        finish(.paused)
        let manifests = try repository.manifests().sorted { $0.sequence < $1.sequence }
        XCTAssertEqual(manifests.map(\.frameCount), [960_000, 16_000])
        try assertAudio(manifests, expectedFrames: 976_000)
        XCTAssertTrue(observations.failures.isEmpty, "A scheduling metadata failure cannot stop the microphone writer")
        XCTAssertThrowsError(try repository.freshTransferSnapshot())
        for manifest in manifests {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("staging/" + manifest.id.uuidString.lowercased() + ".pending.json").path))
        }
        writer.log(kind: "synthetic_telemetry", detail: "diagnostic success cannot clear priority warning")
        _ = try waitForStatus { $0.session?.state == .paused && $0.syncWarning != nil }
    }

    func testPauseDrainsTailIntoFreshFIFOBeforeClosingCapture() throws {
        try prepare()
        writer.receive(try pcm(frames: 976_000), at: timestamp(from: mach_absolute_time()))
        finish(.paused)
        let manifests = try repository.manifests().sorted { $0.sequence < $1.sequence }
        XCTAssertEqual(manifests.map(\.frameCount), [960_000, 16_000])
        let first = try repository.freshTransferSnapshot()
        XCTAssertFalse(first.captureOpen)
        XCTAssertEqual(first.unresolvedOpenCount, 0)
        XCTAssertEqual(first.head, manifests[0])
        XCTAssertEqual(first.remainingCount, 2)
        for manifest in manifests {
            try repository.acknowledge(SegmentReceipt(segmentID: manifest.id, sha256: manifest.sha256, byteCount: manifest.byteCount))
        }
        XCTAssertFalse(try repository.freshTransferSnapshot().blocksHistory)
        XCTAssertTrue(observations.failures.isEmpty)
    }

    func testAutomaticWriterResumeRetainsEpochAndEarlierFreshTail() throws {
        try prepare()
        writer.receive(try pcm(frames: 16_000), at: timestamp(from: mach_absolute_time()))
        finish(.interrupted, priorityCaptureContinues: true)
        let first = try repository.freshTransferSnapshot()
        XCTAssertTrue(first.captureOpen)
        let firstManifest = try XCTUnwrap(first.head)
        try prepare(startNewPriorityEpoch: false)
        writer.receive(try pcm(frames: 16_000), at: timestamp(from: mach_absolute_time()))
        finish(.paused)
        XCTAssertEqual(try repository.freshTransferSnapshot().head, firstManifest)
        try repository.acknowledge(SegmentReceipt(segmentID: firstManifest.id, sha256: firstManifest.sha256, byteCount: firstManifest.byteCount))
        let second = try repository.freshTransferSnapshot()
        XCTAssertNotEqual(second.head?.id, firstManifest.id)
        XCTAssertEqual(second.headEpochID, first.headEpochID)
        XCTAssertFalse(second.captureOpen)
        XCTAssertTrue(observations.failures.isEmpty)
    }

    private func prepare(startNewPriorityEpoch: Bool = true) throws {
        let ready = expectation(description: "writer prepared")
        writer.prepare(startNewPriorityEpoch: startNewPriorityEpoch) { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            ready.fulfill()
        }
        wait(for: [ready], timeout: 10)
        writer.enableInput()
    }

    private func finish(_ state: CaptureState = .ended, detail: String? = nil,
                        priorityCaptureContinues: Bool = false) {
        let done = expectation(description: "writer drained and sealed")
        writer.finish(state: state, detail: detail, priorityCaptureContinues: priorityCaptureContinues) { done.fulfill() }
        wait(for: [done], timeout: 10)
    }

    private func waitForStatus(after revision: UInt64 = 0,
                               where predicate: @escaping (WatchRecordingStatus) -> Bool) throws -> WatchRecordingStatus {
        let match = expectation(for: NSPredicate { [observations] _, _ in
            observations!.statuses.contains { $0.revision > revision && predicate($0) }
        }, evaluatedWith: nil)
        wait(for: [match], timeout: 10)
        return try XCTUnwrap(observations.statuses.last { $0.revision > revision && predicate($0) })
    }

    private func seedHistoricalRecording() throws -> SegmentManifest {
        var session = try repository.createSession(at: Date().addingTimeInterval(-120))
        let id = UUID(), buffer = try pcm(frames: 16_000)
        let file = try AVAudioFile(forWriting: repository.stagingURL(for: id), settings: buffer.format.settings,
                                   commonFormat: buffer.format.commonFormat, interleaved: buffer.format.isInterleaved)
        try file.write(from: buffer)
        file.close()
        let manifest = try repository.sealSegment(stagedURL: repository.stagingURL(for: id), id: id,
            sessionID: session.id, sequence: 0, startedAt: session.startedAt,
            endedAt: session.startedAt.addingTimeInterval(1), sampleRate: 16_000, frameCount: 16_000)
        session.state = .ended
        session.endedAt = manifest.endedAt
        try repository.saveSession(session)
        return manifest
    }

    private func pcm(frames: UInt32) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        try XCTUnwrap(buffer.floatChannelData?[0]).initialize(repeating: 0.25, count: Int(frames))
        return buffer
    }

    private func timestamp(offset: TimeInterval = 0, from origin: UInt64) -> AVAudioTime {
        AVAudioTime(hostTime: origin + AVAudioTime.hostTime(forSeconds: offset))
    }

    private func assertAudio(_ manifests: [SegmentManifest], expectedFrames: Int64) throws {
        XCTAssertEqual(manifests.reduce(Int64(0)) { $0 + $1.frameCount }, expectedFrames)
        for manifest in manifests {
            let file = try AVAudioFile(forReading: repository.audioURL(for: manifest))
            XCTAssertEqual(file.length, manifest.frameCount)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096))
            var read: Int64 = 0
            while file.framePosition < file.length {
                try file.read(into: buffer)
                XCTAssertGreaterThan(buffer.frameLength, 0)
                guard buffer.frameLength > 0 else { break }
                let samples = try XCTUnwrap(buffer.floatChannelData?[0])
                XCTAssertTrue(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength))
                    .allSatisfy { abs($0 - 0.25) < 0.00001 })
                read += Int64(buffer.frameLength)
            }
            XCTAssertEqual(read, manifest.frameCount)
            XCTAssertEqual(try RecordingRepository.fingerprint(of: repository.audioURL(for: manifest)).sha256, manifest.sha256)
        }
    }

    private final class Observations: @unchecked Sendable {
        private let lock = NSLock()
        private var savedStatuses: [WatchRecordingStatus] = []
        private var savedFailures: [String] = []
        private var savedWarnings: [String?] = []
        func status(_ value: WatchRecordingStatus) { lock.lock(); defer { lock.unlock() }; savedStatuses.append(value) }
        func failure(_ value: String) { lock.lock(); defer { lock.unlock() }; savedFailures.append(value) }
        func warning(_ value: String?) { lock.lock(); defer { lock.unlock() }; savedWarnings.append(value) }
        var statuses: [WatchRecordingStatus] { lock.lock(); defer { lock.unlock() }; return savedStatuses }
        var failures: [String] { lock.lock(); defer { lock.unlock() }; return savedFailures }
        var warningValues: [String?] { lock.lock(); defer { lock.unlock() }; return savedWarnings }
    }

    private final class PendingReadProbe: @unchecked Sendable {
        private let repository: RecordingRepository
        private let firstReadStarted: XCTestExpectation
        private let gate = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var count = 0
        init(repository: RecordingRepository, firstReadStarted: XCTestExpectation) {
            self.repository = repository
            self.firstReadStarted = firstReadStarted
        }
        func read() throws -> Int {
            let result = try repository.pendingSegments().count
            lock.lock()
            count += 1
            let first = count == 1
            lock.unlock()
            if first {
                firstReadStarted.fulfill()
                _ = gate.wait(timeout: .now() + 15)
            }
            return result
        }
        func release() { gate.signal() }
        var reads: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
}
