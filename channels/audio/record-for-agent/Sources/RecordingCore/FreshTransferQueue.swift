import Foundation

/// The exact selected head, not authority to acknowledge or remove audio.
public struct FreshTransferPriorityIdentity: Equatable, Sendable {
    public let epochID: UUID
    public let headID: UUID
    public let position: Int
}

/// One already committed candidate, in durable seal order. Admission does not
/// acknowledge it or advance either durable acknowledgement cursor.
public struct FreshTransferAdmission: Equatable, Sendable {
    public let manifest: SegmentManifest
    public let position: Int
}

/// Local scheduling metadata. Never a receipt or permission to remove audio.
public struct FreshTransferQueueSnapshot: Sendable {
    public let captureOpen: Bool
    public let head: SegmentManifest?
    /// A conservative global-log remainder, including out-of-order ACK holes.
    public let remainingCount: Int
    /// Selection stopped before filling the requested bounded window. A later
    /// pass may still require the same head ACK; this is not progress evidence.
    public let needsAnotherPass: Bool
    public let checkedCount: Int
    public let headEpochID: UUID?
    public let unresolvedOpenCount: Int
    /// Nil for a legacy/global fallback head and before a priority head seals.
    public let priorityIdentity: FreshTransferPriorityIdentity?
    /// A bounded pipeline in the selected priority range. ACK holes retain the
    /// head; a transport callback never advances this window by itself.
    public let admissions: [FreshTransferAdmission]
    public var blocksHistory: Bool { captureOpen || remainingCount > 0 || unresolvedOpenCount > 0 }
}

struct FreshCaptureBoundary: Codable, Equatable {
    let epochID: UUID
    let sessionID: UUID
    let nextSequence: Int
}
struct FreshTransferEntry: Codable, Equatable {
    let boundary: FreshCaptureBoundary
    let segmentID: UUID
    let position: Int
}
private struct FreshTransferState: Codable {
    var version = 1
    var capture: FreshCaptureBoundary?
    var sessions: [UUID] = []
    var openSegmentIDs: [UUID] = []
    var count = 0
    var head = 0
    var blocked = false
    var blockedCanBeRepairedByAudioTransaction = false
    var priorityEpochID: UUID?
    var prioritySessionID: UUID?
    var priorityStartPosition: Int?
    var priorityCursor: Int?

    enum CodingKeys: String, CodingKey {
        case version, capture, sessions, openSegmentIDs, count, head, blocked, blockedCanBeRepairedByAudioTransaction
        case priorityEpochID, prioritySessionID, priorityStartPosition, priorityCursor
    }
    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        capture = try values.decodeIfPresent(FreshCaptureBoundary.self, forKey: .capture)
        sessions = try values.decode([UUID].self, forKey: .sessions)
        openSegmentIDs = try values.decode([UUID].self, forKey: .openSegmentIDs)
        count = try values.decode(Int.self, forKey: .count)
        head = try values.decode(Int.self, forKey: .head)
        blocked = try values.decode(Bool.self, forKey: .blocked)
        blockedCanBeRepairedByAudioTransaction = try values.decode(Bool.self, forKey: .blockedCanBeRepairedByAudioTransaction)
        let priorityKeys: [CodingKeys] = [.priorityEpochID, .prioritySessionID, .priorityStartPosition, .priorityCursor]
        if priorityKeys.contains(where: values.contains) {
            // Only the complete absence of these fields is a legacy queue.
            priorityEpochID = try values.decode(UUID.self, forKey: .priorityEpochID)
            prioritySessionID = try values.decode(UUID.self, forKey: .prioritySessionID)
            priorityStartPosition = try values.decode(Int.self, forKey: .priorityStartPosition)
            priorityCursor = try values.decode(Int.self, forKey: .priorityCursor)
        }
    }
}

extension RecordingRepository {
    private var freshDirectory: URL { root.appendingPathComponent("fresh-transfer", isDirectory: true) }
    private var freshInitializedURL: URL { root.appendingPathComponent("fresh-transfer.initialized") }
    private var freshStateURL: URL { freshDirectory.appendingPathComponent("state.json") }
    private var freshLogURL: URL { freshDirectory.appendingPathComponent("order.ids") }
    private func freshBoundariesURL(_ id: UUID) -> URL {
        freshDirectory.appendingPathComponent("session-" + id.uuidString.lowercased() + ".json")
    }
    private func freshEntryURL(_ id: UUID) -> URL { freshDirectory.appendingPathComponent(id.uuidString.lowercased() + ".json") }
    private func readFreshBoundaries(sessionID: UUID) throws -> [FreshCaptureBoundary] {
        let values = try TransportCodec.decode([FreshCaptureBoundary].self,
            from: Data(contentsOf: freshBoundariesURL(sessionID)))
        guard !values.isEmpty,
              values.allSatisfy({ $0.sessionID == sessionID && $0.nextSequence >= 0 }) else {
            throw RepositoryError.persistenceFailure("新录音范围记录损坏")
        }
        return values
    }
    private func readFreshState() throws -> FreshTransferState? {
        let initialized = try RecordingMetadataAccess.exists(at: freshInitializedURL)
        guard try RecordingMetadataAccess.exists(at: freshDirectory) else {
            if initialized { throw RepositoryError.persistenceFailure("新录音发送顺序目录缺失") }
            return nil
        }
        let state = try TransportCodec.decode(FreshTransferState.self, from: Data(contentsOf: freshStateURL))
        guard state.version == 1, state.head >= 0, state.count >= state.head, state.count <= Int.max / 37,
              state.capture.map({ $0.nextSequence >= 0 }) ?? true else {
            throw RepositoryError.persistenceFailure("新录音发送顺序需要修复")
        }
        if let epoch = state.priorityEpochID, let session = state.prioritySessionID,
           let start = state.priorityStartPosition, let cursor = state.priorityCursor {
            guard start >= 0, start <= cursor, cursor <= state.count,
                  state.sessions.contains(session),
                  state.capture.map({ $0.epochID == epoch }) ?? true,
                  try readFreshBoundaries(sessionID: session).contains(where: { $0.epochID == epoch }) else {
                throw RepositoryError.persistenceFailure("当前新录音优先范围需要恢复")
            }
        }
        let size = try FileManager.default.attributesOfItem(atPath: freshLogURL.path)[.size] as? NSNumber
        guard let size, size.int64Value >= Int64(state.count) * 37 else {
            throw RepositoryError.persistenceFailure("新录音发送顺序不完整")
        }
        // A previously visible write with a failed fsync is not durability proof.
        try synchronizeFile(freshStateURL)
        try synchronizeDirectory(freshDirectory)
        return state
    }

    /// Call only after recovering the prior open audio and determining nextSequence.
    /// Automatic recovery can change session while retaining the same user epoch.
    public func beginPriorityCapture(sessionID: UUID, nextSequence: Int, newEpoch: Bool) throws {
        try synchronized {
          do {
            guard nextSequence >= 0 else { throw RepositoryError.invalidManifest("片段序号无效") }
            var state: FreshTransferState
            if let existing = try readFreshState() { state = existing }
            else {
                try FileManager.default.createDirectory(at: freshDirectory, withIntermediateDirectories: true)
                try applyFileProtection(freshDirectory)
                try Data().write(to: freshLogURL, options: .atomic)
                try synchronizeFile(freshLogURL)
                try synchronizeDirectory(freshDirectory)
                state = FreshTransferState()
            }
            if try !RecordingMetadataAccess.exists(at: freshInitializedURL) {
                try Data("1\n".utf8).write(to: freshInitializedURL, options: .atomic)
                try synchronizeFile(freshInitializedURL)
                try synchronizeDirectory(root)
            }
            guard !state.blocked else { throw RepositoryError.persistenceFailure("新录音发送顺序等待恢复") }
            let epoch = !newEpoch ? (state.capture?.epochID ?? state.priorityEpochID ?? UUID()) : UUID()
            let boundary = FreshCaptureBoundary(epochID: epoch, sessionID: sessionID, nextSequence: nextSequence)
            let boundaryURL = freshBoundariesURL(sessionID)
            var boundaries = try RecordingMetadataAccess.exists(at: boundaryURL)
                ? try readFreshBoundaries(sessionID: sessionID) : []
            if boundaries.last != boundary { boundaries.append(boundary) }
            try persist(boundaries, at: boundaryURL)
            state.capture = boundary
            if !state.sessions.contains(sessionID) { state.sessions.append(sessionID) }
            if newEpoch {
                state.priorityEpochID = epoch
                state.prioritySessionID = sessionID
                state.priorityStartPosition = state.count
                state.priorityCursor = state.count
            }
            try freshFault?(.beforeFreshCaptureCommit)
            try persist(state, at: freshStateURL)
            freshPriorityFailure = nil
          } catch { blockPriorityCapture(error); throw error }
        }
    }

    /// Close only after all accepted buffers and the final segment have committed.
    public func closePriorityCapture() throws {
        try synchronized {
            guard freshPriorityFailure == nil else { throw RepositoryError.persistenceFailure(freshPriorityFailure!) }
            guard var state = try readFreshState() else { return }
            guard !state.blocked else { throw RepositoryError.persistenceFailure("新录音发送顺序等待恢复") }
            do {
                try freshFault?(.beforeFreshCloseCommit)
                state.capture = nil
                try persist(state, at: freshStateURL)
                try freshFault?(.afterFreshCloseCommit)
            } catch { blockPriorityCapture(error); throw error }
        }
    }


    /// Recovery calls this before any session lookup or CAF parsing. It repairs
    /// a process exit between the original identity journal and scheduling hint.
    public func registerPriorityOpenSegmentForRecovery(_ segment: OpenAudioSegment) {
        synchronized { notePriorityOpenSegment(segment) }
    }

    /// Record the identity before its first sample. A future failed recovery or
    /// new session cannot silently erase an earlier unsealed fresh tail.
    func notePriorityOpenSegment(_ segment: OpenAudioSegment) {
        do {
            guard var state = try readFreshState() else { return }
            let url = freshBoundariesURL(segment.sessionID)
            guard try RecordingMetadataAccess.exists(at: url) else {
                if state.sessions.contains(segment.sessionID) { throw RepositoryError.persistenceFailure("新录音范围记录缺失") }
                return
            }
            let boundaries = try readFreshBoundaries(sessionID: segment.sessionID)
            guard boundaries.contains(where: { $0.sessionID == segment.sessionID && segment.sequence >= $0.nextSequence }) else { return }
            if !state.openSegmentIDs.contains(segment.id) {
                state.openSegmentIDs.append(segment.id)
                try persist(state, at: freshStateURL)
            }
        } catch { blockPriorityCapture(error) }
    }

    /// Remove an open-tail gate only after its entry and exact manifest commit.
    func notePrioritySegmentCommitted(_ manifest: SegmentManifest) throws {
        guard var state = try readFreshState(), state.openSegmentIDs.contains(manifest.id) else { return }
        let entry = try TransportCodec.decode(FreshTransferEntry.self, from: Data(contentsOf: freshEntryURL(manifest.id)))
        guard entry.segmentID == manifest.id, entry.position >= 0, entry.position < state.count else {
            throw RepositoryError.persistenceFailure("新录音尾段顺序尚未提交")
        }
        state.openSegmentIDs.removeAll { $0 == manifest.id }
        try persist(state, at: freshStateURL)
    }

    public var priorityCaptureWarning: String? { synchronized { freshPriorityFailure } }

    func priorityEntry(for manifest: SegmentManifest) throws -> FreshTransferEntry? {
        guard freshPriorityFailure == nil else { throw RepositoryError.persistenceFailure(freshPriorityFailure!) }
        guard let state = try readFreshState() else { return nil }
        guard !state.blocked else { throw RepositoryError.persistenceFailure("新录音发送顺序等待恢复") }
        let boundaryURL = freshBoundariesURL(manifest.sessionID)
        guard try RecordingMetadataAccess.exists(at: boundaryURL) else {
            if state.sessions.contains(manifest.sessionID) || state.capture?.sessionID == manifest.sessionID {
                throw RepositoryError.persistenceFailure("新录音范围记录缺失")
            }
            return nil
        }
        let boundaries = try readFreshBoundaries(sessionID: manifest.sessionID)
        guard let boundary = boundaries.last(where: { manifest.sequence >= $0.nextSequence }) else { return nil }
        if try RecordingMetadataAccess.exists(at: freshEntryURL(manifest.id)) {
            let entry = try TransportCodec.decode(FreshTransferEntry.self, from: Data(contentsOf: freshEntryURL(manifest.id)))
            guard entry.segmentID == manifest.id, entry.boundary.epochID == boundary.epochID else {
                throw RepositoryError.conflictingSegment
            }
            return entry
        }
        guard !state.blocked, freshPriorityFailure == nil else {
            throw RepositoryError.persistenceFailure("新录音发送顺序等待恢复")
        }
        return FreshTransferEntry(boundary: boundary, segmentID: manifest.id, position: state.count)
    }

    /// The pending audio transaction owns this position until manifest commit.
    /// Replaying an append uses the same offset and cannot duplicate or reorder it.
    func appendFreshEntry(_ entry: FreshTransferEntry) throws {
        guard var state = try readFreshState(), entry.position >= 0, entry.position < Int.max / 37,
              entry.position <= state.count else { throw RepositoryError.persistenceFailure("新录音发送顺序无效") }
        let url = freshEntryURL(entry.segmentID)
        if try RecordingMetadataAccess.exists(at: url) {
            guard try TransportCodec.decode(FreshTransferEntry.self, from: Data(contentsOf: url)) == entry else {
                throw RepositoryError.conflictingSegment
            }
        } else { try persist(entry, at: url) }
        try freshFault?(.beforeFreshAppend)
        let bytes = Data((entry.segmentID.uuidString.lowercased() + "\n").utf8)
        let handle = try FileHandle(forUpdating: freshLogURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(entry.position * 37))
        let existing = try handle.read(upToCount: 37) ?? Data()
        if existing.count == 37 {
            guard existing == bytes else { throw RepositoryError.conflictingSegment }
        } else {
            guard entry.position == state.count else { throw RepositoryError.persistenceFailure("新录音顺序记录损坏") }
            try handle.seek(toOffset: UInt64(entry.position * 37))
            try handle.write(contentsOf: bytes)
            try handle.truncate(atOffset: UInt64((entry.position + 1) * 37))
        }
        try handle.synchronize()
        try freshFault?(.afterFreshAppend)
        if entry.position == state.count {
            state.count += 1
            try persist(state, at: freshStateURL)
        }
    }

    func blockPriorityCapture(_ error: Error, pendingTransactionCanRepair: Bool = false) {
        freshPriorityFailure = "新录音已保留，发送顺序需恢复：\(error.localizedDescription)"
        if var state = try? readFreshState() {
            state.blockedCanBeRepairedByAudioTransaction = state.blocked
                ? state.blockedCanBeRepairedByAudioTransaction && pendingTransactionCanRepair
                : pendingTransactionCanRepair
            state.blocked = true
            try? persist(state, at: freshStateURL)
        }
    }

    /// Ordinary transaction recovery may repair the append before clearing this gate.
    func finishPriorityRecovery(succeeded: Bool) throws {
        guard succeeded else { return }
        guard var state = try readFreshState() else { freshPriorityFailure = nil; return }
        // Absence of a pending audio WAL says nothing about a failed capture
        // boundary, a raw open tail, or an unconfirmed close. Only exact audio
        // transaction repair may clear its own recoverable scheduling failure.
        if state.blocked, !state.blockedCanBeRepairedByAudioTransaction {
            freshPriorityFailure = "新录音发送顺序需要核对，原始音频已保留。"
            return
        }
        state.blocked = false
        state.blockedCanBeRepairedByAudioTransaction = false
        try persist(state, at: freshStateURL)
        freshPriorityFailure = nil
    }

    public func isProtectedFreshSegment(_ manifest: SegmentManifest) throws -> Bool {
        try synchronized {
            guard let state = try readFreshState() else { return false }
            let url = freshEntryURL(manifest.id)
            guard try RecordingMetadataAccess.exists(at: url) else { return false }
            let entry = try TransportCodec.decode(FreshTransferEntry.self, from: Data(contentsOf: url))
            guard entry.segmentID == manifest.id, entry.position >= 0, entry.position < state.count else {
                throw RepositoryError.persistenceFailure("新录音顺序需要恢复")
            }
            return entry.position >= state.head
        }
    }

    private func openCompleteFreshLog(_ state: FreshTransferState) throws -> FileHandle {
        let size = try FileManager.default.attributesOfItem(atPath: freshLogURL.path)[.size] as? NSNumber
        guard size?.int64Value == Int64(state.count) * 37 else {
            throw RepositoryError.persistenceFailure("新录音顺序事务等待恢复")
        }
        return try FileHandle(forReadingFrom: freshLogURL)
    }

    /// A bounded candidate read must bind the log, entry, committed manifest and
    /// archived boundary. An unrelated/missing boundary is never an old epoch.
    private func readFreshCandidate(at position: Int, state: FreshTransferState,
                                    log: FileHandle) throws -> (FreshTransferEntry, SegmentManifest) {
        guard position >= 0, position < state.count else { throw RepositoryError.conflictingSegment }
        try log.seek(toOffset: UInt64(position * 37))
        let data = try log.read(upToCount: 37) ?? Data()
        guard data.count == 37, data.last == 10,
              let text = String(data: data.dropLast(), encoding: .utf8), let id = UUID(uuidString: text),
              text == id.uuidString.lowercased() else {
            throw RepositoryError.persistenceFailure("新录音队首记录损坏")
        }
        let entry = try TransportCodec.decode(FreshTransferEntry.self, from: Data(contentsOf: freshEntryURL(id)))
        let manifest = try self.manifest(id: id)
        guard entry.segmentID == id, entry.position == position,
              state.sessions.contains(manifest.sessionID), manifest.sessionID == entry.boundary.sessionID,
              try readFreshBoundaries(sessionID: manifest.sessionID)
                .last(where: { manifest.sequence >= $0.nextSequence }) == entry.boundary else {
            throw RepositoryError.conflictingSegment
        }
        return (entry, manifest)
    }

    /// Fixed-file identity revalidation; boundary data can grow per session.
    /// No cursor advancement or whole-library scan occurs here.
    public func isCurrentPriority(_ identity: FreshTransferPriorityIdentity) throws -> Bool {
        try synchronized {
            guard freshPriorityFailure == nil else { throw RepositoryError.persistenceFailure(freshPriorityFailure!) }
            guard let state = try readFreshState() else { return false }
            guard !state.blocked else { throw RepositoryError.persistenceFailure("新录音发送顺序等待恢复") }
            guard state.priorityEpochID == identity.epochID, state.priorityCursor == identity.position,
                  identity.position < state.count else { return false }
            let log = try openCompleteFreshLog(state)
            defer { try? log.close() }
            let (entry, manifest) = try readFreshCandidate(at: identity.position, state: state, log: log)
            guard entry.segmentID == identity.headID, entry.boundary.epochID == identity.epochID,
                  try !hasDurableAcknowledgement(for: manifest) else { return false }
            return try pendingSegment(id: identity.headID) == manifest
        }
    }

    /// Serialize only the final short metadata/intent/cancel operation with a
    /// new capture boundary. Callers must not hash or await callbacks in `body`.
    @discardableResult
    public func withCurrentPriority(_ identity: FreshTransferPriorityIdentity,
                                    _ body: () throws -> Void) throws -> Bool {
        try synchronized {
            guard try isCurrentPriority(identity) else { return false }
            try body()
            return true
        }
    }

    /// The same short admission guard for legacy/global fallback heads. It
    /// cannot rescan or consume an additional background candidate budget.
    @discardableResult
    public func withCurrentFreshHead(_ manifest: SegmentManifest,
                                     priority: FreshTransferPriorityIdentity?,
                                     _ body: () throws -> Void) throws -> Bool {
        try synchronized {
            if let priority {
                guard priority.headID == manifest.id, try self.manifest(id: manifest.id) == manifest else { return false }
                return try withCurrentPriority(priority, body)
            }
            guard freshPriorityFailure == nil else { throw RepositoryError.persistenceFailure(freshPriorityFailure!) }
            guard let state = try readFreshState() else { return false }
            guard !state.blocked else { throw RepositoryError.persistenceFailure("新录音发送顺序等待恢复") }
            guard state.priorityEpochID == nil || (state.capture == nil && state.priorityCursor == state.count),
                  state.head < state.count else { return false }
            let log = try openCompleteFreshLog(state)
            defer { try? log.close() }
            let (_, current) = try readFreshCandidate(at: state.head, state: state, log: log)
            guard current == manifest, try !hasDurableAcknowledgement(for: current),
                  try pendingSegment(id: current.id) == current else { return false }
            try body()
            return true
        }
    }

    /// Revalidate the same selected head and scope immediately before a later
    /// window member is handed to the system. A concurrent explicit resume, ACK,
    /// manifest replacement or damaged entry revokes the old admission snapshot.
    @discardableResult
    public func withCurrentFreshAdmission(_ admission: FreshTransferAdmission,
                                          head: SegmentManifest,
                                          priority: FreshTransferPriorityIdentity?,
                                          _ body: () throws -> Void) throws -> Bool {
        try synchronized {
            var admitted = false
            let current = try withCurrentFreshHead(head, priority: priority) {
                guard let state = try readFreshState() else { return }
                let first = priority?.position ?? state.head
                guard admission.position >= first, admission.position < state.count else { return }
                let log = try openCompleteFreshLog(state)
                defer { try? log.close() }
                let (entry, manifest) = try readFreshCandidate(at: admission.position, state: state, log: log)
                guard manifest == admission.manifest,
                      priority.map({ entry.boundary.epochID == $0.epochID }) ?? true,
                      try !hasDurableAcknowledgement(for: manifest),
                      try pendingSegment(id: manifest.id) == manifest else { return }
                try body()
                admitted = true
            }
            return current && admitted
        }
    }

    /// Fixed state metadata only; selecting a larger closed-backlog budget does
    /// not inspect audio or enumerate the source library.
    public func hasClosedFreshBacklog() throws -> Bool {
        try synchronized {
            guard let state = try readFreshState(), !state.blocked else { return false }
            return state.capture == nil && state.count > state.head
        }
    }

    /// Native ownership survives a smaller candidate window. This validates the
    /// exact committed identity and epoch, never grants admission or an ACK.
    public func isOwnedFreshTransfer(_ manifest: SegmentManifest,
                                     priority: FreshTransferPriorityIdentity?) throws -> Bool {
        try synchronized {
            guard freshPriorityFailure == nil, let state = try readFreshState(), !state.blocked,
                  try self.manifest(id: manifest.id) == manifest else { return false }
            if let priority {
                guard state.priorityEpochID == priority.epochID, try isCurrentPriority(priority) else { return false }
            } else {
                guard state.capture == nil, state.priorityEpochID == nil || state.priorityCursor == state.count else { return false }
            }
            let entry = try TransportCodec.decode(FreshTransferEntry.self,
                from: Data(contentsOf: freshEntryURL(manifest.id)))
            let log = try openCompleteFreshLog(state)
            defer { try? log.close() }
            let (verified, current) = try readFreshCandidate(at: entry.position, state: state, log: log)
            return verified == entry && current == manifest
                && (priority.map { entry.boundary.epochID == $0.epochID } ?? true)
        }
    }

    /// Historical audio may yield; fresh audio may yield only if its exact
    /// committed entry predates the current explicit begin. A late recovered
    /// old tail is conservatively ineligible until a subsequent explicit begin.
    public func canYieldToPriority(_ manifest: SegmentManifest,
                                   priority: FreshTransferPriorityIdentity) throws -> Bool {
        try synchronized {
            guard try isCurrentPriority(priority), let state = try readFreshState(),
                  let start = state.priorityStartPosition,
                  try pendingSegment(id: manifest.id) == manifest else { return false }
            let url = freshEntryURL(manifest.id)
            guard try RecordingMetadataAccess.exists(at: url) else {
                let boundariesURL = freshBoundariesURL(manifest.sessionID)
                guard try RecordingMetadataAccess.exists(at: boundariesURL) else {
                    guard !state.sessions.contains(manifest.sessionID) else { throw RepositoryError.conflictingSegment }
                    return true
                }
                guard try readFreshBoundaries(sessionID: manifest.sessionID)
                    .last(where: { manifest.sequence >= $0.nextSequence }) == nil else {
                    throw RepositoryError.conflictingSegment
                }
                return true
            }
            let entry = try TransportCodec.decode(FreshTransferEntry.self, from: Data(contentsOf: url))
            let log = try openCompleteFreshLog(state)
            defer { try? log.close() }
            let (verifiedEntry, verifiedManifest) = try readFreshCandidate(at: entry.position, state: state, log: log)
            guard entry == verifiedEntry, verifiedManifest == manifest else { throw RepositoryError.conflictingSegment }
            return entry.position < start && entry.boundary.epochID != priority.epochID
        }
    }

    /// Latest explicit capture first; FIFO within that epoch. Both cursors share
    /// one candidate budget. Only contiguous durable ACKs advance global head.
    /// Notify each attempted read synchronously so callers can charge it even
    /// if that read throws. A revoked/empty budget performs no candidate check.
    public func freshTransferSnapshot(acknowledgementLimit: Int = 8,
                                      maximumAdmissions: Int = 1,
                                      closedCaptureMaximumAdmissions: Int? = nil,
                                      while shouldContinue: () -> Bool = { true },
                                      onCandidateCheck: () -> Void = {}) throws -> FreshTransferQueueSnapshot {
        try synchronized {
            guard freshPriorityFailure == nil else { throw RepositoryError.persistenceFailure(freshPriorityFailure!) }
            guard var state = try readFreshState() else {
                return FreshTransferQueueSnapshot(captureOpen: false, head: nil, remainingCount: 0, needsAnotherPass: false, checkedCount: 0, headEpochID: nil, unresolvedOpenCount: 0, priorityIdentity: nil, admissions: [])
            }
            guard !state.blocked else { throw RepositoryError.persistenceFailure("新录音发送顺序等待恢复") }
            let handle = try openCompleteFreshLog(state)
            defer { try? handle.close() }
            var checked = 0
            let limit = min(64, max(0, acknowledgementLimit))
            func snapshot(head: SegmentManifest? = nil, entry: FreshTransferEntry? = nil,
                          more: Bool = false, priority: Bool = false,
                          admissions: [FreshTransferAdmission] = []) -> FreshTransferQueueSnapshot {
                FreshTransferQueueSnapshot(captureOpen: state.capture != nil, head: head,
                    remainingCount: state.count - state.head, needsAnotherPass: more, checkedCount: checked,
                    headEpochID: entry?.boundary.epochID, unresolvedOpenCount: state.openSegmentIDs.count,
                    priorityIdentity: priority ? entry.map {
                        FreshTransferPriorityIdentity(epochID: $0.boundary.epochID, headID: $0.segmentID, position: $0.position)
                    } : nil, admissions: admissions)
            }
            func ready(_ manifest: SegmentManifest, entry: FreshTransferEntry, priority: Bool) throws -> FreshTransferQueueSnapshot {
                var admissions = [FreshTransferAdmission(manifest: manifest, position: entry.position)]
                var position = entry.position + 1
                let requested = state.capture == nil ? (closedCaptureMaximumAdmissions ?? maximumAdmissions) : maximumAdmissions
                let maximum = min(12, max(1, requested))
                var lookaheadStopped = false
                while admissions.count < maximum, position < state.count, checked < limit, shouldContinue() {
                    checked += 1
                    onCandidateCheck()
                    do {
                        let (nextEntry, nextManifest) = try readFreshCandidate(at: position, state: state, log: handle)
                        position += 1
                        if priority, nextEntry.boundary.epochID != entry.boundary.epochID { continue }
                        if try hasDurableAcknowledgement(for: nextManifest) { continue }
                        guard let pending = try pendingSegment(id: nextManifest.id), pending == nextManifest else {
                            throw RepositoryError.conflictingSegment
                        }
                        admissions.append(FreshTransferAdmission(manifest: pending, position: nextEntry.position))
                    } catch {
                        // A damaged later entry cannot authorize its own send,
                        // but must not revoke the already verified earlier head.
                        // No cursor skips it: it becomes the reported head error
                        // after preceding entries receive their durable ACKs.
                        lookaheadStopped = true
                        break
                    }
                }
                let more = lookaheadStopped || (admissions.count < maximum && position < state.count)
                return snapshot(head: manifest, entry: entry, more: more, priority: priority, admissions: admissions)
            }
            if let epoch = state.priorityEpochID {
                while let cursor = state.priorityCursor, cursor < state.count {
                    guard checked < limit, shouldContinue() else { return snapshot(more: true) }
                    checked += 1
                    onCandidateCheck()
                    let (entry, manifest) = try readFreshCandidate(at: cursor, state: state, log: handle)
                    let acknowledged = try hasDurableAcknowledgement(for: manifest)
                    if entry.boundary.epochID == epoch, !acknowledged {
                        guard let pending = try pendingSegment(id: manifest.id), pending == manifest else {
                            throw RepositoryError.conflictingSegment
                        }
                        return try ready(pending, entry: entry, priority: true)
                    }
                    try freshFault?(.beforeFreshHeadCommit)
                    state.priorityCursor = cursor + 1
                    // Reuse this exact ACK check if both cursors meet. Never
                    // jump global head over any earlier unacknowledged entry.
                    if acknowledged, state.head == cursor { state.head += 1 }
                    try persist(state, at: freshStateURL)
                    try freshFault?(.afterFreshHeadCommit)
                }
                // Do not insert old work into gaps between current seals.
                if state.capture != nil { return snapshot() }
            }
            while state.head < state.count {
                guard checked < limit, shouldContinue() else { return snapshot(more: true) }
                checked += 1
                onCandidateCheck()
                let (entry, manifest) = try readFreshCandidate(at: state.head, state: state, log: handle)
                if try hasDurableAcknowledgement(for: manifest) {
                    try freshFault?(.beforeFreshHeadCommit)
                    state.head += 1
                    try persist(state, at: freshStateURL)
                    try freshFault?(.afterFreshHeadCommit)
                    continue
                }
                guard let pending = try pendingSegment(id: manifest.id), pending == manifest else {
                    throw RepositoryError.conflictingSegment
                }
                return try ready(pending, entry: entry, priority: false)
            }
            return snapshot()
        }
    }
}

/// Preserve the old flat pending-manifest schema for existing recovery tooling.
struct AudioCommitTransaction: Codable {
    let manifest: SegmentManifest
    let freshEntry: FreshTransferEntry?
    let priorityBlocked: Bool
    enum CodingKeys: String, CodingKey { case localFreshEntry, localPriorityBlocked }
    init(manifest: SegmentManifest, freshEntry: FreshTransferEntry?, priorityBlocked: Bool) {
        self.manifest = manifest; self.freshEntry = freshEntry; self.priorityBlocked = priorityBlocked
    }
    init(from decoder: Decoder) throws {
        manifest = try SegmentManifest(from: decoder)
        let values = try decoder.container(keyedBy: CodingKeys.self)
        freshEntry = try values.decodeIfPresent(FreshTransferEntry.self, forKey: .localFreshEntry)
        priorityBlocked = try values.decodeIfPresent(Bool.self, forKey: .localPriorityBlocked) ?? false
    }
    func encode(to encoder: Encoder) throws {
        try manifest.encode(to: encoder)
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(freshEntry, forKey: .localFreshEntry)
        if priorityBlocked { try values.encode(true, forKey: .localPriorityBlocked) }
    }
}
