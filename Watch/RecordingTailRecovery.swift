import Foundation
import RecordingCore

/// Runs only before microphone capture, never on the real-time audio path. One
/// damaged old tail cannot prevent recovery of another or starting a new session.
enum RecordingTailRecovery {
    struct Report {
        let inventory: RecordingInventory
        let message: String?
        let recoveredCount: Int
        let requiresNewSession: Bool
    }

    static func recover(repository: RecordingRepository, at now: Date = Date()) throws -> Report {
        var issues: [String] = []
        do { try repository.recoverPendingTransactions() }
        catch { issues.append("旧片段提交待核对：\(error.localizedDescription)") }

        let initialInventory = try repository.recordingInventory()
        var sessions = Dictionary(uniqueKeysWithValues: initialInventory.sessions.map { ($0.id, $0) })
        let tailInventory: OpenAudioSegmentInventory?
        do { tailInventory = try repository.openAudioSegments() }
        catch {
            issues.append("暂存尾段暂时无法核对：\(error.localizedDescription)")
            tailInventory = nil
        }
        var recoveredCount = 0
        if let tailInventory {
            issues.append(contentsOf: tailInventory.issues.map { "\($0.fileName)：\($0.reason)" })
            for draft in tailInventory.segments {
                repository.registerPriorityOpenSegmentForRecovery(draft)
                do {
                    guard var session = sessions[draft.sessionID] else {
                        throw RepositoryError.invalidManifest("尾段所属会话无法核对，保留原件")
                    }
                    let manifest: SegmentManifest
                    let justRecovered: Bool
                    if let committed = try repository.committedAudioSegment(for: draft) {
                        manifest = committed
                        justRecovered = false
                    } else {
                        let candidateURL = try repository.prepareAudioRecoveryCandidate(for: draft)
                        guard let format = AudioTailRecovery.PCMFormat(rawValue: draft.pcmFormat.rawValue) else {
                            throw RepositoryError.invalidManifest("不支持的尾段采样格式")
                        }
                        let metadata = AudioTailRecovery.Metadata(id: draft.id, sessionID: draft.sessionID,
                            sequence: draft.sequence, startedAt: draft.startedAt, sampleRate: draft.sampleRate,
                            channelCount: draft.channelCount, pcmFormat: format,
                            interleaved: draft.interleaved, timeZoneIdentifier: draft.timeZoneIdentifier)
                        let candidate = try AudioTailRecovery.prepareCandidate(
                            sourceURL: repository.stagingURL(for: draft.id), candidateURL: candidateURL,
                            metadata: metadata)
                        manifest = try repository.commitRecoveredAudioSegment(draft,
                            candidateURL: candidate.candidateURL, frameCount: candidate.frameCount)
                        justRecovered = true
                        recoveredCount += 1
                        do {
                            try repository.appendEvent(RecordingEvent(kind: "tail_recovered",
                                detail: "id=\(draft.id.uuidString) frames=\(candidate.frameCount) partialBytesExcluded=\(candidate.discardedPartialFrameBytes)",
                                sessionID: draft.sessionID, intervalStart: manifest.startedAt, intervalEnd: manifest.endedAt))
                        } catch { issues.append("尾段已恢复，恢复日志待核对：\(error.localizedDescription)") }
                    }

                    // The old heartbeat may include buffers not flushed at exit.
                    // For the current recovered tail, use actual surviving frames.
                    if session.currentSegmentStartedAt == draft.startedAt {
                        session.currentSegmentStartedAt = nil
                        session.lastAudioAt = manifest.endedAt
                    }
                    session.lastSealedAt = max(session.lastSealedAt ?? manifest.endedAt, manifest.endedAt)
                    try repository.saveSession(session)
                    sessions[session.id] = session
                    try repository.completeAudioSegment(draft, justCommitted: justRecovered ? manifest : nil)
                } catch {
                    issues.append("尾段 \(draft.id.uuidString.lowercased()) 已保留待核对：\(error.localizedDescription)")
                }
            }
        }

        // Use independent valid records rather than a strict all-history scan.
        // Corrupt legacy records remain untouched and force a fresh session.
        // On a clean launch the first inventory is already current. Re-read
        // only after a recovery step could have changed the metadata on disk,
        // including a step that wrote one file before reporting a failure.
        let hasDrafts = tailInventory?.segments.isEmpty == false
        let afterRecovery = hasDrafts ? try repository.recordingInventory() : initialInventory
        let interruptedSessions = afterRecovery.sessions.filter { $0.state == .recording || $0.state == .starting }
        for var session in interruptedSessions {
            let sealedBoundary = afterRecovery.manifests.filter { $0.sessionID == session.id }.map(\.endedAt).max()
            let provisionalStart = session.currentSegmentStartedAt ?? session.lastSealedAt ?? session.startedAt
            let start = max(provisionalStart, sealedBoundary ?? session.startedAt)
            do {
                try repository.appendEvent(RecordingEvent(kind: "recovered_unknown_interval",
                    detail: "上次采集未正常结束；已恢复可校验的尾段，其余时间待核对，请主动继续录音。",
                    sessionID: session.id, timestamp: now, intervalStart: start, intervalEnd: max(start, now)))
                session.state = .interrupted
                session.updatedAt = now
                try repository.saveSession(session)
            } catch { issues.append("旧会话中断状态待核对：\(error.localizedDescription)") }
        }
        let finalInventory = interruptedSessions.isEmpty ? afterRecovery : try repository.recordingInventory()
        let oldFileCount = tailInventory?.untrackedAudioCount ?? 0
        let messages = [
            recoveredCount > 0 ? "已恢复 \(recoveredCount) 段异常退出前的音频，原始临时文件已保留。" : nil,
            !issues.isEmpty || !finalInventory.issues.isEmpty
                ? "另有 \(issues.count + finalInventory.issues.count) 项历史录音待核对，原文件保留，不影响新录音。" : nil,
            oldFileCount > 0 ? "\(oldFileCount) 份旧临时音频缺少恢复信息，已保留待核对。" : nil
        ].compactMap { $0 }
        return Report(inventory: finalInventory, message: messages.isEmpty ? nil : messages.joined(separator: " "),
                      recoveredCount: recoveredCount,
                      requiresNewSession: !issues.isEmpty || !finalInventory.issues.isEmpty)
    }
}
