import Foundation
import Darwin

/// A diagnostic publication only. Each generation owns its exact metadata bytes;
/// advancing the index never rewrites an already committed generation.
final class ImmutableObservationSnapshotPublisher {
    static let indexName = "snapshot-index.json"
    static let generationsName = "SnapshotGenerations"
    static let manifestName = "manifest.json"
    static let maximumIndexBytes = 16_384
    static let maximumManifestBytes = 262_144
    static let maximumGenerationBytes = 32 * 1_024 * 1_024
    struct Retention {
        // The collector's hard deadline is 420 s, even when a normal collection
        // takes about two minutes. Give it another 60 s after supersession.
        var minimumAgeMS: Int64 = 480_000
        var recentCount = 8
        var maximumCount = 128
        var maximumBytes = 64 * 1_024 * 1_024
        static func forReportKind(_ kind: String) -> Self {
            switch kind {
            case "watch_backlog":
                return .init(recentCount: 4, maximumCount: 64, maximumBytes: 128 * 1_024 * 1_024)
            case "watch_runtime", "google_drive_worker":
                return .init(recentCount: 16, maximumCount: 512, maximumBytes: 16 * 1_024 * 1_024)
            case "google_drive", "icloud_drive":
                return .init(recentCount: 4, maximumCount: 64, maximumBytes: 64 * 1_024 * 1_024)
            default: return .init()
            }
        }
    }
    struct Index: Codable, Equatable {
        let schemaVersion: Int
        let reportKind: String
        let build: String
        let observerProcessRunID: UUID
        let fenceID: UUID
        let available: Bool
        let sequence: UInt64
        let observedAtMS: Int64
        let continuousTimeMS: Int64
        let clockName: String
        let generationID: String?
        let manifestSHA256: String?
        let manifestByteCount: Int?
        let failureCode: String?
    }
    struct Manifest: Codable {
        let schemaVersion: Int
        let generationID: String
        let reportKind: String
        let build: String
        let observerProcessRunID: UUID
        let fenceID: UUID
        let sequence: UInt64
        let observedAtMS: Int64
        let continuousTimeMS: Int64
        let clockName: String
        // Optional so generations made before this field remain readable.
        let bootSessionID: String?
        let sourceGeneratedAtMS: Int64
        let identity: [String: String]
        let audioRead: Bool
        let includesAudio: Bool
        let files: [VerifiedObservationFile]
    }
    enum Failure: Error { case unavailable, unsafePath, capacity, lowSpace, invalidSource, concurrentWriter }
    enum CommitDisposition: Equatable { case published, coalesced }
    private struct Lease {
        let root: Int32
        let generations: Int32
        let lock: Int32
        // O_EXLOCK is tied to this open file description and releases on close.
        func close() { Darwin.close(lock); Darwin.close(generations); Darwin.close(root) }
    }
    private struct StoredGeneration {
        let name: String
        let manifest: Manifest?
        let files: [String: Int]
        var protectedSince: (wall: Int64, continuous: Int64)
        var bytes: Int { files.values.reduce(0, +) }
    }
    private let directory: URL
    private let reportKind: String
    private let build: String
    private let process: UUID
    private let retention: Retention
    private let bootSessionID: String?
    private let availableBytes: (Int32) -> Int64?
    private let recordingReserveBytes: () -> Int64
    private var storedGenerations: [String: StoredGeneration] = [:]
    private var currentGeneration: String?
    // Exposed internally for focused verification of the incremental GC path.
    private(set) var generationScanCount = 0
    private var fenceID = UUID()
    private var lease: Lease?
    private var pendingIndex: Index?
    private var pendingIndexBytes: Data?
    private var pendingAttemptSequence: UInt64?
    private var coalescing = false
    private var lastCommittedIndexBytes: Data?
    private var coalescingCandidate: Index?
    private var requestedPublicationIntervalMS: Int64 = 0
    private var largestGenerationBytes = 0
    /// Leave the host's 300-second freshness boundary unchanged. A genuinely
    /// full archive still fails closed when it cannot publish within this age.
    static let maximumCoalescingAgeMS: Int64 = 240_000
    private(set) var recommendedPublicationIntervalMS: Int64 = 30_000

    init(directory: URL, reportKind: String, build: String, processRunID: UUID,
         retention: Retention? = nil,
         bootSessionID: String? = ImmutableObservationSnapshotPublisher.currentBootSessionID(),
         availableBytes: @escaping (Int32) -> Int64? = ImmutableObservationSnapshotPublisher.availableBytes,
         recordingReserveBytes: @escaping () -> Int64 = { RecordingStorageBudget.observationReserveBytes }) {
        self.directory = directory; self.reportKind = reportKind; self.build = build
        process = processRunID; self.retention = retention ?? .forReportKind(reportKind)
        self.bootSessionID = bootSessionID; self.availableBytes = availableBytes
        self.recordingReserveBytes = recordingReserveBytes
    }
    deinit { lease?.close() }

    /// Always persist pending before validation. A build-88 coalesced attempt uses
    /// the existing generation's sequence/time for its pending marker, so restoring
    /// that exact pointer cannot roll either clock or the sequence backward.
    func begin(sequence: UInt64, time: (wall: Int64, continuous: Int64),
               minimumPublicationIntervalMS: Int64 = 0) throws {
        guard lease == nil else { throw Failure.concurrentWriter }
        let opened = try openLease(); lease = opened
        do {
            var candidate: (Index, Data)?
            if let bytes = try? Self.read(Self.indexName, root: opened.root, maximum: Self.maximumIndexBytes),
               let previous = try? JSONDecoder().decode(Index.self, from: bytes), previous.available {
                currentGeneration = previous.generationID
                if (UInt64(build) ?? 0) >= 88, minimumPublicationIntervalMS > 0,
                   bytes == lastCommittedIndexBytes,
                   previous.reportKind == reportKind, previous.build == build,
                   previous.observerProcessRunID == process, previous.fenceID == fenceID,
                   previous.sequence < sequence, previous.failureCode == nil,
                   previous.generationID != nil, previous.manifestSHA256 != nil, previous.manifestByteCount != nil,
                   time.wall >= previous.observedAtMS, time.continuous >= previous.continuousTimeMS {
                    candidate = (previous, bytes)
                }
            }
            // Avoid collecting/copying a large metadata payload on a volume
            // already inside the recording reserve. Exact size is checked below.
            do { try checkFreeSpace(opened.generations, addingBytes: 0) }
            catch Failure.lowSpace {
                // Low space must not prevent cleanup of the stale diagnostics
                // that could be responsible for it. Active pins keep their grace.
                try reclaimAndCheckCapacity(opened.generations, addingBytes: 0,
                    nowMS: time.wall, continuousMS: time.continuous, checkCapacity: false)
                try checkFreeSpace(opened.generations, addingBytes: 0)
            }
            requestedPublicationIntervalMS = minimumPublicationIntervalMS
            coalescingCandidate = candidate?.0
            coalescing = candidate.map {
                time.continuous - $0.0.continuousTimeMS < minimumPublicationIntervalMS
            } ?? false
            if let candidate {
                // Keep the candidate's time/sequence even when the ordinary
                // interval is due: only commit knows this payload's exact size.
                // Capacity pacing may restore this pointer, never freshen it.
                let value = index(sequence: candidate.0.sequence,
                    time: (candidate.0.observedAtMS, candidate.0.continuousTimeMS), failure: "validation_pending")
                try writeIndex(value, root: opened.root)
                pendingIndex = value; pendingIndexBytes = try Self.encode(value)
            } else {
                let value = index(sequence: sequence, time: time, failure: "validation_pending")
                try writeIndex(value, root: opened.root)
                pendingIndex = value; pendingIndexBytes = try Self.encode(value)
            }
            pendingAttemptSequence = sequence
        } catch { finishLease(opened); throw error }
    }

    @discardableResult
    func commit(source: VerifiedObservationSource, receipt: VerifiedObservationPublisher.Receipt,
                receiptBytes: Data, statusBytes: Data) throws -> CommitDisposition {
        guard let lease, let pendingIndex, pendingAttemptSequence == receipt.sequence,
              pendingIndex.fenceID == fenceID, receipt.reportKind == reportKind, receipt.build == build,
              receipt.observerProcessRunID == process,
              let sourceBytes = source.snapshotFiles,
              sourceBytes.count == source.files.count,
              Set(sourceBytes.keys) == Set(source.files.map(\.name)),
              source.files.allSatisfy({ file in
                  guard let bytes = sourceBytes[file.name] else { return false }
                  return Self.allowedSource(file.name, kind: reportKind) && file.byteCount == bytes.count
                      && file.sha256 == VerifiedObservationPublisher.digest(bytes)
              }) else { throw Failure.invalidSource }
        var bytes = sourceBytes
        bytes[VerifiedObservationPublisher.fileName] = receiptBytes
        bytes[VerifiedObservationPublisher.statusName] = statusBytes
        guard bytes.count <= 514, bytes.values.allSatisfy({ !$0.isEmpty && $0.count <= 8 * 1_024 * 1_024 }),
              bytes.values.reduce(0, { $0 + $1.count }) <= Self.maximumGenerationBytes else { throw Failure.capacity }
        let generation = UUID().uuidString.lowercased()
        let manifest = Manifest(schemaVersion: 1, generationID: generation, reportKind: reportKind,
            build: build, observerProcessRunID: process, fenceID: fenceID, sequence: receipt.sequence,
            observedAtMS: receipt.observedAtMS, continuousTimeMS: receipt.continuousTimeMS,
            clockName: VerifiedObservationPublisher.clockName, bootSessionID: bootSessionID,
            sourceGeneratedAtMS: source.sourceGeneratedAtMS,
            identity: source.identity, audioRead: false, includesAudio: false,
            files: bytes.keys.sorted().map { .init(name: $0, bytes: bytes[$0]!) })
        let manifestBytes = try Self.encode(manifest)
        guard manifestBytes.count <= Self.maximumManifestBytes else { throw Failure.capacity }
        let total = bytes.values.reduce(manifestBytes.count, { $0 + $1.count })
        if (UInt64(build) ?? 0) >= 88 {
            // Restored build87 generations retain their full pin protection.
            // Include them in the size budget before the first build88 publish.
            // Coalesced observations do not allocate a generation or need a GC.
            if !coalescing {
                try reclaimAndCheckCapacity(lease.generations, addingBytes: 0,
                    nowMS: receipt.observedAtMS, continuousMS: receipt.continuousTimeMS, checkCapacity: false)
            }
            largestGenerationBytes = max(largestGenerationBytes,
                max(total, storedGenerations.values.map(\.bytes).max() ?? 0))
            let slots = min(retention.maximumCount, retention.maximumBytes / max(1, largestGenerationBytes))
            let interval = slots > 1
                ? (max(0, retention.minimumAgeMS) + Int64(slots - 2)) / Int64(slots - 1)
                : Self.maximumCoalescingAgeMS
            recommendedPublicationIntervalMS = min(Self.maximumCoalescingAgeMS, max(30_000, interval))
            if let candidate = coalescingCandidate {
                coalescing = receipt.continuousTimeMS - candidate.continuousTimeMS
                    < min(Self.maximumCoalescingAgeMS,
                        max(requestedPublicationIntervalMS, recommendedPublicationIntervalMS))
            }
        }
        if coalescing {
            // Full semantics were checked by the owner; exact allowlisted source
            // bytes, hashes and all size limits were checked above. The live
            // receipt/status describe that real validation. Restore the exact
            // previous pointer only after CAS; new readers cannot pin it while
            // validation is pending. No immutable observation time is refreshed.
            return try restoreCoalescedPointer(lease)
        }
        do {
            try reclaimAndCheckCapacity(lease.generations, addingBytes: total,
                nowMS: receipt.observedAtMS, continuousMS: receipt.continuousTimeMS)
        } catch Failure.capacity {
            // A sudden payload increase can coexist with many smaller pins.
            // Wait for their original retention deadline without expanding the
            // quota or pretending this older generation is a fresh observation.
            // Startup/recovery has no same-fence candidate and cannot take this
            // path. Source errors, I/O, low space and unsafe paths still fail.
            guard let candidate = coalescingCandidate,
                  total <= retention.maximumBytes,
                  receipt.continuousTimeMS - candidate.continuousTimeMS < Self.maximumCoalescingAgeMS
            else { throw Failure.capacity }
            return try restoreCoalescedPointer(lease)
        }
        try checkFreeSpace(lease.generations, addingBytes: total)
        guard Darwin.mkdirat(lease.generations, generation, 0o700) == 0 else { throw Failure.unavailable }
        let target = try Self.openDirectory(generation, parent: lease.generations)
        defer { Darwin.close(target) }
        do {
            for name in bytes.keys.sorted() { try Self.writeNew(bytes[name]!, path: name, root: target) }
            // The manifest is last inside the generation; the mutable index is
            // committed only after all files and directory entries are durable.
            try Self.writeNew(manifestBytes, path: Self.manifestName, root: target)
            guard Darwin.fsync(target) == 0, Darwin.fsync(lease.generations) == 0 else { throw Failure.unavailable }
            try requireUnchangedIndex(root: lease.root)
            let committed = Index(schemaVersion: 1, reportKind: reportKind, build: build, observerProcessRunID: process,
                fenceID: fenceID, available: true, sequence: receipt.sequence, observedAtMS: receipt.observedAtMS,
                continuousTimeMS: receipt.continuousTimeMS, clockName: VerifiedObservationPublisher.clockName,
                generationID: generation, manifestSHA256: VerifiedObservationPublisher.digest(manifestBytes),
                manifestByteCount: manifestBytes.count, failureCode: nil)
            try writeIndex(committed, root: lease.root)
            lastCommittedIndexBytes = try Self.encode(committed)
            var sizes = bytes.mapValues(\.count); sizes[Self.manifestName] = manifestBytes.count
            storedGenerations[generation] = .init(name: generation, manifest: manifest, files: sizes,
                protectedSince: (receipt.observedAtMS, receipt.continuousTimeMS))
            currentGeneration = generation
            finishLease(lease)
            return .published
        } catch {
            // Incomplete generations are unreachable and reclaimed by the next
            // writer, including after a crash or restart.
            throw error
        }
    }

    func invalidate(sequence: UInt64, time: (wall: Int64, continuous: Int64), code: String) throws {
        fenceID = UUID()
        lastCommittedIndexBytes = nil
        let active = try lease ?? openLease()
        defer { finishLease(active) }
        try writeIndex(index(sequence: sequence, time: time, failure: code), root: active.root)
    }

    private func restoreCoalescedPointer(_ lease: Lease) throws -> CommitDisposition {
        try requireUnchangedIndex(root: lease.root)
        guard let lastCommittedIndexBytes else { throw Failure.invalidSource }
        try writeIndexBytes(lastCommittedIndexBytes, root: lease.root)
        finishLease(lease)
        return .coalesced
    }

    private func requireUnchangedIndex(root: Int32) throws {
        guard let pendingIndexBytes,
              try Self.read(Self.indexName, root: root, maximum: Self.maximumIndexBytes) == pendingIndexBytes
        else { throw Failure.concurrentWriter }
    }

    private func finishLease(_ active: Lease) {
        active.close(); lease = nil; pendingIndex = nil; pendingIndexBytes = nil
        pendingAttemptSequence = nil; coalescing = false
        coalescingCandidate = nil; requestedPublicationIntervalMS = 0
    }

    private func index(sequence: UInt64, time: (wall: Int64, continuous: Int64), failure: String) -> Index {
        Index(schemaVersion: 1, reportKind: reportKind, build: build, observerProcessRunID: process,
            fenceID: fenceID, available: false, sequence: sequence, observedAtMS: time.wall,
            continuousTimeMS: time.continuous, clockName: VerifiedObservationPublisher.clockName,
            generationID: nil, manifestSHA256: nil, manifestByteCount: nil, failureCode: failure)
    }

    private func openLease() throws -> Lease {
        let root = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard root >= 0 else { throw Failure.unavailable }
        var generations: Int32 = -1, lock: Int32 = -1
        do {
            try Self.checkDirectory(root)
            try Self.createDirectory(Self.generationsName, parent: root)
            generations = try Self.openDirectory(Self.generationsName, parent: root)
            lock = Darwin.openat(root, ".snapshot-writer.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_EXLOCK, 0o600)
            guard lock >= 0 else { throw Failure.concurrentWriter }
            try Self.checkFile(lock, maximum: 1)
            return Lease(root: root, generations: generations, lock: lock)
        } catch {
            if lock >= 0 { Darwin.close(lock) }; if generations >= 0 { Darwin.close(generations) }; Darwin.close(root)
            throw error
        }
    }

    private func writeIndex(_ index: Index, root: Int32) throws {
        try writeIndexBytes(Self.encode(index), root: root)
    }

    private func writeIndexBytes(_ bytes: Data, root: Int32) throws {
        do {
            guard bytes.count <= Self.maximumIndexBytes else { throw Failure.capacity }
            var existing = stat()
            if Darwin.fstatat(root, Self.indexName, &existing, AT_SYMLINK_NOFOLLOW) == 0 {
                guard existing.st_mode & S_IFMT == S_IFREG, existing.st_nlink == 1,
                      existing.st_uid == getuid() else { throw Failure.unsafePath }
            } else if errno != ENOENT { throw Failure.unavailable }
            let temporary = ".snapshot-index-" + UUID().uuidString.lowercased() + ".tmp"
            defer { Darwin.unlinkat(root, temporary, 0) }
            try Self.writeNew(bytes, path: temporary, root: root, temporary: true)
            guard Darwin.renameat(root, temporary, root, Self.indexName) == 0,
                  Darwin.fsync(root) == 0 else { throw Failure.unavailable }
        } catch {
            // If a durable failure/pending fence cannot be replaced, remove the
            // mutable entry rather than leave an older available pointer. The
            // immutable generations remain intact for forensic inspection.
            Darwin.unlinkat(root, Self.indexName, 0); Darwin.fsync(root)
            throw error
        }
    }

    private func reclaimAndCheckCapacity(_ root: Int32, addingBytes: Int, nowMS: Int64, continuousMS: Int64,
                                         checkCapacity: Bool = true) throws {
        // Crash leftovers are not bounded by the committed-generation quota.
        // Do not let the per-directory payload-entry limit prevent their GC.
        let names = try Self.names(root, maximumCount: nil)
        let present = Set(names)
        storedGenerations = storedGenerations.filter { present.contains($0.key) }
        // Generations are immutable under the writer lease. Only newly discovered
        // directories need a tree walk and manifest decode; known generations use
        // cached sizes. Removal independently revalidates every path before unlink.
        for name in names where storedGenerations[name] == nil {
            guard UUID(uuidString: name)?.uuidString.lowercased() == name else { throw Failure.unsafePath }
            let child = try Self.openDirectory(name, parent: root); defer { Darwin.close(child) }
            let files = try Self.tree(child)
            generationScanCount += 1
            let manifest = try? JSONDecoder().decode(Manifest.self,
                from: Self.read(Self.manifestName, root: child, maximum: Self.maximumManifestBytes))
            let valid = manifest.flatMap { value -> Manifest? in
                guard value.schemaVersion == 1, value.generationID == name,
                      value.reportKind == reportKind, value.observedAtMS > 0,
                      value.continuousTimeMS >= 0, value.clockName == VerifiedObservationPublisher.clockName,
                      value.files.count <= 514, Set(value.files.map(\.name)).count == value.files.count,
                      Set(files.keys) == Set(value.files.map(\.name) + [Self.manifestName]),
                      value.files.allSatisfy({ files[$0.name] == $0.byteCount &&
                          (Self.allowedSource($0.name, kind: reportKind) ||
                           [VerifiedObservationPublisher.fileName, VerifiedObservationPublisher.statusName].contains($0.name)) })
                else { return nil }
                return value
            }
            // A recovered directory might have been superseded immediately before
            // the writer stopped. Conservatively start its grace period now.
            storedGenerations[name] = .init(name: name, manifest: valid, files: files,
                protectedSince: (nowMS, continuousMS))
        }
        // A still-current generation can be pinned regardless of its age. Its
        // collection grace therefore starts on supersession, not on creation.
        if let currentGeneration, storedGenerations[currentGeneration] != nil {
            storedGenerations[currentGeneration]?.protectedSince = (nowMS, continuousMS)
        }
        func priorBoot(_ item: StoredGeneration) -> Bool {
            guard let manifest = item.manifest else { return false }
            if let current = bootSessionID, let original = manifest.bootSessionID { return current != original }
            // Older builds lack a boot ID. A monotonic timestamp beyond this
            // boot's uptime is sufficient evidence that it cannot be live now.
            return manifest.continuousTimeMS > continuousMS
        }
        let newest = Set(storedGenerations.values.filter { $0.manifest != nil && !priorBoot($0) }.sorted {
            if $0.manifest!.observedAtMS == $1.manifest!.observedAtMS { return $0.name > $1.name }
            return $0.manifest!.observedAtMS > $1.manifest!.observedAtMS
        // The generation about to be committed occupies one recent slot.
        }.prefix(max(0, retention.recentCount - 1)).map(\.name))
        var removed = false
        for item in Array(storedGenerations.values) {
            // Incomplete/invalid generations never became a pin target. Prior
            // boot generations cannot belong to a surviving observer process.
            let stranded = item.manifest == nil || priorBoot(item)
            let expired = !newest.contains(item.name) && nowMS >= item.protectedSince.wall &&
                continuousMS >= item.protectedSince.continuous &&
                nowMS - item.protectedSince.wall >= retention.minimumAgeMS &&
                continuousMS - item.protectedSince.continuous >= retention.minimumAgeMS
            guard stranded || expired else { continue }
            let child = try Self.openDirectory(item.name, parent: root)
            do { try Self.removeTree(child, expected: item.files) } catch { Darwin.close(child); throw error }
            Darwin.close(child)
            guard Darwin.unlinkat(root, item.name, AT_REMOVEDIR) == 0 else { throw Failure.unavailable }
            storedGenerations.removeValue(forKey: item.name)
            removed = true
        }
        if removed { guard Darwin.fsync(root) == 0 else { throw Failure.unavailable } }
        // Reclaim before enforcing limits: crash leftovers must not permanently
        // block the very writer that can remove them.
        guard !checkCapacity || (storedGenerations.count < retention.maximumCount &&
              storedGenerations.values.reduce(addingBytes, { $0 + $1.bytes }) <= retention.maximumBytes
        )
        else { throw Failure.capacity }
    }

    private func checkFreeSpace(_ root: Int32, addingBytes: Int) throws {
        let reserve = max(0, recordingReserveBytes())
        // Leave room for the small failure index/status as well as the recording
        // budget. A failed diagnostic never propagates into the audio writer.
        guard let free = availableBytes(root), free >= reserve,
              free - reserve >= Int64(addingBytes) + 64 * 1_024 else { throw Failure.lowSpace }
    }

    static func availableBytes(_ root: Int32) -> Int64? {
        var info = statfs()
        guard Darwin.fstatfs(root, &info) == 0, info.f_bsize > 0 else { return nil }
        let (bytes, overflow) = UInt64(info.f_bavail).multipliedReportingOverflow(by: UInt64(info.f_bsize))
        guard !overflow, bytes <= UInt64(Int64.max) else { return nil }
        return Int64(bytes)
    }

    static func currentBootSessionID() -> String? {
        var boot = timeval(); var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0,
              size == MemoryLayout<timeval>.size, boot.tv_sec > 0 else { return nil }
        return "\(boot.tv_sec).\(boot.tv_usec)"
    }

    static func allowedSource(_ name: String, kind: String) -> Bool {
        guard safePath(name), name.hasSuffix(".json") else { return false }
        if ["phone_receipts", "google_drive", "icloud_drive"].contains(kind) {
            return ["metadata-capture.json", "capture-status.json"].contains(name)
        }
        if kind == "google_drive_worker" { return ["worker-status.json", "worker-health.json"].contains(name) }
        if kind == "watch_runtime" { return name == "watch-runtime.json" }
        guard kind == "watch_backlog" else { return false }
        var relative = name
        if relative.hasPrefix("CurrentEvidence/v1/") { relative.removeFirst("CurrentEvidence/v1/".count) }
        if ["watch-backlog.json", "watch-backlog-status.json", "current-cohort.json", "legacy-empty-reference.json"].contains(relative) { return true }
        let parts = relative.split(separator: "/").map(String.init)
        guard parts.count == 3, parts[0] == "BacklogEvidence", UUID(uuidString: parts[1]) != nil else { return false }
        return parts[2].range(of: #"^page-[0-9]{4}-g[0-9]{20}\.json$"#, options: .regularExpression) != nil
    }
    private static func safePath(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 256 && !name.hasPrefix("/") &&
        name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && part.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,95].contains($0)
            }
        }
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private static func checkDirectory(_ fd: Int32) throws {
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o022 == 0 else { throw Failure.unsafePath }
    }
    private static func checkFile(_ fd: Int32, maximum: Int) throws {
        var info = stat()
        guard Darwin.fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_uid == getuid(), info.st_size >= 0,
              info.st_size <= maximum else { throw Failure.unsafePath }
    }
    private static func createDirectory(_ name: String, parent: Int32) throws {
        guard Darwin.mkdirat(parent, name, 0o700) == 0 || errno == EEXIST else { throw Failure.unavailable }
        let fd = try openDirectory(name, parent: parent); Darwin.close(fd)
    }
    private static func openDirectory(_ name: String, parent: Int32) throws -> Int32 {
        let fd = Darwin.openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.unsafePath }
        do { try checkDirectory(fd); return fd } catch { Darwin.close(fd); throw error }
    }
    private static func writeNew(_ bytes: Data, path: String, root: Int32, temporary: Bool = false) throws {
        guard safePath(path), temporary || path.hasSuffix(".json") else { throw Failure.unsafePath }
        let parts = path.split(separator: "/").map(String.init)
        var parent = Darwin.dup(root); guard parent >= 0 else { throw Failure.unavailable }
        defer { Darwin.close(parent) }
        for part in parts.dropLast() {
            try createDirectory(part, parent: parent)
            let next = try openDirectory(part, parent: parent); Darwin.close(parent); parent = next
        }
        let fd = Darwin.openat(parent, parts.last!, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw Failure.unavailable }; defer { Darwin.close(fd) }
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: bytes)
        guard Darwin.fsync(fd) == 0, Darwin.fsync(parent) == 0 else { throw Failure.unavailable }
    }
    private static func read(_ name: String, root: Int32, maximum: Int) throws -> Data {
        let fd = Darwin.openat(root, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.unavailable }; defer { Darwin.close(fd) }
        try checkFile(fd, maximum: maximum)
        let bytes = try FileHandle(fileDescriptor: fd, closeOnDealloc: false).read(upToCount: maximum + 1) ?? Data()
        guard !bytes.isEmpty, bytes.count <= maximum else { throw Failure.capacity }
        return bytes
    }
    private static func names(_ root: Int32, maximumCount: Int? = 1024) throws -> [String] {
        // dup shares a directory's seek position; a second traversal would then
        // appear empty. A fresh open description keeps validation and deletion
        // independent while remaining anchored to the already checked directory.
        let fd = Darwin.openat(root, ".", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw Failure.unavailable }
        guard let directory = Darwin.fdopendir(fd) else { Darwin.close(fd); throw Failure.unavailable }
        defer { Darwin.closedir(directory) }
        var result: [String] = []
        while let entry = Darwin.readdir(directory) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            guard safePath(name), !name.contains("/"), maximumCount.map({ result.count < $0 }) ?? true else { throw Failure.capacity }
            result.append(name)
        }
        return result.sorted()
    }
    private static func tree(_ root: Int32, prefix: String = "", depth: Int = 0) throws -> [String: Int] {
        guard depth <= 5 else { throw Failure.capacity }
        var result: [String: Int] = [:]
        for name in try names(root) {
            var info = stat()
            guard Darwin.fstatat(root, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_uid == getuid() else { throw Failure.unsafePath }
            if info.st_mode & S_IFMT == S_IFDIR {
                let child = try openDirectory(name, parent: root); defer { Darwin.close(child) }
                result.merge(try tree(child, prefix: prefix + name + "/", depth: depth + 1)) { first, _ in first }
            } else {
                guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                      name.hasSuffix(".json"), info.st_size >= 0, info.st_size <= maximumGenerationBytes else { throw Failure.unsafePath }
                result[prefix + name] = Int(info.st_size)
            }
            guard result.count <= 515, result.values.reduce(0, +) <= maximumGenerationBytes + maximumManifestBytes else { throw Failure.capacity }
        }
        return result
    }
    private static func removeTree(_ root: Int32, expected: [String: Int]) throws {
        guard try tree(root) == expected else { throw Failure.concurrentWriter }
        for name in try names(root) {
            var info = stat()
            guard Darwin.fstatat(root, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.unavailable }
            if info.st_mode & S_IFMT == S_IFDIR {
                let child = try openDirectory(name, parent: root)
                let childExpected = Dictionary(uniqueKeysWithValues: expected.compactMap { key, size in
                    key.hasPrefix(name + "/") ? (String(key.dropFirst(name.count + 1)), size) : nil
                })
                do { try removeTree(child, expected: childExpected) } catch { Darwin.close(child); throw error }
                Darwin.close(child)
                guard Darwin.unlinkat(root, name, AT_REMOVEDIR) == 0 else { throw Failure.unavailable }
            } else {
                guard info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
                      Darwin.unlinkat(root, name, 0) == 0 else { throw Failure.unsafePath }
            }
        }
        guard Darwin.fsync(root) == 0 else { throw Failure.unavailable }
    }
}
