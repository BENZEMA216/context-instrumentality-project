import Combine
import Foundation
import RecordingCore

@MainActor
final class PersonalLibraryStore: ObservableObject {
    struct RecordingTranscription {
        let groupID: UUID
        let failures: [UUID: String]?
    }

    @Published private(set) var snapshot: CloudLibrarySnapshot?
    @Published private(set) var cloudStatus = PrivateCloudLibraryStatus(message: "正在读取个人录音库状态。",
        canUpload: false, isUploading: false, authorizedCount: 0, savedAudioCount: 0,
        savedTranscriptCount: 0, errors: [])
    @Published private(set) var modelStatus: OnDeviceTranscriber.ModelStatus = .unsupportedOS
    @Published private(set) var transcripts: [UUID: SegmentTranscript] = [:]
    @Published private(set) var issues: [UUID: String] = [:]
    @Published private(set) var isBusy = false
    @Published private(set) var activity = ""
    @Published private(set) var error: String?
    @Published private(set) var recordingTranscription: RecordingTranscription?
    @Published var localeIdentifier = "zh-CN"

    let cloud: PrivateCloudLibrary
    let drive: GoogleDriveLibrary
    let iCloudDrive: ICloudDriveLibrary
    lazy var agentConnections = AgentConnectionStore(cloud: cloud, transcriptProvider: { [weak self] in
        self?.transcripts ?? [:]
    })
    private let repository: RecordingRepository
    private let transcriptRepository: TranscriptRepository
    private let transcriber = OnDeviceTranscriber()
    private var operation: Task<Void, Never>?
    private var operationID: UUID?
    private var stateRevision: UInt64 = 0

    init(repository: RecordingRepository, transcriptRepository: TranscriptRepository) {
        self.repository = repository
        self.transcriptRepository = transcriptRepository
        cloud = PrivateCloudLibrary(repository: repository)
        drive = GoogleDriveLibrary(repository: repository, transcriptRepository: transcriptRepository)
        iCloudDrive = ICloudDriveLibrary(repository: repository, transcriptRepository: transcriptRepository)
    }

    var transcriptCount: Int {
        guard let snapshot else { return 0 }
        return snapshot.manifests.filter { transcripts[$0.id] != nil }.count
    }

    var modelReady: Bool {
        if case .ready = modelStatus { return true }
        return false
    }

    /// The receiver already validated and atomically committed this exact source.
    /// Reuse the ordinary Drive discovery path; its separate grant still decides
    /// whether the returned text may be uploaded.
    func receiverTranscriptDidSave(for manifest: SegmentManifest) {
        stateRevision &+= 1
        drive.transcriptDidSave(for: manifest)
        iCloudDrive.transcriptDidSave(for: manifest)
        Task { await refresh() }
    }

    var modelMessage: String {
        switch modelStatus {
        case .unsupportedOS: return "本机转写需要 iOS 26 或更高版本。"
        case .deviceUnavailable: return "这台设备暂不支持本机转写。"
        case .unsupportedLocale: return "本机转写暂不支持所选语言。"
        case .notInstalled: return "先下载所选语言的模型，之后可在本机转写。"
        case .downloading: return "语言模型正在下载。"
        case .ready: return "模型已就绪，音频在本机处理。"
        }
    }

    func refresh() async {
        let observedRevision = stateRevision
        let locale = localeIdentifier
        var refreshedSnapshot: CloudLibrarySnapshot?
        var refreshError: String?
        do {
            refreshedSnapshot = try await cloud.initialSnapshot()
        } catch { refreshError = error.localizedDescription }
        let manifests = refreshedSnapshot?.manifests ?? []
        let transcriptRepository = transcriptRepository
        let refreshedText = await Task.detached(priority: .utility) {
            transcriptRepository.availableTranscripts(for: manifests)
        }.value
        let refreshedCloud = await cloud.status()
        let refreshedModel = await transcriber.modelStatus(localeIdentifier: locale)
        guard !Task.isCancelled, stateRevision == observedRevision, localeIdentifier == locale else { return }
        snapshot = refreshedSnapshot
        transcripts = refreshedText.transcripts
        let authorizedIDs = Set(manifests.map(\.id))
        issues = issues.filter { authorizedIDs.contains($0.key) && transcripts[$0.key] == nil }
            .merging(refreshedText.issues) { _, current in current }
        cloudStatus = refreshedCloud
        modelStatus = refreshedModel
        if let refreshError { error = refreshError }
    }

    func captureInitialSnapshot(_ manifests: [SegmentManifest]) {
        guard !isBusy else { return }
        let id = begin("正在确定首批录音范围。")
        operation = Task {
            defer { finish(id) }
            do {
                snapshot = try await cloud.captureInitialSnapshot(manifests)
                try Task.checkCancellation()
                await refresh()
                activity = "已确定首批 \(snapshot?.manifests.count ?? 0) 段。之后新增的录音不会自动加入。"
            } catch { self.error = error.localizedDescription }
        }
    }

    func prepareModel() {
        guard !isBusy else { return }
        let id = begin("正在准备本机语言模型，首次下载可能需要一些时间。")
        let locale = localeIdentifier
        operation = Task {
            defer { finish(id) }
            do {
                modelStatus = try await transcriber.prepareModel(localeIdentifier: locale)
                activity = "本机转写模型已就绪。"
            } catch is CancellationError { activity = "已取消模型准备。" }
            catch { self.error = error.localizedDescription }
        }
    }

    func refreshTranscriptionModel() async {
        let observedRevision = stateRevision
        let locale = localeIdentifier
        let status = await transcriber.modelStatus(localeIdentifier: locale)
        guard !Task.isCancelled, stateRevision == observedRevision, localeIdentifier == locale else { return }
        modelStatus = status
    }

    func availableTranscripts(for manifests: [SegmentManifest]) async -> TranscriptRepository.AvailableTranscripts {
        let transcriptRepository = transcriptRepository
        return await Task.detached(priority: .utility) {
            transcriptRepository.availableTranscripts(for: manifests)
        }.value
    }

    func transcribeRecording(_ manifests: [SegmentManifest], groupID: UUID) {
        guard !isBusy, modelReady, !manifests.isEmpty,
              manifests.allSatisfy({ $0.recordingGroupID == groupID }) else { return }
        let id = begin("正在本机转写这条录音。")
        let locale = localeIdentifier
        recordingTranscription = .init(groupID: groupID, failures: nil)
        operation = Task {
            var failures: [UUID: String] = [:]
            defer {
                recordingTranscription = .init(groupID: groupID, failures: failures)
                finish(id)
            }
            for manifest in manifests {
                do {
                    try Task.checkCancellation()
                    let value = try await transcribeAndSave(manifest, locale: locale)
                    if snapshot?.manifests.contains(manifest) == true {
                        transcripts[manifest.id] = value
                        issues.removeValue(forKey: manifest.id)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    failures[manifest.id] = error.localizedDescription
                }
            }
        }
    }

    func cancelRecordingTranscription(for groupID: UUID) {
        guard let recordingTranscription, recordingTranscription.groupID == groupID,
              recordingTranscription.failures == nil else { return }
        operation?.cancel()
    }

    func transcribeInitialSnapshot() {
        guard !isBusy, let snapshot, modelReady else { return }
        let id = begin("正在准备首批录音的转写。")
        let locale = localeIdentifier
        operation = Task {
            defer { finish(id) }
            for (index, manifest) in snapshot.manifests.enumerated() {
                if Task.isCancelled { activity = "已停止转写。已完成的文字和原录音仍保留。"; return }
                if transcripts[manifest.id] != nil { continue }
                activity = "正在本机转写第 \(index + 1) / \(snapshot.manifests.count) 段。"
                do {
                    transcripts[manifest.id] = try await transcribeAndSave(manifest, locale: locale)
                    issues.removeValue(forKey: manifest.id)
                } catch is CancellationError {
                    activity = "已停止转写。已完成的文字和原录音仍保留。"
                    return
                } catch {
                    issues[manifest.id] = error.localizedDescription
                }
            }
            activity = "已有 \(transcriptCount) / \(snapshot.manifests.count) 段转写文字。"
            if !issues.isEmpty { activity += "其余结果请查看对应片段。" }
        }
    }

    private func transcribeAndSave(_ manifest: SegmentManifest, locale: String) async throws -> SegmentTranscript {
        let transcriptRepository = transcriptRepository
        let existing = try await Task.detached(priority: .utility) {
            try transcriptRepository.transcript(for: manifest)
        }.value
        if let existing { return existing }
        try Task.checkCancellation()
        let value = try await transcriber.transcribe(audioURL: repository.audioURL(for: manifest),
            manifest: manifest, localeIdentifier: locale)
        try Task.checkCancellation()
        let (saved, inserted) = try await Task.detached(priority: .utility) {
            if try transcriptRepository.saveIfAbsent(value, for: manifest) { return (value, true) }
            guard let existing = try transcriptRepository.transcript(for: manifest) else {
                throw TranscriptRepositoryError.invalidFile
            }
            return (existing, false)
        }.value
        if inserted {
            drive.transcriptDidSave(for: manifest)
            iCloudDrive.transcriptDidSave(for: manifest)
        }
        return saved
    }

    func checkCloudAccount() {
        guard !isBusy else { return }
        let id = begin("正在检查 iCloud 账户。")
        operation = Task {
            defer { finish(id) }
            cloudStatus = await cloud.checkAccount()
            activity = cloudStatus.message
        }
    }

    func saveToCloud() {
        guard !isBusy, snapshot != nil, cloudStatus.canUpload else { return }
        let id = begin("正在保存首批录音到 iCloud。")
        let values = Array(transcripts.values)
        operation = Task {
            defer { finish(id) }
            cloudStatus = await cloud.uploadInitialSnapshot(transcripts: values) { [weak self] status in
                Task { @MainActor [weak self] in
                    guard let self, self.operationID == id else { return }
                    self.cloudStatus = status
                    self.activity = status.message
                }
            }
            activity = cloudStatus.message
        }
    }

    func cancel() {
        guard isBusy else { return }
        activity = "正在停止当前操作。"
        operation?.cancel()
        Task {
            await cloud.cancel()
            cloudStatus = await cloud.status()
        }
    }

    private func begin(_ message: String) -> UUID {
        stateRevision &+= 1
        let id = UUID()
        operationID = id
        isBusy = true
        activity = message
        error = nil
        return id
    }

    private func finish(_ id: UUID) {
        guard operationID == id else { return }
        stateRevision &+= 1
        operationID = nil
        isBusy = false
        operation = nil
    }
}
