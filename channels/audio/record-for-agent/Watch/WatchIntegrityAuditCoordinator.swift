import CryptoKit
import CoreFoundation
import Darwin
import Foundation
import RecordingCore

/// Developer maintenance mailbox. It never changes the recording repository or
/// uses the audio transfer queue. All outputs live beside the recording root.
struct WatchIntegrityAuditRequest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let requestID: String
    let mode: RecordingIntegrityMode
    let expectedBaselineID: String?

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 16_384,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: ["schemaVersion", "requestID", "mode", "expectedBaselineID"]),
              let version = object["schemaVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              let id = object["requestID"] as? String,
              UUID(uuidString: id)?.uuidString.lowercased() == id,
              let modeString = object["mode"] as? String,
              let mode = RecordingIntegrityMode(rawValue: modeString) else { throw RequestError.invalidRequest }
        let baseline: String?
        if let value = object["expectedBaselineID"], !(value is NSNull) {
            guard let digest = value as? String, isDigest(digest) else { throw RequestError.invalidRequest }
            baseline = digest
        } else { baseline = nil }
        return .init(schemaVersion: 1, requestID: id, mode: mode, expectedBaselineID: baseline)
    }

    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    enum RequestError: Error { case invalidRequest }
}

struct WatchIntegrityAuditEnvelope: Codable, Sendable {
    let schemaVersion: Int
    let requestID: String
    let mode: RecordingIntegrityMode
    let status: String
    let appBundleID: String
    let appBuild: String
    let generatedAtUnixMS: Int64
    let criticalSettings: [String: String]
    let audit: RecordingIntegrityReport?
    let baselineID: String?
    let usedBaselineID: String?
    let errorCode: String?
}

final class WatchIntegrityAuditCoordinator: @unchecked Sendable {
    typealias AuditOperation = (RecordingIntegrityMode, String, RecordingIntegrityBaseline?,
        RecordingIntegrityCheckpoint?, () -> Bool,
        @escaping (RecordingIntegrityCheckpoint) -> Void) throws -> RecordingIntegrityReport

    var onMessage: (@Sendable (String) -> Void)?
    let outputRoot: URL
    private let sourceRoot: URL
    private let bundleID: String
    private let appBuild: String
    private let batchSeconds: TimeInterval
    private let auditOperation: AuditOperation
    private let work = DispatchQueue(label: "WristRecord.integrity-audit", qos: .utility)
    private let lock = NSLock()
    private var availability = Availability()
    private var cancellationRevision: UInt64 = 0
    private var pollQueued = false
    private var malformedRequestDigest: String?

    private struct Availability {
        var foreground = false
        var ready = false
        var captureActive = true
        var settings: [String: String] = [:]
        var allowsAudit: Bool { foreground && ready && !captureActive }
    }
    private struct BaselinePointer: Codable { let baselineID: String }
    private enum StorageError: Error { case invalidFile, baselineMismatch, persistenceFailed }

    init(sourceRoot: URL, outputRoot: URL? = nil,
         bundleID: String = Bundle.main.bundleIdentifier ?? "unknown",
         appBuild: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
         batchSeconds: TimeInterval = 20, auditOperation: AuditOperation? = nil) {
        self.sourceRoot = sourceRoot
        self.outputRoot = outputRoot ?? sourceRoot.deletingLastPathComponent()
            .appendingPathComponent("WristRecordIntegrity", isDirectory: true)
        self.bundleID = bundleID
        self.appBuild = appBuild
        self.batchSeconds = max(0.01, min(batchSeconds, 60))
        self.auditOperation = auditOperation ?? { mode, nonce, baseline, checkpoint, continuation, progress in
            let generation = try RecordingIntegrityAuditor.libraryGeneration(at: sourceRoot)
            return try RecordingIntegrityAuditor(root: sourceRoot, libraryGeneration: generation)
                .audit(mode: mode, nonce: nonce, baseline: baseline, checkpoint: checkpoint,
                       checkpointInterval: 1, while: continuation, onCheckpoint: progress)
        }
        work.async { [self] in try? prepareOutputDirectories() }
    }

    /// Synchronous cancellation latch: starting audio never waits for hashing.
    /// Re-entering the foreground cannot revive a chunk that was cancelled.
    func setAvailability(foreground: Bool, ready: Bool, captureActive: Bool,
                         criticalSettings: [String: String]) {
        lock.lock()
        if !foreground || !ready || captureActive || availability.settings != criticalSettings {
            cancellationRevision &+= 1
        }
        availability = .init(foreground: foreground, ready: ready,
                             captureActive: captureActive, settings: criticalSettings)
        lock.unlock()
    }

    /// Called by a small foreground timer. A running hash never builds a queue
    /// of repeated polls. An incomplete request continues with the same nonce.
    func pollMailbox() {
        lock.lock()
        guard !pollQueued else { lock.unlock(); return }
        pollQueued = true
        lock.unlock()
        work.async { [self] in
            defer { lock.lock(); pollQueued = false; lock.unlock() }
            do {
                try prepareOutputDirectories()
                let path = outputRoot.appendingPathComponent("request.json")
                guard FileManager.default.fileExists(atPath: path.path) else { return }
                let data = try readRegular(path, limit: 16_384)
                let request = try WatchIntegrityAuditRequest.decode(data)
                try process(request)
            } catch {
                // Malformed requests have no safe filename/nonce to report to.
                // They never choose a path, baseline, or source operation.
                let data = (try? readRegular(outputRoot.appendingPathComponent("request.json"), limit: 16_384)) ?? Data()
                let digest = Self.digest(data)
                if malformedRequestDigest != digest {
                    malformedRequestDigest = digest
                    onMessage?("校验请求无效，请重新发起检查。")
                }
            }
        }
    }

    func acceptLaunchArguments(_ arguments: [String]) {
        let flag = "--recording-integrity-request"
        let locations = arguments.indices.filter { arguments[$0] == flag }
        guard locations.count == 1, let index = locations.first,
              index + 1 < arguments.count, arguments[index + 1].utf8.count <= 24_000,
              let data = Data(base64Encoded: arguments[index + 1]),
              let request = try? WatchIntegrityAuditRequest.decode(data) else { return }
        enqueue(request)
    }

    /// The normal product UI uses the same mailbox protocol. Its last completed
    /// baseline is selected explicitly, rather than implicitly by the auditor.
    func requestFromDiagnostics(mode: RecordingIntegrityMode) {
        work.async { [self] in
            let pointerURL = outputRoot.appendingPathComponent("current-baseline.json")
            let pointer = (try? readRegular(pointerURL, limit: 4_096))
                .flatMap { try? TransportCodec.decode(BaselinePointer.self, from: $0) }
            let request = WatchIntegrityAuditRequest(schemaVersion: 1,
                requestID: UUID().uuidString.lowercased(), mode: mode,
                expectedBaselineID: pointer?.baselineID)
            do {
                try prepareOutputDirectories()
                try write(TransportCodec.encode(request), to: outputRoot.appendingPathComponent("request.json"))
                try process(request)
            } catch { onMessage?("无法保存校验报告；原录音未改动。") }
        }
    }

    private func enqueue(_ request: WatchIntegrityAuditRequest) {
        work.async { [self] in
            do {
                try prepareOutputDirectories()
                try write(TransportCodec.encode(request), to: outputRoot.appendingPathComponent("request.json"))
                try process(request)
            } catch { onMessage?("无法保存校验报告；原录音未改动。") }
        }
    }

    private func process(_ request: WatchIntegrityAuditRequest) throws {
        try prepareOutputDirectories()
        let reportURL = outputRoot.appendingPathComponent("reports/\(request.requestID).json")
        if FileManager.default.fileExists(atPath: reportURL.path) {
            let old = try TransportCodec.decode(WatchIntegrityAuditEnvelope.self,
                from: readRegular(reportURL, limit: 32 * 1_048_576))
            guard old.requestID == request.requestID, old.mode == request.mode else {
                throw StorageError.invalidFile
            }
            // A nonce names one immutable request, even across app relaunches.
            let bindingURL = outputRoot.appendingPathComponent("requests/\(request.requestID).json")
            guard try WatchIntegrityAuditRequest.decode(readRegular(bindingURL, limit: 16_384)) == request else {
                throw StorageError.invalidFile
            }
            if old.status == "complete" || old.status == "failed" { return }
        }
        let bindingURL = outputRoot.appendingPathComponent("requests/\(request.requestID).json")
        if FileManager.default.fileExists(atPath: bindingURL.path) {
            guard try WatchIntegrityAuditRequest.decode(readRegular(bindingURL, limit: 16_384)) == request else {
                throw StorageError.invalidFile
            }
        } else { try write(TransportCodec.encode(request), to: bindingURL) }

        let initial = state()
        guard initial.value.allowsAudit else {
            // Repeated foreground polls do not rewrite an unchanged deferral.
            if !FileManager.default.fileExists(atPath: reportURL.path) {
                try saveEnvelope(request, status: "deferred", settings: initial.value.settings,
                    audit: nil, baselineID: nil,
                    errorCode: initial.value.captureActive ? "capture_active" : "awaiting_foreground_ready")
                onMessage?("校验已等待；暂停录音并打开 App 后会继续。")
            }
            return
        }

        do {
            let baseline: RecordingIntegrityBaseline?
            if let id = request.expectedBaselineID {
                let data = try readRegular(outputRoot.appendingPathComponent("baselines/\(id).json"), limit: 32 * 1_048_576)
                guard Self.digest(data) == id else { throw StorageError.baselineMismatch }
                baseline = try TransportCodec.decode(RecordingIntegrityBaseline.self, from: data)
            } else { baseline = nil }
            let checkpointURL = outputRoot.appendingPathComponent("checkpoints/\(request.requestID).json")
            let checkpoint: RecordingIntegrityCheckpoint?
            if FileManager.default.fileExists(atPath: checkpointURL.path) {
                checkpoint = try TransportCodec.decode(RecordingIntegrityCheckpoint.self,
                    from: readRegular(checkpointURL, limit: 32 * 1_048_576))
            } else { checkpoint = nil }
            let started = ProcessInfo.processInfo.systemUptime
            var persistenceFailed = false
            var lastCheckpointWrite = -Double.infinity
            onMessage?(request.mode == .full ? "正在手表上完整校验录音…" : "正在检查录音保存情况…")
            let report = try auditOperation(request.mode, request.requestID, baseline, checkpoint, { [self] in
                let current = state()
                return !persistenceFailed && current.revision == initial.revision
                    && current.value.allowsAudit
                    && ProcessInfo.processInfo.systemUptime - started < batchSeconds
            }, { [self] progress in
                // A process killed between checkpoints may reread a few files;
                // it cannot turn unread bytes into a successful observation.
                let now = ProcessInfo.processInfo.systemUptime
                guard now - lastCheckpointWrite >= 1 else { return }
                do {
                    try write(TransportCodec.encode(progress), to: checkpointURL)
                    lastCheckpointWrite = now
                } catch { persistenceFailed = true }
            })
            guard report.nonce == request.requestID, report.mode == request.mode else { throw StorageError.invalidFile }
            guard !persistenceFailed else { throw StorageError.persistenceFailed }
            try write(TransportCodec.encode(report.checkpoint), to: checkpointURL)
            // Main-actor capture/settings changes can race the final hash return.
            // Never promote that observation to the current baseline. No source
            // lock or disk write is allowed to delay the microphone controls.
            let stateUnchanged = availabilityMatches(initial)
            var baselineID: String?
            if stateUnchanged, report.isComplete, report.passed, let next = report.nextBaseline {
                let data = try TransportCodec.encode(next)
                let id = Self.digest(data)
                try write(data, to: outputRoot.appendingPathComponent("baselines/\(id).json"))
                baselineID = id
            }
            // Only a budget/capture interruption can automatically continue.
            // A changed catalog, invalid source or expired window stays failed.
            let nonInterruptionIssue = report.issues.contains { $0.code != "interrupted" }
            var status = report.isComplete && report.passed ? "complete"
                : (report.isComplete || nonInterruptionIssue ? "failed" : "incomplete")
            if status == "complete", !availabilityMatches(initial) {
                status = "incomplete"
                baselineID = nil
            }
            if status == "complete" {
                if try !commitComplete(request, audit: report, baselineID: baselineID, initial: initial) {
                    status = "incomplete"
                    baselineID = nil
                    try saveEnvelope(request, status: status, settings: state().value.settings, audit: report,
                                     baselineID: nil, errorCode: "availability_changed")
                }
            } else {
                try saveEnvelope(request, status: status, settings: state().value.settings, audit: report,
                                 baselineID: nil, errorCode: status == "failed" ? "audit_failed" : nil)
            }
            if status == "complete" {
                onMessage?(report.passed ? "录音校验完成。" : "发现录音校验异常；请保留原文件。")
            } else if status == "failed" {
                onMessage?("校验需要重新检查；原录音未改动。")
            } else { onMessage?("校验进度已保存，暂停录音并保持 App 打开时继续。") }
        } catch {
            let code: String
            if case RecordingIntegrityAuditError.invalidCheckpoint(let reason) = error { code = reason }
            else if error is StorageError { code = "audit_storage_or_baseline_invalid" }
            else { code = "audit_unavailable" }
            try saveEnvelope(request, status: "failed", settings: initial.value.settings,
                             audit: nil, baselineID: nil, errorCode: code)
            onMessage?("无法完成校验；原录音未改动。")
        }
    }

    private func saveEnvelope(_ request: WatchIntegrityAuditRequest, status: String,
                              settings: [String: String], audit: RecordingIntegrityReport?,
                              baselineID: String?, errorCode: String?) throws {
        let value = envelope(request, status: status, settings: settings,
                             audit: audit, baselineID: baselineID, errorCode: errorCode)
        try write(TransportCodec.encode(value), to: outputRoot.appendingPathComponent("reports/\(request.requestID).json"))
    }

    private func envelope(_ request: WatchIntegrityAuditRequest, status: String,
                          settings: [String: String], audit: RecordingIntegrityReport?,
                          baselineID: String?, errorCode: String?) -> WatchIntegrityAuditEnvelope {
        WatchIntegrityAuditEnvelope(schemaVersion: 1, requestID: request.requestID,
            mode: request.mode, status: status, appBundleID: bundleID, appBuild: appBuild,
            generatedAtUnixMS: Int64(Date().timeIntervalSince1970 * 1_000),
            criticalSettings: settings, audit: audit, baselineID: baselineID,
            usedBaselineID: audit == nil ? nil : request.expectedBaselineID, errorCode: errorCode)
    }

    /// Prepare all large JSON and fsync outside the lock. Only the two atomic
    /// renames share the capture/settings cancellation boundary. Starting audio
    /// never waits for audio reads, JSON encoding, or report data writes.
    private func commitComplete(_ request: WatchIntegrityAuditRequest, audit: RecordingIntegrityReport,
                                baselineID: String?, initial: (value: Availability, revision: UInt64)) throws -> Bool {
        guard let baselineID else { throw StorageError.persistenceFailed }
        let reportURL = outputRoot.appendingPathComponent("reports/\(request.requestID).json")
        let pointerURL = outputRoot.appendingPathComponent("current-baseline.json")
        let reportStage = outputRoot.appendingPathComponent("reports/.commit-\(UUID().uuidString.lowercased()).json")
        let pointerStage = outputRoot.appendingPathComponent(".baseline-\(UUID().uuidString.lowercased()).json")
        defer {
            try? FileManager.default.removeItem(at: reportStage)
            try? FileManager.default.removeItem(at: pointerStage)
        }
        let value = envelope(request, status: "complete", settings: initial.value.settings,
                             audit: audit, baselineID: baselineID, errorCode: nil)
        try write(TransportCodec.encode(value), to: reportStage)
        try write(TransportCodec.encode(BaselinePointer(baselineID: baselineID)), to: pointerStage)
        lock.lock()
        defer { lock.unlock() }
        guard cancellationRevision == initial.revision, availability.allowsAudit,
              availability.settings == initial.value.settings else { return false }
        guard Darwin.rename(reportStage.path, reportURL.path) == 0 else { throw StorageError.persistenceFailed }
        // The report/baseline are authoritative; this tiny pointer is only a
        // convenience for the diagnostics UI. Its failure cannot erase a valid
        // committed observation or force a new full audio read.
        _ = Darwin.rename(pointerStage.path, pointerURL.path)
        return true
    }

    private func state() -> (value: Availability, revision: UInt64) {
        lock.lock(); defer { lock.unlock() }; return (availability, cancellationRevision)
    }

    private func availabilityMatches(_ initial: (value: Availability, revision: UInt64)) -> Bool {
        let current = state()
        return current.revision == initial.revision && current.value.allowsAudit
            && current.value.settings == initial.value.settings
    }

    private func prepareOutputDirectories() throws {
        // No requested path component is used here. Reject pre-existing links.
        for path in [outputRoot, outputRoot.appendingPathComponent("reports"),
                     outputRoot.appendingPathComponent("requests"), outputRoot.appendingPathComponent("baselines"),
                     outputRoot.appendingPathComponent("checkpoints")] {
            if FileManager.default.fileExists(atPath: path.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw StorageError.invalidFile }
            } else {
                try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
        }
    }

    private func readRegular(_ url: URL, limit: Int) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value >= 0,
              size.int64Value <= limit else { throw StorageError.invalidFile }
        let data = try Data(contentsOf: url)
        guard data.count <= limit else { throw StorageError.invalidFile }
        return data
    }

    private func write(_ data: Data, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else { throw StorageError.invalidFile }
        }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        let file = try FileHandle(forWritingTo: url)
        defer { try? file.close() }
        try file.synchronize()
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
