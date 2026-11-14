private extension PhoneReceiptEvidence {
    func probeDrain() { queue.sync {} }
    var probeLoaded: Bool { queue.sync { loaded } }
}
private extension ICloudDriveLibraryWorker {
    var probeLoaded: Bool { loaded }
    var probeArchive: SyncEvidenceArchive { syncEvidence }
}
private final class ProbeProvider: @unchecked Sendable {
    var calls = 0
    var metadataChecks = 0
    var uploaded = false
    var access: ICloudDriveFolderAccess {
        .init(bookmark: { [self] in calls += 1; return Data($0.path.utf8) },
            resolve: { [self] in calls += 1; return (URL(fileURLWithPath: String(decoding: $0, as: UTF8.self)), false) },
            start: { [self] _ in calls += 1; return true }, stop: { [self] _ in calls += 1 },
            validate: { [self] _ in calls += 1 }, identity: { [self] _ in calls += 1; return String(repeating: "a", count: 64) },
            uploaded: { [self] _ in calls += 1; metadataChecks += 1; return uploaded })
    }
}
private final class ObservationFeedback: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (Int, Bool)?
    func record(_ seconds: Int) { lock.lock(); value = (seconds, Thread.isMainThread); lock.unlock() }
    var result: (Int, Bool)? { lock.lock(); defer { lock.unlock() }; return value }
}
private struct MetadataImage: Equatable {
    let bytes: Data
    let seconds: Int
    let nanoseconds: Int
}
@main private struct Probe {
    static var assertions = 0
    static let expectedBuild = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1
        if try !value() { throw NSError(domain: "VerifiedObservationHookProbe", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func snapshot(_ directory: URL,
                         names: [String] = ["index.json", "status.json", "metadata-capture.json", "capture-status.json"])
        throws -> [String: MetadataImage] {
        var result: [String: MetadataImage] = [:]
        for name in names {
            let url = directory.appendingPathComponent(name)
            var info = stat()
            guard Darwin.lstat(url.path, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
            result[name] = .init(bytes: try Data(contentsOf: url), seconds: info.st_mtimespec.tv_sec,
                nanoseconds: info.st_mtimespec.tv_nsec)
        }
        return result
    }
    static func receipt(_ directory: URL, kind: String) throws -> VerifiedObservationPublisher.Receipt {
        let bytes = try Data(contentsOf: directory.appendingPathComponent(VerifiedObservationPublisher.fileName))
        let receipt = try JSONDecoder().decode(VerifiedObservationPublisher.Receipt.self, from: bytes)
        let status = try JSONDecoder().decode(VerifiedObservationPublisher.Status.self,
            from: Data(contentsOf: directory.appendingPathComponent(VerifiedObservationPublisher.statusName)))
        let object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        try check(status.schemaVersion == 2 && receipt.schemaVersion == 2
            && status.clockName == "CLOCK_MONOTONIC" && receipt.clockName == "CLOCK_MONOTONIC"
            && receipt.continuousTimeMS >= 0 && status.continuousTimeMS == receipt.continuousTimeMS
            && object["uptimeMS"] == nil && status.available
            && status.observationSHA256 == VerifiedObservationPublisher.digest(bytes),
            "Successful hook must publish the schema2 continuous-clock receipt/status pair without legacy uptime")
        try check(receipt.reportKind == kind && receipt.build == expectedBuild
            && receipt.observerProcessRunID == VerifiedObservationPublisher.processRunID
            && !receipt.audioRead && !receipt.includesAudio && receipt.files.count == 2,
            "Hook receipt must bind the actual build shared process and only two original archive leaves")
        for item in receipt.files {
            let source = try Data(contentsOf: directory.appendingPathComponent(item.name))
            try check(item.byteCount == source.count && item.sha256 == VerifiedObservationPublisher.digest(source),
                "Hook receipt hash must match original metadata bytes")
        }
        if expectedBuild == "87" {
            let indexBytes = try Data(contentsOf: directory.appendingPathComponent("snapshot-index.json"))
            let index = try JSONSerialization.jsonObject(with: indexBytes) as! [String: Any]
            try check(index["available"] as? Bool == true && index["sequence"] as? UInt64 == receipt.sequence,
                "Build87 real owner publishes a usable generation matching its receipt")
            let generation = directory.appendingPathComponent("SnapshotGenerations/" + (index["generationID"] as! String))
            let manifestBytes = try Data(contentsOf: generation.appendingPathComponent("manifest.json"))
            try check(index["manifestSHA256"] as? String == VerifiedObservationPublisher.digest(manifestBytes),
                "Build87 generation manifest is hash bound")
            let manifest = try JSONSerialization.jsonObject(with: manifestBytes) as! [String: Any]
            for file in manifest["files"] as! [[String: Any]] {
                let name = file["name"] as! String
                let archived = try Data(contentsOf: generation.appendingPathComponent(name))
                let active = try Data(contentsOf: directory.appendingPathComponent(name))
                try check(file["sha256"] as? String == VerifiedObservationPublisher.digest(archived)
                    && archived == active,
                    "Build87 package freezes exact validated source and observation bytes")
            }
        }
        return receipt
    }
    static func preserveArchive(_ directory: URL, root: URL, name: String) throws {
        let destination = root.appendingPathComponent(name + "/SyncEvidence")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: directory, to: destination.appendingPathComponent("icloud_drive"))
    }
    static func verifyUncheckedTailObservations(root: URL) async throws {
        let local = root.appendingPathComponent("tail-phone")
        let folder = root.appendingPathComponent("tail-synthetic-provider")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let repository = try RecordingRepository(root: local)
        let transcripts = try TranscriptRepository(root: local)
        let bytes = Data("REC-8 REC-28 generated synthetic fixture bytes".utf8)
        let seed = root.appendingPathComponent("tail-synthetic-source")
        try bytes.write(to: seed)
        let session = UUID()
        var sources: [SegmentManifest] = []
        for sequence in 0..<20 {
            let id = UUID()
            let source = SegmentManifest(id: id, sessionID: session, sequence: sequence,
                startedAt: Date(timeIntervalSince1970: 100), endedAt: Date(timeIntervalSince1970: 160),
                sampleRate: 16000, frameCount: 960000, fileName: id.uuidString.lowercased() + ".caf",
                byteCount: Int64(bytes.count), sha256: ICloudDriveLibraryLedger.digest(bytes))
            _ = try repository.acceptIncomingFile(at: seed, manifest: source)
            sources.append(source)
        }
        sources.sort { $0.id.uuidString < $1.id.uuidString }
        let ids = Set(sources.map(\.id)), provider = ProbeProvider()
        provider.uploaded = true
        let worker = ICloudDriveLibraryWorker(repository: repository, transcriptRepository: transcripts,
            folderAccess: provider.access)
        _ = try await worker.perform(.connect(folder), gate: ICloudDriveCancellation())
        _ = try await worker.perform(.authorize(.existingAndFuture, sources, ids), gate: ICloudDriveCancellation())
        for _ in 0..<3 {
            _ = try await worker.perform(.sync(sources, ids), gate: ICloudDriveCancellation())
        }
        // A second archive instance is a new publisher and intentionally fences
        // build87 startup. Read the actual actor-owned archive instead.
        let archive = await worker.probeArchive
        let directory = local.appendingPathComponent("SyncEvidence/icloud_drive")
        try check(try archive.load()!.context.counts["provider_uploaded_file_count"] == 61,
            "REC-8 interaction fixture begins with 61 actually confirmed synthetic provider paths")
        let completedBefore = try receipt(directory, kind: "icloud_drive")
        for source in sources { try FileManager.default.removeItem(at: repository.audioURL(for: source)) }
        try FileManager.default.removeItem(at: seed)

        let checksBefore = provider.metadataChecks
        let pendingState = try await worker.perform(.refreshProviderStatus, gate: ICloudDriveCancellation())
        let pending = try archive.load()!
        let published = try receipt(directory, kind: "icloud_drive")
        try check(provider.metadataChecks - checksBefore == 32 && pendingState.uploadedFileCount == 32
            && pendingState.pendingCloudFileCount == 29
            && pending.context.counts["provider_uploaded_file_count"] == 32
            && pending.context.counts["pending_provider_file_count"] == 29
            && pending.context.counts["provider_change_unchecked_file_count"] == 29,
            "REC-8 leaves its 29 unchecked paths pending in both actor state and the publication observed by REC-28")
        try check(published.sequence > completedBefore.sequence
            && published.sourceGeneratedAtMS == pending.index.generatedAtMS
            && published.identity["generationID"] == pending.index.generationID.uuidString,
            "REC-28 automatically replaces the complete sidecar with a receipt bound to the new pending publication")
        try preserveArchive(directory, root: root, name: "tail-pending-published")

        let names = ["index.json", "status.json", "metadata-capture.json", "capture-status.json"]
            + pending.index.pages.map(\.name)
        let sourceBefore = try snapshot(directory, names: names)
        let businessDirectory = local.appendingPathComponent("ICloudDriveLibrary")
        let businessBefore = try snapshot(businessDirectory, names: ["state.json", "provider-evidence.json"])
        let callsBefore = provider.calls, idleChecksBefore = provider.metadataChecks
        await worker.observeVerifiedMetadata()
        try check(try receipt(directory, kind: "icloud_drive").sequence == published.sequence,
            "Ordinary REC-28 observation remains throttled immediately after pending-source publication")
        // Exercise the actual 30-second foreground throttle without substituting
        // the production clock, sourceDidChange flag, or observation publisher.
        try await Task.sleep(nanoseconds: 30_100_000_000)
        await worker.observeVerifiedMetadata()
        let observed = try receipt(directory, kind: "icloud_drive")
        try check(observed.sequence > published.sequence && observed.observedAtMS > published.observedAtMS
            && observed.continuousTimeMS > published.continuousTimeMS
            && observed.sourceGeneratedAtMS == published.sourceGeneratedAtMS
            && observed.identity == published.identity,
            "A fresh REC-28 observation advances only receipt time while its pending source generation remains unchanged")
        try check(try snapshot(directory, names: names) == sourceBefore
            && snapshot(businessDirectory, names: ["state.json", "provider-evidence.json"]) == businessBefore
            && provider.calls == callsBefore && provider.metadataChecks == idleChecksBefore,
            "Ordinary observation preserves every source page, grant, unchecked set and cursor byte/mtime without any provider call")
        let idleProviderCalls = provider.calls - callsBefore
        try preserveArchive(directory, root: root, name: "tail-pending-observed")

        let noPermit = try await worker.perform(.inspectProviderStatus,
            gate: ICloudDriveCancellation(takeProviderMetadataPermit: { false }))
        let zero = try archive.load()!, zeroReceipt = try receipt(directory, kind: "icloud_drive")
        try check(noPermit.uploadedFileCount == 32 && noPermit.pendingCloudFileCount == 29
            && provider.metadataChecks == idleChecksBefore
            && zero.context.counts["provider_change_unchecked_file_count"] == 29
            && zero.context.counts["provider_uploaded_file_count"] == 32
            && zeroReceipt.sequence > observed.sequence
            && zeroReceipt.sourceGeneratedAtMS == zero.index.generatedAtMS,
            "A new zero-permit publication refreshes REC-28 evidence without clearing REC-8 pending coverage")
        try preserveArchive(directory, root: root, name: "tail-zero-permit")

        let beforeContinuation = provider.metadataChecks
        let complete = try await worker.perform(.inspectProviderStatus, gate: ICloudDriveCancellation())
        let finished = try archive.load()!, finishedReceipt = try receipt(directory, kind: "icloud_drive")
        try check(provider.metadataChecks - beforeContinuation == 32 && complete.uploadedFileCount == 61
            && complete.pendingCloudFileCount == 0
            && finished.context.counts["provider_uploaded_file_count"] == 61
            && finished.context.counts["pending_provider_file_count"] == 0
            && finished.context.counts["provider_change_unchecked_file_count"] == 0
            && finishedReceipt.sequence > zeroReceipt.sequence
            && finishedReceipt.sourceGeneratedAtMS == finished.index.generatedAtMS,
            "Only real synthetic provider coverage completes the tail, and its REC-28 receipt binds that later publication")
        try check(try snapshot(businessDirectory, names: ["state.json"])["state.json"] == businessBefore["state.json"]
            && sources.allSatisfy { !FileManager.default.fileExists(atPath: repository.audioURL(for: $0).path) },
            "Observation and provider-only continuation preserve authorization and do not need the removed synthetic source bytes")
        try preserveArchive(directory, root: root, name: "tail-complete")
        let evidence: [String: Any] = ["status": "passed", "sourceCount": 20, "expectedProviderFileCount": 61,
            "pendingConfirmedFileCount": 32, "pendingUncheckedFileCount": 29,
            "providerCallsDuringOrdinaryObservation": idleProviderCalls,
            "sourceBytesAndMTimesUnchangedDuringOrdinaryObservation": true,
            "grantAndProviderCacheBytesAndMTimesUnchangedDuringOrdinaryObservation": true,
            "publishedSequence": published.sequence, "observedSequence": observed.sequence,
            "zeroPermitSequence": zeroReceipt.sequence, "completeSequence": finishedReceipt.sequence,
            "ordinaryObservationElapsedMS": observed.continuousTimeMS - published.continuousTimeMS]
        try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted])
            .write(to: root.appendingPathComponent("tail-interaction.json"))
    }
    static func main() async throws {
        try check(["86", "87"].contains(expectedBuild),
            "The actual production archive must see the synthetic bundle build")
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let phone = root.appendingPathComponent("phone"), repository = try RecordingRepository(root: phone)
        let transcripts = try TranscriptRepository(root: phone)
        let phoneArchive = SyncEvidenceArchive(root: phone, stream: "phone_receipts")
        try phoneArchive.publish(rows: [], context: .init(scope: "phone_library_metadata", discoveryComplete: true,
            counts: ["manifest_count": 0, "receipt_count": 0, "observed_incoming_source_count": 0, "history_unavailable": 0]))
        let phoneDirectory = phone.appendingPathComponent("SyncEvidence/phone_receipts")
        let phoneBefore = try snapshot(phoneDirectory)
        let receipts = PhoneReceiptEvidence(repository: repository, root: phone)
        receipts.observeVerifiedMetadata(); receipts.probeDrain()
        let phoneReceipt = try receipt(phoneDirectory, kind: "phone_receipts")
        try check(try snapshot(phoneDirectory) == phoneBefore && !receipts.probeLoaded,
            "Ordinary receipt observation must preserve all source bytes/mtimes and not restore repository metadata")
        receipts.observeVerifiedMetadata(); receipts.probeDrain()
        try check(try receipt(phoneDirectory, kind: "phone_receipts").sequence == phoneReceipt.sequence,
            "Repeated unchanged foreground hook must use the normal throttle")
        // The normal receipt startup publication invokes the separate observation path.
        receipts.start(); receipts.probeDrain()
        let startupReceipt = try receipt(phoneDirectory, kind: "phone_receipts")
        try check(receipts.probeLoaded && startupReceipt.sequence > phoneReceipt.sequence
            && startupReceipt.sourceGeneratedAtMS == phoneArchive.load()!.index.generatedAtMS,
            "Receipt publication must refresh its sidecar inside the foreground throttle")

        let cloudArchive = SyncEvidenceArchive(root: phone, stream: "icloud_drive")
        try cloudArchive.publish(rows: [], context: .init(scope: "phone_authorized_discovered", libraryID: UUID(),
            scopeMode: "existingAndFuture", authorizedAtMS: Int64(Date().timeIntervalSince1970 * 1_000) - 100,
            enabled: true, discoveryComplete: true,
            counts: ["authorized_source_count": 0, "artifact_count": 0, "provider_uploaded_artifact_count": 0, "commit_file_count": 0]))
        let cloudDirectory = phone.appendingPathComponent("SyncEvidence/icloud_drive")
        let cloudBefore = try snapshot(cloudDirectory)
        let provider = ProbeProvider()
        let worker = ICloudDriveLibraryWorker(repository: repository, transcriptRepository: transcripts, folderAccess: provider.access)
        await worker.observeVerifiedMetadata()
        let cloudReceipt = try receipt(cloudDirectory, kind: "icloud_drive")
        let loaded = await worker.probeLoaded
        try check(try snapshot(cloudDirectory) == cloudBefore && !loaded && provider.calls == 0,
            "Ordinary iCloud observation must not load a ledger, open a provider or change metadata bytes/mtimes")
        try check(cloudReceipt.observerProcessRunID == startupReceipt.observerProcessRunID,
            "Phone receipt and cloud observation hooks must share one process identity")
        let feedback = ObservationFeedback()
        await worker.observeVerifiedMetadata(onThrottle: { feedback.record($0) })
        try check(feedback.result.map { (1...30).contains($0.0) && !$0.1 } == true,
            "iCloud observation runs off the main thread and reports actual cooldown seconds")
        try check(try receipt(cloudDirectory, kind: "icloud_drive").sequence == cloudReceipt.sequence && provider.calls == 0,
            "Repeated iCloud foreground observation must remain throttled and provider-free")
        // Exercise the real actor's normal publication with an explicitly synthetic grant.
        let authorizedRoot = root.appendingPathComponent("authorized-phone")
        let authorizedRepository = try RecordingRepository(root: authorizedRoot)
        let authorizedTranscripts = try TranscriptRepository(root: authorizedRoot)
        let folder = root.appendingPathComponent("synthetic-provider")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let authorizedWorker = ICloudDriveLibraryWorker(repository: authorizedRepository,
            transcriptRepository: authorizedTranscripts, folderAccess: provider.access)
        let gate = ICloudDriveCancellation()
        _ = try await authorizedWorker.perform(.connect(folder), gate: gate)
        _ = try await authorizedWorker.perform(.authorize(.existingAndFuture, [], []), gate: gate)
        let authorizedReceipt = try receipt(authorizedRoot.appendingPathComponent("SyncEvidence/icloud_drive"), kind: "icloud_drive")
        try check(authorizedReceipt.sourceGeneratedAtMS > 0,
            "An actual authorized actor publication must automatically publish a valid observation")
        try await verifyUncheckedTailObservations(root: root)
        print("PASS actual build\(expectedBuild) receipt and iCloud observation hooks assertions=\(assertions); realAudio=false syntheticBytes=true observationMetadataOnly=true device=false realProvider=false")
    }
}
