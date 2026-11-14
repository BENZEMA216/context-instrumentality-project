import CryptoKit
import Foundation
import RecordingCore
import Security

private final class NativeQueryDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var value: [(String, String)] = []
    func append(_ kind: String, _ detail: String) { lock.lock(); value.append((kind, detail)); lock.unlock() }
    var entries: [(String, String)] { lock.lock(); defer { lock.unlock() }; return value }
}

private final class NativeQueryOS: @unchecked Sendable {
    struct Upload: Sendable { let taskID: Int; let nonce: UUID; let body: Data; let due: Date }
    private let lock = NSLock()
    private var sequence = 0
    private var live: [Int: UUID] = [:]
    private var uploadsValue: [Upload] = []
    private var clientsValue: [NativeQueryTransport] = []
    private var resumesValue: [Int] = []
    private var suspended = Set<Int>()
    var snapshotOverride: [ReceiverTranscriptNativeTask]?
    var stateURL: URL?
    private(set) var persistedBeforeResume = true
    var uploads: [Upload] { lock.lock(); defer { lock.unlock() }; return uploadsValue }
    var clients: [NativeQueryTransport] { lock.lock(); defer { lock.unlock() }; return clientsValue }
    var resumes: [Int] { lock.lock(); defer { lock.unlock() }; return resumesValue }
    func make(_ credentials: AutomaticReceiverCredentials, _ tracker: BackgroundSessionEventTracker,
              _ complete: @escaping @Sendable (ReceiverTranscriptNativeResult) async -> Void,
              _ finished: @escaping @Sendable (BackgroundSessionEvent) async -> Void) -> NativeQueryTransport {
        let value = NativeQueryTransport(os: self, credentials: credentials, tracker: tracker, complete: complete, finished: finished)
        lock.lock(); clientsValue.append(value); lock.unlock(); return value
    }
    func create(_ nonce: UUID, _ file: URL, _ due: Date) throws -> Int {
        let body = try Data(contentsOf: file)
        lock.lock(); defer { lock.unlock() }
        sequence += 1; live[sequence] = nonce; suspended.insert(sequence)
        uploadsValue.append(.init(taskID: sequence, nonce: nonce, body: body, due: due)); return sequence
    }
    func resume(_ taskID: Int) {
        lock.lock(); defer { lock.unlock() }
        if let stateURL {
            let value = (try? Data(contentsOf: stateURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            persistedBeforeResume = persistedBeforeResume && ((value?["attempt"] as? [String: Any])?["taskID"] as? Int == taskID)
        }
        resumesValue.append(taskID)
        suspended.remove(taskID)
    }
    func tasks() -> [ReceiverTranscriptNativeTask] {
        lock.lock(); defer { lock.unlock() }
        if let snapshotOverride { return snapshotOverride }
        return live.compactMap { taskID, nonce in
            guard let upload = uploadsValue.first(where: { $0.taskID == taskID }) else { return nil }
            let request = try? TransportCodec.decode(AutomaticReceiverTranscriptClient.Request.self, from: upload.body)
            let scope = clientsValue.last?.endpoint
            return .init(taskID: taskID, nonce: nonce,
                requestURL: scope?.appendingPathComponent("v1/transcripts/query"), method: request == nil ? nil : "POST",
                bodySHA256: SHA256.hash(data: upload.body).map { String(format: "%02x", $0) }.joined(),
                bodyBytes: Int64(upload.body.count), suspended: suspended.contains(taskID))
        }
    }
    func remove(_ taskID: Int) { lock.lock(); live.removeValue(forKey: taskID); lock.unlock() }
    func removeAll() { lock.lock(); live.removeAll(); lock.unlock() }
}

private final class NativeQueryTransport: ReceiverTranscriptNativeTransport, @unchecked Sendable {
    let identifier: String
    let endpoint: URL?
    private let os: NativeQueryOS
    private let tracker: BackgroundSessionEventTracker
    private let complete: @Sendable (ReceiverTranscriptNativeResult) async -> Void
    private let finished: @Sendable (BackgroundSessionEvent) async -> Void
    private let lock = NSLock()
    private var invalidations = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var hold = false
    private var holdsEnumeration = false
    private var enumerationWaiters: [CheckedContinuation<Void, Never>] = []
    private var enumerations = 0
    var holdEnumeration: Bool { get { lock.lock(); defer { lock.unlock() }; return holdsEnumeration } set { lock.lock(); holdsEnumeration = newValue; lock.unlock() } }
    var enumerationCount: Int { lock.lock(); defer { lock.unlock() }; return enumerations }
    var enumerationWaiting: Int { lock.lock(); defer { lock.unlock() }; return enumerationWaiters.count }
    var holdInvalidation: Bool { get { lock.lock(); defer { lock.unlock() }; return hold } set { lock.lock(); hold = newValue; lock.unlock() } }
    var invalidationCount: Int { lock.lock(); defer { lock.unlock() }; return invalidations }
    init(os: NativeQueryOS, credentials: AutomaticReceiverCredentials, tracker: BackgroundSessionEventTracker,
         complete: @escaping @Sendable (ReceiverTranscriptNativeResult) async -> Void,
         finished: @escaping @Sendable (BackgroundSessionEvent) async -> Void) {
        self.os = os; self.tracker = tracker; self.complete = complete; self.finished = finished
        identifier = ReceiverTranscriptNativeClient.identifier(for: credentials.scope)
        endpoint = AutomaticReceiverPairingPayload.endpointURL(credentials.scope.endpoint)
    }
    func tasks() async -> [ReceiverTranscriptNativeTask] {
        await withCheckedContinuation { continuation in
            lock.lock(); enumerations += 1
            if holdsEnumeration { enumerationWaiters.append(continuation); lock.unlock() }
            else { lock.unlock(); continuation.resume() }
        }
        return os.tasks()
    }
    func releaseEnumeration() {
        lock.lock(); holdsEnumeration = false; let pending = enumerationWaiters; enumerationWaiters.removeAll(); lock.unlock()
        pending.forEach { $0.resume() }
    }
    func create(nonce: UUID, file: URL, due: Date) throws -> Int { try os.create(nonce, file, due) }
    func resume(_ taskID: Int) { os.resume(taskID) }
    func invalidateAndDrain() async {
        os.removeAll()
        await withCheckedContinuation { continuation in
            lock.lock(); invalidations += 1
            if hold { waiters.append(continuation); lock.unlock() }
            else { lock.unlock(); continuation.resume() }
        }
    }
    func releaseInvalidation() {
        lock.lock(); hold = false; let pending = waiters; waiters.removeAll(); lock.unlock()
        pending.forEach { $0.resume() }
    }
    func deliver(_ upload: NativeQueryOS.Upload, body: Data? = nil, failure: ReceiverTranscriptNativeFailure? = nil,
                 nonce: UUID? = nil, taskID: Int? = nil, errorCode: ReceiverTranscriptNativeErrorCode = .none) async {
        if nonce == nil && taskID == nil { os.remove(upload.taskID) }
        await complete(.init(taskID: taskID ?? upload.taskID, nonce: nonce ?? upload.nonce, body: body, failure: failure, errorCode: errorCode))
    }
    func finish() async { await finished(tracker.capture(identifier)) }
}

private func returnedTranscript(_ manifest: SegmentManifest, text: String = "合成测试转写：可整理为学习笔记。") -> SegmentTranscript {
    .init(segmentID: manifest.id, audioSHA256: manifest.sha256, locale: "zh-CN", engine: "synthetic-receiver",
          createdAt: Date(timeIntervalSince1970: 1_792_876_029.274), text: text, spans: [])
}

extension Probe {
    private func nativeReturner(_ f: Fixture, scope: AutomaticDeliveryScope, token: String,
                                os: NativeQueryOS, gate: BackgroundSessionRestorationGate,
                                authorized: @escaping (AutomaticReceiverTranscriptQuery) -> Bool = { _ in true },
                                saved: @escaping (SegmentManifest) -> Void = { _ in },
                                diagnostic: @escaping @Sendable (String, String) -> Void = { _, _ in },
                                beginExecution: @escaping @Sendable (@escaping @Sendable (String) -> Void) async -> (any AutomaticDeliveryExecutionLease)? = { _ in nil }) throws -> PhoneReceiverTranscriptReturn {
        let directory = f.root.appendingPathComponent("transcript-queries", isDirectory: true)
        os.stateURL = directory.appendingPathComponent("native-query-state.json")
        return try .init(credentials: .init(scope: scope, token: token), repository: TranscriptRepository(root: f.repository.root),
            stateURL: f.root.appendingPathComponent("native-return-state.json"), schedulesRetries: false,
            authorized: authorized, didSave: saved, requestBackgroundRetry: { _ in }, diagnostic: diagnostic,
            beginExecution: beginExecution, clientFactory: { _ in ControlledTranscriptTransport(scope: scope) },
            restorationGate: gate, initiallyEnabled: true,
            backgroundFactory: { os.make($0, $1, $2, $3) })
    }

    func executeNativeTranscriptCases() async {
        await run("native_query_production_configuration_has_bounded_scheduling_resource_window") { f in
            let identifier = "synthetic.transcript-query.resource-window"
            // This is the same real Foundation configuration returned to the
            // production URLSession initializer, not the controlled transport.
            let config = ReceiverTranscriptNativeClient.sessionConfiguration(identifier: identifier)
            let sdkDefault = URLSessionConfiguration.background(withIdentifier: identifier + ".sdk-default")
            try self.check(config.identifier == identifier && config.timeoutIntervalForRequest == 30,
                "Production background configuration must retain the exact owner and 30-second request timeout")
            try self.check(config.timeoutIntervalForResource == 604_800
                && config.timeoutIntervalForResource == sdkDefault.timeoutIntervalForResource,
                "Production resource window must be the finite seven-day Foundation default, not the old 120 seconds")
            try self.check(config.timeoutIntervalForResource >= 86_400 + 120,
                "A legal one-day future plan must retain time for the subsequent request and connectivity")
            try self.check(!config.isDiscretionary && config.sessionSendsLaunchEvents
                && config.waitsForConnectivity && !config.allowsCellularAccess,
                "The scheduling policy must preserve background launch, connectivity wait and Wi-Fi-only transfer")
            try self.check(config.httpCookieStorage == nil && !config.httpShouldSetCookies
                && config.urlCredentialStorage == nil && config.urlCache == nil
                && config.requestCachePolicy == .reloadIgnoringLocalCacheData,
                "The timeout change must not introduce shared cookies, credentials or cached responses")
            let other = ReceiverTranscriptNativeClient.sessionConfiguration(identifier: identifier + ".other")
            other.timeoutIntervalForResource = 1
            try self.check(config !== other && config.timeoutIntervalForResource == 604_800,
                "Each grant must receive an independent configuration instead of a mutable shared owner")
            let evidence: [String: Any] = ["configurationType": "URLSessionConfiguration.background",
                "productionFactoryUsedByClientInit": true, "requestSeconds": config.timeoutIntervalForRequest,
                "resourceSeconds": config.timeoutIntervalForResource, "SDKDefaultResourceSeconds": sdkDefault.timeoutIntervalForResource,
                "realSessionCreated": false, "networkRequests": 0]
            try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys])
                .write(to: f.root.appendingPathComponent("actual-production-configuration.json"))
        }
        for (name, horizon) in [("one_hour", 3_600.0), ("one_day", 86_400.0)] {
            await run("native_query_future_\(name)_preserves_backoff_and_single_owner") { f in
                let source = try f.addRecording(0), payload = self.payload("native-resource-" + name)
                let scope = self.transcriptScope(payload), query = self.transcriptQuery(source, scope: scope)
                let clock = SyntheticTransferClock(), os = NativeQueryOS()
                let directory = f.root.appendingPathComponent("future-resource")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: NSNumber(value: 0o700)])
                let stateURL = directory.appendingPathComponent("native-query-state.json")
                let retryMilliseconds = Int64((clock.now().addingTimeInterval(3_600).timeIntervalSince1970 * 1_000).rounded())
                let seed: [String: Any] = ["schemaVersion": 1,
                    "scope": try JSONSerialization.jsonObject(with: TransportCodec.encode(scope)),
                    "failures": 30, "retryAt": retryMilliseconds]
                try JSONSerialization.data(withJSONObject: seed).write(to: stateURL)
                try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: stateURL.path)
                os.stateURL = stateURL
                let queue = try ReceiverTranscriptBackgroundQueue(credentials: .init(scope: scope, token: payload.token),
                    directory: directory, gate: .init(isForeground: { true }, eventTracker: .init()), enabled: true,
                    factory: { os.make($0, $1, $2, $3) }, now: { clock.now() },
                    diagnostic: { _, _ in }, retry: { _ in }, consume: { _, _ in 0 }, changed: {})
                defer { queue.retire() }
                try await self.eventually("future owner ready", { queue.canRegister })
                let originalRetry = queue.retryAt
                let due = clock.now().addingTimeInterval(horizon)
                try queue.register([query], due: due)
                let upload = os.uploads[0]
                let config = ReceiverTranscriptNativeClient.sessionConfiguration(identifier: queue.identifier)
                try self.check(abs(upload.due.timeIntervalSince(due)) < 0.002
                    && config.timeoutIntervalForResource >= upload.due.timeIntervalSince(clock.now()) + 120,
                    "The real resource configuration must outlast the exact future due plus transfer margin")
                try self.check(os.persistedBeforeResume && os.resumes == [upload.taskID]
                    && os.uploads.count == 1 && !queue.canRegister,
                    "A future query must still persist its exact sole task before resuming")
                clock.advance(121)
                let enumerations = os.clients[0].enumerationCount
                queue.restore()
                try await self.eventually("future owner recovered after old timeout", {
                    os.clients[0].enumerationCount > enumerations
                })
                try queue.register([query], due: clock.now())
                try self.check(queue.hasAttempt && os.uploads.count == 1
                    && os.clients.count == 1 && os.clients[0].invalidationCount == 0,
                    "Passing the old 120-second limit must not cancel, replace or duplicate a future owner")
                var saved = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
                try self.check(saved["failures"] as? Int == 30 && queue.retryAt == originalRetry,
                    "Installing a longer resource policy must not reset existing failures or bypass real backoff")
                await os.clients[0].deliver(upload, failure: .network, errorCode: .timedOut)
                saved = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
                try self.check(!queue.hasAttempt && saved["failures"] as? Int == 30
                    && abs((queue.retryAt?.timeIntervalSince(clock.now()) ?? 0) - 3_600) < 0.002,
                    "A genuine timeout must retain the existing capped failure and one-hour retry policy")
            }
        }
        await run("native_query_p0_empty_cleanup_preserves_real_failure_backoff") { f in
            let source = try f.addRecording(0), payload = self.payload("native-empty-cleanup")
            let scope = self.transcriptScope(payload), query = self.transcriptQuery(source, scope: scope)
            let os = NativeQueryOS(), tracker = BackgroundSessionEventTracker()
            let gate = BackgroundSessionRestorationGate(isForeground: { true }, eventTracker: tracker)
            let directory = f.root.appendingPathComponent("empty-cleanup")
            let queue = try ReceiverTranscriptBackgroundQueue(credentials: .init(scope: scope, token: payload.token),
                directory: directory, gate: gate, enabled: true, factory: { os.make($0, $1, $2, $3) },
                diagnostic: { _, _ in }, retry: { _ in }, consume: { _, _ in 0 }, changed: {})
            defer { queue.retire() }
            try await self.eventually("empty native owner", { queue.canRegister })
            _ = tracker.capture(queue.identifier)
            queue.restore()
            try await self.eventually("empty ambiguity drained", { os.clients[0].invalidationCount == 1 && queue.canRegister })
            var state = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("native-query-state.json"))) as! [String: Any]
            try self.check(state["failures"] as? Int == 0 && queue.retryAt == nil,
                "Cleaning an empty ambiguous session must not manufacture a network failure or retry deadline")
            try queue.register([query], due: Date())
            await os.clients.last!.deliver(os.uploads[0], failure: .tls)
            let realRetry = queue.retryAt
            _ = tracker.capture(queue.identifier)
            let client = os.clients.last!
            queue.restore()
            try await self.eventually("post-failure empty ambiguity drained", { client.invalidationCount == 1 && queue.canRegister })
            state = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("native-query-state.json"))) as! [String: Any]
            try self.check(state["failures"] as? Int == 1 && queue.retryAt == realRetry,
                "Empty cleanup must preserve, without increasing or clearing, the preceding real TLS failure backoff")
        }
        await run("native_query_p0_future_no_speech_yields_to_new_authorized_missing_source") { f in
            let oldSource = try f.addRecording(0), newSource = try f.addRecording(1)
            let payload = self.payload("native-no-speech-preemption"), scope = self.transcriptScope(payload)
            let oldQuery = self.transcriptQuery(oldSource, scope: scope), newQuery = self.transcriptQuery(newSource, scope: scope)
            let os = NativeQueryOS(), gate = BackgroundSessionRestorationGate(isForeground: { true }, eventTracker: .init())
            var saved = 0
            let returner = try self.nativeReturner(f, scope: scope, token: payload.token, os: os, gate: gate, saved: { _ in saved += 1 })
            defer { os.clients.first?.releaseInvalidation(); returner.retire() }
            returner.synchronize([oldQuery], enabled: true)
            try await self.eventually("initial no-speech query", { os.uploads.count == 1 })
            let oldClient = os.clients[0]
            var firstCompleted = 0
            gate.receive(oldClient.identifier) { firstCompleted += 1 }
            await oldClient.deliver(os.uploads[0], body: try transcriptResponse([oldQuery], scope: scope, statuses: [oldSource.id: .noSpeech]))
            await oldClient.finish()
            try await self.eventually("future no-speech native owner", { os.uploads.count == 2 && firstCompleted == 1 })
            let future = os.uploads[1]
            oldClient.holdInvalidation = true
            returner.synchronize([oldQuery, newQuery], enabled: true)
            try await self.eventually("new missing source preempts future no-speech", { oldClient.invalidationCount == 1 })
            var completed = 0
            gate.receive(oldClient.identifier) { completed += 1 }
            try self.check(os.uploads.count == 2 && os.clients.count == 1 && completed == 0,
                "The exact old future query must drain before any replacement session or UIKit completion")
            await oldClient.deliver(future, body: try transcriptResponse([oldQuery], scope: scope))
            try self.check(saved == 0 && (try TranscriptRepository(root: f.repository.root).transcript(for: oldSource)) == nil,
                "A superseded future response must not become a saved transcript")
            oldClient.releaseInvalidation()
            try await self.eventually("new due-now native query", { os.uploads.count == 3 && completed == 1 })
            let replacement = os.uploads[2]
            let request = try TransportCodec.decode(AutomaticReceiverTranscriptClient.Request.self, from: replacement.body)
            try self.check(request.items.count == 1 && request.items[0].source == newQuery.source && request.items[0].receipt == newQuery.receipt,
                "Only the newly authorized exact missing source may replace the no-speech query")
            let state = try JSONSerialization.jsonObject(with: Data(contentsOf: os.stateURL!)) as! [String: Any]
            try self.check(replacement.due.timeIntervalSinceNow < 5 && state["failures"] as? Int == 0 && state["retryAt"] == nil,
                "Intentional future-query preemption must not create network backoff")
            await os.clients.last!.deliver(replacement, body: try transcriptResponse([newQuery], scope: scope))
            try self.check(saved == 1 && (try TranscriptRepository(root: f.repository.root).transcript(for: newSource)) != nil,
                "The replacement query must use the actual strict persistence path")
        }
        await run("native_query_p0_no_speech_preemption_respects_authorization_and_existing_local_text") { f in
            let old = try f.addRecording(0), added = try f.addRecording(1)
            let payload = self.payload("native-preempt-filter"), scope = self.transcriptScope(payload)
            let oldQuery = self.transcriptQuery(old, scope: scope), addedQuery = self.transcriptQuery(added, scope: scope)
            let os = NativeQueryOS(), gate = BackgroundSessionRestorationGate(isForeground: { true }, eventTracker: .init())
            let diagnostics = NativeQueryDiagnostics()
            var allowNew = false
            let returner = try self.nativeReturner(f, scope: scope, token: payload.token, os: os, gate: gate,
                authorized: { $0.source == oldQuery.source || allowNew }, diagnostic: { diagnostics.append($0, $1) })
            defer { returner.retire() }
            returner.synchronize([oldQuery], enabled: true)
            try await self.eventually("filter initial task", { os.uploads.count == 1 })
            gate.receive(os.clients[0].identifier) {}
            await os.clients[0].deliver(os.uploads[0], body: try transcriptResponse([oldQuery], scope: scope, statuses: [old.id: .noSpeech]))
            await os.clients[0].finish()
            try await self.eventually("filter future task", { os.uploads.count == 2 })
            returner.synchronize([oldQuery, addedQuery], enabled: true)
            await returner.waitForCurrentQuery()
            try self.check(os.clients[0].invalidationCount == 0 && os.uploads.count == 2
                && !diagnostics.entries.contains { $0.0 == "phone.transcript_native_invalidation_started" },
                "An unauthorized new source cannot cancel the current native query")
            try TranscriptRepository(root: f.repository.root).save(returnedTranscript(added), for: added)
            allowNew = true
            returner.synchronize([oldQuery, addedQuery], enabled: true)
            await returner.waitForCurrentQuery()
            try self.check(os.clients[0].invalidationCount == 0 && os.uploads.count == 2
                && !diagnostics.entries.contains { $0.0 == "phone.transcript_native_invalidation_started" },
                "An already valid local transcript cannot manufacture a missing-source preemption")
        }
        for (status, due) in [(AutomaticReceiverTranscriptStatus.pending, true), (.pending, false), (.retry, true)] {
            await run("native_query_p0_known_\(status.rawValue)_\(due ? "due" : "future")_behind_no_speech") { f in
                let old = try f.addRecording(0), candidate = try f.addRecording(1)
                let payload = self.payload("native-known-due"), scope = self.transcriptScope(payload)
                let oldQuery = self.transcriptQuery(old, scope: scope), query = self.transcriptQuery(candidate, scope: scope)
                func object<T: Encodable>(_ value: T) throws -> Any {
                    try JSONSerialization.jsonObject(with: TransportCodec.encode(value))
                }
                let date = Date()
                let entries: [String: Any] = [
                    old.id.uuidString.lowercased(): ["receipt": try object(oldQuery.receipt), "source": try object(oldQuery.source),
                        "status": "no_speech", "nextQueryAt": Int64(date.addingTimeInterval(3_600).timeIntervalSince1970 * 1_000)],
                    candidate.id.uuidString.lowercased(): ["receipt": try object(query.receipt), "source": try object(query.source),
                        "status": status.rawValue, "nextQueryAt": Int64(date.addingTimeInterval(due ? -1 : 3_600).timeIntervalSince1970 * 1_000)]
                ]
                let state: [String: Any] = ["schemaVersion": 1, "scope": try object(scope), "entries": entries, "scanCursor": 0]
                try JSONSerialization.data(withJSONObject: state).write(to: f.root.appendingPathComponent("native-return-state.json"))
                let os = NativeQueryOS(), gate = BackgroundSessionRestorationGate(isForeground: { true }, eventTracker: .init())
                let diagnostics = NativeQueryDiagnostics()
                let returner = try self.nativeReturner(f, scope: scope, token: payload.token, os: os, gate: gate,
                    diagnostic: { diagnostics.append($0, $1) })
                defer { os.clients.first?.releaseInvalidation(); returner.retire() }
                returner.synchronize([oldQuery], enabled: true)
                try await self.eventually("known source old no-speech future owner", { os.uploads.count == 1 })
                let client = os.clients[0]; client.holdInvalidation = true
                returner.synchronize([oldQuery, query], enabled: true)
                if due {
                    try await self.eventually("known due source requests supersession", { client.invalidationCount == 1 })
                    try self.check(os.uploads.count == 1, "Known due source must still wait for exact native invalidation")
                    client.releaseInvalidation()
                    try await self.eventually("known due source registered", { os.uploads.count == 2 })
                    let request = try TransportCodec.decode(AutomaticReceiverTranscriptClient.Request.self, from: os.uploads[1].body)
                    try self.check(request.items.count == 1 && request.items[0].source == query.source && os.uploads[1].due.timeIntervalSinceNow < 5,
                        "An exact already-due pending or retry source cannot remain behind a terminal no-speech future poll")
                } else {
                    await returner.waitForCurrentQuery()
                    try self.check(os.uploads.count == 1 && client.invalidationCount == 0
                        && !diagnostics.entries.contains { $0.0 == "phone.transcript_native_invalidation_started" },
                        "A known pending source whose due time has not arrived cannot trigger supersession")
                }
            }
        }
        for pause in [false, true] {
            await run(pause ? "native_query_p0_pause_during_supersession_cannot_rebuild" : "native_query_p0_revoke_during_supersession_cannot_register") { f in
                let old = try f.addRecording(0), added = try f.addRecording(1)
                let payload = self.payload("native-preempt-stop"), scope = self.transcriptScope(payload)
                let oldQuery = self.transcriptQuery(old, scope: scope), addedQuery = self.transcriptQuery(added, scope: scope)
                let os = NativeQueryOS(), gate = BackgroundSessionRestorationGate(isForeground: { true }, eventTracker: .init())
                var authorized = true, saved = 0
                let returner = try self.nativeReturner(f, scope: scope, token: payload.token, os: os, gate: gate,
                    authorized: { _ in authorized }, saved: { _ in saved += 1 })
                defer { os.clients.first?.releaseInvalidation(); returner.retire() }
                returner.synchronize([oldQuery], enabled: true)
                try await self.eventually("stop initial task", { os.uploads.count == 1 })
                gate.receive(os.clients[0].identifier) {}
                await os.clients[0].deliver(os.uploads[0], body: try transcriptResponse([oldQuery], scope: scope, statuses: [old.id: .noSpeech]))
                await os.clients[0].finish()
                try await self.eventually("stop future task", { os.uploads.count == 2 })
                let client = os.clients[0]; client.holdInvalidation = true
                returner.synchronize([oldQuery, addedQuery], enabled: true)
                try await self.eventually("stop supersession held", { client.invalidationCount == 1 })
                if pause { returner.stop() } else { authorized = false }
                client.releaseInvalidation()
                try await self.settle()
                try self.check(os.uploads.count == 2 && saved == 0,
                    "Pause or revoked authorization during ordered drain must prevent replacement registration and persistence")
                if pause { try self.check(os.clients.count == 1, "Paused supersession cannot reconstruct a native owner") }
            }
        }
        await run("native_query_p0_pending_future_is_not_no_speech_preemption") { f in
            let old = try f.addRecording(0), added = try f.addRecording(1)
            let payload = self.payload("native-preempt-pending"), scope = self.transcriptScope(payload)
            let oldQuery = self.transcriptQuery(old, scope: scope), addedQuery = self.transcriptQuery(added, scope: scope)
            let os = NativeQueryOS(), gate = BackgroundSessionRestorationGate(isForeground: { true }, eventTracker: .init())
            let diagnostics = NativeQueryDiagnostics()
            let returner = try self.nativeReturner(f, scope: scope, token: payload.token, os: os, gate: gate,
                diagnostic: { diagnostics.append($0, $1) })
            defer { returner.retire() }
            returner.synchronize([oldQuery], enabled: true)
            try await self.eventually("pending initial task", { os.uploads.count == 1 })
            gate.receive(os.clients[0].identifier) {}
            await os.clients[0].deliver(os.uploads[0], body: try transcriptResponse([oldQuery], scope: scope, statuses: [old.id: .pending]))
            await os.clients[0].finish()
            try await self.eventually("pending future task", { os.uploads.count == 2 })
            returner.synchronize([oldQuery, addedQuery], enabled: true)
            await returner.waitForCurrentQuery()
            try self.check(os.clients[0].invalidationCount == 0 && os.uploads.count == 2
                && !diagnostics.entries.contains { $0.0 == "phone.transcript_native_invalidation_started" },
                "A pending ASR query is not a terminal no-speech ticket and must retain its native owner")
        }
        await run("native_query_p0_deferred_ticket_binds_nonce_request_and_future_due") { f in
            let source = try f.addRecording(0), payload = self.payload("native-preempt-ticket")
            let scope = self.transcriptScope(payload), query = self.transcriptQuery(source, scope: scope)
            let os = NativeQueryOS(), clock = SyntheticTransferClock()
            let queue = try ReceiverTranscriptBackgroundQueue(credentials: .init(scope: scope, token: payload.token),
                directory: f.root.appendingPathComponent("ticket"), gate: .init(isForeground: { true }, eventTracker: .init()),
                enabled: true, factory: { os.make($0, $1, $2, $3) }, now: { clock.now() },
                diagnostic: { _, _ in }, retry: { _ in }, consume: { _, _ in nil }, changed: {})
            defer { queue.retire() }
            try await self.eventually("ticket owner ready", { queue.canRegister })
            try queue.register([query], due: clock.now().addingTimeInterval(3_600))
            let ticket = queue.deferredAttempt!
            try self.check(!queue.supersedeDeferredAttempt(.init(nonce: UUID(), queries: ticket.queries, due: ticket.due)),
                "A stale or fabricated nonce cannot cancel a different retained attempt")
            let foreign = self.transcriptQuery(source, scope: self.transcriptScope(self.payload("different-grant")))
            try self.check(!queue.supersedeDeferredAttempt(.init(nonce: ticket.nonce, queries: [foreign], due: ticket.due)),
                "The complete receipt and scope must bind the preempted request bytes")
            let changedReceipt = self.transcriptQuery(source, scope: scope)
            try self.check(!queue.supersedeDeferredAttempt(.init(nonce: ticket.nonce, queries: [changedReceipt], due: ticket.due)),
                "Another valid receipt for the same source and scope cannot impersonate the retained request digest")
            clock.advance(3_601)
            try self.check(!queue.supersedeDeferredAttempt(ticket) && os.clients[0].invalidationCount == 0,
                "A query whose due time has arrived cannot be cancelled using an old future ticket")
        }
        await run("native_query_p0_error_diagnostics_keep_alias_and_fixed_whitelist") { f in
            let samples: [(Int, ReceiverTranscriptNativeErrorCode)] = [(-999, .cancelled), (-1001, .timedOut),
                (-1005, .connectionLost), (-1009, .offline), (-997, .backgroundDisconnected), (-996, .backgroundOwnerConflict), (-1202, .tls)]
            for (code, expected) in samples {
                try self.check(ReceiverTranscriptNativeErrorCode.classify(NSError(domain: NSURLErrorDomain, code: code,
                    userInfo: [NSLocalizedDescriptionKey: "SYNTHETIC_PRIVATE_ERROR_BODY"])) == expected,
                    "Native failure code must use only its reviewed fixed classification")
            }
            try self.check(ReceiverTranscriptNativeErrorCode.classify(NSError(domain: "private-domain", code: -1001)) == .other,
                "An unrelated error domain cannot impersonate an NSURLError code")
            let source = try f.addRecording(0), payload = self.payload("native-safe-diagnostics")
            let scope = self.transcriptScope(payload), query = self.transcriptQuery(source, scope: scope)
            let os = NativeQueryOS(), diagnostics = NativeQueryDiagnostics()
            let queue = try ReceiverTranscriptBackgroundQueue(credentials: .init(scope: scope, token: payload.token),
                directory: f.root.appendingPathComponent("diagnostics"), gate: .init(isForeground: { true }, eventTracker: .init()),
                enabled: true, factory: { os.make($0, $1, $2, $3) }, diagnostic: { diagnostics.append($0, $1) },
                retry: { _ in }, consume: { _, _ in 0 }, changed: {})
            defer { queue.retire() }
            try await self.eventually("diagnostic owner", { queue.canRegister })
            try queue.register([query], due: Date(timeIntervalSinceNow: 3_600))
            await os.clients[0].deliver(os.uploads[0], failure: .network, errorCode: .timedOut)
            let registered = diagnostics.entries.first { $0.0 == "phone.transcript_native_registered" }!.1
            let failure = diagnostics.entries.first { $0.0 == "phone.transcript_native_failed" }!.1
            try self.check(Array(registered.split(separator: " ").prefix(2)) == Array(failure.split(separator: " ").prefix(2))
                && failure.contains("category=network error_code=timed_out phase=completion")
                && failure.contains("elapsed_seconds=") && failure.contains("due_in_seconds="),
                "Failure diagnostics must correlate to the registered attempt without losing its fixed error stage")
            try self.check(!failure.contains(payload.token) && !failure.contains(payload.endpoint)
                && !failure.contains(source.id.uuidString) && !failure.contains("SYNTHETIC_PRIVATE_ERROR_BODY"),
                "Native diagnostics must never contain credentials, identities, endpoints or private error descriptions")
        }
        await run("native_query_cold_wc_real_finite_lease_registers_without_fake_processing") { f in
            let source = try f.addRecording(0), payload = self.payload("native-cold-wc")
            let scope = self.transcriptScope(payload), query = self.transcriptQuery(source, scope: scope)
            let os = NativeQueryOS(), gate = BackgroundSessionRestorationGate(isForeground: { false }, eventTracker: .init())
            let lease = SyntheticDeliveryLease()
            let returner = try self.nativeReturner(f, scope: scope, token: payload.token, os: os, gate: gate,
                beginExecution: { _ in lease })
            defer { returner.retire() }
            try self.check(os.clients.isEmpty && !gate.canRestore(ReceiverTranscriptNativeClient.identifier(for: scope)),
                           "Cold WC initialization alone must not invent foreground or BGProcessing permission")
            returner.synchronize([query], enabled: true)
            try await self.eventually("real finite WC opportunity registered native query", { os.uploads.count == 1 && os.resumes.count == 1 })
            try self.check(os.clients.count == 1 && !gate.canRestore(os.clients[0].identifier),
                           "The actual finite lease may construct the exact native owner without opening a fake processing token")
            try self.check(lease.endCount >= 1, "Registering native ownership must release the finite parent lease")
        }
        await run("native_query_expired_cold_lease_cannot_construct_owner") { f in
            let source = try f.addRecording(0), payload = self.payload("native-expired-lease")
            let scope = self.transcriptScope(payload), query = self.transcriptQuery(source, scope: scope)
            let os = NativeQueryOS(), gate = BackgroundSessionRestorationGate(isForeground: { false }, eventTracker: .init())
            let lease = SyntheticDeliveryLease(permitted: false)
            let returner = try self.nativeReturner(f, scope: scope, token: payload.token, os: os, gate: gate,
                beginExecution: { _ in lease })
            defer { returner.retire() }
            returner.synchronize([query], enabled: true); await returner.waitForCurrentQuery()
            try self.check(os.clients.isEmpty && os.uploads.isEmpty && !gate.canRestore(ReceiverTranscriptNativeClient.identifier(for: scope)),
                           "Expired execution cannot create a native query or grant itself background permission")
        }
        await run("native_query_old_cancelled_worker_cannot_end_new_execution") { f in
            let source = try f.addRecording(0), payload = self.payload("native-run-fence")
            let scope = self.transcriptScope(payload), query = self.transcriptQuery(source, scope: scope)
            let os = NativeQueryOS(), gate = BackgroundSessionRestorationGate(isForeground: { true }, eventTracker: .init())
            let leases = DeliveryLeaseGate()
            let returner = try self.nativeReturner(f, scope: scope, token: payload.token, os: os, gate: gate,
                beginExecution: { _ in await leases.acquire() })
            defer { returner.retire() }
            try await self.eventually("initial native owner", { os.clients.count == 1 && os.clients[0].enumerationCount == 1 })
            try await self.settle() // Let init's ordinary enumeration finish before holding the replacement run.
            os.clients[0].holdEnumeration = true
            returner.synchronize([query], enabled: true)
            try await self.eventually("old execution awaiting lease", { leases.count == 1 })
            returner.suspendProcessWork()
            returner.synchronize([query], enabled: true)
            try await self.eventually("replacement execution awaiting lease", { leases.count == 2 })
            let current = SyntheticDeliveryLease(), old = SyntheticDeliveryLease()
            leases.release(current, at: 1)
            try await self.eventually("new execution held in native enumeration", { os.clients[0].enumerationWaiting == 1 })
            try await self.settle() // New run has its lease and awaits the held OS snapshot.
            leases.release(old)
            try await self.settle()
            try self.check(old.endCount == 1 && current.endCount == 0,
                "A delayed cancelled worker must end only its own returned lease")
            var drained = false
            let wait = Task { await returner.waitForCurrentQuery(); drained = true }
            await Task.yield()
            try self.check(!drained, "The old worker must not clear the new worker handle")
            os.clients[0].releaseEnumeration()
            await wait.value
            try self.check(os.uploads.count == 1 && current.endCount == 1,
                "The replacement execution retains its lease through durable native registration")
        }
        await run("native_query_expired_enumeration_cannot_adopt_or_replay") { f in
            let source = try f.addRecording(0), payload = self.payload("native-enumeration-expiry")
            let scope = self.transcriptScope(payload), query = self.transcriptQuery(source, scope: scope)
            let os = NativeQueryOS(), directory = f.root.appendingPathComponent("enumeration-expiry")
            var queue: ReceiverTranscriptBackgroundQueue? = try .init(credentials: .init(scope: scope, token: payload.token),
                directory: directory, gate: .init(isForeground: { true }, eventTracker: .init()), enabled: true,
                factory: { os.make($0, $1, $2, $3) }, diagnostic: { _, _ in }, retry: { _ in }, consume: { _, _ in 0 }, changed: {})
            try await self.eventually("seed durable attempt", { queue?.canRegister == true })
            try queue?.register([query], due: Date())
            let original = os.uploads[0], task = os.tasks()[0]
            let stateURL = directory.appendingPathComponent("native-query-state.json")
            var state = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
            var attempt = state["attempt"] as! [String: Any]; attempt.removeValue(forKey: "taskID"); state["attempt"] = attempt
            try JSONSerialization.data(withJSONObject: state).write(to: stateURL)
            let beforeBytes = try Data(contentsOf: stateURL)
            os.snapshotOverride = [.init(taskID: original.taskID, nonce: original.nonce, requestURL: task.requestURL,
                method: task.method, bodySHA256: task.bodySHA256, bodyBytes: task.bodyBytes, suspended: true)]
            queue = nil
            var changed = 0, consumed = 0
            let gate = BackgroundSessionRestorationGate(isForeground: { false }, eventTracker: .init())
            let restored = try ReceiverTranscriptBackgroundQueue(credentials: .init(scope: scope, token: payload.token),
                directory: directory, gate: gate, enabled: true,
                factory: { let client = os.make($0, $1, $2, $3); client.holdEnumeration = true; return client },
                diagnostic: { _, _ in }, retry: { _ in }, consume: { _, _ in consumed += 1; return 0 }, changed: { changed += 1 })
            defer { os.snapshotOverride = nil; restored.retire() }
            let expired = SyntheticDeliveryLease()
            restored.restore(executionLease: expired)
            try await self.eventually("cold enumeration held", { os.clients.count == 2 && os.clients[1].enumerationCount == 1 })
            expired.end(); os.clients[1].releaseEnumeration()
            try await self.eventually("expired enumeration returned", { !restored.isRecovering })
            try self.check(try Data(contentsOf: stateURL) == beforeBytes && changed == 0 && consumed == 0 && os.resumes.count == 1,
                "An expired finite opportunity cannot adopt, replay, resume or announce work after native enumeration")
            restored.restore(executionLease: SyntheticDeliveryLease())
            try await self.eventually("new finite opportunity recovers original task", { os.resumes.count == 2 })
            try self.check(restored.hasAttempt && os.uploads.count == 1 && changed == 1,
                "Expired enumeration retains durable ownership for the next actual opportunity")
        }
        await run("native_query_actual_tls_policy_rejects_wrong_pin_host_and_port") { _ in
            let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Fixtures/native-query-synthetic-cert.der")
            let bytes = try Data(contentsOf: file)
            let certificate = SecCertificateCreateWithData(nil, bytes as CFData)!
            let host = "native-query.example.invalid"
            var trust: SecTrust?
            try self.check(SecTrustCreateWithCertificates(certificate, SecPolicyCreateSSL(true, host as CFString), &trust) == errSecSuccess,
                           "Synthetic trust must be locally constructible without any network")
            let verificationDate = ISO8601DateFormatter().date(from: "2026-10-26T00:00:00Z")!
            SecTrustSetVerifyDate(trust!, verificationDate as CFDate)
            let pin = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            func scope(_ digest: String) -> AutomaticDeliveryScope {
                .init(receiverID: UUID(), pairingID: UUID(), grantEpoch: UUID(), sourceInstallationID: UUID(),
                      endpoint: "https://" + host + ":8766", certificateSHA256: digest)
            }
            try self.check(ReceiverTranscriptNativeClient.acceptsPeer(trust!, host: host, port: 8766, scope: scope(pin)),
                           "The exact paired self-signed leaf with valid hostname must pass the actual native trust function")
            try self.check(!ReceiverTranscriptNativeClient.acceptsPeer(trust!, host: host, port: 443, scope: scope(pin)), "Wrong port cannot reuse paired trust")
            try self.check(!ReceiverTranscriptNativeClient.acceptsPeer(trust!, host: "other.example.invalid", port: 8766, scope: scope(pin)), "Wrong host cannot reuse paired trust")
            try self.check(!ReceiverTranscriptNativeClient.acceptsPeer(trust!, host: host, port: 8766, scope: scope(String(repeating: "a", count: 64))), "Wrong leaf pin cannot accept a native response")
        }
        await run("native_query_private_files_reject_links_and_keep_private_modes") { f in
            let directory = f.root.appendingPathComponent("private-native"), file = directory.appendingPathComponent("state.json")
            let bytes = Data("{\"synthetic\":true}".utf8)
            try ReceiverTranscriptPrivateFiles.write(bytes, to: file)
            let fm = FileManager.default
            try self.check((try fm.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700
                && (try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600,
                "Durable authority and derived response files must be private")
            try self.check(try ReceiverTranscriptPrivateFiles.read(file, limit: 64) == bytes, "Descriptor-bound read must preserve exact bytes")
            let hard = directory.appendingPathComponent("hard.json")
            try fm.linkItem(at: file, to: hard)
            var rejected = 0
            do { _ = try ReceiverTranscriptPrivateFiles.read(file, limit: 64) } catch { rejected += 1 }
            do { try ReceiverTranscriptPrivateFiles.write(bytes, to: hard) } catch { rejected += 1 }
            try fm.removeItem(at: hard)
            let symlink = directory.appendingPathComponent("symlink.json")
            try fm.createSymbolicLink(at: symlink, withDestinationURL: file)
            do { _ = try ReceiverTranscriptPrivateFiles.read(symlink, limit: 64) } catch { rejected += 1 }
            do { try ReceiverTranscriptPrivateFiles.write(bytes, to: symlink) } catch { rejected += 1 }
            do { try ReceiverTranscriptPrivateFiles.remove(symlink) } catch { rejected += 1 }
            try self.check(rejected == 5 && (try Data(contentsOf: file)) == bytes,
                "Linked files must be rejected without modifying or recursively removing the target")
        }
        await run("native_query_registers_real_file_and_exact_task_before_resume") { f in
            let source = try f.addRecording(0), payload = self.payload("native-register")
            let scope = self.transcriptScope(payload), query = self.transcriptQuery(source, scope: scope)
            let os = NativeQueryOS(), gate = BackgroundSessionRestorationGate(isForeground: { true }, eventTracker: .init())
            let returner = try self.nativeReturner(f, scope: scope, token: payload.token, os: os, gate: gate)
            defer { returner.retire() }
            returner.synchronize([query], enabled: true)
            try await self.eventually("native query registered", { os.uploads.count == 1 && os.resumes.count == 1 })
            let upload = os.uploads[0]
            try self.check(upload.body == AutomaticReceiverTranscriptClient.requestBody([query], scope: scope), "Native wire must use the actual bounded receipt encoding")
            try self.check(os.persistedBeforeResume, "The exact native task ID must be durable before resume")
            try self.check(os.clients[0].identifier != AutomaticReceiverClient.sessionIdentifier(for: scope), "Transcript and audio sessions must have distinct owners")
            try self.check(upload.body.count <= 32 * 1_024 && os.tasks().count == 1, "One grant owns at most one real bounded query")
            returner.synchronize([query], enabled: true)
            try await self.settle()
            try self.check(os.uploads.count == 1, "Repeated receipt discovery cannot duplicate a retained native query")
        }
        await run("native_query_pending_requeues_due_before_uikit_completion_without_timer") { f in
            let source = try f.addRecording(0), payload = self.payload("native-pending")
            let scope = self.transcriptScope(payload), query = self.transcriptQuery(source, scope: scope)
            let os = NativeQueryOS(), gate = BackgroundSessionRestorationGate(isForeground: { true }, eventTracker: .init())
            let returner = try self.nativeReturner(f, scope: scope, token: payload.token, os: os, gate: gate)
            defer { returner.retire() }
            returner.synchronize([query], enabled: true)
            try await self.eventually("first real query", { os.uploads.count == 1 })
            var completions = 0, registeredAtCompletion = 0
            gate.receive(os.clients[0].identifier) { completions += 1; registeredAtCompletion = os.uploads.count }
            let before = Date()
            await os.clients[0].deliver(os.uploads[0], body: try transcriptResponse([query], scope: scope, statuses: [source.id: .pending]))
            await os.clients[0].finish()
            try await self.eventually("next due query is owned natively", { os.uploads.count == 2 })
            try self.check(os.uploads[1].due.timeIntervalSince(before) >= 59, "Pending status must preserve a real 60-second due date")
            try self.check(completions == 1 && registeredAtCompletion == 2, "UIKit completion must follow next bounded native registration")
            try self.check(os.clients[0].invalidationCount == 0, "A normal valid background wave must not cancel native work")
            try self.check(try TranscriptRepository(root: f.repository.root).transcript(for: source) == nil, "Pending never becomes an empty transcript")
        }
        await run("native_query_uikit_completion_waits_for_held_next_registration") { f in
            let source = try f.addRecording(0), payload = self.payload("native-held-next")
            let scope = self.transcriptScope(payload), query = self.transcriptQuery(source, scope: scope)
            let os = NativeQueryOS(), gate = BackgroundSessionRestorationGate(isForeground: { true }, eventTracker: .init())
            let leases = DeliveryLeaseGate()
            let returner = try self.nativeReturner(f, scope: scope, token: payload.token, os: os, gate: gate,
                beginExecution: { _ in os.uploads.isEmpty ? nil : await leases.acquire() })
            defer { returner.retire() }
            returner.synchronize([query], enabled: true)
            try await self.eventually("first query before held registration", { os.uploads.count == 1 })
            var completed = 0
            let client = os.clients[0]
            gate.receive(client.identifier) { completed += 1 }
            await client.deliver(os.uploads[0], body: try transcriptResponse([query], scope: scope, statuses: [source.id: .pending]))
            try await self.eventually("next local registration lease is held", { leases.count == 1 })
            let finish = Task { await client.finish() }
            try await self.settle()
            try self.check(completed == 0 && os.uploads.count == 1,
                "A fresh drain must not release UIKit before the bounded next-registration worker completes")
            leases.release(SyntheticDeliveryLease())
            await finish.value
            try self.check(completed == 1 && os.uploads.count == 2, "Release only after next real task ownership is durable")
        }
        await run("native_query_cold_restore_keeps_one_task_and_strictly_saves_once") { f in
            let source = try f.addRecording(0), payload = self.payload("native-cold")
            let scope = self.transcriptScope(payload), query = self.transcriptQuery(source, scope: scope)
            let os = NativeQueryOS()
            var returner: PhoneReceiverTranscriptReturn? = try self.nativeReturner(f, scope: scope, token: payload.token,
                os: os, gate: .init(isForeground: { true }, eventTracker: .init()))
            returner?.synchronize([query], enabled: true)
            try await self.eventually("pre-crash native query", { os.uploads.count == 1 })
            returner = nil // The native OS task survives the app object.
            var foreground = false, saved = 0
            let gate = BackgroundSessionRestorationGate(isForeground: { foreground }, eventTracker: .init())
            let restored = try self.nativeReturner(f, scope: scope, token: payload.token, os: os, gate: gate, saved: { _ in saved += 1 })
            defer { restored.retire() }
            restored.synchronize([query], enabled: true)
            try await self.settle()
            try self.check(os.clients.count == 1 && os.uploads.count == 1, "Cold initialization must not attach before an actual opportunity")
            var completed = 0
            gate.receive(ReceiverTranscriptNativeClient.identifier(for: scope)) { completed += 1 }
            try await self.eventually("same native session restored", { os.clients.count == 2 })
            foreground = true
            await os.clients[1].deliver(os.uploads[0], body: try transcriptResponse([query], scope: scope))
            await os.clients[1].finish()
            try self.check(saved == 1 && completed == 1 && os.uploads.count == 1, "A restored exact response commits once before UIKit completion")
            try self.check(try TranscriptRepository(root: f.repository.root).transcript(for: source)?.audioSHA256 == source.sha256, "Restored transcript retains exact audio identity")
            await os.clients[1].deliver(os.uploads[0], body: try transcriptResponse([query], scope: scope))
            try self.check(saved == 1, "Duplicate native completion must not notify Drive twice")
        }
        await run("native_query_pause_waits_invalidation_and_rejects_late_response") { f in
            let source = try f.addRecording(0), payload = self.payload("native-pause")
            let scope = self.transcriptScope(payload), query = self.transcriptQuery(source, scope: scope)
            let os = NativeQueryOS(), gate = BackgroundSessionRestorationGate(isForeground: { true }, eventTracker: .init())
            var saved = 0
            let returner = try self.nativeReturner(f, scope: scope, token: payload.token, os: os, gate: gate, saved: { _ in saved += 1 })
            returner.synchronize([query], enabled: true)
            try await self.eventually("query before pause", { os.uploads.count == 1 })
            let client = os.clients[0]; client.holdInvalidation = true
            var completed = 0
            gate.receive(client.identifier) { completed += 1 }
            returner.stop()
            try await self.eventually("native invalidation held", { client.invalidationCount == 1 })
            await client.deliver(os.uploads[0], body: try transcriptResponse([query], scope: scope))
            await client.finish()
            try self.check(saved == 0 && completed == 0, "Pause rejects old results and cannot finish UIKit before native invalidation")
            client.releaseInvalidation()
            try await self.eventually("paused wave completion", { completed == 1 })
            try self.check(os.clients.count == 1 && os.uploads.count == 1, "Pause cannot rebuild its cancelled query")
            returner.retire()
            gate.restorePermitted()
            try await self.settle()
            try self.check(os.clients.count == 1, "Retired scope must not cold restore")
        }
        await run("native_query_revalidates_authorization_and_preserves_new_local_text") { f in
            let source = try f.addRecording(0), payload = self.payload("native-auth")
            let scope = self.transcriptScope(payload), query = self.transcriptQuery(source, scope: scope)
            let os = NativeQueryOS(), gate = BackgroundSessionRestorationGate(isForeground: { true }, eventTracker: .init())
            var authorized = true, saved = 0
            let returner = try self.nativeReturner(f, scope: scope, token: payload.token, os: os, gate: gate,
                authorized: { _ in authorized }, saved: { _ in saved += 1 })
            defer { returner.retire() }
            returner.synchronize([query], enabled: true)
            try await self.eventually("authorized native query", { os.uploads.count == 1 })
            authorized = false
            await os.clients[0].deliver(os.uploads[0], body: try transcriptResponse([query], scope: scope))
            try self.check(try TranscriptRepository(root: f.repository.root).transcript(for: source) == nil && saved == 0, "Response cannot cross a revoked live authorization fence")
            let local = returnedTranscript(source, text: "新的本机版本")
            try TranscriptRepository(root: f.repository.root).save(local, for: source)
            authorized = true
            returner.synchronize([query], enabled: true)
            try await self.settle()
            try self.check(try TranscriptRepository(root: f.repository.root).transcript(for: source)?.text == local.text && saved == 0,
                "Replayed exact old response must never overwrite a legal local version")
        }
        await run("native_query_durable_failure_backoff_and_stale_nonce_fence") { f in
            let source = try f.addRecording(0), payload = self.payload("native-retry")
            let scope = self.transcriptScope(payload), query = self.transcriptQuery(source, scope: scope)
            let os = NativeQueryOS(), gate = BackgroundSessionRestorationGate(isForeground: { true }, eventTracker: .init())
            var consumed = 0
            let directory = f.root.appendingPathComponent("native-queue")
            let queue = try ReceiverTranscriptBackgroundQueue(credentials: .init(scope: scope, token: payload.token),
                directory: directory, gate: gate, enabled: true, factory: { os.make($0, $1, $2, $3) },
                diagnostic: { _, _ in }, retry: { _ in }, consume: { _, _ in consumed += 1; return 0 }, changed: {})
            defer { queue.retire() }
            try await self.eventually("native queue can register", { queue.canRegister })
            try queue.register([query], due: Date())
            let first = os.uploads[0]
            await os.clients[0].deliver(first, body: Data(), nonce: UUID())
            await os.clients[0].deliver(first, body: Data(), taskID: first.taskID + 1)
            try self.check(queue.hasAttempt && consumed == 0, "Mismatched nonce or task ID cannot consume or clear the active attempt")
            let before = Date()
            await os.clients[0].deliver(first, failure: .tls)
            try self.check(!queue.hasAttempt && consumed == 0 && (queue.retryAt?.timeIntervalSince(before) ?? 0) >= 59,
                "Wrong TLS must not commit data and must durably back off")
            try queue.register([query], due: .distantPast)
            try self.check(os.uploads[1].due >= queue.retryAt!, "A new discovery cannot bypass durable failure backoff")
            await os.clients[0].deliver(os.uploads[1], failure: .network)
            let data = try Data(contentsOf: directory.appendingPathComponent("native-query-state.json"))
            let state = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            try self.check(state["failures"] as? Int == 2 && (queue.retryAt?.timeIntervalSince(before) ?? 0) >= 119,
                "Consecutive no-progress failures must increase persisted backoff")
        }
        await run("native_query_first_persist_failure_creates_no_phantom_task") { f in
            let source = try f.addRecording(0), payload = self.payload("native-persist")
            let scope = self.transcriptScope(payload), query = self.transcriptQuery(source, scope: scope)
            let os = NativeQueryOS(), gate = BackgroundSessionRestorationGate(isForeground: { true }, eventTracker: .init())
            let directory = f.root.appendingPathComponent("native-persist")
            let queue = try ReceiverTranscriptBackgroundQueue(credentials: .init(scope: scope, token: payload.token),
                directory: directory, gate: gate, enabled: true, factory: { os.make($0, $1, $2, $3) },
                diagnostic: { _, _ in }, retry: { _ in }, consume: { _, _ in 0 }, changed: {})
            defer { queue.retire() }
            try await self.eventually("queue before filesystem fault", { queue.canRegister })
            let stateURL = directory.appendingPathComponent("native-query-state.json")
            try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
            var failed = false
            do { try queue.register([query], due: Date()) } catch { failed = true }
            try self.check(failed && queue.canRegister && !queue.hasAttempt && os.uploads.isEmpty && os.resumes.isEmpty,
                "An unpersisted request must roll back in memory before any native create/resume")
            try FileManager.default.removeItem(at: stateURL)
            try queue.register([query], due: Date())
            try self.check(os.uploads.count == 1, "A recoverable persistence failure must not leave a phantom busy attempt")
        }
        await run("native_query_preresume_crash_recovers_exact_suspended_task") { f in
            let source = try f.addRecording(0), payload = self.payload("native-suspended")
            let scope = self.transcriptScope(payload), query = self.transcriptQuery(source, scope: scope)
            let os = NativeQueryOS(), directory = f.root.appendingPathComponent("suspended-queue")
            var foreground = true
            var queue: ReceiverTranscriptBackgroundQueue? = try .init(credentials: .init(scope: scope, token: payload.token),
                directory: directory, gate: .init(isForeground: { foreground }, eventTracker: .init()), enabled: true,
                factory: { os.make($0, $1, $2, $3) }, diagnostic: { _, _ in }, retry: { _ in }, consume: { _, _ in 0 }, changed: {})
            try await self.eventually("queue before simulated process death", { queue?.canRegister == true })
            try queue?.register([query], due: Date())
            let original = os.uploads[0]
            let stateURL = directory.appendingPathComponent("native-query-state.json")
            var state = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
            var attempt = state["attempt"] as! [String: Any]; attempt.removeValue(forKey: "taskID"); state["attempt"] = attempt
            try JSONSerialization.data(withJSONObject: state).write(to: stateURL)
            let originalTask = os.tasks()[0]
            os.snapshotOverride = [.init(taskID: original.taskID, nonce: original.nonce,
                requestURL: originalTask.requestURL, method: originalTask.method, bodySHA256: originalTask.bodySHA256,
                bodyBytes: originalTask.bodyBytes, suspended: true)]
            queue = nil; foreground = false
            let gate = BackgroundSessionRestorationGate(isForeground: { foreground }, eventTracker: .init())
            let restored = try ReceiverTranscriptBackgroundQueue(credentials: .init(scope: scope, token: payload.token),
                directory: directory, gate: gate, enabled: true, factory: { os.make($0, $1, $2, $3) },
                diagnostic: { _, _ in }, retry: { _ in }, consume: { _, _ in 0 }, changed: {})
            defer { os.snapshotOverride = nil; restored.retire() }
            gate.receive(restored.identifier) {}
            try await self.eventually("suspended task resumed", { os.resumes.count == 2 })
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: Any]
            try self.check((saved["attempt"] as? [String: Any])?["taskID"] as? Int == original.taskID,
                "Recovered suspended native task identity must be persisted before resume")
            try self.check(os.uploads.count == 1 && os.resumes == [original.taskID, original.taskID],
                "A crash between create, persist and resume cannot strand or duplicate the original query")
        }
        await run("native_query_rejects_foreign_route_body_and_expired_task_ownership") { f in
            let source = try f.addRecording(0), payload = self.payload("native-foreign")
            let scope = self.transcriptScope(payload), query = self.transcriptQuery(source, scope: scope)
            let os = NativeQueryOS(), directory = f.root.appendingPathComponent("foreign-queue")
            let clock = SyntheticTransferClock()
            let gate = BackgroundSessionRestorationGate(isForeground: { true }, eventTracker: .init())
            let queue = try ReceiverTranscriptBackgroundQueue(credentials: .init(scope: scope, token: payload.token),
                directory: directory, gate: gate, enabled: true, factory: { os.make($0, $1, $2, $3) }, now: { clock.now() },
                diagnostic: { _, _ in }, retry: { _ in }, consume: { _, _ in throw ProbeFailure.failed("Foreign task must never be consumed") }, changed: {})
            defer { queue.retire() }
            try await self.eventually("queue before foreign metadata", { queue.canRegister })
            try queue.register([query], due: clock.now())
            let original = os.uploads[0]
            os.clients[0].holdInvalidation = true
            os.snapshotOverride = [.init(taskID: original.taskID, nonce: original.nonce,
                requestURL: URL(string: payload.endpoint)!.appendingPathComponent("v1/imports"), method: "POST",
                bodySHA256: String(repeating: "a", count: 64), bodyBytes: Int64(original.body.count), suspended: false)]
            queue.restore()
            try await self.eventually("foreign task held for invalidation", { os.clients[0].invalidationCount == 1 })
            try self.check(os.uploads.count == 1 && !queue.canRegister, "Wrong route or body binding requires real invalidation before any replacement")
            os.snapshotOverride = nil; os.clients[0].releaseInvalidation()
            try await self.eventually("foreign task safely retired", { queue.canRegister })
            try queue.register([query], due: clock.now())
            os.removeAll(); clock.advance(241)
            let expiredClient = os.clients.last!
            queue.restore()
            try await self.eventually("expired missing native owner invalidated", { expiredClient.invalidationCount == 1 })
            try await self.eventually("expired attempt returns to durable backoff", { queue.canRegister && !queue.hasAttempt })
            try self.check(os.uploads.count == 2 && queue.retryAt != nil, "Missing expired native task cannot stay permanently busy or bypass backoff")
        }
        await run("native_query_no_speech_keeps_long_due_and_never_saves_empty_text") { f in
            let source = try f.addRecording(0), payload = self.payload("native-no-speech")
            let scope = self.transcriptScope(payload), query = self.transcriptQuery(source, scope: scope)
            let os = NativeQueryOS(), gate = BackgroundSessionRestorationGate(isForeground: { true }, eventTracker: .init())
            var saved = 0
            let returner = try self.nativeReturner(f, scope: scope, token: payload.token, os: os, gate: gate, saved: { _ in saved += 1 })
            defer { returner.retire() }
            returner.synchronize([query], enabled: true)
            try await self.eventually("no speech first query", { os.uploads.count == 1 })
            let before = Date()
            await os.clients[0].deliver(os.uploads[0], body: try transcriptResponse([query], scope: scope, statuses: [source.id: .noSpeech]))
            await os.clients[0].finish()
            try await self.eventually("long due query", { os.uploads.count == 2 })
            try self.check(os.uploads[1].due.timeIntervalSince(before) >= 3_599 && saved == 0,
                "No-speech remains a status with a long real due, never an empty transcript or hot polling loop")
        }
        await run("native_query_corrupt_reply_does_not_commit_and_replay_is_crash_safe") { f in
            let source = try f.addRecording(0), payload = self.payload("native-response")
            let scope = self.transcriptScope(payload), query = self.transcriptQuery(source, scope: scope)
            let os = NativeQueryOS(), directory = f.root.appendingPathComponent("replay-queue")
            var permitted = false, consumed = 0
            var queue: ReceiverTranscriptBackgroundQueue? = try .init(credentials: .init(scope: scope, token: payload.token),
                directory: directory, gate: .init(isForeground: { true }, eventTracker: .init()), enabled: true,
                factory: { os.make($0, $1, $2, $3) }, diagnostic: { _, _ in }, retry: { _ in },
                consume: { queries, data in
                    guard permitted else { return nil }
                    _ = try AutomaticReceiverTranscriptClient.validate(data, for: queries, scope: .init(scope)); consumed += 1; return 1
                }, changed: {})
            try await self.eventually("replay queue ready", { queue?.canRegister == true })
            try queue?.register([query], due: Date())
            await os.clients[0].deliver(os.uploads[0], body: try transcriptResponse([query], scope: scope))
            try self.check(queue?.hasAttempt == true && consumed == 0, "A cold response must stay durable until a current authorized snapshot exists")
            queue = nil; permitted = true
            let restored = try ReceiverTranscriptBackgroundQueue(credentials: .init(scope: scope, token: payload.token),
                directory: directory, gate: .init(isForeground: { true }, eventTracker: .init()), enabled: true,
                factory: { os.make($0, $1, $2, $3) }, diagnostic: { _, _ in }, retry: { _ in },
                consume: { queries, data in
                    _ = try AutomaticReceiverTranscriptClient.validate(data, for: queries, scope: .init(scope)); consumed += 1; return 1
                }, changed: {})
            defer { restored.retire() }
            restored.replay(); restored.replay()
            try self.check(consumed == 1 && !restored.hasAttempt, "Persisted response hash and exact query must replay once across launch")
            try await self.eventually("recovered queue available", { restored.canRegister })
            try restored.register([query], due: Date())
            await os.clients.last!.deliver(os.uploads.last!, body: Data("invalid JSON".utf8))
            try self.check(consumed == 1 && !restored.hasAttempt && restored.retryAt != nil,
                "Bad JSON must clear only its attempt into durable retry and never become ASR")
        }
        await run("native_query_response_state_failure_cannot_replay_uncommitted_metadata") { f in
            let source = try f.addRecording(0), payload = self.payload("native-response-state")
            let scope = self.transcriptScope(payload), query = self.transcriptQuery(source, scope: scope)
            let os = NativeQueryOS(), directory = f.root.appendingPathComponent("response-state")
            var consumed = 0
            let queue = try ReceiverTranscriptBackgroundQueue(credentials: .init(scope: scope, token: payload.token),
                directory: directory, gate: .init(isForeground: { true }, eventTracker: .init()), enabled: true,
                factory: { os.make($0, $1, $2, $3) }, diagnostic: { _, _ in }, retry: { _ in },
                consume: { _, _ in consumed += 1; return 0 }, changed: {})
            defer { queue.retire() }
            try await self.eventually("registered response authority before state fault", { queue.canRegister })
            try queue.register([query], due: Date())
            let stateURL = directory.appendingPathComponent("native-query-state.json"), original = try Data(contentsOf: stateURL)
            try FileManager.default.removeItem(at: stateURL)
            try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: false)
            await os.clients[0].deliver(os.uploads[0], body: try transcriptResponse([query], scope: scope))
            try self.check(consumed == 0 && queue.hasAttempt, "Failed state persistence cannot authorize its newly written response file")
            try FileManager.default.removeItem(at: stateURL)
            try ReceiverTranscriptPrivateFiles.write(original, to: stateURL)
            queue.setEnabled(true)
            try await self.settle()
            try self.check(consumed == 0 && queue.hasAttempt,
                "Re-enabling after repair must not replay response metadata that was never durable")
        }
        await run("native_query_response_persist_failure_cannot_commit_memory_body") { f in
            let source = try f.addRecording(0), payload = self.payload("native-response-fsync")
            let scope = self.transcriptScope(payload), query = self.transcriptQuery(source, scope: scope)
            let os = NativeQueryOS(), directory = f.root.appendingPathComponent("response-persist")
            var consumed = 0
            let queue = try ReceiverTranscriptBackgroundQueue(credentials: .init(scope: scope, token: payload.token),
                directory: directory, gate: .init(isForeground: { true }, eventTracker: .init()), enabled: true,
                factory: { os.make($0, $1, $2, $3) }, diagnostic: { _, _ in }, retry: { _ in },
                consume: { _, _ in consumed += 1; return 1 }, changed: {})
            defer { queue.retire() }
            try await self.eventually("query before response persistence fault", { queue.canRegister })
            try queue.register([query], due: Date())
            let upload = os.uploads[0]
            let blocked = directory.appendingPathComponent(upload.nonce.uuidString.lowercased() + ".response.json")
            try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
            await os.clients[0].deliver(upload, body: try transcriptResponse([query], scope: scope))
            try self.check(consumed == 0 && !queue.hasAttempt && queue.retryAt != nil,
                "Failure to durably store a response must never fall back to committing its in-memory body")
            var isDirectory: ObjCBool = false
            try self.check(FileManager.default.fileExists(atPath: blocked.path, isDirectory: &isDirectory) && isDirectory.boolValue,
                "Invalid response path must not be recursively deleted by attempt cleanup")
        }
        await run("native_query_fair_cursor_reaches_ready_tail_after_140_pending") { f in
            let payload = self.payload("native-fairness"), scope = self.transcriptScope(payload)
            let sources = try (0..<141).map { try f.addRecording($0) }
            let queries = sources.map { self.transcriptQuery($0, scope: scope) }
            let os = NativeQueryOS(), gate = BackgroundSessionRestorationGate(isForeground: { true }, eventTracker: .init())
            var saved: [UUID] = []
            let returner = try self.nativeReturner(f, scope: scope, token: payload.token, os: os, gate: gate, saved: { saved.append($0.id) })
            defer { returner.retire() }
            returner.synchronize(queries, enabled: true)
            for round in 0..<36 {
                try await self.eventually("fair native batch \(round)", { os.uploads.count > round })
                let upload = os.uploads[round]
                let request = try TransportCodec.decode(AutomaticReceiverTranscriptClient.Request.self, from: upload.body)
                let batch = request.items.map { item in queries.first { $0.source == item.source }! }
                let statuses = Dictionary(uniqueKeysWithValues: batch.filter { $0.manifest.id != sources.last!.id }.map { ($0.manifest.id, AutomaticReceiverTranscriptStatus.pending) })
                await os.clients.last!.deliver(upload, body: try transcriptResponse(batch, scope: scope, statuses: statuses))
                await os.clients.last!.finish()
            }
            try self.check(saved == [sources.last!.id] && os.uploads.count <= 37,
                "One native task and a persisted rotating cursor must not starve the ready tail behind 140 pending sources")
        }
    }
}

private func transcriptResponse(_ items: [AutomaticReceiverTranscriptQuery], scope: AutomaticDeliveryScope,
                                statuses: [UUID: AutomaticReceiverTranscriptStatus] = [:]) throws -> Data {
    let wire = try items.map { query -> AutomaticReceiverTranscriptClient.ResponseItem in
        let status = statuses[query.manifest.id] ?? .ready
        let bytes = status == .ready ? try TransportCodec.encode(returnedTranscript(query.manifest)) : nil
        return .init(receipt: query.receipt, source: query.source, status: status,
            transcriptJSON: bytes.map { String(decoding: $0, as: UTF8.self) },
            transcriptSHA256: bytes.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() },
            transcriptByteCount: bytes?.count)
    }
    return try TransportCodec.encode(AutomaticReceiverTranscriptClient.Response(schemaVersion: 1, scope: .init(scope), items: wire))
}

private func changeEmbeddedTranscript(_ object: inout [String: Any], _ mutate: (inout [String: Any]) -> Void) {
    var items = object["items"] as! [[String: Any]]
    var transcript = try! JSONSerialization.jsonObject(with: Data((items[0]["transcriptJSON"] as! String).utf8)) as! [String: Any]
    mutate(&transcript)
    let bytes = try! JSONSerialization.data(withJSONObject: transcript, options: [.sortedKeys])
    items[0]["transcriptJSON"] = String(decoding: bytes, as: UTF8.self)
    items[0]["transcriptSHA256"] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    items[0]["transcriptByteCount"] = bytes.count
    object["items"] = items
}

private final class ControlledTranscriptTransport: AutomaticReceiverTranscriptTransport, @unchecked Sendable {
    let scope: AutomaticDeliveryScope
    private let lock = NSLock()
    private var callsValue: [[AutomaticReceiverTranscriptQuery]] = []
    private var statusesValue: [UUID: AutomaticReceiverTranscriptStatus] = [:]
    private var held: CheckedContinuation<Void, Never>?
    private var holdValue = false
    private var released = false
    var hold: Bool {
        get { lock.lock(); defer { lock.unlock() }; return holdValue }
        set { lock.lock(); holdValue = newValue; lock.unlock() }
    }
    init(scope: AutomaticDeliveryScope) { self.scope = scope }
    var calls: [[AutomaticReceiverTranscriptQuery]] { lock.lock(); defer { lock.unlock() }; return callsValue }
    func statuses(_ value: [UUID: AutomaticReceiverTranscriptStatus]) { lock.lock(); statusesValue = value; lock.unlock() }
    func release() { lock.lock(); released = true; let value = held; held = nil; lock.unlock(); value?.resume() }
    func query(_ items: [AutomaticReceiverTranscriptQuery], timeout: TimeInterval) async throws -> [AutomaticReceiverTranscriptResult] {
        let shouldHold = record(items)
        if shouldHold {
            await withCheckedContinuation { continuation in
                lock.lock()
                if released { lock.unlock(); continuation.resume() }
                else { held = continuation; lock.unlock() }
            }
        }
        let statuses = currentStatuses()
        let data = try transcriptResponse(items, scope: scope, statuses: statuses)
        return try AutomaticReceiverTranscriptClient.validate(data, for: items, scope: .init(scope))
    }
    private func record(_ items: [AutomaticReceiverTranscriptQuery]) -> Bool {
        lock.lock(); defer { lock.unlock() }; callsValue.append(items); return holdValue
    }
    private func currentStatuses() -> [UUID: AutomaticReceiverTranscriptStatus] {
        lock.lock(); defer { lock.unlock() }; return statusesValue
    }
}

private final class TranscriptQueryURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply { let url: URL?; let code: Int; let headers: [String: String]; let data: Data }
    private final class Shared: @unchecked Sendable {
        let lock = NSLock()
        var reply: Reply?
        var requests: [URLRequest] = []
        var hold = false
    }
    private static let shared = Shared()
    static func install(_ reply: Reply, hold: Bool = false) {
        shared.lock.lock(); shared.reply = reply; shared.requests = []; shared.hold = hold; shared.lock.unlock()
    }
    static var requests: [URLRequest] { shared.lock.lock(); defer { shared.lock.unlock() }; return shared.requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.shared.lock.lock(); Self.shared.requests.append(request)
        let reply = Self.shared.reply, hold = Self.shared.hold; Self.shared.lock.unlock()
        if hold { return }
        guard let reply, let url = reply.url ?? request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.code, httpVersion: "HTTP/1.1", headerFields: reply.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension Probe {
    private func transcriptScope(_ payload: AutomaticReceiverPairingPayload) -> AutomaticDeliveryScope {
        .init(receiverID: payload.receiverID, pairingID: UUID(), grantEpoch: UUID(), sourceInstallationID: UUID(),
              endpoint: payload.endpoint, certificateSHA256: payload.certificateSHA256)
    }
    private func transcriptQuery(_ source: SegmentManifest, scope: AutomaticDeliveryScope) -> AutomaticReceiverTranscriptQuery {
        .init(receipt: .init(receiverID: scope.receiverID, deliveryID: UUID(), archiveSHA256: String(repeating: "d", count: 64),
            recordingIDs: [source.id], storedAt: Date(timeIntervalSince1970: 1_792_876_029.274)), manifest: source)
    }
    private func httpClient(scope: AutomaticDeliveryScope, token: String) throws -> AutomaticReceiverTranscriptClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [TranscriptQueryURLProtocol.self]
        return try .init(credentials: .init(scope: scope, token: token), configuration: config)
    }
    private func responseMutation(_ bytes: Data, _ mutate: (inout [String: Any]) -> Void) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        mutate(&object)
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    private func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { throw ProbeFailure.failed("Missing encoded request body") }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw ProbeFailure.failed("Cannot read synthetic request body stream") }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= 32 * 1_024 else { throw ProbeFailure.failed("Request body unexpectedly exceeds limit") }
        }
    }
    private func returner(_ f: Fixture, scope: AutomaticDeliveryScope, token: String, repository: TranscriptRepository,
                          transport: ControlledTranscriptTransport,
                          authorized: @escaping (AutomaticReceiverTranscriptQuery) -> Bool = { _ in true },
                          didSave: @escaping (SegmentManifest) -> Void = { _ in }) throws -> PhoneReceiverTranscriptReturn {
        try .init(credentials: .init(scope: scope, token: token), repository: repository,
            stateURL: f.root.appendingPathComponent("return-state.json"), schedulesRetries: false,
            authorized: authorized, didSave: didSave, requestBackgroundRetry: { _ in }, diagnostic: { _, _ in },
            beginExecution: { _ in nil }, clientFactory: { _ in transport })
    }

    func executeTranscriptReturnCases() async {
        await run("background_parent_waits_for_current_transcript_return") { f in
            let source = try f.addRecording(0), payload = self.payload("background-transcript-parent")
            _ = try f.legacy(payload, recordings: [source], paused: false, deliveredFirst: true)
            let repository = try TranscriptRepository(root: f.repository.root)
            var transport: ControlledTranscriptTransport?
            f.start(transcripts: repository, transcriptFactory: { credentials in
                let value = ControlledTranscriptTransport(scope: credentials.scope)
                value.hold = true; transport = value; return value
            })
            defer { transport?.release() }
            try f.discover()
            try await self.eventually("current transcript query is held") { transport?.calls.count == 1 }
            var completed = false
            let preparation = Task { @MainActor in
                let result = await f.store?.prepareBackgroundDelivery()
                completed = true
                return result
            }
            // Yield for the coordinator's detached discovery, then wait only
            // for local upload preparation. The held query must remain live
            // throughout; no timer or remote ASR result can unblock it.
            try await Task.sleep(nanoseconds: 250_000_000)
            await f.store?.waitForPreparation()
            try await self.settle()
            try self.check(!completed, "A BGProcessing parent must not complete while its current transcript reply is still in flight")
            transport?.release()
            let result = await preparation.value
            try self.check(result == true && completed, "The parent must finish once the bounded query commits")
            let saved = try repository.transcript(for: source)
            try self.check(saved?.text == returnedTranscript(source).text
                           && saved?.segmentID == source.id && saved?.audioSHA256 == source.sha256,
                           "The parent must observe the exact source-bound transcript committed before finishing")
            try self.check(f.returnedTranscriptIDs == [source.id], "The committed query must notify Drive exactly once")
        }
        await run("transcript_query_actual_swift_python_swift_canonical_roundtrip") { _ in
            let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
            let request = try TransportCodec.decode(AutomaticReceiverTranscriptClient.Request.self,
                from: Data(contentsOf: fixtures.appendingPathComponent("swift-query-request.json")))
            let manifest = try TransportCodec.decode(SegmentManifest.self,
                from: Data(contentsOf: fixtures.appendingPathComponent("swift-query-manifest.json")))
            try self.check(request.schemaVersion == 1 && request.items.count == 1 && request.items[0].source == .init(manifest),
                           "Actual Swift query fixture must bind its full synthetic source")
            let query = AutomaticReceiverTranscriptQuery(receipt: request.items[0].receipt, manifest: manifest)
            let response = try Data(contentsOf: fixtures.appendingPathComponent("python-query-response.json"))
            let values = try AutomaticReceiverTranscriptClient.validate(response, for: [query], scope: request.scope)
            try self.check(values.count == 1 && values[0].status == .ready && values[0].transcript != nil,
                           "The actual Python endpoint's canonical response must pass the actual Swift validator")
            try self.check(query.receipt.storedAt == Date(timeIntervalSince1970: 1_792_876_029.274),
                           "Cross-language full receipt retains the exact current-scale integer millisecond value")
        }
        await run("transcript_query_actual_wire_receipt_ms_roundtrip_and_hash") { f in
            let source = try f.addRecording(0), payload = self.payload("transcript-wire"), scope = self.transcriptScope(payload)
            let query = self.transcriptQuery(source, scope: scope)
            let good = try transcriptResponse([query], scope: scope)
            TranscriptQueryURLProtocol.install(.init(url: nil, code: 200, headers: ["Content-Type": "application/json"], data: good))
            let values = try await self.httpClient(scope: scope, token: payload.token).query([query], timeout: 10)
            try self.check(values.count == 1 && values[0].transcript == returnedTranscript(source), "Exact validated ASR must return")
            guard let request = TranscriptQueryURLProtocol.requests.first else { throw ProbeFailure.failed("Missing request") }
            try self.check(request.url?.path == "/v1/transcripts/query" && request.httpMethod == "POST", "Only fixed POST query is allowed")
            try self.check(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + payload.token, "Use only this paired bearer")
            let body = try self.requestBody(request)
            try body.write(to: f.root.appendingPathComponent("swift-query-request.json"))
            try TransportCodec.encode(source).write(to: f.root.appendingPathComponent("swift-query-manifest.json"))
            try good.write(to: f.root.appendingPathComponent("synthetic-query-response.json"))
            let decoded = try TransportCodec.decode(AutomaticReceiverTranscriptClient.Request.self, from: body)
            try self.check(decoded.items[0].receipt == query.receipt, "Receipt must round-trip exactly")
            for milliseconds: Int64 in [1_792_876_029_274, 1_792_876_029_001, 1_792_876_029_999] {
                var receiptJSON = try JSONSerialization.jsonObject(with: TransportCodec.encode(query.receipt)) as! [String: Any]
                receiptJSON["storedAt"] = milliseconds
                let receipt = try TransportCodec.decode(AutomaticDeliveryReceipt.self,
                    from: JSONSerialization.data(withJSONObject: receiptJSON))
                let encoded = try TransportCodec.encode(AutomaticReceiverTranscriptClient.Request(schemaVersion: 1,
                    scope: .init(scope), items: [.init(receipt: receipt, source: query.source)]))
                let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
                let items = object["items"] as! [[String: Any]], stored = items[0]["receipt"] as! [String: Any]
                let number = stored["storedAt"] as! NSNumber
                try self.check(number.int64Value == milliseconds && String(cString: number.objCType) != "d",
                               "Date must re-encode as the identical integer millisecond receipt capability")
                try self.check(try TransportCodec.decode(AutomaticReceiverTranscriptClient.Request.self, from: encoded).items[0].receipt == receipt,
                               "Echoed Date equality must remain exact")
            }
        }
        let mutations: [(String, (inout [String: Any]) -> Void)] = [
            ("scope", { var scope = $0["scope"] as! [String: Any]; scope["grantEpoch"] = UUID().uuidString; $0["scope"] = scope }),
            ("receipt", { var items = $0["items"] as! [[String: Any]]; var r = items[0]["receipt"] as! [String: Any]; r["storedAt"] = 1_792_876_029_275; items[0]["receipt"] = r; $0["items"] = items }),
            ("source", { var items = $0["items"] as! [[String: Any]]; var s = items[0]["source"] as! [String: Any]; s["sessionID"] = UUID().uuidString; items[0]["source"] = s; $0["items"] = items }),
            ("hash", { var items = $0["items"] as! [[String: Any]]; items[0]["transcriptSHA256"] = String(repeating: "b", count: 64); $0["items"] = items }),
            ("size", { var items = $0["items"] as! [[String: Any]]; items[0]["transcriptByteCount"] = 1; $0["items"] = items }),
            ("embedded_audio", { changeEmbeddedTranscript(&$0) { $0["audioSHA256"] = String(repeating: "b", count: 64) } }),
            ("empty_ready_text", { changeEmbeddedTranscript(&$0) { $0["text"] = " " } }),
            ("non_ready_body", { var items = $0["items"] as! [[String: Any]]; items[0]["status"] = "no_speech"; $0["items"] = items }),
            ("unknown_status", { var items = $0["items"] as! [[String: Any]]; items[0]["status"] = "done"; $0["items"] = items })
        ]
        for (name, mutation) in mutations {
            await run("transcript_query_rejects_" + name) { f in
                let source = try f.addRecording(0), payload = self.payload("transcript-invalid"), scope = self.transcriptScope(payload)
                let query = self.transcriptQuery(source, scope: scope)
                let bad = try self.responseMutation(transcriptResponse([query], scope: scope), mutation)
                TranscriptQueryURLProtocol.install(.init(url: nil, code: 200, headers: ["Content-Type": "application/json"], data: bad))
                do { _ = try await self.httpClient(scope: scope, token: payload.token).query([query], timeout: 10)
                    throw ProbeFailure.failed("Mismatched ASR response accepted")
                } catch is ProbeFailure { throw ProbeFailure.failed("Mismatched ASR response accepted") }
                catch { try self.check(true, "Invalid response rejected") }
            }
        }
        await run("transcript_query_rejects_wrong_route_http_and_oversized_stream") { f in
            let source = try f.addRecording(0), payload = self.payload("transcript-route"), scope = self.transcriptScope(payload)
            let query = self.transcriptQuery(source, scope: scope), good = try transcriptResponse([query], scope: scope)
            let replies = [
                TranscriptQueryURLProtocol.Reply(url: URL(string: "https://other.invalid:9443/v1/transcripts/query"), code: 200, headers: ["Content-Type": "application/json"], data: good),
                .init(url: nil, code: 403, headers: ["Content-Type": "application/json"], data: good),
                .init(url: nil, code: 200, headers: ["Content-Type": "application/json"], data: Data(repeating: 32, count: 4 * 1_024 * 1_024 + 1))]
            for reply in replies {
                TranscriptQueryURLProtocol.install(reply)
                do { _ = try await self.httpClient(scope: scope, token: payload.token).query([query], timeout: 10)
                    throw ProbeFailure.failed("Unsafe route/body accepted")
                } catch is ProbeFailure { throw ProbeFailure.failed("Unsafe route/body accepted") }
                catch { try self.check(true, "Unsafe route/body rejected") }
            }
        }
        await run("transcript_query_batch_limit_and_redirect_rejection") { f in
            let source = try f.addRecording(0), payload = self.payload("transcript-limit"), scope = self.transcriptScope(payload)
            let query = self.transcriptQuery(source, scope: scope), client = try self.httpClient(scope: scope, token: payload.token)
            TranscriptQueryURLProtocol.install(.init(url: nil, code: 200, headers: [:], data: Data()))
            do { _ = try await client.query([query, query], timeout: 10); throw ProbeFailure.failed("Duplicate query accepted") }
            catch is ProbeFailure { throw ProbeFailure.failed("Duplicate query accepted") } catch {}
            try self.check(TranscriptQueryURLProtocol.requests.isEmpty, "Invalid batch never transmits")
            let session = URLSession(configuration: .ephemeral), url = URL(string: scope.endpoint + "/v1/transcripts/query")!
            let task = session.dataTask(with: url)
            var redirected = true
            client.urlSession(session, task: task,
                willPerformHTTPRedirection: HTTPURLResponse(url: url, statusCode: 307, httpVersion: nil, headerFields: [:])!,
                newRequest: URLRequest(url: URL(string: "https://other.invalid")!)) { redirected = $0 != nil }
            try self.check(!redirected, "Redirect delegate must refuse before forwarding a bearer")
            session.invalidateAndCancel()
        }
        await run("transcript_query_native_task_cancel_stays_cancellation") { f in
            let source = try f.addRecording(0), payload = self.payload("transcript-cancel"), scope = self.transcriptScope(payload)
            let query = self.transcriptQuery(source, scope: scope), client = try self.httpClient(scope: scope, token: payload.token)
            TranscriptQueryURLProtocol.install(.init(url: nil, code: 200, headers: ["Content-Type": "application/json"], data: Data()), hold: true)
            let task = Task { try await client.query([query], timeout: 10) }
            try await self.eventually("real URLSession query has started") { TranscriptQueryURLProtocol.requests.count == 1 }
            task.cancel()
            do { _ = try await task.value; throw ProbeFailure.failed("Cancelled query succeeded") }
            catch is CancellationError { try self.check(true, "URLSession cancellation stays CancellationError") }
        }
        await run("transcript_return_bad_second_item_cannot_commit_first") { f in
            let sources = try (0..<2).map { try f.addRecording($0) }, payload = self.payload("return-batch"), scope = self.transcriptScope(payload)
            let queries = sources.map { self.transcriptQuery($0, scope: scope) }, repository = try TranscriptRepository(root: f.repository.root)
            let bytes = try self.responseMutation(transcriptResponse(queries, scope: scope)) { object in
                var items = object["items"] as! [[String: Any]]
                items[1]["transcriptSHA256"] = String(repeating: "b", count: 64); object["items"] = items
            }
            TranscriptQueryURLProtocol.install(.init(url: nil, code: 200, headers: ["Content-Type": "application/json"], data: bytes))
            let client = try self.httpClient(scope: scope, token: payload.token)
            var saved = 0
            let runner = try PhoneReceiverTranscriptReturn(credentials: .init(scope: scope, token: payload.token), repository: repository,
                stateURL: f.root.appendingPathComponent("return-state.json"), schedulesRetries: false,
                authorized: { _ in true }, didSave: { _ in saved += 1 }, requestBackgroundRetry: { _ in }, diagnostic: { _, _ in },
                beginExecution: { _ in nil }, clientFactory: { _ in client })
            defer { runner.stop() }
            runner.synchronize(queries, enabled: true); await runner.waitForCurrentQuery()
            try self.check(repository.availableTranscripts(for: sources).transcripts.isEmpty && saved == 0,
                           "Complete batch validation must happen before any ASR save")
            try self.check(runner.returnedTranscriptHash(for: queries[0]) == nil, "A failed batch creates no origin/version marker")
        }
        await run("transcript_return_fair_pending_no_speech_and_later_ready") { f in
            let sources = try (0..<8).map { try f.addRecording($0) }, payload = self.payload("return-fair"), scope = self.transcriptScope(payload)
            let queries = sources.map { self.transcriptQuery($0, scope: scope) }, repository = try TranscriptRepository(root: f.repository.root)
            let transport = ControlledTranscriptTransport(scope: scope)
            transport.statuses([sources[0].id: .noSpeech, sources[1].id: .pending, sources[2].id: .retry, sources[3].id: .unavailable])
            let runner = try self.returner(f, scope: scope, token: payload.token, repository: repository, transport: transport)
            defer { runner.stop() }
            runner.synchronize(queries, enabled: true); await runner.waitForCurrentQuery()
            runner.synchronize(queries, enabled: true); await runner.waitForCurrentQuery()
            try self.check(transport.calls.count == 2 && transport.calls.allSatisfy { $0.count <= 4 }, "Two bounded batches must progress")
            try self.check(Set(transport.calls.flatMap { $0.map { $0.manifest.id } }).count == 8, "Pending/no-speech cannot monopolize the first four")
            try self.check(repository.availableTranscripts(for: sources).transcripts.count == 4, "Only legal ready bodies become text")
            try self.check(try repository.transcript(for: sources[0]) == nil, "No-speech is not an empty transcript")
            runner.synchronize(queries, enabled: true); await runner.waitForCurrentQuery()
            try self.check(transport.calls.count == 2, "Saved ready text and not-yet-due statuses do not re-fetch")
        }
        await run("transcript_return_concurrent_local_result_and_durable_origin_marker") { f in
            let source = try f.addRecording(0), payload = self.payload("return-local"), scope = self.transcriptScope(payload)
            let query = self.transcriptQuery(source, scope: scope), repository = try TranscriptRepository(root: f.repository.root)
            let transport = ControlledTranscriptTransport(scope: scope); transport.hold = true
            var saved = 0
            let runner = try self.returner(f, scope: scope, token: payload.token, repository: repository, transport: transport, didSave: { _ in saved += 1 })
            runner.synchronize([query], enabled: true)
            try await self.eventually("query is held") { transport.calls.count == 1 }
            let local = returnedTranscript(source, text: "较新的本机合成文字不能被覆盖。")
            try repository.save(local, for: source)
            transport.release(); await runner.waitForCurrentQuery()
            try self.check(try repository.transcript(for: source) == local && saved == 0, "A concurrent local version wins unchanged")
            let returnedHash = runner.returnedTranscriptHash(for: query)
            try self.check(returnedHash != nil && returnedHash != SHA256.hash(data: try TransportCodec.encode(local)).map { String(format: "%02x", $0) }.joined(),
                           "Suppression binds only the returned version, not a newer local version")
            runner.stop()
            let reopened = try self.returner(f, scope: scope, token: payload.token, repository: repository, transport: transport)
            defer { reopened.stop() }
            try self.check(reopened.returnedTranscriptHash(for: query) == returnedHash, "Origin/version marker survives restart")
            var changed = query.receipt
            changed = .init(receiverID: changed.receiverID, deliveryID: UUID(), archiveSHA256: changed.archiveSHA256,
                recordingIDs: changed.recordingIDs, storedAt: changed.storedAt)
            try self.check(reopened.returnedTranscriptHash(for: .init(receipt: changed, manifest: source)) == nil,
                           "A different receipt cannot inherit suppression")
        }
        await run("transcript_return_140_due_pending_cannot_starve_tail_ready_across_restarts") { f in
            let sources = try (0..<141).map { try f.addRecording($0) }, payload = self.payload("return-tail"), scope = self.transcriptScope(payload)
            let queries = sources.map { self.transcriptQuery($0, scope: scope) }, repository = try TranscriptRepository(root: f.repository.root)
            let transport = ControlledTranscriptTransport(scope: scope)
            transport.statuses(Dictionary(uniqueKeysWithValues: sources.prefix(140).map { ($0.id, .pending) }))
            for _ in 0..<36 {
                let runner = try self.returner(f, scope: scope, token: payload.token, repository: repository, transport: transport)
                runner.synchronize(queries, enabled: true); await runner.waitForCurrentQuery(); runner.stop()
                if try repository.transcript(for: sources[140]) != nil { break }
                // Model every earlier pending item becoming due before the next
                // launch. Only durable rotation prevents repeated head polling.
                let url = f.root.appendingPathComponent("return-state.json")
                var state = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
                var entries = state["entries"] as! [String: [String: Any]]
                for key in entries.keys { entries[key]!["nextQueryAt"] = 1_700_000_000_000 }
                state["entries"] = entries
                try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]).write(to: url, options: .atomic)
            }
            try self.check(try repository.transcript(for: sources[140]) != nil, "A tail ready source must arrive within 36 bounded batches despite 140 due pending sources")
            try self.check(transport.calls.count <= 36 && transport.calls.allSatisfy { $0.count <= 4 }, "Finite bounded progress survives each restart")
        }
        for pause in [false, true] {
            await run(pause ? "transcript_return_pause_cancels_commit" : "transcript_return_changed_authorization_cancels_commit") { f in
                let source = try f.addRecording(0), payload = self.payload("return-fence"), scope = self.transcriptScope(payload)
                let query = self.transcriptQuery(source, scope: scope), repository = try TranscriptRepository(root: f.repository.root)
                let transport = ControlledTranscriptTransport(scope: scope); transport.hold = true
                var allowed = true, saved = 0
                let runner = try self.returner(f, scope: scope, token: payload.token, repository: repository, transport: transport,
                    authorized: { _ in allowed }, didSave: { _ in saved += 1 })
                runner.synchronize([query], enabled: true)
                try await self.eventually("query is held before fence changes") { transport.calls.count == 1 }
                if pause { runner.stop() } else { allowed = false }
                transport.release(); try await self.settle(); await runner.waitForCurrentQuery()
                try self.check(try repository.transcript(for: source) == nil && saved == 0, "Late response cannot cross pause or authorization fence")
                runner.stop()
            }
        }
        await run("transcript_return_actual_worker_origin_no_zip_echo_other_receiver_and_revision") { f in
            let source = try f.addRecording(0), transcripts = try TranscriptRepository(root: f.repository.root)
            var returned: [ControlledTranscriptTransport] = []
            f.start(transcripts: transcripts, transcriptFactory: { credentials in
                let client = ControlledTranscriptTransport(scope: credentials.scope); returned.append(client); return client
            })
            let a = self.payload("return-origin"), b = self.payload("return-other", seed: 2)
            try f.discover(); try self.pair(a, name: "Origin", in: f)
            let (client, upload) = try await self.uploaded(a.receiverID, in: f)
            client.acknowledge(upload, recordingID: source.id)
            try await self.eventually("ASR is atomically saved and forwarded to Drive callback") { f.returnedTranscriptIDs == [source.id] }
            try f.discover(); await f.store?.waitForPreparation(); try await self.settle()
            try self.check(try f.ledger(a.receiverID).jobs.count == 1 && client.uploads.count == 1,
                           "Returned exact ASR must not create an audio ZIP echo to its origin")
            try self.pair(b, name: "Other", in: f)
            _ = try await self.uploaded(b.receiverID, in: f)
            try self.check(try f.ledger(b.receiverID).jobs.first?.transcriptSHA256 != nil,
                           "Another authorized receiver must still receive the returned ASR")
            try transcripts.save(returnedTranscript(source, text: "更新的本机版本仍按原授权发送。"), for: source)
            try f.discover(); await f.store?.waitForPreparation()
            try self.check(try f.ledger(a.receiverID).jobs.count == 2,
                           "A changed local ASR hash must not be suppressed as an origin echo")
            try self.check(returned.first?.calls.count == 1, "Already saved ASR is never queried again")
        }
    }
}
