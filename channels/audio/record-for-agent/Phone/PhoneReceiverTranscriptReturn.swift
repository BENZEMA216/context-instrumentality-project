import CryptoKit
import Foundation
import RecordingCore

/// A small, separate read loop: uploading audio never waits for ASR. Only exact
/// delivered sources from this grant may be queried or committed. There is no
/// Drive writer here and no request to run ASR or download a model.
@MainActor
final class PhoneReceiverTranscriptReturn {
    private struct Entry: Codable {
        let receipt: AutomaticDeliveryReceipt
        let source: AutomaticReceiverTranscriptSource
        let status: AutomaticReceiverTranscriptStatus
        let transcriptSHA256: String?
        let nextQueryAt: Date
    }
    private struct State: Codable {
        let schemaVersion: Int
        let scope: AutomaticDeliveryScope
        let entries: [String: Entry]
        let scanCursor: Int?
    }
    private let credentials: AutomaticReceiverCredentials
    private let repository: TranscriptRepository
    private let stateURL: URL
    private let client: any AutomaticReceiverTranscriptTransport
    private let schedulesRetries: Bool
    private let authorized: (AutomaticReceiverTranscriptQuery) -> Bool
    private let didSave: (SegmentManifest) -> Void
    private let requestBackgroundRetry: (Date) -> Void
    private let diagnostic: @Sendable (String, String) -> Void
    private let beginExecution: @Sendable (@escaping @Sendable (String) -> Void) async -> (any AutomaticDeliveryExecutionLease)?
    private var entries: [String: Entry] = [:]
    private var queries: [AutomaticReceiverTranscriptQuery] = []
    private var available = Set<AutomaticReceiverTranscriptSource>()
    private var locallyBlocked = Set<AutomaticReceiverTranscriptSource>()
    private var enabled = false
    private var generation: UInt64 = 0
    private var processRun: UInt64 = 0
    private var task: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var lease: (any AutomaticDeliveryExecutionLease)?
    private var networkRetryAt: Date?
    private var stateUnavailable = false
    private var scanCursor = 0
    private var background: ReceiverTranscriptBackgroundQueue?

    init(credentials: AutomaticReceiverCredentials, repository: TranscriptRepository, stateURL: URL,
         schedulesRetries: Bool,
         authorized: @escaping (AutomaticReceiverTranscriptQuery) -> Bool,
         didSave: @escaping (SegmentManifest) -> Void,
         requestBackgroundRetry: @escaping (Date) -> Void,
         diagnostic: @escaping @Sendable (String, String) -> Void,
         beginExecution: @escaping @Sendable (@escaping @Sendable (String) -> Void) async -> (any AutomaticDeliveryExecutionLease)?,
         clientFactory: AutomaticReceiverTranscriptClientFactory,
         restorationGate: BackgroundSessionRestorationGate? = nil,
         initiallyEnabled: Bool = false,
         backgroundFactory: ReceiverTranscriptNativeFactory? = nil) throws {
        self.credentials = credentials; self.repository = repository; self.stateURL = stateURL
        self.schedulesRetries = schedulesRetries; self.authorized = authorized; self.didSave = didSave
        self.requestBackgroundRetry = requestBackgroundRetry; self.diagnostic = diagnostic
        self.beginExecution = beginExecution
        client = try clientFactory(credentials)
        do { try load() }
        catch { stateUnavailable = true; diagnostic("phone.transcript_return_state_invalid", "retry_required=true") }
        var nativeFactory = backgroundFactory
        #if os(iOS)
        if nativeFactory == nil {
            nativeFactory = { try ReceiverTranscriptNativeClient(credentials: $0, tracker: $1, complete: $2, finished: $3) }
        }
        #endif
        if let nativeFactory, let restorationGate, !stateUnavailable {
            background = try ReceiverTranscriptBackgroundQueue(credentials: credentials,
                directory: stateURL.deletingLastPathComponent().appendingPathComponent("transcript-queries", isDirectory: true),
                gate: restorationGate, enabled: initiallyEnabled, factory: nativeFactory,
                diagnostic: diagnostic, retry: requestBackgroundRetry,
                consume: { [weak self] batch, bytes in
                    guard let self, self.enabled, !self.stateUnavailable,
                          batch.allSatisfy(self.authorized) else { return nil }
                    let results = try AutomaticReceiverTranscriptClient.validate(bytes, for: batch, scope: .init(credentials.scope))
                    return try self.commit(results, token: self.generation)
                }, changed: { [weak self] in self?.schedule() },
                beforeFinish: { [weak self] in await self?.waitForCurrentQuery() })
        }
    }

    deinit { task?.cancel(); retryTask?.cancel() }

    var hasPendingWork: Bool {
        enabled && !stateUnavailable && (background?.hasAttempt == true || queries.contains {
            authorized($0) && !available.contains($0.source) && !locallyBlocked.contains($0.source)
        })
    }

    func synchronize(_ queries: [AutomaticReceiverTranscriptQuery], enabled: Bool) {
        if !self.queries.isEmpty, self.queries.map(\.source) != queries.map(\.source) { scanCursor = 0 }
        self.queries = queries
        locallyBlocked = []
        if !enabled { stop(); return }
        self.enabled = true
        background?.setEnabled(true)
        schedule()
    }

    func stop() {
        enabled = false; generation &+= 1
        background?.setEnabled(false)
        suspendProcessWork()
    }

    func retire() { stop(); background?.retire() }

    /// An archive session handoff or expired parent must not cancel a separate
    /// native query that the OS already owns for the still-authorized grant.
    func suspendProcessWork() {
        processRun &+= 1
        task?.cancel(); task = nil; retryTask?.cancel(); retryTask = nil
        lease?.end(); lease = nil
    }

    func waitForCurrentQuery() async { await task?.value }

    /// Suppress only the identical ASR version returned by this exact receipt and
    /// source. A revised local version still follows ordinary receiver delivery.
    func returnedTranscriptHash(for query: AutomaticReceiverTranscriptQuery) -> String? {
        guard !stateUnavailable, let entry = entries[query.manifest.id.uuidString.lowercased()],
              entry.receipt == query.receipt, entry.source == query.source, entry.status == .ready else { return nil }
        return entry.transcriptSHA256
    }

    private func schedule() {
        guard enabled, !stateUnavailable, task == nil else { return }
        retryTask?.cancel(); retryTask = nil
        if let retry = networkRetryAt, retry > Date() { scheduleRetry(); return }
        let token = generation
        processRun &+= 1
        let run = processRun
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == token, self.processRun == run {
                    self.task = nil; self.lease?.end(); self.lease = nil
                    self.scheduleRetry()
                }
            }
            do {
                let diagnostic = self.diagnostic
                let lease = await self.beginExecution { diagnostic("phone.transcript_return_lease", $0) }
                guard self.generation == token, self.processRun == run, self.enabled, !Task.isCancelled, lease?.hasTimeRemaining != false else {
                    if self.generation == token, self.processRun == run { self.networkRetryAt = Date(timeIntervalSinceNow: 60) }
                    lease?.end(); return
                }
                self.lease = lease
                let stopAt = ProcessInfo.processInfo.systemUptime + 12
                var deferredNoSpeech: ReceiverTranscriptBackgroundQueue.DeferredAttempt?
                if let background = self.background {
                    background.restore(executionLease: lease)
                    while background.isRecovering {
                        try self.check(token, run: run, stopAt: stopAt)
                        try await Task.sleep(nanoseconds: 10_000_000)
                    }
                    try self.check(token, run: run, stopAt: stopAt)
                    background.replay()
                    if background.hasAttempt {
                        guard let deferred = background.deferredAttempt,
                              self.isExactNoSpeech(deferred.queries) else { return }
                        deferredNoSpeech = deferred
                    }
                }
                let snapshot = self.queries.filter(self.authorized)
                let entries = self.entries, repository = self.repository, now = Date()
                let usesNative = self.background != nil
                let cursor = snapshot.isEmpty ? 0 : self.scanCursor % snapshot.count
                let knownAvailable = self.available
                let preemptedSources = deferredNoSpeech.map { Set($0.queries.map(\.source)) }
                let selectionTask = Task.detached(priority: .utility) {
                    var candidates: [AutomaticReceiverTranscriptQuery] = []
                    var future: (AutomaticReceiverTranscriptQuery, Date)?
                    var available = Set<AutomaticReceiverTranscriptSource>()
                    var blocked = Set<AutomaticReceiverTranscriptSource>()
                    var index = cursor, scanned = 0
                    while scanned < snapshot.count {
                        try Task.checkCancellation()
                        guard ProcessInfo.processInfo.systemUptime < stopAt,
                              lease?.hasTimeRemaining != false else { break }
                        let query = snapshot[index]
                        index = (index + 1) % snapshot.count; scanned += 1
                        if knownAvailable.contains(query.source) { continue }
                        do {
                            if try repository.transcript(for: query.manifest) != nil {
                                available.insert(query.source); continue
                            }
                        } catch { blocked.insert(query.source); continue } // Never replace damaged or mismatched local text.
                        let entry = entries[query.manifest.id.uuidString.lowercased()]
                        if let preemptedSources {
                            // A new identity or an already due nonterminal query,
                            // still missing local text, can displace this poll.
                            let isNewIdentity = entry == nil || entry?.source != query.source || entry?.receipt != query.receipt
                            let isKnownDue = entry.map {
                                $0.source == query.source && $0.receipt == query.receipt
                                    && $0.status != .noSpeech && $0.nextQueryAt <= now
                            } ?? false
                            guard !preemptedSources.contains(query.source),
                                  isNewIdentity || isKnownDue else { continue }
                        }
                        if let entry, entry.source == query.source, entry.receipt == query.receipt,
                           entry.status != .ready, entry.nextQueryAt > now {
                            if usesNative, future == nil || entry.nextQueryAt < future!.1 { future = (query, entry.nextQueryAt) }
                            continue
                        }
                        candidates.append(query)
                        if candidates.count == 4 { break }
                    }
                    if usesNative, preemptedSources == nil, candidates.isEmpty, let future { candidates = [future.0] }
                    return (candidates, available, blocked, index)
                }
                let selection = try await withTaskCancellationHandler {
                    try await selectionTask.value
                } onCancel: { selectionTask.cancel() }
                try self.check(token, run: run, stopAt: stopAt)
                self.scanCursor = selection.3
                self.available.formUnion(selection.1)
                self.locallyBlocked = selection.2
                try self.persist(self.entries)
                let batch = selection.0
                guard !batch.isEmpty, batch.allSatisfy(self.authorized) else { return }
                if let background = self.background {
                    if let deferredNoSpeech {
                        try self.check(token, run: run, stopAt: stopAt)
                        guard self.isExactNoSpeech(deferredNoSpeech.queries) else { return }
                        // End this finite worker immediately after requesting
                        // cancellation. Waiting here would create a cycle with
                        // native finished-events waiting for this worker.
                        background.supersedeDeferredAttempt(deferredNoSpeech)
                        return
                    }
                    guard background.canRegister else { return }
                    let due = batch.map { query -> Date in
                        guard let entry = self.entries[query.manifest.id.uuidString.lowercased()],
                              entry.receipt == query.receipt, entry.source == query.source, entry.status != .ready else { return Date() }
                        return entry.nextQueryAt
                    }.max() ?? Date()
                    try self.check(token, run: run, stopAt: stopAt)
                    try background.register(batch, due: max(due, background.retryAt ?? .distantPast), executionLease: lease)
                    return
                }
                let remaining = stopAt - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw CancellationError() }
                let results = try await self.client.query(batch, timeout: remaining)
                try self.check(token, run: run, stopAt: stopAt)
                guard results.count == batch.count,
                      zip(results, batch).allSatisfy({ pair in
                          pair.0.query.receipt == pair.1.receipt && pair.0.query.source == pair.1.source
                      }),
                      results.allSatisfy({ self.authorized($0.query) }) else {
                    throw AutomaticReceiverTranscriptError.invalidResponse
                }
                self.networkRetryAt = nil
                _ = try self.commit(results, token: token, stopAt: stopAt)
            } catch is CancellationError {
                // A cancelled read never becomes a transcript or a delivery ACK.
                if self.generation == token, self.processRun == run { self.networkRetryAt = Date(timeIntervalSinceNow: 60) }
            } catch {
                guard self.generation == token, self.processRun == run else { return }
                self.networkRetryAt = Date(timeIntervalSinceNow: 60)
                self.diagnostic("phone.transcript_return_failed", "retry_required=true")
            }
        }
    }

    private func isExactNoSpeech(_ queries: [AutomaticReceiverTranscriptQuery]) -> Bool {
        !queries.isEmpty && queries.allSatisfy { query in
            guard authorized(query), let entry = entries[query.manifest.id.uuidString.lowercased()] else { return false }
            return entry.status == .noSpeech && entry.source == query.source && entry.receipt == query.receipt
        }
    }

    private func commit(_ results: [AutomaticReceiverTranscriptResult], token: UInt64, stopAt: TimeInterval? = nil) throws -> Int {
        var savedCount = 0
        for result in results {
            try self.check(token, stopAt: stopAt, needsLease: stopAt != nil)
            guard self.authorized(result.query) else { throw CancellationError() }
            let hash: String?
            if let transcript = result.transcript {
                guard result.status == .ready else { throw AutomaticReceiverTranscriptError.invalidResponse }
                try transcript.validate(against: result.query.manifest)
                hash = Self.digest(try TransportCodec.encode(transcript))
            } else {
                guard result.status != .ready else { throw AutomaticReceiverTranscriptError.invalidResponse }
                hash = nil
            }
            let delay: TimeInterval
            switch result.status {
            case .ready: delay = 600
            case .pending: delay = 60
            case .retry: delay = 120
            case .noSpeech: delay = 3_600
            case .unavailable: delay = 600
            }
            var candidate = self.entries
            candidate[result.query.manifest.id.uuidString.lowercased()] = Entry(receipt: result.query.receipt,
                source: result.query.source, status: result.status, transcriptSHA256: hash,
                nextQueryAt: Date(timeIntervalSinceNow: delay))
            // Store the origin/version marker first. A failure here must
            // not leave new text that would send its audio back as a ZIP.
            try self.persist(candidate)
            self.entries = candidate
            if let transcript = result.transcript {
                try self.check(token, stopAt: stopAt, needsLease: stopAt != nil)
                guard self.authorized(result.query) else { throw CancellationError() }
                // No await between the live scope/receipt fence and this
                // locked atomic save. Pause/unpair cannot cross that fence.
                let saved = try self.repository.saveIfAbsent(transcript, for: result.query.manifest)
                self.available.insert(result.query.source)
                if saved {
                    savedCount += 1
                    self.diagnostic("phone.transcript_return_saved", "source_verified=true")
                    self.didSave(result.query.manifest)
                }
            } else {
                self.diagnostic("phone.transcript_return_waiting", "status=" + result.status.rawValue)
            }
        }
        return savedCount
    }

    private func check(_ token: UInt64, run: UInt64? = nil, stopAt: TimeInterval? = nil, needsLease: Bool = true) throws {
        try Task.checkCancellation()
        guard enabled, generation == token, run == nil || processRun == run, !needsLease || lease?.hasTimeRemaining != false else { throw CancellationError() }
        if let stopAt, ProcessInfo.processInfo.systemUptime >= stopAt { throw CancellationError() }
    }

    private func scheduleRetry() {
        guard enabled, !stateUnavailable, task == nil else { return }
        if background?.hasAttempt == true { return } // Native task owns its due date across suspension.
        let pending = queries.filter { authorized($0) && !available.contains($0.source) && !locallyBlocked.contains($0.source) }
        guard !pending.isEmpty else { return }
        let next = networkRetryAt ?? pending.map { query -> Date in
            guard let entry = entries[query.manifest.id.uuidString.lowercased()],
                  entry.source == query.source, entry.receipt == query.receipt, entry.status != .ready else { return Date() }
            return entry.nextQueryAt
        }.min() ?? Date()
        requestBackgroundRetry(next)
        guard schedulesRetries else { return }
        let delay = max(2, min(3_600, next.timeIntervalSinceNow))
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            catch { return }
            self?.schedule()
        }
    }

    private func load() throws {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: stateURL.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code) { return }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.referenceCount] as? NSNumber)?.intValue ?? 1) == 1,
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 8 * 1_024 * 1_024 else {
            throw AutomaticReceiverTranscriptError.invalidResponse
        }
        let data = try Data(contentsOf: stateURL)
        guard data.count <= 8 * 1_024 * 1_024 else { throw AutomaticReceiverTranscriptError.invalidResponse }
        let value = try TransportCodec.decode(State.self, from: data)
        guard value.schemaVersion == 1, value.scope == credentials.scope, value.entries.count <= 10_000,
              (0...10_000).contains(value.scanCursor ?? 0),
              value.entries.allSatisfy({ key, entry in
                  key == entry.source.segmentID.uuidString.lowercased()
                    && entry.source.sequence >= 0 && AutomaticReceiverPairingPayload.isDigest(entry.source.audioSHA256)
                    && entry.receipt.receiverID == credentials.scope.receiverID
                    && entry.receipt.recordingIDs == [entry.source.segmentID]
                    && (entry.status == .ready) == (entry.transcriptSHA256 != nil)
                    && (entry.transcriptSHA256.map(AutomaticReceiverPairingPayload.isDigest) ?? true)
                    && entry.nextQueryAt.timeIntervalSince1970.isFinite
              }) else { throw AutomaticReceiverTranscriptError.invalidResponse }
        entries = value.entries
        scanCursor = value.scanCursor ?? 0
    }

    private func persist(_ entries: [String: Entry]) throws {
        guard entries.count <= 10_000 else { throw AutomaticReceiverTranscriptError.invalidResponse }
        let bytes = try TransportCodec.encode(State(schemaVersion: 1, scope: credentials.scope, entries: entries, scanCursor: scanCursor))
        guard bytes.count <= 8 * 1_024 * 1_024 else { throw AutomaticReceiverTranscriptError.invalidResponse }
        let directory = stateURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)])
        if FileManager.default.fileExists(atPath: stateURL.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: stateURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  ((attributes[.referenceCount] as? NSNumber)?.intValue ?? 1) == 1 else {
                throw AutomaticReceiverTranscriptError.invalidResponse
            }
        }
        try bytes.write(to: stateURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: stateURL.path)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: stateURL.path)
        #endif
        let handle = try FileHandle(forWritingTo: stateURL)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}
