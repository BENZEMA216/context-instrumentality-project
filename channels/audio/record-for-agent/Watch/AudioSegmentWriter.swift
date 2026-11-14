import AVFoundation
import Darwin
import Foundation
import RecordingCore

struct WatchRecordingStatus: Sendable {
    let revision: UInt64
    let session: RecordingSession?
    let effectiveDuration: TimeInterval
    let pendingCount: Int
    /// The count is cached while a fresh check is running or unavailable.
    let pendingCountIsKnown: Bool
    var pendingCountIsRefreshing = false
    let syncWarning: String?
    let recoveryMessage: String?
    let sealedCount: Int
    let freeBytes: Int64?
    let firstAudioAt: Date?
    let detail: String?

    var snapshot: RecorderSnapshot {
        let state = session?.state ?? .idle
        return RecorderSnapshot(
            state: state,
            sessionID: session?.id,
            observedAt: state == .recording ? (session?.lastAudioAt ?? Date()) : Date(),
            lastAudioAt: session?.lastAudioAt,
            lastSealedAt: session?.lastSealedAt,
            pendingCount: pendingCount,
            pendingCountIsKnown: pendingCountIsKnown,
            detail: detail,
            recordingGroupID: session?.recordingGroup?.id
        )
    }
}

/// Owns all file handles and repository recording mutations on one serial queue.
/// The tap only copies a bounded number of buffers; it never performs file I/O.
final class AudioSegmentWriter: @unchecked Sendable {
    var onStatus: (@Sendable (WatchRecordingStatus) -> Void)?
    var onFailure: (@Sendable (String) -> Void)?
    /// Auxiliary sync/diagnostic failures never close microphone input. nil clears the warning.
    var onWarning: (@Sendable (String?) -> Void)?

    private let repository: RecordingRepository
    private let root: URL
    private let waveform: WatchRecordingWaveform
    private let locationClock: @Sendable () -> Date
    private let pendingCountProvider: @Sendable () throws -> Int
    private let queue = DispatchQueue(label: "WristRecord.segment-writer", qos: .userInitiated,
                                      autoreleaseFrequency: .workItem)
    private let pendingCheckQueue = DispatchQueue(label: "WristRecord.pending-check", qos: .utility,
                                                  autoreleaseFrequency: .workItem)
    private let inputLock = NSLock()
    private let maximumQueuedBuffers = 12
    private var accepting = false
    private var queuedBuffers = 0
    private var overflowReported = false
    private var wallClockOffset: TimeInterval = 0

    // Queue-confined state below.
    private var session: RecordingSession?
    private var statusLoaded = false
    private var file: AVAudioFile?
    private var segmentID: UUID?
    private var segmentStart: Date?
    private var segmentTimeZoneIdentifier: String?
    private var segmentFrames: Int64 = 0
    private var segmentRate: Double = 0
    private var segmentFormat: AVAudioFormat?
    private var openSegmentDraft: OpenAudioSegment?
    private var recoveryMessage: String?
    private var forceFreshSession = false
    // This writer is the sole Watch owner of session and audio mutations.
    // A clean load and a fully sealed stop keep the session/sequence in memory.
    private var recoveryRequired = true
    private var nextSequence = 0
    private var sealedDuration: TimeInterval = 0
    private var sealedCount = 0
    private var firstAudioAt: Date?
    private var lastPublishAudioAt: Date?
    private var lastPersistedAudioAt: Date?
    private var resumeGapStart: Date?
    private var writeFailed = false
    private var currentDetail: String?
    private var lastKnownPendingCount = 0
    private var pendingCountIsKnown = false
    private var pendingCheckGeneration: UInt64 = 0
    private var pendingCheckInFlight = false
    private var pendingCheckRequested = false
    private var pendingSyncWarning: String?
    private var diagnosticWarning: String?
    private var priorityWarning: String?
    private var lastPublishedWarning: String?
    private var statusRevision: UInt64 = 0
    private var locationPolicy = SegmentLocationPolicy()

    init(repository: RecordingRepository, root: URL, waveform: WatchRecordingWaveform = .init(),
         locationClock: @escaping @Sendable () -> Date = { Date() },
         pendingCountProvider: (@Sendable () throws -> Int)? = nil) {
        self.repository = repository
        self.root = root
        self.waveform = waveform
        self.locationClock = locationClock
        self.pendingCountProvider = pendingCountProvider ?? { try repository.pendingSegments().count }
    }

    func load() {
        queue.async { [self] in
            WatchStartupDiagnostics.shared.recordOnce(.localLibraryCheckStarted)
            do {
                let report = try RecordingTailRecovery.recover(repository: repository)
                recoveryMessage = report.message
                forceFreshSession = report.requiresNewSession
                // Older interrupted sessions remain available for sync. The
                // newest session determines whether the next start can resume.
                session = report.inventory.sessions.last
                refreshSessionTotals(inventory: report.inventory)
                recoveryRequired = forceFreshSession
                if !report.requiresNewSession { closePriorityCaptureOnQueue() }
                statusLoaded = true
                WatchStartupDiagnostics.shared.recordOnce(.localLibraryCheckCompleted)
                publish(refreshPendingCount: true)
            } catch { reportFailure("无法读取本地录音：\(error.localizedDescription)") }
        }
    }

    func prepare(startNewPriorityEpoch: Bool = true, completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        let requestedAt = locationClock()
        queue.async { [self] in
            locationPolicy.beginRecording(at: requestedAt)
            do {
                // The first load or an incomplete write needs on-disk recovery.
                // After a clean stop, scanning the entire library delays the microphone.
                let ranRecovery = recoveryRequired
                if ranRecovery {
                    let report = try RecordingTailRecovery.recover(repository: repository)
                    if let message = report.message { recoveryMessage = message }
                    forceFreshSession = forceFreshSession || report.requiresNewSession
                    if let id = session?.id {
                        session = report.inventory.sessions.first { $0.id == id } ?? session
                    }
                    refreshSessionTotals(inventory: report.inventory)
                    recoveryRequired = report.requiresNewSession
                }
                if session == nil || session?.state == .ended || forceFreshSession {
                    session = try repository.createSession()
                    nextSequence = 0
                    forceFreshSession = false
                }
                resumeGapStart = session?.recordingGroupClosed != true &&
                    (session?.state == .interrupted || session?.state == .failed)
                    ? (session?.currentSegmentStartedAt ?? session?.lastAudioAt ?? session?.lastSealedAt) : nil
                // A failed seal leaves its staging file for diagnosis; it must not count as
                // part of the next run or be overwritten by a new segment.
                if file == nil {
                    segmentID = nil
                    segmentStart = nil
                    segmentTimeZoneIdentifier = nil
                    segmentFrames = 0
                    segmentRate = 0
                    segmentFormat = nil
                    openSegmentDraft = nil
                }
                session?.state = .starting
                if session?.recordingGroupClosed == true {
                    session?.recordingGroup = nil
                    session?.recordingGroupClosed = nil
                }
                session?.updatedAt = Date()
                session?.currentSegmentStartedAt = nil
                if let session { try repository.saveSession(session) }
                if session?.recordingGroup == nil {
                    sealedDuration = 0
                    sealedCount = 0
                }
                if let session {
                    do { try repository.beginPriorityCapture(sessionID: session.id, nextSequence: nextSequence,
                                                              newEpoch: startNewPriorityEpoch)
                         priorityWarning = nil }
                    catch { priorityWarning = "新录音已保留，优先发送状态待恢复：\(error.localizedDescription)" }
                }
                writeFailed = false
                currentDetail = nil
                firstAudioAt = nil
                lastPublishAudioAt = nil
                lastPersistedAudioAt = nil
                waveform.reset()
                try repository.appendEvent(RecordingEvent(kind: "capture_start_requested",
                    detail: "等待首个实际音频缓冲", sessionID: session?.id))
                statusLoaded = true
                publish(refreshPendingCount: ranRecovery)
                completion(.success(()))
            } catch {
                recoveryRequired = true
                locationPolicy.endRecording()
                completion(.failure(error))
            }
        }
    }

    /// An explicit end of user capture intent, serialized after an in-flight finish.
    /// Failed or still-open tails keep their epoch until successful recovery.
    func closePriorityCapture() {
        queue.async { [self] in
            closePriorityCaptureOnQueue()
            publish(refreshPendingCount: false)
        }
    }

    private func closePriorityCaptureOnQueue() {
        guard !writeFailed, file == nil, openSegmentDraft == nil else { return }
        do { try repository.closePriorityCapture(); priorityWarning = nil }
        catch { priorityWarning = "录音已保留，发送顺序待恢复：\(error.localizedDescription)" }
    }

    /// Safe from any thread. Closing/revoking location clears unsealed fixes without touching audio.
    /// Callers must also stop delivering stale provider callbacks when location is disabled.
    func updateLocation(_ location: SegmentLocation?) {
        let receivedAt = locationClock()
        queue.async { [self] in locationPolicy.update(location, receivedAt: receivedAt) }
    }

    /// Called only once the previous finish has drained the writer queue.
    func enableInput() {
        inputLock.lock()
        wallClockOffset = Date().timeIntervalSince1970
            - AVAudioTime.seconds(forHostTime: mach_absolute_time())
        overflowReported = false
        accepting = true
        inputLock.unlock()
    }

    func disableInput() {
        inputLock.lock()
        accepting = false
        inputLock.unlock()
    }

    func receive(_ source: AVAudioPCMBuffer, at time: AVAudioTime) {
        inputLock.lock()
        guard accepting else { inputLock.unlock(); return }
        guard queuedBuffers < maximumQueuedBuffers else {
            accepting = false
            let shouldReport = !overflowReported
            overflowReported = true
            inputLock.unlock()
            if shouldReport {
                queue.async { [self] in
                    reportFailure("写入速度不足，音频队列已满。录音已中断，请检查可用空间后继续。")
                }
            }
            return
        }
        guard source.frameLength > 0,
              let copy = Self.copy(source, offset: 0, count: source.frameLength) else {
            accepting = false
            inputLock.unlock()
            queue.async { [self] in reportFailure("无法复制麦克风音频，录音已中断。") }
            return
        }
        let start = time.isHostTimeValid
            ? Date(timeIntervalSince1970: AVAudioTime.seconds(forHostTime: time.hostTime) + wallClockOffset)
            : Date().addingTimeInterval(-Double(copy.frameLength) / copy.format.sampleRate)
        let captured = CapturedBuffer(buffer: copy, startedAt: start, hasHardwareTime: time.isHostTimeValid)
        queuedBuffers += 1
        // Submit while holding the input lock so finish cannot overtake an accepted buffer.
        queue.async { [self] in
            defer {
                inputLock.lock()
                queuedBuffers -= 1
                inputLock.unlock()
            }
            guard !writeFailed else { return }
            do {
                try consume(captured)
                if !writeFailed { waveform.observe(captured.buffer, startedAt: captured.startedAt) }
            } catch { reportFailure("保存录音失败：\(error.localizedDescription)") }
        }
        inputLock.unlock()
    }

    /// The caller first disables input and stops the engine. All accepted buffers then drain.
    func finish(state: CaptureState, detail: String?, priorityCaptureContinues: Bool = false, completion: @escaping @Sendable () -> Void) {
        disableInput()
        queue.async { [self] in
            defer {
                locationPolicy.endRecording()
                waveform.reset()
            }
            if state == .paused || state == .ended {
                session?.recordingGroupClosed = true
            }
            do {
                try sealCurrentSegment()
                if session != nil {
                    session?.state = state
                    session?.updatedAt = Date()
                    session?.currentSegmentStartedAt = nil
                    if state == .ended { session?.endedAt = Date() }
                    if let session { try repository.saveSession(session) }
                }
                if !priorityCaptureContinues { closePriorityCaptureOnQueue() }
                currentDetail = detail
                let kind = state == .paused ? "user_paused"
                    : state == .ended ? "user_ended" : "capture_interrupted"
                appendEvent(kind: kind, detail: detail ?? state.rawValue,
                            intervalStart: state == .interrupted || state == .failed ? session?.lastAudioAt : nil)
                publish(refreshPendingCount: true)
            } catch {
                session?.state = .failed
                session?.updatedAt = Date()
                if let session { try? repository.saveSession(session) }
                reportFailure("封存片段失败，临时音频已保留：\(error.localizedDescription)")
                publish(refreshPendingCount: true)
            }
            completion()
        }
    }

    func refreshStatus() { queue.async { [self] in publish(refreshPendingCount: true) } }

    /// Observe only this living writer's memory on its serial queue. This is
    /// deliberately separate from refreshStatus()/publish(): no journal scan,
    /// pending-count provider, audio handle, status observer or sync trigger.
    func queryStatus(completion: @escaping @Sendable (RecorderSnapshot?) -> Void) {
        queue.async { [self] in
            guard statusLoaded else { completion(nil); return }
            let capture = session?.state ?? .idle
            completion(RecorderSnapshot(state: capture, sessionID: session?.id,
                observedAt: capture == .recording ? (session?.lastAudioAt ?? .distantPast) : Date(),
                lastAudioAt: session?.lastAudioAt, lastSealedAt: session?.lastSealedAt,
                pendingCount: lastKnownPendingCount, pendingCountIsKnown: false, detail: currentDetail,
                recordingGroupID: session?.recordingGroup?.id))
        }
    }

    /// Foreground polling may retry a failed check without invalidating a slow one.
    func retrySyncStatusIfNeeded() {
        queue.async { [self] in
            guard !pendingCountIsKnown, !pendingCheckInFlight else { return }
            publish(refreshPendingCount: true)
        }
    }

    /// Reads after accepted buffers on the writer queue. The check time belongs to this
    /// evidence, so a delayed main-thread callback cannot make healthy audio look stale.
    func inspectAudioFreshness(completion: @escaping @Sendable (Date?, Date) -> Void) {
        queue.async { [self] in completion(session?.lastAudioAt, Date()) }
    }

    func log(kind: String, detail: String) {
        queue.async { [self] in
            let previous = diagnosticWarning
            do {
                try repository.appendEvent(RecordingEvent(kind: kind, detail: detail, sessionID: session?.id))
                diagnosticWarning = nil
            } catch {
                // External telemetry is not a capture durability boundary. Keep
                // recording; open/seal/session persistence retain their fatal path.
                diagnosticWarning = "诊断日志暂未保存：\(error.localizedDescription)"
            }
            if previous != diagnosticWarning { publish() }
        }
    }

    private func consume(_ captured: CapturedBuffer) throws {
        guard session != nil else { throw WriterError.missingSession }
        let buffer = captured.buffer
        guard buffer.format.sampleRate > 0, buffer.format.channelCount > 0 else {
            throw WriterError.invalidFormat
        }

        if let previous = session?.lastAudioAt, captured.hasHardwareTime,
           session?.state == .recording, captured.startedAt.timeIntervalSince(previous) > 0.05 {
            // A manifest represents contiguous samples. Never conceal an internal time gap
            // by stretching (or shortening) its duration relative to its frame count.
            try sealCurrentSegment()
            appendEvent(kind: "audio_gap", detail: "硬件音频时间戳不连续",
                        intervalStart: previous, intervalEnd: captured.startedAt)
        }
        if session?.state != .recording {
            if let resumeGapStart {
                appendEvent(kind: "gap_closed", detail: "重新收到实际音频",
                            intervalStart: resumeGapStart, intervalEnd: captured.startedAt)
            }
            resumeGapStart = nil
            session?.state = .recording
            appendEvent(kind: "audio_started", detail: "已收到麦克风音频")
        }

        var offset: AVAudioFrameCount = 0
        while offset < buffer.frameLength {
            let start = captured.startedAt.addingTimeInterval(Double(offset) / buffer.format.sampleRate)
            if let segmentFormat, !segmentFormat.isEqual(buffer.format) {
                try sealCurrentSegment()
                appendEvent(kind: "audio_format_changed", detail: buffer.format.description)
            }
            if file == nil { try openSegment(format: buffer.format, startedAt: start) }
            let targetFrames = max(Int64(1), Int64((segmentRate * 60).rounded()))
            let remaining = targetFrames - segmentFrames
            let count = AVAudioFrameCount(min(Int64(buffer.frameLength - offset), remaining))
            guard let slice = Self.copy(buffer, offset: offset, count: count), let file else {
                throw WriterError.bufferCopyFailed
            }
            try file.write(from: slice)
            if firstAudioAt == nil { firstAudioAt = start }
            segmentFrames += Int64(count)
            offset += count
            session?.lastAudioAt = start.addingTimeInterval(Double(count) / segmentRate)
            if segmentFrames == targetFrames { try sealCurrentSegment() }
        }

        let lastAudioUpdate = session?.lastAudioAt ?? Date()
        session?.updatedAt = lastAudioUpdate
        if let last = session?.lastAudioAt,
           lastPersistedAudioAt == nil || last.timeIntervalSince(lastPersistedAudioAt!) >= 1 {
            if let session { try repository.saveSession(session) }
            lastPersistedAudioAt = last
        }
        if let last = session?.lastAudioAt,
           lastPublishAudioAt == nil || last.timeIntervalSince(lastPublishAudioAt!) >= 1 {
            lastPublishAudioAt = last
            publish()
        }
    }

    private func openSegment(format: AVAudioFormat, startedAt: Date) throws {
        let bufferCount = format.isInterleaved ? 1 : Int(format.channelCount)
        let minimumFree = RecordingStorageBudget.minimumFreeBytes(sampleRate: format.sampleRate,
            bytesPerFrame: format.streamDescription.pointee.mBytesPerFrame, bufferCount: bufferCount)
        RecordingStorageBudget.registerRecordingReserve(minimumFree)
        if let free = availableBytes(), free < minimumFree { throw WriterError.insufficientStorage }
        guard let sessionID = session?.id else { throw WriterError.missingSession }
        let id = UUID()
        let pcmFormat: OpenAudioSegment.PCMFormat
        switch format.commonFormat {
        case .pcmFormatFloat32: pcmFormat = .float32
        case .pcmFormatFloat64: pcmFormat = .float64
        case .pcmFormatInt16: pcmFormat = .int16
        case .pcmFormatInt32: pcmFormat = .int32
        default: throw WriterError.invalidFormat
        }
        let timeZone = TimeZone.current
        if session?.recordingGroup == nil {
            session?.recordingGroup = RecordingGroup(startedAt: startedAt, timeZone: timeZone, firstSequence: nextSequence)
            if let session { try repository.saveSession(session) }
        }
        let draft = OpenAudioSegment(id: id, sessionID: sessionID, sequence: nextSequence,
            startedAt: startedAt, sampleRate: format.sampleRate, channelCount: format.channelCount,
            pcmFormat: pcmFormat, interleaved: format.isInterleaved, timeZoneIdentifier: timeZone.identifier,
            recordingGroup: session?.recordingGroup)
        try repository.beginAudioSegment(draft)
        openSegmentDraft = draft
        file = try AVAudioFile(forWriting: repository.stagingURL(for: id), settings: format.settings,
                               commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        segmentID = id
        segmentStart = startedAt
        segmentTimeZoneIdentifier = draft.timeZoneIdentifier
        segmentFrames = 0
        segmentRate = format.sampleRate
        segmentFormat = format
        session?.currentSegmentStartedAt = startedAt
        if let session { try repository.saveSession(session) }
        appendEvent(kind: "segment_opened",
                    detail: "id=\(id.uuidString) rate=\(format.sampleRate) channels=\(format.channelCount) format=\(format.commonFormat.rawValue)")
    }

    private func sealCurrentSegment() throws {
        guard let file, let id = segmentID, let start = segmentStart, let sessionID = session?.id else { return }
        file.close()
        self.file = nil
        guard segmentFrames > 0 else {
            // A failed first write can still leave physical samples. Keep both
            // CAF and identity record for the recovery pass; never assume empty.
            recoveryRequired = true
            segmentID = nil
            segmentTimeZoneIdentifier = nil
            segmentFormat = nil
            openSegmentDraft = nil
            return
        }
        let end = start.addingTimeInterval(Double(segmentFrames) / segmentRate)
        let location = locationPolicy.sealSegment(startedAt: start, endedAt: end)
        let manifest = try repository.sealSegment(
            stagedURL: repository.stagingURL(for: id), id: id, sessionID: sessionID,
            sequence: nextSequence, startedAt: start, endedAt: end,
            sampleRate: segmentRate, frameCount: segmentFrames,
            timeZoneIdentifier: segmentTimeZoneIdentifier, location: location,
            recordingGroup: openSegmentDraft?.recordingGroup
        )
        if let warning = repository.priorityCaptureWarning { priorityWarning = warning }
        nextSequence += 1
        if nextSequence >= Int.max - 1 { forceFreshSession = true }
        sealedDuration += manifest.duration
        sealedCount += 1
        session?.lastSealedAt = end
        session?.currentSegmentStartedAt = nil
        segmentFrames = 0
        segmentID = nil
        segmentStart = nil
        segmentTimeZoneIdentifier = nil
        segmentFormat = nil
        if let session { try repository.saveSession(session) }
        if let draft = openSegmentDraft {
            do { try repository.completeAudioSegment(draft, justCommitted: manifest) }
            catch {
                recoveryRequired = true
                recoveryMessage = "录音已保存，尾段恢复记录暂未清理，原文件已保留。"
            }
        }
        openSegmentDraft = nil
        appendEvent(kind: "segment_sealed", detail: "id=\(manifest.id.uuidString) frames=\(manifest.frameCount) bytes=\(manifest.byteCount)")
        publish(refreshPendingCount: true)
    }

    private func refreshSessionTotals(inventory: RecordingInventory) {
        let manifests = inventory.manifests.filter { $0.sessionID == session?.id }
        let visibleSegments: [SegmentManifest]
        if let groupID = session?.recordingGroup?.id {
            visibleSegments = manifests.filter { $0.recordingGroup?.id == groupID }
        } else if session?.state == .starting {
            visibleSegments = []
        } else {
            visibleSegments = manifests.filter { $0.recordingGroup == nil }
        }
        sealedDuration = visibleSegments.reduce(0) { $0 + $1.duration }
        sealedCount = visibleSegments.count
        // A still-unresolved draft in the recovery report already forces a new
        // session. Only sealed sequence numbers matter for an eligible session.
        let maximum = manifests.map(\.sequence).max() ?? -1
        if maximum >= Int.max - 1 {
            nextSequence = 0
            forceFreshSession = true
        } else { nextSequence = maximum + 1 }
        if !inventory.issues.isEmpty {
            recoveryMessage = "部分历史录音待核对，原文件已保留，新录音将使用独立会话。"
            forceFreshSession = true
        }
    }

    private func publish(refreshPendingCount: Bool = false) {
        // A history scan never occupies the audio writer queue. Coalesce requests
        // and discard results superseded by a seal, ACK, or explicit refresh.
        if refreshPendingCount {
            pendingCheckGeneration &+= 1
            pendingCountIsKnown = false
            pendingCheckRequested = true
            startPendingCheckIfNeeded()
        }
        let warning = repository.priorityCaptureWarning ?? priorityWarning ?? pendingSyncWarning ?? diagnosticWarning
        if lastPublishedWarning != warning {
            lastPublishedWarning = warning
            onWarning?(warning)
        }
        statusRevision &+= 1
        onStatus?(WatchRecordingStatus(
            revision: statusRevision,
            session: session,
            effectiveDuration: sealedDuration + (segmentRate > 0 ? Double(segmentFrames) / segmentRate : 0),
            pendingCount: lastKnownPendingCount,
            pendingCountIsKnown: pendingCountIsKnown,
            pendingCountIsRefreshing: pendingCheckInFlight || pendingCheckRequested, syncWarning: warning,
            recoveryMessage: recoveryMessage,
            sealedCount: sealedCount, freeBytes: availableBytes(), firstAudioAt: firstAudioAt, detail: currentDetail
        ))
    }

    /// Called only on the writer queue; at most one history read is outstanding.
    private func startPendingCheckIfNeeded() {
        guard pendingCheckRequested, !pendingCheckInFlight else { return }
        pendingCheckRequested = false
        pendingCheckInFlight = true
        let generation = pendingCheckGeneration
        pendingCheckQueue.async { [self] in
            let result = Result { try pendingCountProvider() }
            queue.async { [self] in
                pendingCheckInFlight = false
                if generation == pendingCheckGeneration {
                    switch result {
                    case .success(let count):
                        lastKnownPendingCount = count
                        pendingCountIsKnown = true
                        pendingSyncWarning = nil
                    case .failure(let error):
                        pendingCountIsKnown = false
                        pendingSyncWarning = "同步状态暂时无法核对：\(error.localizedDescription)"
                    }
                    publish()
                }
                startPendingCheckIfNeeded()
            }
        }
    }

    private func appendEvent(kind: String, detail: String, intervalStart: Date? = nil, intervalEnd: Date? = nil) {
        do {
            try repository.appendEvent(RecordingEvent(kind: kind, detail: detail, sessionID: session?.id,
                                                      intervalStart: intervalStart, intervalEnd: intervalEnd))
        } catch {
            // A recording cannot be claimed healthy if its durability journal cannot be written.
            reportFailure("无法保存录音状态：\(error.localizedDescription)")
        }
    }

    private func reportFailure(_ message: String) {
        disableInput()
        let firstFailure = !writeFailed
        writeFailed = true
        recoveryRequired = true
        currentDetail = message
        if firstFailure { onFailure?(message) }
    }

    private func availableBytes() -> Int64? {
        (try? FileManager.default.attributesOfFileSystem(forPath: root.path)[.systemFreeSize] as? NSNumber)?.int64Value
    }

    private static func copy(_ source: AVAudioPCMBuffer, offset: AVAudioFrameCount,
                             count: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard count > 0, offset + count <= source.frameLength,
              let destination = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: count) else { return nil }
        destination.frameLength = count
        let sources = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let destinations = UnsafeMutableAudioBufferListPointer(destination.mutableAudioBufferList)
        guard sources.count == destinations.count else { return nil }
        let stride = Int(source.format.streamDescription.pointee.mBytesPerFrame)
        guard stride > 0 else { return nil }
        for index in sources.indices {
            guard let from = sources[index].mData, let to = destinations[index].mData,
                  Int(sources[index].mDataByteSize) >= (Int(offset) + Int(count)) * stride else { return nil }
            memcpy(to, from.advanced(by: Int(offset) * stride), Int(count) * stride)
        }
        return destination
    }

    private struct CapturedBuffer: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        let startedAt: Date
        let hasHardwareTime: Bool
    }

    private enum WriterError: LocalizedError {
        case missingSession, invalidFormat, bufferCopyFailed, insufficientStorage
        var errorDescription: String? {
            switch self {
            case .missingSession: return "没有可写入的录音会话"
            case .invalidFormat: return "麦克风音频格式不可用"
            case .bufferCopyFailed: return "无法分配音频缓冲"
            case .insufficientStorage: return "可用空间不足；未确认的录音不会被自动删除"
            }
        }
    }
}

/// A short in-memory envelope of audio already accepted by the writer.
final class WatchRecordingWaveform: @unchecked Sendable {
    static let barsPerSecond = 24.0
    private static let historyCount = 48

    struct Snapshot {
        let levels: [Double]
        let latestSampleAt: Date?
    }

    private struct Bucket {
        var frames = 0
        var samples = 0
        var power = 0.0
        var peak = 0.0

        var level: Double {
            guard samples > 0, power > 0 else { return 0 }
            let rmsPower = power / Double(samples)
            let decibels = 10 * log10(0.8 * rmsPower + 0.2 * peak * peak)
            return min(1, max(0, (decibels + 56) / 47))
        }
    }

    private let lock = NSLock()
    private var visible = false
    private var generation: UInt64 = 0
    private var levels = Array(repeating: 0.0, count: historyCount)
    private var next = 0
    private var latestSampleAt: Date?
    private var bucket = Bucket()
    private var framesPerBar = 0

    func setVisible(_ value: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard visible != value else { return }
        visible = value
        clear()
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        clear()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(levels: Array(levels[next...] + levels[..<next]), latestSampleAt: latestSampleAt)
    }

    func observe(_ buffer: AVAudioPCMBuffer, startedAt: Date) {
        let frameCount = Int(buffer.frameLength)
        let rate = buffer.format.sampleRate
        let channelStride = buffer.stride
        guard frameCount > 0, rate.isFinite, rate > 0, channelStride > 0 else { return }
        let bucketSize = max(1, Int((rate / Self.barsPerSecond).rounded()))
        lock.lock()
        let current = visible ? generation : nil
        var pending = framesPerBar == bucketSize ? bucket : Bucket()
        lock.unlock()
        guard let current else { return }

        // Carry partial windows across tap buffers so the audio clock, rather
        // than callback size, determines the spacing of the bars.
        var measured: [Double] = []
        var completedAt: Date?
        func measure(_ sample: (Int) -> Double) {
            var offset = 0
            while offset < frameCount {
                let end = offset + min(bucketSize - pending.frames, frameCount - offset)
                for frame in stride(from: offset, to: end, by: 4) {
                    let value = sample(frame * channelStride)
                    if value.isFinite {
                        pending.power += value * value
                        pending.peak = max(pending.peak, abs(value))
                        pending.samples += 1
                    }
                }
                pending.frames += end - offset
                if pending.frames == bucketSize {
                    measured.append(pending.level)
                    completedAt = startedAt.addingTimeInterval(Double(end) / rate)
                    pending = Bucket()
                }
                offset = end
            }
        }

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let channel = buffer.floatChannelData?[0] else { return }
            measure { Double(channel[$0]) }
        case .pcmFormatFloat64:
            let audio = buffer.audioBufferList.pointee.mBuffers
            let sampleCount = (frameCount - 1) * channelStride + 1
            guard Int(audio.mDataByteSize) / MemoryLayout<Double>.stride >= sampleCount,
                  let channel = audio.mData?.assumingMemoryBound(to: Double.self) else { return }
            measure { channel[$0] }
        case .pcmFormatInt16:
            guard let channel = buffer.int16ChannelData?[0] else { return }
            measure { Double(channel[$0]) / 32_768 }
        case .pcmFormatInt32:
            guard let channel = buffer.int32ChannelData?[0] else { return }
            measure { Double(channel[$0]) / 2_147_483_648 }
        default:
            return
        }

        lock.lock()
        defer { lock.unlock() }
        guard visible, current == generation else { return }
        bucket = pending
        framesPerBar = bucketSize
        if let completedAt { latestSampleAt = completedAt }
        for value in measured {
            levels[next] = value
            next = (next + 1) % Self.historyCount
        }
    }

    private func clear() {
        generation &+= 1
        levels = Array(repeating: 0, count: Self.historyCount)
        next = 0
        latestSampleAt = nil
        bucket = Bucket()
        framesPerBar = 0
    }
}
