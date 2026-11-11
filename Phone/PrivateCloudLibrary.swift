import CloudKit
import CryptoKit
import Foundation
import RecordingCore

struct PrivateCloudLibraryStatus: Equatable, Sendable {
    let message: String
    let canUpload: Bool
    let isUploading: Bool
    let authorizedCount: Int
    let savedAudioCount: Int
    let savedTranscriptCount: Int
    let errors: [String]
}

/// Explicit, user-triggered uploads only. This actor never issues transport ACKs,
/// deletes repository audio, expands the first selection, or rebinds its account.
actor PrivateCloudLibrary {
    typealias Progress = @Sendable (PrivateCloudLibraryStatus) -> Void

    private let repository: RecordingRepository
    private let ledgerURL: URL
    private let configuration: Configuration
    private var ledger = CloudLibraryLedger()
    private var ledgerError: String?
    private var container: CKContainer?
    private var accountObservation: CloudAccountObservation?
    private var activeOperations: [UUID: CKDatabaseOperation] = [:]
    private var generation: UInt64 = 0
    private var activeRun: UUID?
    private var message: String
    private var errors: [String] = []

    init(repository: RecordingRepository, bundle: Bundle = .main) {
        self.repository = repository
        self.ledgerURL = repository.root.appendingPathComponent("CloudLibrary/ledger.json")
        self.configuration = Configuration(bundle: bundle)
        self.message = configuration.unavailableReason ?? "iCloud 已配置。点击保存时会检查账户，并只处理本次授权的录音。"
        do { ledger = try CloudLibraryLedger.load(from: ledgerURL) }
        catch {
            ledgerError = "iCloud 本机记录无法读取，已暂停上传，避免混用账户或录音。"
            message = ledgerError!
        }
    }

    /// This captures metadata only, even in a build without iCloud capability.
    /// Calling it after more recordings arrive does not authorize those recordings.
    @discardableResult
    func captureInitialSnapshot(_ manifests: [SegmentManifest]) throws -> CloudLibrarySnapshot {
        guard ledgerError == nil else { throw Failure.ledgerUnavailable }
        guard activeRun == nil else { throw Failure.busy }
        var candidate = ledger
        let snapshot = try candidate.captureInitialSnapshot(manifests)
        if candidate != ledger {
            try commit(candidate)
        }
        return snapshot
    }

    func boundScope() throws -> CloudLibraryScope? {
        guard ledgerError == nil else { throw Failure.ledgerUnavailable }
        return ledger.scope
    }

    func initialSnapshot() throws -> CloudLibrarySnapshot? {
        guard ledgerError == nil else { throw Failure.ledgerUnavailable }
        return ledger.snapshot
    }

    func savedReceipts() throws -> [CloudLibraryReceipt] {
        guard ledgerError == nil else { throw Failure.ledgerUnavailable }
        return ledger.receipts
    }

    /// A caller such as the gateway can explicitly recheck the current account.
    /// The returned hash is for local session binding, never user-facing text.
    /// Reading it does not bind an unbound snapshot or authorize an upload.
    func verifiedCurrentScope() async throws -> CloudLibraryScope {
        guard ledgerError == nil else { throw Failure.ledgerUnavailable }
        let token = generation
        let scope = try await resolveCurrentScope(generation: token)
        if ledger.scope != nil { try ledger.requireScope(scope) }
        return scope
    }

    /// A local status read never creates CKContainer or starts network work.
    func status() -> PrivateCloudLibraryStatus {
        let unavailable = ledgerError ?? configuration.unavailableReason
        return PrivateCloudLibraryStatus(message: unavailable ?? message,
            canUpload: unavailable == nil && activeRun == nil && ledger.snapshot != nil,
            isUploading: activeRun != nil, authorizedCount: ledger.snapshot?.manifests.count ?? 0,
            savedAudioCount: ledger.savedAudioCount, savedTranscriptCount: ledger.savedTranscriptCount,
            errors: unavailable == nil ? errors : [])
    }

    /// Optional explicit account check. It does not bind an unbound snapshot or upload.
    func checkAccount() async -> PrivateCloudLibraryStatus {
        guard ledgerError == nil, configuration.unavailableReason == nil, activeRun == nil else { return status() }
        let token = generation
        do {
            let scope = try await resolveCurrentScope(generation: token)
            if ledger.scope != nil { try ledger.requireScope(scope) }
            errors = []
            message = ledger.scope == nil
                ? "iCloud 账户可用。本次授权范围尚未上传，首次保存时会绑定这个账户。"
                : "iCloud 账户与本次录音的绑定账户一致，可以继续保存。"
        } catch {
            guard generation == token else { return status() }
            message = Self.userMessage(error)
            errors = [message]
        }
        return status()
    }

    /// The original local audio remains the durable source. Transcripts run after
    /// the audio loop; their failures do not roll back successful audio backups.
    func uploadInitialSnapshot(transcripts: [SegmentTranscript] = [],
                               progress: @escaping Progress = { _ in }) async -> PrivateCloudLibraryStatus {
        guard let run = beginRun() else { return status() }
        let token = generation
        progress(status())
        do {
            guard let snapshot = ledger.snapshot else { throw CloudLibraryLedgerError.noSnapshot }
            let scope = try await scopeForUpload(generation: token, run: run)
            let available = try repository.manifests()
            let local = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0) })
            for (index, manifest) in snapshot.manifests.enumerated() {
                try requireRun(run, generation: token)
                message = "正在保存第 \(index + 1) / \(snapshot.manifests.count) 段录音到 iCloud。"
                progress(status())
                do {
                    guard let current = local[manifest.id] else { throw Failure.localAudioUnavailable }
                    try ledger.requireAuthorized(current)
                    try await saveAudio(manifest, scope: scope, generation: token, run: run)
                } catch {
                    try requireRun(run, generation: token)
                    if Self.mustStopRun(error) { throw error }
                    errors.append("第 \(index + 1) 段：\(Self.userMessage(error))")
                }
                progress(status())
            }
            try await saveTranscripts(transcripts, scope: scope, generation: token, run: run, progress: progress)
            finishRun(run)
        } catch {
            finishRun(run, error: error)
        }
        progress(status())
        return status()
    }

    /// Later transcription can be uploaded separately, for the same authorized
    /// audio and account only. A missing cloud audio record stops that transcript.
    func uploadTranscripts(_ transcripts: [SegmentTranscript],
                           progress: @escaping Progress = { _ in }) async -> PrivateCloudLibraryStatus {
        guard let run = beginRun() else { return status() }
        let token = generation
        progress(status())
        do {
            let scope = try await scopeForUpload(generation: token, run: run)
            try await saveTranscripts(transcripts, scope: scope, generation: token, run: run, progress: progress)
            finishRun(run)
        } catch {
            finishRun(run, error: error)
        }
        progress(status())
        return status()
    }

    /// Cancellation never clears the snapshot, its original owner, or saved receipts.
    /// There is deliberately no reset/rebind method for moving old audio to account B.
    func cancel() {
        generation &+= 1
        activeRun = nil
        activeOperations.values.forEach { $0.cancel() }
        activeOperations.removeAll()
        message = "已停止本次 iCloud 操作。已保存记录和原始录音仍保留，授权范围及绑定账户不变。"
        errors = []
    }

    private func beginRun() -> UUID? {
        guard ledgerError == nil, configuration.unavailableReason == nil, activeRun == nil else { return nil }
        guard ledger.snapshot != nil else {
            message = CloudLibraryLedgerError.noSnapshot.localizedDescription
            errors = [message]
            return nil
        }
        let run = UUID()
        activeRun = run
        errors = []
        message = "正在检查 iCloud 账户。"
        return run
    }

    private func finishRun(_ run: UUID, error: Error? = nil) {
        guard activeRun == run else { return }
        activeRun = nil
        if let error {
            let detail = Self.userMessage(error)
            errors.append(detail)
            message = detail
        } else if errors.isEmpty {
            message = "iCloud 已保存 \(ledger.savedAudioCount) / \(ledger.snapshot?.manifests.count ?? 0) 段录音。云端记录信息已核对，未进行独立音频下载校验。"
        } else {
            message = "iCloud 已保存 \(ledger.savedAudioCount) / \(ledger.snapshot?.manifests.count ?? 0) 段录音，部分内容尚未完成。原始录音仍保留。"
        }
    }

    private func configuredContainer() throws -> CKContainer {
        guard configuration.unavailableReason == nil,
              let identifier = configuration.containerIdentifier else { throw Failure.notConfigured }
        // WRCloudKitEnabled is set only by a signing-verified CloudKit build. The
        // normal and simulator products must leave it false. No private entitlement
        // API or Mach-O inspection is used, and disabled builds never construct this.
        if let container { return container }
        accountObservation = CloudAccountObservation { [weak self] in
            Task { await self?.accountDidChange() }
        }
        let created = CKContainer(identifier: identifier)
        container = created
        return created
    }

    private func accountDidChange() {
        generation &+= 1
        activeRun = nil
        activeOperations.values.forEach { $0.cancel() }
        activeOperations.removeAll()
        message = "iCloud 账户状态发生变化，已停止进行中的操作。原绑定账户和授权录音不变，请重新检查账户。"
        errors = []
    }

    private func requireRun(_ run: UUID, generation token: UInt64) throws {
        try Task.checkCancellation()
        guard token == generation, activeRun == run else { throw Failure.cancelledOrAccountChanged }
    }

    private func resolveCurrentScope(generation token: UInt64) async throws -> CloudLibraryScope {
        try Task.checkCancellation()
        guard generation == token else { throw Failure.cancelledOrAccountChanged }
        let container = try configuredContainer()
        let availability = try await container.accountStatus()
        try Task.checkCancellation()
        guard generation == token else { throw Failure.cancelledOrAccountChanged }
        switch availability {
        case .available: break
        case .noAccount: throw Failure.signedOut
        case .restricted: throw Failure.restricted
        case .couldNotDetermine: throw Failure.accountUnknown
        case .temporarilyUnavailable: throw Failure.accountTemporarilyUnavailable
        @unknown default: throw Failure.accountUnknown
        }
        let user = try await container.userRecordID()
        try Task.checkCancellation()
        guard generation == token else { throw Failure.cancelledOrAccountChanged }
        let ownerHash = Self.digest(Data(user.recordName.utf8))
        guard let identifier = configuration.containerIdentifier,
              let environment = configuration.environment else { throw Failure.notConfigured }
        return CloudLibraryScope(containerIdentifier: identifier, environment: environment, ownerHash: ownerHash)
    }

    private func scopeForUpload(generation token: UInt64, run: UUID) async throws -> CloudLibraryScope {
        let scope = try await resolveCurrentScope(generation: token)
        try requireRun(run, generation: token)
        var candidate = ledger
        try candidate.bind(to: scope)
        if candidate != ledger {
            try commit(candidate)
        }
        return scope
    }

    /// Rechecking on both sides of every cloud mutation prevents a pending job from
    /// being resumed under a newly signed-in user. Account notifications also cancel
    /// the active CKOperations and invalidate their callbacks before local commits.
    private func requireOwner(_ expected: CloudLibraryScope, generation token: UInt64, run: UUID) async throws {
        try requireRun(run, generation: token)
        let current = try await resolveCurrentScope(generation: token)
        try requireRun(run, generation: token)
        try ledger.requireScope(current)
        guard current == expected else { throw CloudLibraryLedgerError.accountChanged }
    }

    private func saveAudio(_ manifest: SegmentManifest, scope: CloudLibraryScope,
                           generation token: UInt64, run: UUID) async throws {
        try ledger.requireAuthorized(manifest)
        try await requireOwner(scope, generation: token, run: run)
        let recordID = CKRecord.ID(recordName: CloudLibraryLedger.audioRecordName(for: manifest.id))
        let database = try configuredContainer().privateCloudDatabase
        if let existing = try await fetchRecord(recordID, database: database) {
            try validateAudioRecord(existing, against: manifest, scope: scope)
        } else {
            try await requireOwner(scope, generation: token, run: run)
            let asset = try stageAudio(manifest)
            defer { try? FileManager.default.removeItem(at: asset.deletingLastPathComponent()) }
            try await requireOwner(scope, generation: token, run: run)
            let record = CKRecord(recordType: "RecordingSegment", recordID: recordID)
            record["schemaVersion"] = NSNumber(value: 1)
            record["ownerHash"] = scope.ownerHash as NSString
            record["segmentID"] = manifest.id.uuidString.lowercased() as NSString
            record["audioSHA256"] = manifest.sha256 as NSString
            record["byteCount"] = NSNumber(value: manifest.byteCount)
            record["manifestData"] = try TransportCodec.encode(manifest) as NSData
            record["audio"] = CKAsset(fileURL: asset)
            record["audioStored"] = NSNumber(value: true)
            do { try await saveNewRecord(record, database: database) }
            catch {
                // Another identical request may have won the create race. Never
                // overwrite it: the readback below must prove exact identity.
                guard (error as? CKError)?.code == .serverRecordChanged else { throw error }
            }
        }
        try await requireOwner(scope, generation: token, run: run)
        guard let readback = try await fetchRecord(recordID, database: database) else { throw Failure.cloudRecordMissing }
        try validateAudioRecord(readback, against: manifest, scope: scope)
        try await requireOwner(scope, generation: token, run: run)
        var candidate = ledger
        try candidate.recordAudioSaved(manifest, in: scope, cloudRecordName: recordID.recordName)
        try commit(candidate)
    }

    private func validateAudioRecord(_ record: CKRecord, against manifest: SegmentManifest,
                                     scope: CloudLibraryScope) throws {
        guard record.recordType == "RecordingSegment",
              record.recordID.recordName == CloudLibraryLedger.audioRecordName(for: manifest.id),
              (record["schemaVersion"] as? NSNumber)?.intValue == 1,
              record["ownerHash"] as? String == scope.ownerHash,
              record["segmentID"] as? String == manifest.id.uuidString.lowercased(),
              record["audioSHA256"] as? String == manifest.sha256,
              (record["byteCount"] as? NSNumber)?.int64Value == manifest.byteCount,
              let encoded = record["manifestData"] as? Data,
              let remote = try? TransportCodec.decode(SegmentManifest.self, from: encoded), remote == manifest,
              (record["audioStored"] as? NSNumber)?.boolValue == true else { throw Failure.cloudContentConflict }
        // audioStored and the CKAsset were written together in one immutable
        // record. This readback intentionally fetches metadata only; it neither
        // downloads nor independently hashes the remote asset bytes.
    }

    private func saveTranscripts(_ transcripts: [SegmentTranscript], scope: CloudLibraryScope,
                                 generation token: UInt64, run: UUID, progress: @escaping Progress) async throws {
        guard let snapshot = ledger.snapshot else { throw CloudLibraryLedgerError.noSnapshot }
        let authorized = Dictionary(uniqueKeysWithValues: snapshot.manifests.map { ($0.id, $0) })
        for transcript in transcripts {
            try requireRun(run, generation: token)
            guard let manifest = authorized[transcript.segmentID] else {
                if !errors.contains(CloudLibraryLedgerError.notAuthorized.localizedDescription) {
                    errors.append(CloudLibraryLedgerError.notAuthorized.localizedDescription)
                }
                continue
            }
            do {
                try transcript.validate(against: manifest)
                guard ledger.receipt(for: manifest.id) != nil else { throw CloudLibraryLedgerError.audioNotSaved }
                message = "正在保存已授权录音的转写文字。原始音频的保存结果保持不变。"
                progress(status())
                try await saveTranscript(transcript, manifest: manifest, scope: scope, generation: token, run: run)
            } catch {
                try requireRun(run, generation: token)
                if Self.mustStopRun(error) { throw error }
                errors.append("转写：\(Self.userMessage(error))")
            }
            progress(status())
        }
    }

    private func saveTranscript(_ transcript: SegmentTranscript, manifest: SegmentManifest,
                                scope: CloudLibraryScope, generation token: UInt64, run: UUID) async throws {
        let encoded = try TransportCodec.encode(transcript)
        guard encoded.count <= 750 * 1_024 else { throw Failure.transcriptTooLarge }
        let contentHash = Self.digest(encoded)
        try await requireOwner(scope, generation: token, run: run)
        let database = try configuredContainer().privateCloudDatabase
        let audioID = CKRecord.ID(recordName: CloudLibraryLedger.audioRecordName(for: manifest.id))
        guard let audio = try await fetchRecord(audioID, database: database) else { throw CloudLibraryLedgerError.audioNotSaved }
        try validateAudioRecord(audio, against: manifest, scope: scope)
        try await requireOwner(scope, generation: token, run: run)
        let recordID = CKRecord.ID(recordName: CloudLibraryLedger.transcriptRecordName(for: manifest.id, contentSHA256: contentHash))
        if let existing = try await fetchRecord(recordID, database: database) {
            try validateTranscriptRecord(existing, transcript: transcript, manifest: manifest, scope: scope, encoded: encoded, contentHash: contentHash)
        } else {
            try await requireOwner(scope, generation: token, run: run)
            let record = CKRecord(recordType: "RecordingTranscript", recordID: recordID)
            record["schemaVersion"] = NSNumber(value: 1)
            record["ownerHash"] = scope.ownerHash as NSString
            record["segmentID"] = manifest.id.uuidString.lowercased() as NSString
            record["audioSHA256"] = manifest.sha256 as NSString
            record["contentSHA256"] = contentHash as NSString
            record["transcriptData"] = encoded as NSData
            do { try await saveNewRecord(record, database: database) }
            catch { guard (error as? CKError)?.code == .serverRecordChanged else { throw error } }
        }
        try await requireOwner(scope, generation: token, run: run)
        guard let readback = try await fetchRecord(recordID, database: database) else { throw Failure.cloudRecordMissing }
        try validateTranscriptRecord(readback, transcript: transcript, manifest: manifest, scope: scope, encoded: encoded, contentHash: contentHash)
        try await requireOwner(scope, generation: token, run: run)
        var candidate = ledger
        try candidate.recordTranscriptSaved(for: manifest, in: scope, contentSHA256: contentHash, cloudRecordName: recordID.recordName)
        try commit(candidate)
    }

    private func commit(_ candidate: CloudLibraryLedger) throws {
        do {
            try candidate.persist(to: ledgerURL)
            ledger = candidate
        } catch {
            // An atomic file may already be visible even if its durability step
            // failed. Freeze this instance instead of recapturing a wider snapshot
            // or binding another account from stale in-memory state.
            ledgerError = "iCloud 本机记录未能可靠保存，已暂停后续操作。原始录音仍保留。"
            throw Failure.ledgerUnavailable
        }
    }

    private func validateTranscriptRecord(_ record: CKRecord, transcript: SegmentTranscript,
                                          manifest: SegmentManifest, scope: CloudLibraryScope,
                                          encoded: Data, contentHash: String) throws {
        guard record.recordType == "RecordingTranscript",
              record.recordID.recordName == CloudLibraryLedger.transcriptRecordName(for: manifest.id, contentSHA256: contentHash),
              (record["schemaVersion"] as? NSNumber)?.intValue == 1,
              record["ownerHash"] as? String == scope.ownerHash,
              record["segmentID"] as? String == manifest.id.uuidString.lowercased(),
              record["audioSHA256"] as? String == manifest.sha256,
              record["contentSHA256"] as? String == contentHash,
              let remoteData = record["transcriptData"] as? Data, remoteData == encoded,
              let remote = try? TransportCodec.decode(SegmentTranscript.self, from: remoteData), remote == transcript else {
            throw Failure.cloudContentConflict
        }
        try remote.validate(against: manifest)
    }

    private func stageAudio(_ manifest: SegmentManifest) throws -> URL {
        let fm = FileManager.default
        let source = repository.audioURL(for: manifest)
        let attributes = try fm.attributesOfItem(atPath: source.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == manifest.byteCount else { throw Failure.localAudioChanged }
        let directory = repository.root.appendingPathComponent("CloudLibrary/UploadStaging/" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
            let copy = directory.appendingPathComponent(manifest.id.uuidString.lowercased() + ".caf")
            try fm.copyItem(at: source, to: copy)
            let copyAttributes = try fm.attributesOfItem(atPath: copy.path)
            guard copyAttributes[.type] as? FileAttributeType == .typeRegular else { throw Failure.localAudioChanged }
            try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: copy.path)
            let fingerprint = try RecordingRepository.fingerprint(of: copy)
            guard fingerprint.sha256 == manifest.sha256, fingerprint.byteCount == manifest.byteCount else { throw Failure.localAudioChanged }
            return copy
        } catch {
            try? fm.removeItem(at: directory)
            throw error
        }
    }

    private func fetchRecord(_ recordID: CKRecord.ID, database: CKDatabase) async throws -> CKRecord? {
        try Task.checkCancellation()
        let operation = CKFetchRecordsOperation(recordIDs: [recordID])
        // Fetching the audio asset would download the whole CAF on each retry.
        // Read only fields used for the explicitly stated metadata verification.
        operation.desiredKeys = ["schemaVersion", "ownerHash", "segmentID", "audioSHA256",
                                 "byteCount", "manifestData", "audioStored", "contentSHA256", "transcriptData"]
        configure(operation)
        let id = UUID()
        activeOperations[id] = operation
        defer { activeOperations[id] = nil }
        let slot = CloudRecordResultSlot()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CKRecord?, Error>) in
                operation.perRecordResultBlock = { _, result in slot.set(result) }
                operation.fetchRecordsResultBlock = { result in
                    if case .failure(let error) = result, (error as? CKError)?.code == .unknownItem {
                        continuation.resume(returning: nil)
                    } else if case .failure(let error) = result, (error as? CKError)?.code != .partialFailure {
                        continuation.resume(throwing: error)
                    } else if let recordResult = slot.get() {
                        switch recordResult {
                        case .success(let record): continuation.resume(returning: record)
                        case .failure(let error):
                            if (error as? CKError)?.code == .unknownItem { continuation.resume(returning: nil) }
                            else { continuation.resume(throwing: error) }
                        }
                    } else if case .failure(let error) = result {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(throwing: Failure.cloudRecordMissing)
                    }
                }
                database.add(operation)
            }
        } onCancel: { operation.cancel() }
    }

    private func saveNewRecord(_ record: CKRecord, database: CKDatabase) async throws {
        try Task.checkCancellation()
        let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
        operation.savePolicy = .ifServerRecordUnchanged
        // The default private zone needs no custom-zone provisioning. This operation
        // creates one immutable record and never performs a multi-record transaction.
        operation.isAtomic = false
        configure(operation)
        let id = UUID()
        activeOperations[id] = operation
        defer { activeOperations[id] = nil }
        let slot = CloudRecordResultSlot()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                operation.perRecordSaveBlock = { _, result in slot.set(result) }
                operation.modifyRecordsResultBlock = { result in
                    if case .failure(let error) = result, (error as? CKError)?.code != .partialFailure {
                        continuation.resume(throwing: error)
                    } else if let saved = slot.get() {
                        switch saved {
                        case .success: continuation.resume(returning: ())
                        case .failure(let error): continuation.resume(throwing: error)
                        }
                    } else if case .failure(let error) = result {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(throwing: Failure.cloudRecordMissing)
                    }
                }
                database.add(operation)
            }
        } onCancel: { operation.cancel() }
    }

    private func configure(_ operation: CKDatabaseOperation) {
        operation.configuration.qualityOfService = .userInitiated
        operation.configuration.isLongLived = false
        operation.configuration.timeoutIntervalForRequest = 60
        operation.configuration.timeoutIntervalForResource = 180
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func mustStopRun(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let ledger = error as? CloudLibraryLedgerError {
            return [.accountChanged, .scopeChanged, .accountNotBound, .invalidLedger, .unsupportedVersion].contains(ledger)
        }
        if let failure = error as? Failure {
            return [.signedOut, .restricted, .accountUnknown, .accountTemporarilyUnavailable, .cancelledOrAccountChanged, .ledgerUnavailable].contains(failure)
        }
        // System/cloud failures are retried only by a later explicit action. A
        // quota or network failure should not fire the entire remaining batch.
        return error is CKError
    }

    private static func userMessage(_ error: Error) -> String {
        if error is CancellationError { return Failure.cancelledOrAccountChanged.localizedDescription }
        if let failure = error as? Failure { return failure.localizedDescription }
        if let ledger = error as? CloudLibraryLedgerError { return ledger.localizedDescription }
        if let transcript = error as? SegmentTranscriptValidationError { return transcript.localizedDescription }
        if let cloud = error as? CKError {
            switch cloud.code {
            case .notAuthenticated: return "请在系统设置中登录 iCloud，再手动重试。"
            case .networkUnavailable, .networkFailure: return "暂时无法连接 iCloud，请检查网络后重试。原始录音仍保留。"
            case .quotaExceeded: return "iCloud 可用空间不足，尚未上传的录音仍保存在手机。"
            case .permissionFailure, .missingEntitlement: return "这个安装版本尚未获得所需的 iCloud 权限，未继续上传。"
            case .serviceUnavailable, .requestRateLimited, .zoneBusy: return "iCloud 暂时忙，请稍后手动重试。"
            case .operationCancelled: return Failure.cancelledOrAccountChanged.localizedDescription
            case .serverRecordChanged: return Failure.cloudContentConflict.localizedDescription
            default: return "iCloud 暂未完成这次保存。原始录音仍保留，可稍后重试。"
            }
        }
        return "读取或保存本机 iCloud 记录失败，原始录音仍保留。请稍后重试。"
    }

    private struct Configuration: Sendable {
        let containerIdentifier: String?
        let environment: String?
        let unavailableReason: String?

        init(bundle: Bundle) {
            #if targetEnvironment(simulator)
            containerIdentifier = nil
            environment = nil
            unavailableReason = "模拟器不会连接真实 iCloud，也不会上传验证用录音。"
            #else
            let raw = bundle.object(forInfoDictionaryKey: "WRCloudKitEnabled")
            let enabled = (raw as? Bool) == true || ["YES", "TRUE", "1"].contains((raw as? String)?.uppercased() ?? "")
            let identifier = (bundle.object(forInfoDictionaryKey: "WRCloudKitContainerIdentifier") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let targetEnvironment = bundle.object(forInfoDictionaryKey: "WRCloudKitEnvironment") as? String
            containerIdentifier = identifier
            environment = targetEnvironment
            if !enabled {
                unavailableReason = "这个安装版本尚未启用 iCloud。录音继续保存在手机，未发起云端操作。"
            } else if let identifier, identifier.hasPrefix("iCloud."), identifier.count > 7,
                      !identifier.contains("$("), !identifier.contains(where: { $0.isWhitespace }),
                      let targetEnvironment, ["Development", "Production"].contains(targetEnvironment) {
                unavailableReason = nil
            } else {
                unavailableReason = "iCloud 容器或环境配置尚未完成，未发起云端操作。"
            }
            #endif
        }
    }

    private enum Failure: LocalizedError, Equatable {
        case notConfigured, ledgerUnavailable, busy, signedOut, restricted, accountUnknown
        case accountTemporarilyUnavailable, cancelledOrAccountChanged, localAudioUnavailable
        case localAudioChanged, cloudContentConflict, cloudRecordMissing, transcriptTooLarge

        var errorDescription: String? {
            switch self {
            case .notConfigured: return "这个安装版本尚未配置 iCloud，未发起云端操作。"
            case .ledgerUnavailable: return "iCloud 本机记录无法读取，已暂停上传。"
            case .busy: return "正在处理本次 iCloud 操作，请等待完成或先停止。"
            case .signedOut: return "这台 iPhone 尚未登录 iCloud，请登录后手动重试。"
            case .restricted: return "系统限制了这台 iPhone 的 iCloud 使用，未上传录音。"
            case .accountUnknown: return "暂时无法确认 iCloud 账户，未上传录音。请稍后重试。"
            case .accountTemporarilyUnavailable: return "iCloud 账户暂时不可用，录音仍保存在手机。"
            case .cancelledOrAccountChanged: return "本次操作已停止或 iCloud 账户发生变化。未改变原授权和账户绑定。"
            case .localAudioUnavailable: return "本机缺少所选录音，未上传这段内容。"
            case .localAudioChanged: return "所选原始音频未通过完整性检查，未上传这段内容。"
            case .cloudContentConflict: return "云端已有不同内容，已拒绝覆盖，也未标记这段内容为已保存。"
            case .cloudRecordMissing: return "尚未读回匹配的云端记录，未标记为已保存。"
            case .transcriptTooLarge: return "这份转写内容超过当前单次保存上限，原始音频的云端结果不受影响。"
            }
        }
    }
}

/// CloudKit invokes callbacks on its own queues; result collection is synchronized.
private final class CloudRecordResultSlot: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<CKRecord, Error>?
    func set(_ result: Result<CKRecord, Error>) { lock.lock(); value = result; lock.unlock() }
    func get() -> Result<CKRecord, Error>? { lock.lock(); defer { lock.unlock() }; return value }
}

private final class CloudAccountObservation: @unchecked Sendable {
    private let token: NSObjectProtocol
    init(onChange: @escaping @Sendable () -> Void) {
        token = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: nil) { _ in onChange() }
    }
    deinit { NotificationCenter.default.removeObserver(token) }
}
