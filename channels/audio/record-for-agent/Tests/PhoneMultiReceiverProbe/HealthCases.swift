import Foundation
import CryptoKit
import RecordingCore

/// Retains synthetic requests so cancellation and stale completion races can be
/// tested without a URLSession, audio file, transcript query or receiver process.
private final class ControlledHealthCheck: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [CheckedContinuation<AutomaticReceiverProbeResult, Never>] = []
    private var scopes: [AutomaticDeliveryScope] = []
    var count: Int { locked { scopes.count } }
    var requestedScopes: [AutomaticDeliveryScope] { locked { scopes } }
    private func locked<T>(_ action: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return action() }
    func check(_ credentials: AutomaticReceiverCredentials) async -> AutomaticReceiverProbeResult {
        await withCheckedContinuation { continuation in
            locked { scopes.append(credentials.scope); pending.append(continuation) }
        }
    }
    func finish(_ result: AutomaticReceiverProbeResult) {
        let continuation = locked { pending.removeFirst() }
        continuation.resume(returning: result)
    }
}

private final class HealthDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(String, String)] = []
    func record(_ event: String, _ detail: String) { lock.lock(); values.append((event, detail)); lock.unlock() }
    var entries: [(String, String)] { lock.lock(); defer { lock.unlock() }; return values }
}

@MainActor
private extension Fixture {
    func restoredHealthWorker(_ id: UUID, diagnostic: @escaping @Sendable (String, String) -> Void = { _, _ in },
        healthCheck: @escaping AutomaticReceiverHealthCheck = { _ in .reachable },
        healthDate: @escaping @Sendable () -> Date = { Date() }) throws -> PhoneReceiverDeliveryStore {
        let factory = factory
        return PhoneReceiverDeliveryStore(pairing: try pairing(id), repository: repository, transcriptRepository: nil,
            persistEnabled: { _ in }, schedulesRetries: false, diagnostic: diagnostic,
            healthCheck: healthCheck, healthDate: healthDate,
            beginExecution: { _ in nil }, clientFactory: { try factory.make($0, $1, $2) })
    }

    /// Seeds an already prepared archive boundary with inert synthetic bytes.
    /// This isolates transfer status/receipt handling from NSFileCoordinator's
    /// OS archive service. No audio file is created, read, copied or hashed.
    func preparedHealthWorker(_ payload: AutomaticReceiverPairingPayload, interrupted: Bool = false)
        throws -> (PhoneReceiverDeliveryStore, SegmentManifest) {
        let (worker, manifests) = try preparedHealthWorker(payload, sourceCount: 1, interrupted: interrupted)
        return (worker, manifests[0])
    }

    func preparedHealthWorker(_ payload: AutomaticReceiverPairingPayload, sourceCount: Int, interrupted: Bool = false)
        throws -> (PhoneReceiverDeliveryStore, [SegmentManifest]) {
        let manifests = (0..<sourceCount).map { sequence in
            let sourceID = UUID(), start = Date(timeIntervalSince1970: 1_800_000_000 + Double(sequence))
            return SegmentManifest(id: sourceID, sessionID: UUID(), sequence: sequence, startedAt: start,
                endedAt: start.addingTimeInterval(1), sampleRate: 16_000, frameCount: 16_000,
                fileName: sourceID.uuidString.lowercased() + ".caf", byteCount: 100, sha256: String(repeating: "a", count: 64))
        }
        let sourceIDs = Set(manifests.map(\.id))
        let scope = AutomaticDeliveryScope(receiverID: payload.receiverID, pairingID: UUID(), grantEpoch: UUID(),
            sourceInstallationID: try vault.installationID(), endpoint: payload.endpoint,
            certificateSHA256: payload.certificateSHA256)
        let credentials = AutomaticReceiverCredentials(scope: scope, token: payload.token)
        let pairing = AutomaticReceiverStoredPairing(displayName: "Synthetic prepared status", credentials: credentials, enabled: true)
        try PhoneReceiverDeliveryStore.prepareNewGrant(credentials, repository: repository, knownRecordingIDs: sourceIDs)
        let directory = grantDirectory(scope)
        let ledgerURL = directory.appendingPathComponent("ledger.json")
        var ledger = try AutomaticDeliveryLedger.load(from: ledgerURL, expectedScope: scope)
        let deliveryIDs = try ledger.reconcile(manifests: manifests, receivedSegmentIDs: sourceIDs)
        let bytes = Data("synthetic inert prepared archive boundary".utf8)
        let archiveDirectory = directory.appendingPathComponent("archives")
        try FileManager.default.createDirectory(at: archiveDirectory, withIntermediateDirectories: true)
        for deliveryID in deliveryIDs {
            try ledger.beginPreparation(deliveryID: deliveryID)
            let name = deliveryID.uuidString.lowercased() + ".zip"
            try bytes.write(to: archiveDirectory.appendingPathComponent(name))
            try ledger.recordPreparedArchive(deliveryID: deliveryID, relativePath: name,
                sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), byteCount: Int64(bytes.count))
            if interrupted { try ledger.beginUpload(deliveryID: deliveryID) }
        }
        try ledger.persist(to: ledgerURL)
        try vault.saveAll([pairing])
        let worker = try restoredHealthWorker(payload.receiverID)
        worker.discover(manifests: manifests, receivedSegmentIDs: sourceIDs)
        return (worker, manifests)
    }
}

private func samePersistedTime(_ lhs: Date?, _ rhs: Date?) -> Bool {
    guard let lhs, let rhs else { return false }
    return abs(lhs.timeIntervalSince(rhs)) < 0.001
}

@MainActor
private extension Probe {
    /// Unexpected requests must fail an assertion, not leave the probe waiting
    /// forever on a continuation that the no-request branch never completes.
    func expectNoHealthRequest(_ health: ControlledHealthCheck, _ message: String,
        action: @escaping @MainActor () async -> Void) async throws {
        let before = health.count
        var completed = false
        let task = Task { await action(); completed = true }
        try await eventually("Expected no-request action completes or exposes an unexpected request") {
            completed || health.count > before
        }
        if health.count > before { health.finish(.reachable) }
        await task.value
        try check(health.count == before, message)
    }
}

extension Probe {
    func executeHealthCases() async {
        await run("receiver_health_paused_check_is_read_only_and_recovery_is_timestamped") { f in
            let payload = self.payload("health-paused"), health = ControlledHealthCheck(), clock = SyntheticTransferClock()
            let worker = try f.isolatedWorker(payload, healthDate: { clock.now() },
                healthCheck: { await health.check($0) }, beginExecution: { _ in nil })
            defer { worker.retire() }
            worker.setEnabled(false)
            let transportCount = f.factory.all.count
            let saved = try f.pairing(payload.receiverID), ledger = try f.ledger(payload.receiverID)
            try self.check(health.count == 0 && worker.lastProbeAt == nil && !worker.connectionWarning,
                "Restoring saved pairing and a paused setting cannot invent or schedule a live observation")
            let check = Task { await worker.checkConnection() }
            try await self.eventually("Explicit paused check enters its bounded request") { health.count == 1 }
            try self.check(worker.isCheckingConnection && !worker.isEnabled,
                "A read-only connection check remains available without enabling delivery")
            let failureAt = clock.now()
            health.finish(.failed(.dns)); await check.value
            try self.check(worker.lastProbeAt == failureAt && worker.lastProbeFailure == .dns
                && worker.connectionWarning && worker.connectionHint == AutomaticReceiverFailureCategory.dns.hint
                && worker.connectionSummary == "配对已保存 · 连接检查失败",
                "A DNS failure is visible as a dated fixed category and actionable warning")
            try self.check(worker.lastTransferAt == nil && worker.lastReceiptAt == nil,
                "A status request cannot create a transfer result or storage receipt")
            clock.advance(30)
            let recovery = Task { await worker.checkConnection() }
            try await self.eventually("An explicit later check starts exactly one request") { health.count == 2 }
            health.finish(.reachable); await recovery.value
            try self.check(worker.lastProbeAt == clock.now() && worker.lastProbeFailure == nil
                && !worker.connectionWarning && worker.reachabilityTitle == "检查时可连接",
                "Successful recovery is labelled with the check time instead of permanent online status")
            try self.check(!worker.isEnabled && health.requestedScopes.allSatisfy { $0 == saved.credentials.scope }
                && f.factory.all.count == transportCount && f.factory.all.allSatisfy { $0.uploads.isEmpty }
                && f.requestedRetryDates.isEmpty,
                "Read-only probes preserve pause and the exact grant without uploads or recurring retries")
            try self.check(try f.ledger(payload.receiverID).jobs == ledger.jobs
                && f.pairing(payload.receiverID).credentials.scope == saved.credentials.scope,
                "Probes leave the empty metadata ledger and credential scope unchanged")
        }
        await run("receiver_health_concurrent_checks_share_one_request_without_polling") { f in
            let health = ControlledHealthCheck()
            let worker = try f.isolatedWorker(self.payload("health-concurrent"),
                healthCheck: { await health.check($0) }, beginExecution: { _ in nil })
            defer { worker.retire() }
            let transportCount = f.factory.all.count
            let first = Task { await worker.checkConnection() }
            try await self.eventually("First health request is held") { health.count == 1 }
            let second = Task { await worker.checkConnection() }
            await second.value
            try self.check(health.count == 1 && worker.isCheckingConnection && worker.lastProbeAt == nil,
                "Concurrent page and button requests cannot produce duplicate probes or false observations")
            health.finish(.failed(.timeout)); await first.value
            for _ in 0..<10 { _ = worker.connectionSummary; _ = worker.connectionHint }
            try await self.settle()
            try self.check(health.count == 1 && !worker.isCheckingConnection && worker.lastProbeFailure == .timeout,
                "Failure and subsequent status reads cannot arm recurring health polling")
            try self.check(f.factory.all.count == transportCount && f.factory.all.allSatisfy { $0.uploads.isEmpty }
                && f.requestedRetryDates.isEmpty,
                "A failed health-only request never starts audio delivery or a background retry")
        }
        await run("receiver_health_natural_checks_throttle_but_manual_checks_bypass") { f in
            let payload = self.payload("health-throttled"), health = ControlledHealthCheck(), clock = SyntheticTransferClock()
            let worker = try f.isolatedWorker(payload, healthDate: { clock.now() },
                healthCheck: { await health.check($0) }, beginExecution: { _ in nil })
            defer { worker.retire() }
            let first = Task { await worker.checkConnectionIfNeeded() }
            try await self.eventually("First page entry starts its status request") { health.count == 1 }
            await worker.checkConnectionIfNeeded()
            await worker.checkConnection()
            try self.check(health.count == 1 && worker.isCheckingConnection,
                "Natural and manual checks still share an existing in-flight request")
            health.finish(.failed(.timeout)); await first.value
            let failureAt = worker.lastProbeAt
            clock.advance(29)
            try await self.expectNoHealthRequest(health, "A recent failure suppresses a repeated natural check") {
                await worker.checkConnectionIfNeeded()
            }
            try self.check(health.count == 1 && worker.lastProbeAt == failureAt && worker.lastProbeFailure == .timeout,
                "Returning to the page before thirty seconds keeps the same dated result without another request")
            let manual = Task { await worker.checkConnection() }
            try await self.eventually("Explicit button bypasses a recent observation") { health.count == 2 }
            health.finish(.reachable); await manual.value
            try self.check(worker.lastProbeAt == clock.now() && worker.lastProbeFailure == nil,
                "The explicit check records its actual newer result")
            clock.advance(29)
            try await self.expectNoHealthRequest(health, "A recent manual result suppresses a repeated natural check") {
                await worker.checkConnectionIfNeeded()
            }
            try self.check(health.count == 2,
                "The natural interval starts from the latest manual observation")
            clock.advance(1)
            let due = Task { await worker.checkConnectionIfNeeded() }
            try await self.eventually("Natural checks resume at the thirty-second boundary") { health.count == 3 }
            health.finish(.reachable); await due.value
            let restored = try f.restoredHealthWorker(payload.receiverID,
                healthCheck: { await health.check($0) }, healthDate: { clock.now() })
            defer { restored.retire() }
            // Persisted timestamps round to milliseconds. Model the small
            // elapsed restore time instead of freezing just before that value.
            clock.advance(0.001)
            try await self.expectNoHealthRequest(health, "A recent persisted result suppresses a natural check after restore") {
                await restored.checkConnectionIfNeeded()
            }
            try self.check(health.count == 3 && samePersistedTime(restored.lastProbeAt, worker.lastProbeAt)
                && f.factory.all.allSatisfy { $0.uploads.isEmpty } && f.requestedRetryDates.isEmpty,
                "Restoring a recent observation preserves the throttle without upload or recurring polling")
        }
        await run("receiver_health_cancelled_natural_check_still_throttles_page_reentry") { f in
            let health = ControlledHealthCheck(), clock = SyntheticTransferClock()
            let worker = try f.isolatedWorker(self.payload("health-cancelled-page"), healthDate: { clock.now() },
                healthCheck: { await health.check($0) }, beginExecution: { _ in nil })
            defer { worker.retire() }
            let cancelled = Task { await worker.checkConnectionIfNeeded() }
            try await self.eventually("Initial natural check starts") { health.count == 1 }
            cancelled.cancel()
            health.finish(.reachable); await cancelled.value
            try self.check(worker.lastProbeAt == nil && worker.lastProbeFailure == nil && !worker.isCheckingConnection,
                "Leaving the first check does not manufacture a completed observation")
            clock.advance(29)
            try await self.expectNoHealthRequest(health, "Cancellation still suppresses rapid natural reentry") {
                await worker.checkConnectionIfNeeded()
            }
            try self.check(health.count == 1 && worker.lastProbeAt == nil,
                "Rapid page reentry is throttled even when cancellation left no previous observation timestamp")
            clock.advance(1)
            let due = Task { await worker.checkConnectionIfNeeded() }
            try await self.eventually("A canceled page check is eligible again after thirty seconds") { health.count == 2 }
            health.finish(.reachable); await due.value
            try self.check(worker.lastProbeAt == clock.now() && worker.lastProbeFailure == nil
                && f.factory.all.allSatisfy { $0.uploads.isEmpty } && f.requestedRetryDates.isEmpty,
                "The next due page check records an actual observation without background polling or delivery")
        }
        await run("receiver_health_unsupported_probe_is_neutral_and_survives_restore") { f in
            let payload = self.payload("health-old-receiver"), clock = SyntheticTransferClock()
            let worker = try f.isolatedWorker(payload, healthDate: { clock.now() },
                healthCheck: { _ in .unsupportedProbe }, beginExecution: { _ in nil })
            defer { worker.retire() }
            await worker.checkConnection()
            let observedAt = worker.lastProbeAt
            try self.check(worker.isProbeUnsupported && worker.lastProbeFailure == nil
                && !worker.connectionWarning && worker.error == nil
                && worker.connectionSummary == "已连接 · 建议升级电脑接收程序"
                && worker.reachabilityTitle == "已连接 · 建议升级电脑接收程序"
                && worker.connectionHint == AutomaticReceiverFailureCategory.unsupportedProbe.hint,
                "An authenticated old receiver response is a neutral version limitation with upgrade guidance")
            let restored = try f.restoredHealthWorker(payload.receiverID, healthDate: { clock.now() })
            defer { restored.retire() }
            try self.check(restored.isProbeUnsupported && restored.lastProbeFailure == nil
                && samePersistedTime(restored.lastProbeAt, observedAt) && !restored.connectionWarning
                && restored.connectionSummary == worker.connectionSummary
                && restored.reachabilityTitle == worker.reachabilityTitle
                && restored.lastTransferAt == nil && restored.lastReceiptAt == nil,
                "Relaunch preserves the neutral result without manufacturing transfer or receipt evidence")
            let scope = try f.pairing(payload.receiverID).credentials.scope
            let json = try JSONSerialization.jsonObject(with:
                Data(contentsOf: f.grantDirectory(scope).appendingPathComponent("connection-status.json"))) as! [String: Any]
            try self.check(json["probeUnsupported"] as? Bool == true && json["probeFailure"] == nil,
                "Neutral unsupported capability is persisted separately from failure history")
            clock.advance(1)
            await restored.checkConnection()
            try self.check(!restored.isProbeUnsupported && restored.lastProbeFailure == nil
                && restored.reachabilityTitle == "检查时可连接" && !restored.connectionWarning,
                "A supported response clears the obsolete upgrade guidance")
        }
        await run("receiver_health_legacy_unsupported_failure_migrates_to_neutral") { f in
            let payload = self.payload("health-legacy-unsupported")
            let original = try f.isolatedWorker(payload, beginExecution: { _ in nil })
            defer { original.retire() }
            await original.checkConnection()
            let observedAt = original.lastProbeAt, scope = try f.pairing(payload.receiverID).credentials.scope
            let url = f.grantDirectory(scope).appendingPathComponent("connection-status.json")
            var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            json["probeFailure"] = "unsupportedProbe"
            json.removeValue(forKey: "probeUnsupported")
            try JSONSerialization.data(withJSONObject: json).write(to: url)
            let restored = try f.restoredHealthWorker(payload.receiverID, healthCheck: { _ in .failed(.unsupportedProbe) })
            defer { restored.retire() }
            try self.check(restored.isProbeUnsupported && restored.lastProbeFailure == nil
                && samePersistedTime(restored.lastProbeAt, observedAt) && !restored.connectionWarning
                && restored.connectionSummary == "已连接 · 建议升级电脑接收程序",
                "Existing unsupportedProbe failure metadata migrates without a false connection warning")
            await restored.checkConnection()
            json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            try self.check(restored.isProbeUnsupported && restored.lastProbeFailure == nil
                && !restored.connectionWarning && json["probeUnsupported"] as? Bool == true && json["probeFailure"] == nil,
                "Legacy injected responses also normalize and the next save writes neutral capability metadata")
        }
        await run("receiver_health_cancelled_success_preserves_previous_observation") { f in
            let health = ControlledHealthCheck(), clock = SyntheticTransferClock()
            let worker = try f.isolatedWorker(self.payload("health-cancelled"), healthDate: { clock.now() },
                healthCheck: { await health.check($0) }, beginExecution: { _ in nil })
            defer { worker.retire() }
            let first = Task { await worker.checkConnection() }
            try await self.eventually("Initial failure probe starts") { health.count == 1 }
            health.finish(.failed(.cannotConnect)); await first.value
            let previousAt = worker.lastProbeAt
            clock.advance(40)
            let cancelled = Task { await worker.checkConnection() }
            try await self.eventually("Second probe starts before leaving its owner") { health.count == 2 }
            cancelled.cancel()
            health.finish(.reachable); await cancelled.value
            try self.check(worker.lastProbeAt == previousAt && worker.lastProbeFailure == .cannotConnect
                && worker.connectionWarning && !worker.isCheckingConnection,
                "A cancelled page request cannot replace the last observation with its late success")
            let classifiedCancellation = Task { await worker.checkConnection() }
            try await self.eventually("A later explicitly cancelled response starts") { health.count == 3 }
            health.finish(.failed(.cancelled)); await classifiedCancellation.value
            try self.check(worker.lastProbeAt == previousAt && worker.lastProbeFailure == .cannotConnect,
                "Native cancellation is not a new connection failure or successful recovery")
        }
        await run("receiver_health_retired_grant_rejects_late_probe_result") { f in
            let health = ControlledHealthCheck()
            let worker = try f.isolatedWorker(self.payload("health-retired"),
                healthCheck: { await health.check($0) }, beginExecution: { _ in nil })
            let transportCount = f.factory.all.count
            let request = Task { await worker.checkConnection() }
            try await self.eventually("Probe starts before grant retirement") { health.count == 1 }
            worker.retire()
            health.finish(.failed(.networkRestricted)); await request.value
            try self.check(worker.lastProbeAt == nil && worker.lastProbeFailure == nil && !worker.isCheckingConnection,
                "A retired grant ignores a late probe callback instead of restoring status")
            await worker.checkConnection()
            try self.check(health.count == 1 && f.factory.all.count == transportCount,
                "A retired worker cannot run another health request or recreate transport")
        }
        await run("receiver_health_relaunch_restores_exact_grant_observation_without_request") { f in
            let payload = self.payload("health-restored")
            let original = try f.isolatedWorker(payload, healthCheck: { _ in .failed(.dns) }, beginExecution: { _ in nil })
            defer { original.retire() }
            original.setEnabled(false)
            await original.checkConnection()
            let observedAt = original.lastProbeAt, scope = try f.pairing(payload.receiverID).credentials.scope
            let health = ControlledHealthCheck()
            let restored = try f.restoredHealthWorker(payload.receiverID, healthCheck: { await health.check($0) })
            defer { restored.retire() }
            try self.check(samePersistedTime(restored.lastProbeAt, observedAt) && restored.lastProbeFailure == .dns
                && restored.connectionWarning && !restored.isEnabled && health.count == 0
                && f.factory.all.allSatisfy { $0.uploads.isEmpty },
                "Relaunch preserves the last dated failure and pause without starting a status request or upload")
            let data = try Data(contentsOf: f.grantDirectory(scope).appendingPathComponent("connection-status.json"))
            let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            try self.check(Set(json.keys).isSubset(of: ["schemaVersion", "grantEpoch", "probeAt", "probeFailure", "probeUnsupported",
                "transferAt", "transferFailure", "transferDeliveryID"])
                && !String(decoding: data, as: UTF8.self).contains(".invalid")
                && !String(decoding: data, as: UTF8.self).contains("https://"),
                "Persisted connection status is limited to fixed categories, dates and grant/delivery identifiers")
        }
        for foreignGrant in [false, true] {
            await run(foreignGrant ? "receiver_health_foreign_grant_status_is_rejected_and_check_recovers"
                : "receiver_health_corrupt_status_is_rejected_and_check_recovers") { f in
                let payload = self.payload("health-damaged-status")
                let original = try f.isolatedWorker(payload, beginExecution: { _ in nil })
                defer { original.retire() }
                await original.checkConnection()
                let scope = try f.pairing(payload.receiverID).credentials.scope
                let statusURL = f.grantDirectory(scope).appendingPathComponent("connection-status.json")
                if foreignGrant {
                    var json = try JSONSerialization.jsonObject(with: Data(contentsOf: statusURL)) as! [String: Any]
                    json["grantEpoch"] = UUID().uuidString
                    try JSONSerialization.data(withJSONObject: json).write(to: statusURL)
                } else { try Data("synthetic-corrupt-metadata".utf8).write(to: statusURL) }
                let restored = try f.restoredHealthWorker(payload.receiverID)
                defer { restored.retire() }
                let transportCount = f.factory.all.count
                try self.check(restored.lastProbeAt == nil && restored.lastProbeFailure == nil
                    && restored.connectionWarning && restored.error != nil && restored.isPaired,
                    "Invalid or foreign status metadata cannot claim success and must retain pairing with a warning")
                await restored.checkConnection()
                try self.check(restored.lastProbeAt != nil && restored.lastProbeFailure == nil
                    && restored.error == nil && !restored.connectionWarning,
                    "A fresh read-only check replaces damaged status and clears its recoverable warning")
                try self.check(try f.pairing(payload.receiverID).credentials.scope == scope
                    && f.factory.all.count == transportCount && f.factory.all.allSatisfy { $0.uploads.isEmpty },
                    "Status repair does not re-pair, widen authorization or create upload transport")
            }
        }
        await run("receiver_health_success_preserves_persisted_transfer_failure") { f in
            let payload = self.payload("health-transfer-failure")
            let (worker, _) = try f.preparedHealthWorker(payload)
            defer { worker.retire() }
            let (client, upload) = try await self.uploaded(payload.receiverID, in: f)
            client.emit(.init(scope: client.credentials.scope, deliveryID: upload.id, receipt: nil,
                statusCode: nil, message: "synthetic-private-host.local /synthetic/private/path", requiresRepair: false,
                attemptCount: upload.attemptCount, failureCategory: .timeout))
            try await self.eventually("Failure status is durably saved") { worker.lastTransferFailure == .timeout }
            let failureAt = worker.lastTransferAt
            let restored = try f.restoredHealthWorker(payload.receiverID)
            defer { restored.retire() }
            try self.check(samePersistedTime(restored.lastTransferAt, failureAt) && restored.lastTransferFailure == .timeout
                && restored.lastTransferDeliveryID == upload.id,
                "Relaunch restores the same delivery's fixed failure category and actual result time")
            await restored.checkConnection()
            try self.check(restored.lastProbeAt != nil && restored.lastProbeFailure == nil
                && restored.reachabilityTitle == "检查时可连接" && samePersistedTime(restored.lastTransferAt, failureAt)
                && restored.lastTransferFailure == .timeout && restored.connectionWarning
                && restored.connectionSummary == "配对已保存 · 最近传输失败" && restored.lastReceiptAt == nil,
                "A successful status-only check cannot erase failed transfer history or manufacture a storage receipt")
            let scope = client.credentials.scope
            let status = try String(contentsOf: f.grantDirectory(scope).appendingPathComponent("connection-status.json"), encoding: .utf8)
            let ledger = try String(contentsOf: f.grantDirectory(scope).appendingPathComponent("ledger.json"), encoding: .utf8)
            try self.check(!status.contains("synthetic-private-host") && !status.contains("/synthetic/private/path")
                && !ledger.contains("synthetic-private-host") && !ledger.contains("/synthetic/private/path"),
                "Raw transport messages cannot escape into status or durable delivery error records")
        }
        await run("receiver_health_http_200_without_valid_receipt_remains_transfer_failure") { f in
            let payload = self.payload("health-no-receipt")
            let (worker, recording) = try f.preparedHealthWorker(payload)
            defer { worker.retire() }
            let (client, upload) = try await self.uploaded(payload.receiverID, in: f)
            client.emit(.init(scope: client.credentials.scope, deliveryID: upload.id, receipt: nil,
                statusCode: 200, message: nil, requiresRepair: false, attemptCount: upload.attemptCount,
                failureCategory: .invalidResponse))
            try await self.eventually("HTTP success without receipt is rejected") { worker.lastTransferFailure == .invalidResponse }
            try self.check(worker.lastReceiptAt == nil && worker.deliveredCount == 0 && worker.connectionWarning,
                "HTTP 200 alone never marks the transfer or its source as saved")
            let receipt = AutomaticDeliveryReceipt(receiverID: client.credentials.scope.receiverID, deliveryID: upload.id,
                archiveSHA256: upload.sha256, recordingIDs: [UUID()], storedAt: Date())
            client.emit(.init(scope: client.credentials.scope, deliveryID: upload.id, receipt: receipt,
                statusCode: 200, message: nil, requiresRepair: false, attemptCount: upload.attemptCount))
            try await self.eventually("Mismatched source receipt stays blocked") { worker.blockedCount == 1 }
            try self.check(worker.lastTransferFailure == .invalidResponse && worker.lastReceiptAt == nil
                && !worker.deliveredSegmentIDs.contains(recording.id),
                "A receipt for another source cannot repair the original delivery's failure")
            client.acknowledge(upload, recordingID: recording.id)
            try await self.eventually("The exact late receipt alone repairs the same delivery") {
                worker.lastTransferFailure == nil && worker.deliveredSegmentIDs.contains(recording.id)
            }
            try self.check(worker.lastTransferDeliveryID == upload.id && !worker.connectionWarning,
                "Only the original delivery's validated receipt clears its transfer failure")
        }
        await run("receiver_health_repair_reason_survives_other_receipt_and_restore") { f in
            let payload = self.payload("health-repair-required")
            let (worker, recordings) = try f.preparedHealthWorker(payload, sourceCount: 2)
            defer { worker.retire() }
            let (client, blockedUpload) = try await self.uploaded(payload.receiverID, in: f)
            let blockedJob = try f.ledger(payload.receiverID).job(for: blockedUpload.id)!
            let reason = AutomaticReceiverFailureCategory.pairingRepairRequired.title + "。"
                + AutomaticReceiverFailureCategory.pairingRepairRequired.hint
            client.emit(.init(scope: client.credentials.scope, deliveryID: blockedUpload.id, receipt: nil,
                statusCode: 200, message: "synthetic-private-host.local /synthetic/private/path", requiresRepair: true,
                attemptCount: blockedUpload.attemptCount, failureCategory: .invalidResponse))
            try await self.eventually("Repair result blocks the original delivery with explicit guidance") {
                worker.blockedCount == 1 && worker.lastTransferFailure == .pairingRepairRequired
            }
            try self.check(worker.error == reason && worker.blockedReason == reason && worker.connectionWarning,
                "A requiresRepair result cannot degrade into a generic response error or ordinary retry advice")
            try await self.eventually("Another authorized queued delivery can finish independently") { client.uploads.count == 2 }
            let otherUpload = client.uploads.last!
            let otherJob = try f.ledger(payload.receiverID).job(for: otherUpload.id)!
            try self.check(otherUpload.id != blockedUpload.id && otherJob.manifest.id != blockedJob.manifest.id,
                "The following success belongs to another delivery and source")
            client.acknowledge(otherUpload, recordingID: otherJob.manifest.id)
            try await self.eventually("Other delivery receipt is durably accepted") {
                worker.deliveredCount == 1 && worker.lastTransferFailure == nil
            }
            try self.check(worker.blockedCount == 1 && worker.blockedReason == reason && worker.error == reason
                && worker.connectionWarning && worker.lastTransferDeliveryID == otherUpload.id,
                "The latest success cannot erase the outstanding blocked delivery's recovery reason")
            worker.retire()
            let restored = try f.restoredHealthWorker(payload.receiverID)
            defer { restored.retire() }
            try self.check(restored.blockedCount == 1 && restored.blockedReason == reason && restored.connectionWarning
                && restored.lastTransferFailure == nil && restored.lastTransferDeliveryID == otherUpload.id,
                "Restoration recovers blocked guidance independently of the latest successful transfer summary")
            let restoredClient = f.factory.clients(for: payload.receiverID).last!
            restoredClient.acknowledge(blockedUpload, recordingID: blockedJob.manifest.id)
            try await self.eventually("The original valid late receipt resolves the final blocked job") {
                restored.blockedCount == 0 && restored.deliveredCount == recordings.count
            }
            try self.check(restored.blockedReason == nil && restored.error == nil && !restored.connectionWarning
                && restored.lastTransferDeliveryID == blockedUpload.id && restored.lastTransferFailure == nil,
                "Guidance clears only after all blocked deliveries receive their own valid receipt")
            let ledger = try String(contentsOf: f.grantDirectory(client.credentials.scope).appendingPathComponent("ledger.json"), encoding: .utf8)
            try self.check(!ledger.contains("synthetic-private-host") && !ledger.contains("/synthetic/private/path"),
                "Repair guidance is fixed vocabulary rather than the receiver's raw payload")
        }
        for (label, localError) in [("invalid_archive", AutomaticReceiverError.invalidArchive),
                                   ("state_unavailable", AutomaticReceiverError.localStateUnavailable)] {
            await run("receiver_health_synchronous_local_" + label + "_retains_accurate_error") { f in
                let payload = self.payload("health-local-upload-error")
                f.factory = ControlledFactory(uploadError: localError)
                let (worker, recording) = try f.preparedHealthWorker(payload)
                defer { worker.retire() }
                try await self.eventually("Local upload registration failure retains its own recovery category") {
                    worker.lastTransferFailure == .localState
                }
                let job = try f.ledger(payload.receiverID).jobs[0]
                try self.check(worker.error == localError.localizedDescription
                    && worker.lastTransferDeliveryID == job.id && worker.lastTransferAt != nil
                    && job.state == .retryWaiting && job.attemptCount == 1 && worker.connectionWarning,
                    "A local registration error retains its specific prompt and original delivery identity")
                try self.check(job.lastError == AutomaticReceiverFailureCategory.localState.title + "。"
                    + AutomaticReceiverFailureCategory.localState.hint
                    && worker.connectionHint == AutomaticReceiverFailureCategory.localState.hint
                    && f.factory.all.allSatisfy { $0.uploads.isEmpty } && worker.lastReceiptAt == nil,
                    "A local file/state failure cannot claim network failure, native upload or successful storage")
                let client = f.factory.clients(for: payload.receiverID).last!
                let receipt = AutomaticDeliveryReceipt(receiverID: payload.receiverID, deliveryID: job.id,
                    archiveSHA256: job.archive!.sha256, recordingIDs: [recording.id], storedAt: Date())
                client.emit(.init(scope: client.credentials.scope, deliveryID: job.id, receipt: receipt,
                    statusCode: 200, message: nil, requiresRepair: false, attemptCount: job.attemptCount))
                try await self.eventually("The original local registration failure receives a valid storage receipt") {
                    worker.lastTransferFailure == nil && worker.lastReceiptAt != nil
                }
                try self.check(worker.error == nil && !worker.connectionWarning,
                    "The exact delivery's receipt clears its local failure prompt without leaving a sticky warning")
            }
        }
        await run("receiver_health_local_error_is_cleared_only_by_its_own_receipt") { f in
            let payload = self.payload("health-local-error-owner"), localError = AutomaticReceiverError.invalidArchive
            f.factory = ControlledFactory(uploadError: localError)
            let (worker, _) = try f.preparedHealthWorker(payload, sourceCount: 2)
            defer { worker.retire() }
            try await self.eventually("First local registration attempt has failed") { worker.lastTransferFailure == .localState }
            await worker.waitForPreparation()
            // Retry timers are disabled in this fixture. A fresh action gives
            // the still-queued second delivery its own registration attempt.
            worker.resume()
            try await self.eventually("Both local registration attempts fail independently") {
                try f.ledger(payload.receiverID).jobs.allSatisfy { $0.state == .retryWaiting && $0.attemptCount == 1 }
            }
            let jobs = try f.ledger(payload.receiverID).jobs
            let latest = jobs.first { $0.id == worker.lastTransferDeliveryID }!
            let other = jobs.first { $0.id != latest.id }!
            let client = f.factory.clients(for: payload.receiverID).last!
            let otherReceipt = AutomaticDeliveryReceipt(receiverID: payload.receiverID, deliveryID: other.id,
                archiveSHA256: other.archive!.sha256, recordingIDs: [other.manifest.id], storedAt: Date())
            client.emit(.init(scope: client.credentials.scope, deliveryID: other.id, receipt: otherReceipt,
                statusCode: 200, message: nil, requiresRepair: false, attemptCount: other.attemptCount))
            try await self.eventually("An unrelated delivery's valid receipt is accepted") { worker.deliveredCount == 1 }
            try self.check(worker.error == localError.localizedDescription && worker.connectionWarning,
                "Identical local error text does not let another delivery's success erase the pending error owner")
            let matchingReceipt = AutomaticDeliveryReceipt(receiverID: payload.receiverID, deliveryID: latest.id,
                archiveSHA256: latest.archive!.sha256, recordingIDs: [latest.manifest.id], storedAt: Date())
            client.emit(.init(scope: client.credentials.scope, deliveryID: latest.id, receipt: matchingReceipt,
                statusCode: 200, message: nil, requiresRepair: false, attemptCount: latest.attemptCount))
            try await self.eventually("The local error owner's valid receipt is accepted") { worker.deliveredCount == 2 }
            try self.check(worker.error == nil && !worker.connectionWarning && worker.lastTransferFailure == nil,
                "The pending local error clears when its own delivery is durably confirmed")
        }
        await run("receiver_health_missing_ledger_binding_preserves_dated_summary") { f in
            let payload = self.payload("health-orphan-summary"), diagnostics = HealthDiagnostics()
            let original = try f.isolatedWorker(payload, beginExecution: { _ in nil })
            defer { original.retire() }
            await original.checkConnection()
            let scope = try f.pairing(payload.receiverID).credentials.scope
            let url = f.grantDirectory(scope).appendingPathComponent("connection-status.json")
            var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            let missingDeliveryID = UUID()
            json["transferAt"] = json["probeAt"]
            json["transferFailure"] = "timeout"
            json["transferDeliveryID"] = missingDeliveryID.uuidString
            try JSONSerialization.data(withJSONObject: json).write(to: url)
            let restored = try f.restoredHealthWorker(payload.receiverID, diagnostic: { diagnostics.record($0, $1) })
            defer { restored.retire() }
            try self.check(samePersistedTime(restored.lastTransferAt, original.lastProbeAt)
                && restored.lastTransferFailure == .timeout && restored.lastTransferDeliveryID == nil
                && restored.lastTransferTitle == "失败 · 连接电脑超时" && restored.connectionWarning
                && restored.connectionSummary == "配对已保存 · 最近传输失败" && restored.error == nil,
                "Missing ledger binding preserves dated result history while dropping only the unverified delivery identity")
            let bindingDiagnostics = diagnostics.entries.filter { $0.0 == "phone.receiver_transfer_binding_missing" }
            try self.check(bindingDiagnostics.count == 1 && bindingDiagnostics[0].1 == "category=timeout",
                "Missing-binding diagnostics contain only a fixed category, never the history payload or delivery identifier")
            await restored.checkConnection()
            json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            try self.check(json["transferDeliveryID"] == nil && json["transferAt"] != nil
                && json["transferFailure"] as? String == "timeout",
                "The next unrelated status save preserves the timestamp and failure without reintroducing the missing binding")
            let roundTrip = try f.restoredHealthWorker(payload.receiverID, diagnostic: { diagnostics.record($0, $1) })
            defer { roundTrip.retire() }
            try self.check(samePersistedTime(roundTrip.lastTransferAt, restored.lastTransferAt)
                && roundTrip.lastTransferFailure == .timeout && roundTrip.lastTransferDeliveryID == nil
                && roundTrip.connectionSummary == restored.connectionSummary
                && diagnostics.entries.filter { $0.0 == "phone.receiver_transfer_binding_missing" }.count == 1
                && f.factory.all.allSatisfy { $0.uploads.isEmpty },
                "A second restoration retains the unbound summary without repeat diagnostics or any upload")
        }
        await run("receiver_health_synchronous_upload_error_records_safe_transfer_failure") { f in
            let payload = self.payload("health-upload-registration-failure")
            f.factory = ControlledFactory(uploadErrorCode: NSURLErrorCannotConnectToHost)
            let (worker, recording) = try f.preparedHealthWorker(payload)
            defer { worker.retire() }
            try await self.eventually("Synchronous transport registration failure is projected") {
                worker.lastTransferFailure == .cannotConnect
            }
            let job = try f.ledger(payload.receiverID).jobs[0]
            try self.check(worker.lastTransferDeliveryID == job.id && worker.lastTransferAt != nil
                && job.state == .retryWaiting && job.attemptCount == 1 && worker.connectionWarning,
                "A synchronous sender failure retains its actual failed delivery and retry eligibility")
            try self.check(f.factory.all.allSatisfy { $0.uploads.isEmpty } && worker.lastReceiptAt == nil,
                "No native upload or receipt may be invented after failed registration")
            try self.check(!(job.lastError ?? "").contains("synthetic-private-host")
                && !(job.lastError ?? "").contains("/synthetic/private/path"),
                "Synchronous URL errors retain only fixed categories and safe recovery guidance")
            let client = f.factory.clients(for: payload.receiverID).last!
            let receipt = AutomaticDeliveryReceipt(receiverID: payload.receiverID, deliveryID: job.id,
                archiveSHA256: job.archive!.sha256, recordingIDs: [recording.id], storedAt: Date())
            client.emit(.init(scope: client.credentials.scope, deliveryID: job.id, receipt: receipt,
                statusCode: 200, message: nil, requiresRepair: false, attemptCount: job.attemptCount))
            try await self.eventually("A validated receipt clears the same registration failure") {
                worker.lastTransferFailure == nil && worker.lastReceiptAt != nil
            }
            try self.check(!worker.connectionWarning && worker.error == nil,
                "A successful original receipt cannot leave a sticky generic registration error behind")
        }
        await run("receiver_health_interrupted_transfer_keeps_failure_time_during_same_id_retry") { f in
            let payload = self.payload("health-interrupted-retry")
            let (worker, recording) = try f.preparedHealthWorker(payload, interrupted: true)
            defer { worker.retire() }
            try await self.eventually("Vanished native task records interrupted transfer") {
                worker.lastTransferFailure == .unknown
            }
            let failed = try f.ledger(payload.receiverID).jobs[0]
            let failureAt = worker.lastTransferAt
            guard let due = failed.nextAttemptAt else { throw ProbeFailure.failed("Interrupted task has no durable retry date") }
            try self.check(failed.state == .retryWaiting && failed.attemptCount == 1
                && worker.lastTransferDeliveryID == failed.id && failureAt != nil && worker.connectionWarning,
                "A vanished native task cannot leave an old success visible or lose its original delivery identity")
            worker.resume(); await worker.waitForPreparation()
            try self.check(f.factory.all.allSatisfy { $0.uploads.isEmpty },
                "Status recovery and a manual resume cannot bypass the original durable backoff")
            while due.timeIntervalSinceNow > 0 {
                try await Task.sleep(nanoseconds: UInt64(max(0.001, min(due.timeIntervalSinceNow + 0.002, 0.2)) * 1_000_000_000))
            }
            worker.resume()
            let (client, retry) = try await self.uploaded(payload.receiverID, in: f)
            try self.check(retry.id == failed.id && retry.attemptCount == 2
                && worker.lastTransferAt == failureAt && worker.lastTransferFailure == .unknown
                && worker.uploadingCount == 1 && worker.connectionWarning
                && worker.connectionSummary == "配对已保存 · 最近传输失败",
                "The same-ID retry preserves the dated failure warning until storage is actually confirmed")
            client.emit(.init(scope: client.credentials.scope, deliveryID: retry.id, receipt: nil,
                statusCode: 401, message: "synthetic obsolete failure", requiresRepair: true,
                attemptCount: 1, failureCategory: .unauthorized))
            try await self.settle()
            try self.check(worker.lastTransferAt == failureAt && worker.lastTransferFailure == .unknown
                && worker.uploadingCount == 1,
                "An older attempt's late failure cannot overwrite or block the active retry")
            client.acknowledge(retry, recordingID: recording.id)
            try await self.eventually("Exact receipt repairs the original interrupted delivery") {
                worker.lastTransferFailure == nil && worker.deliveredSegmentIDs == [recording.id]
            }
            try self.check(worker.lastTransferDeliveryID == failed.id && !worker.connectionWarning
                && worker.lastProbeAt == nil && worker.reachabilityTitle == "当前可达性未确认",
                "Validated receipt recovery is distinct from a live connection observation")
        }
    }
}
