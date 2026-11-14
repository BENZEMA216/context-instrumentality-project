import AVFoundation
import Darwin
import XCTest
import RecordingCore
@testable import WatchAudio

/// Synthetic PCM exercises the real AVAudioFile writer, not the microphone or watchOS background policy.
final class AudioSegmentWriterTests: XCTestCase {
    private var root: URL!
    private var repository: RecordingRepository!
    private var writer: AudioSegmentWriter!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        repository = try RecordingRepository(root: root)
        writer = AudioSegmentWriter(repository: repository, root: root)
        writer.onFailure = { message in XCTFail(message) }
    }

    override func tearDownWithError() throws {
        writer = nil
        repository = nil
        try FileManager.default.removeItem(at: root)
    }

    private func prepare(automatically: Bool = false) throws {
        let ready = expectation(description: "writer prepared")
        writer.prepare(startNewPriorityEpoch: !automatically) { result in
            if case .failure(let error) = result { XCTFail(error.localizedDescription) }
            ready.fulfill()
        }
        wait(for: [ready], timeout: 10)
        writer.enableInput()
    }

    private final class QueryCounter: @unchecked Sendable {
        let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func queriedStatus() -> RecorderSnapshot? {
        let done = expectation(description: "read writer memory only")
        let result = QuerySnapshot()
        writer.queryStatus { snapshot in result.set(snapshot); done.fulfill() }
        wait(for: [done], timeout: 5)
        return result.value
    }

    private final class QuerySnapshot: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshot: RecorderSnapshot?
        func set(_ value: RecorderSnapshot?) { lock.lock(); snapshot = value; lock.unlock() }
        var value: RecorderSnapshot? { lock.lock(); defer { lock.unlock() }; return snapshot }
    }

    func testStatusQueryBeforeLoadRemainsUnknown() throws {
        let files = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()
        XCTAssertNil(queriedStatus())
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted(), files)
        XCTAssertTrue(try repository.events().isEmpty)
    }

    func testStatusQueryObservesPausedMemoryWithoutPendingScanOrPublication() throws {
        let calls = QueryCounter(), statuses = StatusRecorder()
        writer = AudioSegmentWriter(repository: repository, root: root, pendingCountProvider: {
            calls.increment(); return 7
        })
        writer.onStatus = { statuses.append($0) }
        try prepare()
        finish(.paused)
        _ = try waitForPendingCount(7, statuses: statuses)
        let callsBefore = calls.count
        let publicationsBefore = statuses.values.count
        let eventsBefore = try repository.events()
        let sessionsBefore = try repository.sessions()
        let queryStarted = Date()
        let result = try XCTUnwrap(queriedStatus())
        XCTAssertEqual(result.state, .paused)
        XCTAssertGreaterThanOrEqual(result.observedAt.timeIntervalSince1970, queryStarted.timeIntervalSince1970 - 0.001)
        XCTAssertFalse(result.pendingCountIsKnown, "Cached count is not a fresh inventory check")
        XCTAssertEqual(result.pendingCount, 7)
        XCTAssertEqual(calls.count, callsBefore)
        XCTAssertEqual(statuses.values.count, publicationsBefore, "Query cannot notify model/transfer observers")
        XCTAssertEqual(try repository.events(), eventsBefore)
        XCTAssertEqual(try repository.sessions(), sessionsBefore)
    }

    func testStatusQueryNeverFreshensStaleRecordingEvidence() throws {
        let statuses = StatusRecorder()
        writer.onStatus = { statuses.append($0) }
        try prepare()
        let oldHostTime = mach_absolute_time() - AVAudioTime.hostTime(forSeconds: 600)
        writer.receive(try pcm(frames: 16_000), at: AVAudioTime(hostTime: oldHostTime))
        drainPendingAudio()
        let before = try XCTUnwrap(statuses.values.last?.session?.lastAudioAt)
        let result = try XCTUnwrap(queriedStatus())
        XCTAssertEqual(result.state, .recording)
        XCTAssertEqual(result.observedAt.timeIntervalSince1970, before.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result.lastAudioAt).timeIntervalSince1970,
                       before.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertTrue(result.isStale(), "No new PCM means old evidence must remain stale")
        finish(.paused)
    }

    private func finish(_ state: CaptureState = .ended) {
        let done = expectation(description: "writer drained and sealed")
        writer.finish(state: state, detail: nil) { done.fulfill() }
        wait(for: [done], timeout: 10)
    }

    private func drainPendingAudio() {
        let drained = expectation(description: "accepted audio and status callbacks drained")
        writer.inspectAudioFreshness { _, _ in drained.fulfill() }
        wait(for: [drained], timeout: 10)
    }

    private func waitForPendingCount(_ expected: Int, statuses: StatusRecorder) throws -> WatchRecordingStatus {
        let checked = expectation(for: NSPredicate { _, _ in
            statuses.values.last.map { $0.pendingCountIsKnown && $0.pendingCount == expected } ?? false
        }, evaluatedWith: nil)
        wait(for: [checked], timeout: 10)
        return try XCTUnwrap(statuses.values.last)
    }

    private final class StatusRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [WatchRecordingStatus] = []

        func append(_ status: WatchRecordingStatus) {
            lock.lock()
            defer { lock.unlock() }
            recorded.append(status)
        }

        var values: [WatchRecordingStatus] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }
    }

    private final class LocationClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date().addingTimeInterval(-120)
        func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ value: Date) { lock.lock(); defer { lock.unlock() }; self.value = value }
    }

    private func prepareWithLocationClock() throws -> (LocationClock, StatusRecorder) {
        let clock = LocationClock(), statuses = StatusRecorder()
        writer = AudioSegmentWriter(repository: repository, root: root, locationClock: { clock.now() })
        writer.onFailure = { message in XCTFail(message) }
        writer.onStatus = { statuses.append($0) }
        try prepare()
        clock.set(Date().addingTimeInterval(120))
        return (clock, statuses)
    }

    private func location(at time: Date, latitude: Double = 31) -> SegmentLocation {
        SegmentLocation(latitude: latitude, longitude: 121, horizontalAccuracy: 10, capturedAt: time)
    }

    private func pcm(frames: UInt32, sampleRate: Double = 16_000, value: Float = 0.25) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        channel.initialize(repeating: value, count: Int(frames))
        return buffer
    }

    private func timestamp(offset: TimeInterval = 0, from origin: UInt64 = mach_absolute_time()) -> AVAudioTime {
        AVAudioTime(hostTime: origin + AVAudioTime.hostTime(forSeconds: offset))
    }

    private func readSamples(_ file: AVAudioFile) throws -> [Float] {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4_096))
        var samples: [Float] = []
        while file.framePosition < file.length {
            let requested = AVAudioFrameCount(min(Int64(buffer.frameCapacity), file.length - file.framePosition))
            try file.read(into: buffer, frameCount: requested)
            guard buffer.frameLength > 0 else {
                XCTFail("Audio ended before its declared frame count")
                break
            }
            samples.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        }
        return samples
    }

    func testBufferCrossingSixtySecondBoundaryPreservesEveryFrame() throws {
        try prepare()
        let input = try pcm(frames: 960_123)
        writer.receive(input, at: timestamp())
        finish()
        let manifests = try repository.manifests()
        XCTAssertEqual(manifests.map(\.frameCount), [960_000, 123])
        XCTAssertEqual(manifests.map(\.sequence), [0, 1])
        XCTAssertEqual(Set(manifests.map(\.sessionID)).count, 1)
        for manifest in manifests {
            XCTAssertNil(manifest.location)
            XCTAssertEqual(manifest.timeZoneIdentifier, TimeZone.current.identifier)
            XCTAssertEqual(try AgentRecordingMetadata(manifest: manifest).timeZoneSource, "recorded")
            let file = try AVAudioFile(forReading: repository.audioURL(for: manifest))
            XCTAssertEqual(file.length, manifest.frameCount)
            XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
            let samples = try readSamples(file)
            XCTAssertEqual(samples.count, Int(manifest.frameCount))
            XCTAssertEqual(try XCTUnwrap(samples.first), 0.25, accuracy: 0.00001)
            XCTAssertEqual(try XCTUnwrap(samples.last), 0.25, accuracy: 0.00001)
        }
    }

    func testSealingUpdatesPendingCountWhileRemainingAudioAdvancesStatus() throws {
        let statuses = StatusRecorder()
        writer.onStatus = { statuses.append($0) }
        try prepare()
        defer { finish() }
        _ = try waitForPendingCount(0, statuses: statuses)

        writer.receive(try pcm(frames: 976_000), at: timestamp()) // 61 seconds in one buffer.
        drainPendingAudio()
        _ = try waitForPendingCount(1, statuses: statuses)

        let recording = statuses.values.filter { $0.session?.state == .recording }
        let sealed = try XCTUnwrap(recording.first { $0.sealedCount == 1 })
        let latest = try XCTUnwrap(recording.last)
        XCTAssertFalse(sealed.pendingCountIsKnown)
        XCTAssertTrue(sealed.pendingCountIsRefreshing)
        XCTAssertFalse(sealed.snapshot.pendingCountIsKnown)
        XCTAssertEqual(sealed.effectiveDuration, 60, accuracy: 0.0001)
        XCTAssertEqual(latest.pendingCount, 1)
        XCTAssertTrue(latest.snapshot.pendingCountIsKnown)
        XCTAssertFalse(latest.pendingCountIsRefreshing)
        XCTAssertEqual(latest.sealedCount, 1)
        XCTAssertEqual(latest.effectiveDuration, 61, accuracy: 0.0001)
        let sealedAudioAt = try XCTUnwrap(sealed.session?.lastAudioAt)
        let latestAudioAt = try XCTUnwrap(latest.session?.lastAudioAt)
        XCTAssertEqual(latestAudioAt.timeIntervalSince(sealedAudioAt), 1, accuracy: 0.002)
        XCTAssertGreaterThan(latest.revision, sealed.revision)
    }

    func testAcknowledgementRefreshesPendingCountWithoutStoppingAudioProgress() throws {
        let statuses = StatusRecorder()
        writer.onStatus = { statuses.append($0) }
        try prepare()
        defer { finish() }
        let origin = mach_absolute_time()
        writer.receive(try pcm(frames: 960_000), at: timestamp(from: origin))
        drainPendingAudio()
        let sealed = try waitForPendingCount(1, statuses: statuses)
        XCTAssertEqual(sealed.pendingCount, 1)

        let manifest = try XCTUnwrap(repository.manifests().first)
        try repository.acknowledge(SegmentReceipt(segmentID: manifest.id,
            sha256: manifest.sha256, byteCount: manifest.byteCount))
        writer.receive(try pcm(frames: 32_000), at: timestamp(offset: 60, from: origin))
        drainPendingAudio()

        // Audio ticks keep the last observed count until the ACK's repository-change
        // notification explicitly refreshes it; fresh audio must still be published.
        let beforeRefresh = try XCTUnwrap(statuses.values.last)
        XCTAssertEqual(beforeRefresh.pendingCount, 1)
        XCTAssertEqual(beforeRefresh.effectiveDuration, 62, accuracy: 0.0001)
        let sealedAudioAt = try XCTUnwrap(sealed.session?.lastAudioAt)
        let beforeRefreshAudioAt = try XCTUnwrap(beforeRefresh.session?.lastAudioAt)
        XCTAssertEqual(beforeRefreshAudioAt.timeIntervalSince(sealedAudioAt), 2, accuracy: 0.002)

        writer.refreshStatus()
        drainPendingAudio()
        let refreshed = try waitForPendingCount(0, statuses: statuses)
        XCTAssertEqual(refreshed.pendingCount, 0)
        XCTAssertEqual(refreshed.effectiveDuration, beforeRefresh.effectiveDuration)
        XCTAssertEqual(refreshed.session?.lastAudioAt, beforeRefresh.session?.lastAudioAt)
        XCTAssertGreaterThan(refreshed.revision, beforeRefresh.revision)

        writer.receive(try pcm(frames: 32_000), at: timestamp(offset: 62, from: origin))
        drainPendingAudio()
        let latest = try XCTUnwrap(statuses.values.last)
        XCTAssertEqual(latest.session?.state, .recording)
        XCTAssertEqual(latest.pendingCount, 0)
        XCTAssertEqual(latest.effectiveDuration, 64, accuracy: 0.0001)
        let latestAudioAt = try XCTUnwrap(latest.session?.lastAudioAt)
        XCTAssertEqual(latestAudioAt.timeIntervalSince(beforeRefreshAudioAt), 2, accuracy: 0.002)
    }

    func testInputBufferIsCopiedBeforeCallbackReturns() throws {
        try prepare()
        let input = try pcm(frames: 32_000, value: 0.75)
        writer.receive(input, at: timestamp())
        input.floatChannelData![0].update(repeating: -0.5, count: 32_000)
        finish()
        let manifest = try XCTUnwrap(repository.manifests().first)
        let file = try AVAudioFile(forReading: repository.audioURL(for: manifest))
        let samples = try readSamples(file)
        XCTAssertEqual(samples.count, 32_000)
        XCTAssertEqual(try XCTUnwrap(samples.first), 0.75, accuracy: 0.00001)
        XCTAssertEqual(try XCTUnwrap(samples.last), 0.75, accuracy: 0.00001)
    }

    func testManualPauseClosesGroupWithoutResettingTransferSequence() throws {
        let statuses = StatusRecorder()
        writer.onStatus = { statuses.append($0) }
        try prepare()
        writer.receive(try pcm(frames: 16_000), at: timestamp())
        finish(.paused)
        XCTAssertEqual(statuses.values.last?.effectiveDuration, 1)
        let first = try XCTUnwrap(repository.manifests().first)
        XCTAssertEqual(try repository.sessions().first?.state, .paused)
        writer = AudioSegmentWriter(repository: repository, root: root)
        writer.onStatus = { statuses.append($0) }
        writer.onFailure = { message in XCTFail(message) }
        writer.load()
        drainPendingAudio()
        XCTAssertEqual(statuses.values.last?.effectiveDuration, 1)
        try prepare()
        XCTAssertEqual(statuses.values.last?.effectiveDuration, 0)
        writer.receive(try pcm(frames: 8_000), at: timestamp())
        finish()
        XCTAssertEqual(statuses.values.last?.effectiveDuration, 0.5)
        let manifests = try repository.manifests()
        XCTAssertEqual(manifests.reduce(Int64(0)) { $0 + $1.frameCount }, 24_000)
        XCTAssertEqual(Set(manifests.map(\.sessionID)), [first.sessionID])
        XCTAssertEqual(manifests.map(\.sequence).sorted(), [0, 1])
        let second = try XCTUnwrap(manifests.first { $0.sequence == 1 })
        let firstGroup = try XCTUnwrap(first.recordingGroup)
        let secondGroup = try XCTUnwrap(second.recordingGroup)
        XCTAssertNotEqual(firstGroup.id, secondGroup.id)
        XCTAssertEqual(firstGroup.startedAt, first.startedAt)
        XCTAssertEqual(secondGroup.startedAt, second.startedAt)
        XCTAssertEqual(manifests.map(\.recordingPartIndex), [0, 0])
    }

    func testAutomaticResumeContinuesTheSameRecordingGroup() throws {
        try prepare()
        writer.receive(try pcm(frames: 16_000), at: timestamp())
        finish(.interrupted)
        try prepare(automatically: true)
        writer.receive(try pcm(frames: 8_000), at: timestamp())
        finish()
        let manifests = try repository.manifests().sorted { $0.sequence < $1.sequence }
        XCTAssertEqual(manifests.count, 2)
        XCTAssertNotNil(manifests.first?.recordingGroup)
        XCTAssertEqual(manifests.first?.recordingGroup, manifests.last?.recordingGroup)
        XCTAssertEqual(manifests.map(\.recordingPartIndex), [0, 1])
    }

    func testStopSavesTailAndNextStartCreatesIndependentGroupAfterRelaunch() throws {
        var olderSession = try repository.createSession(at: Date().addingTimeInterval(-60))
        try prepare()
        writer.receive(try pcm(frames: 16_000), at: timestamp())
        finish()
        let first = try XCTUnwrap(repository.manifests().first)
        XCTAssertEqual(first.frameCount, 16_000)

        olderSession.state = .paused
        try repository.saveSession(olderSession)
        writer = AudioSegmentWriter(repository: repository, root: root)
        let statuses = StatusRecorder()
        writer.onStatus = { statuses.append($0) }
        writer.onFailure = { message in XCTFail(message) }
        writer.load()
        drainPendingAudio()
        XCTAssertEqual(statuses.values.last?.session?.id, first.sessionID)
        XCTAssertEqual(statuses.values.last?.session?.state, .ended)

        try prepare()
        writer.receive(try pcm(frames: 8_000), at: timestamp())
        finish()
        let manifests = try repository.manifests()
        XCTAssertEqual(manifests.count, 2)
        let second = try XCTUnwrap(manifests.first { $0.id != first.id })
        XCTAssertEqual(second.frameCount, 8_000)
        XCTAssertNotEqual(first.sessionID, second.sessionID)
        XCTAssertNotEqual(try XCTUnwrap(first.recordingGroup).id, try XCTUnwrap(second.recordingGroup).id)
        XCTAssertEqual(manifests.map(\.recordingPartIndex), [0, 0])
        XCTAssertEqual(try repository.sessions().map(\.state), [.paused, .ended, .ended])
    }

    func testHardwareTimestampGapSealsPreviousFileAndLogsGap() throws {
        try prepare()
        let origin = mach_absolute_time()
        writer.receive(try pcm(frames: 16_000), at: timestamp(from: origin))
        writer.receive(try pcm(frames: 16_000), at: timestamp(offset: 11, from: origin))
        finish()
        let manifests = try repository.manifests()
        XCTAssertEqual(manifests.count, 2)
        XCTAssertEqual(manifests.map(\.frameCount), [16_000, 16_000])
        XCTAssertEqual(manifests[1].startedAt.timeIntervalSince(manifests[0].endedAt), 10, accuracy: 0.002)
        let gap = try XCTUnwrap(repository.events().first { $0.kind == "audio_gap" })
        XCTAssertEqual(try XCTUnwrap(gap.intervalEnd).timeIntervalSince(XCTUnwrap(gap.intervalStart)), 10, accuracy: 0.002)
    }

    func testWaveformUsesWrittenAudioAndGoesQuietOffscreen() throws {
        let waveform = WatchRecordingWaveform()
        writer = AudioSegmentWriter(repository: repository, root: root, waveform: waveform)
        writer.onFailure = { XCTFail($0) }
        waveform.setVisible(true)
        try prepare()
        let origin = mach_absolute_time()
        let samples = try pcm(frames: 16_000)
        samples.floatChannelData![0].update(repeating: 0, count: 16_000)
        writer.receive(samples, at: timestamp(from: origin))
        drainPendingAudio()
        XCTAssertEqual(waveform.snapshot().levels.max(), 0)

        samples.floatChannelData![0].update(repeating: 0.25, count: 16_000)
        writer.receive(samples, at: timestamp(offset: 1, from: origin))
        drainPendingAudio()
        XCTAssertGreaterThan(try XCTUnwrap(waveform.snapshot().levels.max()), 0.5)

        waveform.setVisible(false)
        writer.receive(samples, at: timestamp(offset: 2, from: origin))
        drainPendingAudio()
        XCTAssertEqual(waveform.snapshot().levels.max(), 0)
        XCTAssertNil(waveform.snapshot().latestSampleAt)
        finish()
        XCTAssertEqual(try repository.manifests().map(\.frameCount), [48_000])
    }

    func testWaveformKeepsTheSameAudioClockAcrossTapBufferBoundaries() throws {
        let origin = Date(timeIntervalSince1970: 1_800_000_000)
        let whole = WatchRecordingWaveform()
        let split = WatchRecordingWaveform()
        whole.setVisible(true)
        split.setVisible(true)
        let complete = try pcm(frames: 8_000)
        complete.floatChannelData![0].update(repeating: 0.25, count: 8_000)
        whole.observe(complete, startedAt: origin)
        let partial = try pcm(frames: 400)
        partial.floatChannelData![0].update(repeating: 0.25, count: 400)
        for index in 0..<20 {
            split.observe(partial, startedAt: origin.addingTimeInterval(Double(index) / 40))
        }
        let expected = whole.snapshot()
        let actual = split.snapshot()
        XCTAssertEqual(actual.levels, expected.levels)
        XCTAssertEqual(actual.levels.filter { $0 > 0 }.count, 11)
        XCTAssertEqual(try XCTUnwrap(actual.latestSampleAt).timeIntervalSince(
            XCTUnwrap(expected.latestSampleAt)), 0, accuracy: 0.000_01)
    }

    func testDisabledInputCannotAccumulateNewAudio() throws {
        try prepare()
        writer.receive(try pcm(frames: 16_000), at: timestamp())
        writer.disableInput()
        writer.receive(try pcm(frames: 16_000), at: timestamp(offset: 1))
        finish(.paused)
        XCTAssertEqual(try repository.manifests().reduce(Int64(0)) { $0 + $1.frameCount }, 16_000)
    }

    func testLatestInSegmentLocationSurvivesLaterOutOfBoundsAndInvalidFixes() throws {
        let (_, statuses) = try prepareWithLocationClock()
        writer.receive(try pcm(frames: 16_000), at: timestamp())
        drainPendingAudio()
        let start = try XCTUnwrap(statuses.values.last?.session?.currentSegmentStartedAt)
        let latest = location(at: start.addingTimeInterval(0.8))
        writer.updateLocation(location(at: start.addingTimeInterval(0.2)))
        writer.updateLocation(latest)
        writer.updateLocation(location(at: start.addingTimeInterval(1.2)))
        writer.updateLocation(location(at: start.addingTimeInterval(-1)))
        writer.updateLocation(location(at: start.addingTimeInterval(0.9), latitude: .nan))
        finish(.paused)
        let manifest = try XCTUnwrap(repository.manifests().first)
        XCTAssertEqual(manifest.location, latest)
        XCTAssertEqual(manifest.frameCount, 16_000)
    }

    func testLocationCanArriveBeforeAudioProcessingFromAnotherThread() throws {
        _ = try prepareWithLocationClock()
        let origin = mach_absolute_time()
        let fix = location(at: Date().addingTimeInterval(0.5))
        let queued = expectation(description: "background location callback queued")
        let writer = try XCTUnwrap(writer)
        DispatchQueue.global().async {
            writer.updateLocation(fix)
            queued.fulfill()
        }
        wait(for: [queued], timeout: 5)
        writer.receive(try pcm(frames: 16_000), at: timestamp(from: origin))
        finish()
        XCTAssertEqual(try repository.manifests().first?.location, fix)
    }

    func testDisablingLocationClearsUnsealedPointWithoutAffectingAudio() throws {
        let (_, statuses) = try prepareWithLocationClock()
        writer.receive(try pcm(frames: 16_000), at: timestamp())
        drainPendingAudio()
        let start = try XCTUnwrap(statuses.values.last?.session?.currentSegmentStartedAt)
        let fix = location(at: start.addingTimeInterval(0.5))
        writer.updateLocation(fix)
        writer.updateLocation(nil)
        writer.updateLocation(fix) // Delayed provider callback from before the clear.
        finish()
        let manifest = try XCTUnwrap(repository.manifests().first)
        XCTAssertNil(manifest.location)
        XCTAssertEqual(manifest.frameCount, 16_000)
        XCTAssertEqual(try AVAudioFile(forReading: repository.audioURL(for: manifest)).length, 16_000)
    }

    func testPausePreservesCurrentLocationAndResumeDoesNotReuseIt() throws {
        let (clock, statuses) = try prepareWithLocationClock()
        let origin = mach_absolute_time()
        writer.receive(try pcm(frames: 16_000), at: timestamp(from: origin))
        drainPendingAudio()
        let start = try XCTUnwrap(statuses.values.last?.session?.currentSegmentStartedAt)
        let fix = location(at: start.addingTimeInterval(0.5))
        writer.updateLocation(fix)
        finish(.paused)
        let first = try XCTUnwrap(repository.manifests().first)
        XCTAssertEqual(first.location, fix)
        clock.set(start.addingTimeInterval(1.5))
        try prepare()
        clock.set(start.addingTimeInterval(10))
        writer.updateLocation(fix) // Late callback from the previous run must not refill the cache.
        writer.receive(try pcm(frames: 16_000), at: timestamp(offset: 2, from: origin))
        finish()
        let manifests = try repository.manifests()
        XCTAssertEqual(manifests.count, 2)
        XCTAssertEqual(manifests[0], first)
        XCTAssertNil(manifests[1].location)
        XCTAssertEqual(Set(manifests.map(\.sessionID)), [first.sessionID])
    }

    func testFutureAtCallbackIsRejectedEvenWhenWriterQueueRunsLater() throws {
        let (clock, statuses) = try prepareWithLocationClock()
        writer.receive(try pcm(frames: 16_000), at: timestamp())
        drainPendingAudio()
        let start = try XCTUnwrap(statuses.values.last?.session?.currentSegmentStartedAt)
        let blocked = expectation(description: "writer queue blocked")
        let gate = DispatchSemaphore(value: 0)
        writer.inspectAudioFreshness { _, _ in
            blocked.fulfill()
            _ = gate.wait(timeout: .now() + 5)
        }
        wait(for: [blocked], timeout: 5)
        clock.set(start.addingTimeInterval(0.25))
        writer.updateLocation(location(at: start.addingTimeInterval(0.5)))
        clock.set(start.addingTimeInterval(0.75))
        gate.signal()
        finish()
        XCTAssertNil(try repository.manifests().first?.location)
        XCTAssertEqual(try repository.manifests().first?.frameCount, 16_000)
    }

    func testLateFixNeverRewritesSealedSegmentOrLeaksIntoNextSegment() throws {
        _ = try prepareWithLocationClock()
        let origin = mach_absolute_time()
        writer.receive(try pcm(frames: 960_000), at: timestamp(from: origin))
        drainPendingAudio()
        let first = try XCTUnwrap(repository.manifests().first)
        XCTAssertNil(first.location)
        writer.updateLocation(location(at: first.startedAt.addingTimeInterval(30)))
        writer.receive(try pcm(frames: 16_000), at: timestamp(offset: 60, from: origin))
        finish()
        let manifests = try repository.manifests()
        XCTAssertEqual(manifests.count, 2)
        XCTAssertEqual(manifests[0], first)
        XCTAssertNil(manifests[1].location)
        XCTAssertEqual(manifests.reduce(0) { $0 + $1.frameCount }, 976_000)
    }
}
