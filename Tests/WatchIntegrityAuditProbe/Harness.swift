import CryptoKit
import Foundation
import RecordingCore

private enum Failure: Error { case assertion(String), timeout }
private var assertions = 0
private func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    assertions += 1
    if try !value() { throw Failure.assertion(message) }
}
private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func change<T>(_ block: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return block(&value)
    }
    var current: Value { change { $0 } }
}
private final class Fixture {
    let root: URL
    let output: URL
    let repository: RecordingRepository
    var coordinator: WatchIntegrityAuditCoordinator!
    init(_ base: URL, operation: WatchIntegrityAuditCoordinator.AuditOperation? = nil) throws {
        root = base.appendingPathComponent("WristRecord")
        output = base.appendingPathComponent("WristRecordIntegrity")
        repository = try RecordingRepository(root: root)
        coordinator = WatchIntegrityAuditCoordinator(sourceRoot: root, outputRoot: output,
            bundleID: "test.watch", appBuild: "39", auditOperation: operation)
    }
    func ready(_ foreground: Bool = true, capture: Bool = false) {
        coordinator.setAvailability(foreground: foreground, ready: true, captureActive: capture,
            criticalSettings: ["recordingRequested": capture ? "true" : "false", "recordingState": capture ? "recording" : "paused"])
    }
    @discardableResult func seal(_ content: String) throws -> SegmentManifest {
        let id = UUID(), session = RecordingSession(startedAt: Date(), state: .paused)
        try repository.saveSession(session)
        try Data(content.utf8).write(to: repository.stagingURL(for: id))
        return try repository.sealSegment(stagedURL: repository.stagingURL(for: id), id: id,
            sessionID: session.id, sequence: 0, startedAt: session.startedAt,
            endedAt: session.startedAt.addingTimeInterval(60), sampleRate: 16_000, frameCount: 960_000)
    }
    func submit(_ mode: RecordingIntegrityMode = .full, baseline: String? = nil,
                id: String = UUID().uuidString.lowercased()) throws -> WatchIntegrityAuditRequest {
        let request = WatchIntegrityAuditRequest(schemaVersion: 1, requestID: id, mode: mode, expectedBaselineID: baseline)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try TransportCodec.encode(request).write(to: output.appendingPathComponent("request.json"), options: .atomic)
        coordinator.pollMailbox()
        return request
    }
    func result(_ request: WatchIntegrityAuditRequest, where condition: (WatchIntegrityAuditEnvelope) -> Bool = { _ in true }) throws -> WatchIntegrityAuditEnvelope {
        let until = Date().addingTimeInterval(10)
        let url = output.appendingPathComponent("reports/\(request.requestID).json")
        while Date() < until {
            if let data = try? Data(contentsOf: url), let value = try? TransportCodec.decode(WatchIntegrityAuditEnvelope.self, from: data), condition(value) { return value }
            Thread.sleep(forTimeInterval: 0.01)
        }
        throw Failure.timeout
    }
}

@main private enum Probe {
    static func main() throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let base = URL(fileURLWithPath: CommandLine.arguments[2])
        var failures: [String] = []
        var count = 0
        func run(_ name: String, _ body: () throws -> Void) {
            count += 1
            do { try body() } catch { failures.append("\(name): \(error)") }
        }
        func fixture(_ name: String) throws -> Fixture { try Fixture(base.appendingPathComponent(name)) }

        run("initial launch creates independent mailbox directories") {
            let f = try fixture("bootstrap")
            let until = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: f.output.appendingPathComponent("reports").path), Date() < until {
                Thread.sleep(forTimeInterval: 0.01)
            }
            try expect(FileManager.default.fileExists(atPath: f.output.appendingPathComponent("reports").path), "first launch can accept native request without tapping diagnostic UI")
            try expect(!FileManager.default.fileExists(atPath: f.output.appendingPathComponent("request.json").path), "bootstrap does not invent a request")
        }
        run("strict request scope") {
            let valid = Data("{\"schemaVersion\":1,\"requestID\":\"11111111-1111-4111-8111-111111111111\",\"mode\":\"quick\"}".utf8)
            try expect(try WatchIntegrityAuditRequest.decode(valid).mode == .quick, "valid request")
            let cases = ["../outside", "11111111-1111-4111-8111-11111111111A", "not-a-uuid"]
            for id in cases {
                let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "requestID": id, "mode": "full"])
                try expect((try? WatchIntegrityAuditRequest.decode(data)) == nil, "path/uppercase ID rejected")
            }
            let extra = Data("{\"schemaVersion\":true,\"requestID\":\"11111111-1111-4111-8111-111111111111\",\"mode\":\"quick\"}".utf8)
            try expect((try? WatchIntegrityAuditRequest.decode(extra)) == nil, "bool version rejected")
            let unknown = Data("{\"schemaVersion\":1,\"requestID\":\"11111111-1111-4111-8111-111111111111\",\"mode\":\"full\",\"path\":\"segments\"}".utf8)
            try expect((try? WatchIntegrityAuditRequest.decode(unknown)) == nil, "unknown path control rejected")
        }
        run("capture deferral then foreground continuation") {
            let f = try fixture("defer"); try f.seal("abc"); f.ready(capture: true)
            let request = try f.submit()
            let deferred = try f.result(request)
            try expect(deferred.status == "deferred" && deferred.audit == nil, "capture reads no audio")
            try expect(deferred.errorCode == "capture_active", "explicit deferral")
            f.ready(); f.coordinator.pollMailbox()
            let full = try f.result(request) { $0.status == "complete" }
            try expect(full.audit?.fullContentVerified == true, "paused full physically hashes")
            try expect(full.requestID == request.requestID && full.appBuild == "39" && full.appBundleID == "test.watch", "report request/app binding")
            try expect(full.audit?.nonce == request.requestID, "core nonce binding")
        }
        run("quick explicitly uses baseline and new files hash") {
            let f = try fixture("quick"); try f.seal("old"); f.ready()
            let initial = try f.result(f.submit())
            let id = initial.baselineID!
            try f.seal("new")
            let quick = try f.result(f.submit(.quick, baseline: id))
            try expect(quick.audit?.passed == true && quick.audit?.fullContentVerified == false, "quick never claims full")
            try expect(quick.audit?.entries.filter { $0.sourceKind == "sealed_audio" && $0.verification == .historicalHashMetadataUnchanged }.count == 1, "unchanged historical audio skipped")
            try expect(quick.audit?.entries.filter { $0.sourceKind == "sealed_audio" && $0.verification == .currentHash }.count == 1, "new audio actually hashed")
            let fresh = try f.result(f.submit(.quick))
            try expect(fresh.audit?.historicalHashCount == 0, "absent expectedBaselineID does not reuse old baseline")
        }
        run("missing baseline fails without fallback") {
            let f = try fixture("baseline-missing"); try f.seal("abc"); f.ready()
            let report = try f.result(f.submit(.quick, baseline: String(repeating: "0", count: 64)))
            try expect(report.status == "failed" && report.audit == nil && report.baselineID == nil, "missing requested baseline must fail")
        }
        run("baseline bytes checked against ID") {
            let f = try fixture("baseline-tamper"); try f.seal("abc"); f.ready()
            let first = try f.result(f.submit())
            let id = first.baselineID!
            try Data("{}".utf8).write(to: f.output.appendingPathComponent("baselines/\(id).json"))
            let report = try f.result(f.submit(.quick, baseline: id))
            try expect(report.status == "failed" && report.audit == nil, "tampered baseline fails")
        }
        run("checksum failure cannot become complete") {
            let f = try fixture("checksum"); let audio = try f.seal("abc"); f.ready()
            let initial = try f.result(f.submit())
            let id = initial.baselineID!
            try Data("xyz".utf8).write(to: f.repository.audioURL(for: audio))
            let failed = try f.result(f.submit(.quick, baseline: id))
            try expect(failed.status == "failed", "finished failed checks are not completion")
            try expect(failed.audit?.isComplete == true && failed.audit?.passed == false, "failed Core report retained")
            try expect(failed.baselineID == nil && failed.usedBaselineID == id, "failed audit binds old baseline without generating new baseline")
        }
        run("completed nonce is idempotent and immutable") {
            let f = try fixture("duplicate"); let audio = try f.seal("abc"); f.ready()
            let request = try f.submit()
            let first = try f.result(request)
            let path = f.output.appendingPathComponent("reports/\(request.requestID).json")
            let bytes = try Data(contentsOf: path)
            try Data("def".utf8).write(to: f.repository.audioURL(for: audio))
            _ = try f.submit(.full, id: request.requestID)
            Thread.sleep(forTimeInterval: 0.1)
            try expect(try Data(contentsOf: path) == bytes, "completed nonce not rerun")
            _ = try f.submit(.quick, id: request.requestID)
            Thread.sleep(forTimeInterval: 0.1)
            try expect(try Data(contentsOf: path) == bytes && first.mode == .full, "nonce cannot change mode")
        }
        run("source untouched and report outside source catalog") {
            let f = try fixture("scope"); let audio = try f.seal("abc"); f.ready()
            let before = try Data(contentsOf: f.repository.audioURL(for: audio))
            let result = try f.result(f.submit())
            try expect(try Data(contentsOf: f.repository.audioURL(for: audio)) == before, "audit cannot mutate CAF")
            try expect(!f.output.path.hasPrefix(f.root.path + "/"), "audit reports outside recording root")
            try expect(result.audit?.entries.contains { $0.relativePath.contains("Integrity") } == false, "no report self-reference")
        }
        run("mailbox symlink rejected") {
            let f = try fixture("symlink"); try f.seal("abc"); f.ready()
            try FileManager.default.createDirectory(at: f.output, withIntermediateDirectories: true)
            let outside = base.appendingPathComponent("outside-request.json")
            let request = WatchIntegrityAuditRequest(schemaVersion: 1, requestID: UUID().uuidString.lowercased(), mode: .full, expectedBaselineID: nil)
            try TransportCodec.encode(request).write(to: outside)
            try FileManager.default.createSymbolicLink(at: f.output.appendingPathComponent("request.json"), withDestinationURL: outside)
            f.coordinator.pollMailbox(); Thread.sleep(forTimeInterval: 0.1)
            try expect(!FileManager.default.fileExists(atPath: f.output.appendingPathComponent("reports/\(request.requestID).json").path), "symlink request not followed")
        }
        run("mid-audit recording cancellation remains latched") {
            let f = try fixture("cancel"); try f.seal("abc"); f.ready()
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            let first = Box(true)
            let root = f.root
            f.coordinator = WatchIntegrityAuditCoordinator(sourceRoot: root, outputRoot: f.output,
                auditOperation: { mode, nonce, baseline, checkpoint, continuation, progress in
                    if first.change({ value -> Bool in let result = value; value = false; return result }) {
                        entered.signal(); _ = release.wait(timeout: .now() + 5)
                    }
                    return try RecordingIntegrityAuditor(root: root, libraryGeneration: RecordingIntegrityAuditor.libraryGeneration(at: root))
                        .audit(mode: mode, nonce: nonce, baseline: baseline, checkpoint: checkpoint, while: continuation, onCheckpoint: progress)
                })
            f.ready()
            let request = try f.submit()
            try expect(entered.wait(timeout: .now() + 5) == .success, "hash work off caller")
            f.ready(capture: true); f.ready(); release.signal()
            let cancelled = try f.result(request)
            try expect(cancelled.status == "incomplete" && cancelled.audit?.fullContentVerified == false, "cancelled chunk cannot revive when capture ends quickly")
            f.coordinator.pollMailbox()
            let completed = try f.result(request) { $0.status == "complete" }
            try expect(completed.audit?.fullContentVerified == true, "same nonce continues after stop")
        }
        run("checkpoint resumes bounded real hash observation") {
            let f = try fixture("checkpoint"); try f.seal("first"); try f.seal("second"); f.ready()
            let first = Box(true), root = f.root
            f.coordinator = WatchIntegrityAuditCoordinator(sourceRoot: root, outputRoot: f.output,
                auditOperation: { mode, nonce, baseline, checkpoint, continuation, progress in
                    let limit = first.change { value -> Bool in let result = value; value = false; return result }
                    var audioDone = false
                    return try RecordingIntegrityAuditor(root: root, libraryGeneration: RecordingIntegrityAuditor.libraryGeneration(at: root))
                        .audit(mode: mode, nonce: nonce, baseline: baseline, checkpoint: checkpoint,
                               while: { continuation() && !(limit && audioDone) }, onCheckpoint: { value in
                            progress(value); audioDone = true
                        })
                })
            f.ready(); let request = try f.submit()
            let partial = try f.result(request)
            try expect(partial.status == "incomplete", "first batch partial")
            try expect(partial.audit?.filesHashedInObservationWindow ?? 0 > 0, "real completed files retained")
            f.coordinator.pollMailbox()
            let complete = try f.result(request) { $0.status == "complete" }
            try expect(complete.audit?.fullContentVerified == true, "window full after resume")
            try expect(complete.audit?.entries.contains { $0.verification == .checkpointHashMetadataUnchanged } == true, "same nonce checkpoint distinct from historical baseline")
            try expect((complete.audit?.filesHashedInObservationWindow ?? 0) > (complete.audit?.filesHashedThisCall ?? 0), "window and current counts distinct")
            let quick = try f.result(f.submit(.quick, baseline: complete.baselineID))
            try expect(quick.audit?.historicalHashCount == 2, "completed split-full audio becomes reusable historical baseline")
            try expect(quick.audit?.entries.filter { $0.sourceKind == "sealed_audio" }.allSatisfy { $0.bytesHashed == 0 } == true, "quick does not reread unchanged split-full audio")
        }
        run("setting change after audit cannot publish stale completion") {
            let f = try fixture("commit-race"); try f.seal("abc")
            let root = f.root, target = Box<WatchIntegrityAuditCoordinator?>(nil), once = Box(true)
            let coordinator = WatchIntegrityAuditCoordinator(sourceRoot: root, outputRoot: f.output,
                auditOperation: { mode, nonce, baseline, checkpoint, continuation, progress in
                    let report = try RecordingIntegrityAuditor(root: root, libraryGeneration: RecordingIntegrityAuditor.libraryGeneration(at: root))
                        .audit(mode: mode, nonce: nonce, baseline: baseline, checkpoint: checkpoint,
                               while: continuation, onCheckpoint: progress)
                    if once.change({ value -> Bool in let result = value; value = false; return result }) {
                        target.current?.setAvailability(foreground: true, ready: true, captureActive: false,
                            criticalSettings: ["recordingRequested": "false", "recordingState": "paused", "recordLocations": "true"])
                    }
                    return report
                })
            target.change { $0 = coordinator }; f.coordinator = coordinator; f.ready()
            let request = try f.submit()
            let interrupted = try f.result(request)
            try expect(interrupted.status == "incomplete" && interrupted.baselineID == nil, "settings changed after last hash invalidates completion")
            try expect(interrupted.criticalSettings["recordLocations"] == "true", "current settings reported")
            try expect(!FileManager.default.fileExists(atPath: f.output.appendingPathComponent("current-baseline.json").path), "stale baseline not promoted")
            f.coordinator.pollMailbox()
            let completed = try f.result(request) { $0.status == "complete" }
            try expect(completed.audit?.passed == true, "same window can complete after stable settings")
        }
        run("launch argument request uses same safe path") {
            let f = try fixture("launch"); try f.seal("abc"); f.ready()
            let request = WatchIntegrityAuditRequest(schemaVersion: 1, requestID: UUID().uuidString.lowercased(), mode: .full, expectedBaselineID: nil)
            f.coordinator.acceptLaunchArguments(["app", "--recording-integrity-request", try TransportCodec.encode(request).base64EncodedString()])
            let result = try f.result(request)
            try expect(result.requestID == request.requestID && result.audit?.passed == true, "launch protocol matches mailbox")
        }
        let report: [String: Any] = ["status": failures.isEmpty ? "passed" : "failed", "caseCount": count,
                                     "assertionCount": assertions, "failures": failures]
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]).write(to: output)
        if !failures.isEmpty { throw Failure.assertion(failures.joined(separator: "; ")) }
    }
}
