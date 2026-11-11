import Foundation
import RecordingCore
import Darwin

/// Small synthetic JSON fixtures only. Never opens recordings or a network.
enum GoogleDriveFaultReportCases {
    private struct Failure: Error { let message: String }
    static func run() throws -> Int {
        var count = 0
        func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try value() else { throw Failure(message: message) }; count += 1
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("drive-fault-fixtures-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        func url(_ name: String) -> URL { root.appendingPathComponent(name).appendingPathComponent("faults.json") }
        let requestID = UUID()
        let privateMarker = "SYNTHETIC_PRIVATE_MUST_NOT_APPEAR"
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/" + privateMarker + "?fields=id")!)
        request.setValue(privateMarker, forHTTPHeaderField: "Authorization"); request.httpBody = Data(privateMarker.utf8)
        let error = NSError(domain: NSURLErrorDomain, code: -1200,
            userInfo: [NSLocalizedDescriptionKey: privateMarker, "_kCFStreamErrorDomainKey": 3, "_kCFStreamErrorCodeKey": -9816])
        func diagnostic(_ failed: Bool, id: UUID? = requestID,
                        origin: GoogleDriveTransportDiagnostic.Origin? = .natural,
                        phase: GoogleDriveTransportDiagnostic.Phase = .apiRequest,
                        status: Int = 200) -> GoogleDriveTransportDiagnostic {
            .capture(error: failed ? error : nil, request: request, phase: phase,
                httpStatus: failed ? nil : status, requestID: id, origin: origin)
        }
        let recorder = try GoogleDriveTransportFaultRecorder(storeURL: url("normal"), now: at)
        for index in 0..<40 {
            try recorder.record(diagnostic(false, id: UUID()), at: at.addingTimeInterval(Double(index) / 100), build: 52, applicationState: .active)
        }
        for status in [308, 404, 409, 410, 503] {
            try recorder.record(diagnostic(false, id: UUID(), status: status), at: at.addingTimeInterval(0.5), build: 52, applicationState: .active)
        }
        try require(!FileManager.default.fileExists(atPath: url("normal").path), "Ordinary successes created a fault archive")
        let triggered = at.addingTimeInterval(1)
        try recorder.record(diagnostic(true), at: triggered, build: 52, applicationState: .background)
        let immediate = try TransportCodec.decode(GoogleDriveTransportFaultArchive.self, from: Data(contentsOf: url("normal")))
        try require(immediate.reports.count == 1 && immediate.reports[0].state == .collecting
            && immediate.reports[0].completion == nil && immediate.reports[0].events.count == 33,
            "Initial error was not atomically saved with at most 32 observed prior events before recovery")
        let mode = try FileManager.default.attributesOfItem(atPath: url("normal").path)[.posixPermissions] as? NSNumber
        let directoryMode = try FileManager.default.attributesOfItem(atPath: url("normal").deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        try require(mode?.intValue == 0o600 && directoryMode?.intValue == 0o700, "Private archive/directory permissions were not retained")
        try require(immediate.contextScope == .currentProcessTransport && immediate.reports[0].correlationAvailable,
                    "Bounded app observations were presented without their scope or correlation availability")
        let observedBytes = try Data(contentsOf: url("normal"))
        let observedAttributes = try FileManager.default.attributesOfItem(atPath: url("normal").path)
        let observedDirectoryAttributes = try FileManager.default.attributesOfItem(atPath: url("normal").deletingLastPathComponent().path)
        let readOnlyObservation = recorder.observationSnapshot()
        try require(try TransportCodec.encode(readOnlyObservation) == observedBytes && readOnlyObservation.reports[0].state == .collecting,
                    "Read-only fault observation expired or changed the saved archive")
        let afterObservationAttributes = try FileManager.default.attributesOfItem(atPath: url("normal").path)
        let afterObservationDirectoryAttributes = try FileManager.default.attributesOfItem(atPath: url("normal").deletingLastPathComponent().path)
        try require(try Data(contentsOf: url("normal")) == observedBytes
            && (observedAttributes[.modificationDate] as? Date) == (afterObservationAttributes[.modificationDate] as? Date)
            && (observedAttributes[.systemFileNumber] as? NSNumber) == (afterObservationAttributes[.systemFileNumber] as? NSNumber)
            && (observedDirectoryAttributes[.modificationDate] as? Date) == (afterObservationDirectoryAttributes[.modificationDate] as? Date),
            "Read-only fault observation rewrote bytes, metadata or the archive directory")
        let unrelated = GoogleDriveRequestCompletion(requestID: UUID(), origin: .natural, attemptCount: 1, outcome: .succeeded)
        try recorder.finish(unrelated, at: triggered.addingTimeInterval(1), build: 52, applicationState: .background)
        try require(try recorder.snapshot(at: triggered.addingTimeInterval(1)).reports[0].completion == nil,
                    "A nearby successful request was misattributed as recovery")
        try recorder.record(diagnostic(false, phase: .apiRecovery), at: triggered.addingTimeInterval(2), build: 52, applicationState: .background)
        let completion = GoogleDriveRequestCompletion(requestID: requestID, origin: .natural, attemptCount: 2, outcome: .recovered)
        try recorder.finish(completion, at: triggered.addingTimeInterval(3), build: 52, applicationState: .background)
        let recovered = try recorder.snapshot(at: triggered.addingTimeInterval(3)).reports[0]
        try require(recovered.completion == completion && recovered.state == .collecting
            && recovered.events.last?.diagnostic.phase == .apiRecovery && !recovered.terminalObservedOutsideWindow,
            "Same-request recovery and still-open context window were conflated")
        let exported = try recorder.encodedForExport(at: triggered.addingTimeInterval(61))
        let closed = try TransportCodec.decode(GoogleDriveTransportFaultArchive.self, from: exported)
        try require(closed.schemaVersion == 2, "New fault evidence retained the legacy schema version")
        try require(closed.reports[0].state == .windowElapsed && closed.reports[0].completion?.outcome == .recovered,
                    "A quiet 60-second window was left collecting at export or lost its request outcome")
        try require(!String(decoding: exported, as: UTF8.self).contains(privateMarker),
                    "URL, header, body or NSError text escaped fixed diagnostic fields")
        let reloaded = try GoogleDriveTransportFaultRecorder(storeURL: url("normal"), now: triggered.addingTimeInterval(65))
        try require(try reloaded.snapshot(at: triggered.addingTimeInterval(65)) == closed, "A completed saved fault changed across restart")

        let correlation = GoogleDriveUploadCorrelation(segmentID: UUID(), kind: .audio,
            manifestSHA256: String(repeating: "c", count: 64))
        let otherCorrelation = GoogleDriveUploadCorrelation(segmentID: UUID(), kind: .audio,
            manifestSHA256: String(repeating: "d", count: 64))
        let correlated = try GoogleDriveTransportFaultRecorder(storeURL: url("correlated"), now: at)
        try correlated.record(diagnostic(true).withUploadCorrelation(correlation), at: at, build: 52, applicationState: .active)
        do {
            try correlated.record(diagnostic(false, phase: .apiRecovery).withUploadCorrelation(otherCorrelation),
                at: at.addingTimeInterval(1), build: 52, applicationState: .active)
            throw Failure(message: "A different upload job relabeled a request's recovery")
        } catch let failure as Failure { throw failure } catch { count += 1 }
        try correlated.record(diagnostic(false, phase: .apiRecovery).withUploadCorrelation(correlation),
            at: at.addingTimeInterval(1), build: 52, applicationState: .active)
        do {
            try correlated.finish(completion, at: at.addingTimeInterval(2), build: 52, applicationState: .active)
            throw Failure(message: "A keyed request accepted a completion missing its upload identity")
        } catch let failure as Failure { throw failure } catch { count += 1 }
        var correlatedCompletion = completion
        correlatedCompletion.uploadCorrelation = correlation
        try correlated.finish(correlatedCompletion, at: at.addingTimeInterval(2), build: 52, applicationState: .active)
        let savedCorrelation = try GoogleDriveTransportFaultRecorder(storeURL: url("correlated"), now: at.addingTimeInterval(65))
            .observationSnapshot().reports[0]
        try require(savedCorrelation.completion?.uploadCorrelation == correlation
            && savedCorrelation.recoveryEvidence?.diagnostic.uploadCorrelation == correlation
            && savedCorrelation.events.first(where: { $0.position == .trigger })?.diagnostic.uploadCorrelation == correlation,
            "Restart lost the upload key connecting failure, recovery attempt and request completion")

        var legacyObject = try JSONSerialization.jsonObject(with: exported) as! [String: Any]
        legacyObject["schemaVersion"] = 1
        let legacyURL = url("schema-one")
        try FileManager.default.createDirectory(at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: legacyObject).write(to: legacyURL)
        let schemaOne = try GoogleDriveTransportFaultRecorder(storeURL: legacyURL, now: triggered.addingTimeInterval(65))
            .observationSnapshot().reports[0]
        try require(schemaOne.completion?.uploadCorrelation == nil
            && schemaOne.events.allSatisfy { $0.diagnostic.uploadCorrelation == nil },
            "Legacy fault archive became unreadable or invented an upload identity")

        let interruptedURL = url("interrupted")
        let interrupted = try GoogleDriveTransportFaultRecorder(storeURL: interruptedURL, now: at)
        try interrupted.record(diagnostic(true), at: at, build: 52, applicationState: .inactive)
        let beforeRollback = try Data(contentsOf: interruptedURL)
        do { _ = try GoogleDriveTransportFaultRecorder(storeURL: interruptedURL, now: at.addingTimeInterval(-60)); throw Failure(message: "A clock rollback fabricated an interruption time") }
        catch let failure as Failure { throw failure } catch { count += 1 }
        do { try interrupted.finish(completion, at: at.addingTimeInterval(-1), build: 52, applicationState: .active); throw Failure(message: "A backdated completion was saved") }
        catch let failure as Failure { throw failure } catch { count += 1 }
        do { try interrupted.record(diagnostic(false, phase: .apiRecovery), at: at.addingTimeInterval(-1), build: 52, applicationState: .active); throw Failure(message: "A backdated recovery was saved") }
        catch let failure as Failure { throw failure } catch { count += 1 }
        try require(try Data(contentsOf: interruptedURL) == beforeRollback,
                    "Rejected wall-clock rollback changed a previously valid saved fault")
        let restarted = try GoogleDriveTransportFaultRecorder(storeURL: interruptedURL, now: at.addingTimeInterval(20))
        try require(try restarted.snapshot(at: at.addingTimeInterval(20)).reports[0].state == .interrupted,
                    "Restart fabricated completion of an unobserved context interval")
        try require(try restarted.snapshot(at: at.addingTimeInterval(20)).reports[0].completion == nil,
                    "Restart fabricated a request's missing terminal outcome")

        let legacy = try GoogleDriveTransportFaultRecorder(storeURL: url("native"), now: at)
        try legacy.record(diagnostic(true, id: nil, origin: nil, phase: .nativeUpload), at: at, build: 52, applicationState: .background)
        try legacy.finish(completion, at: at.addingTimeInterval(2), build: 52, applicationState: .active)
        let legacyReport = try legacy.snapshot(at: at.addingTimeInterval(2)).reports[0]
        try require(!legacyReport.correlationAvailable && legacyReport.origin == .legacyUnknown && legacyReport.completion == nil,
                    "Uncorrelated native/legacy failure was paired with an unrelated completion")

        let synthetic = try GoogleDriveTransportFaultRecorder(storeURL: url("controlled"), now: at)
        try synthetic.record(diagnostic(true, origin: .controlledFault), at: at, build: 52, applicationState: .active)
        try synthetic.record(diagnostic(false, origin: .controlledFault, phase: .apiRecovery), at: at, build: 52, applicationState: .active)
        try synthetic.finish(.init(requestID: requestID, origin: .controlledFault, attemptCount: 2, outcome: .recovered), at: at, build: 52, applicationState: .active)
        try synthetic.record(diagnostic(true), at: at.addingTimeInterval(1), build: 52, applicationState: .active)
        let noSynthetic = try synthetic.snapshot(at: at.addingTimeInterval(1))
        try require(noSynthetic.reports.count == 1 && noSynthetic.reports[0].events.count == 1,
                    "Controlled injection entered natural faults or their preceding context")

        let bounded = try GoogleDriveTransportFaultRecorder(storeURL: url("bounds"), now: at)
        try bounded.record(diagnostic(true), at: at, build: 52, applicationState: .active)
        for index in 0..<65 {
            try bounded.record(diagnostic(false, id: UUID()), at: at.addingTimeInterval(Double(index + 1) / 100), build: 52, applicationState: .active)
        }
        let truncated = try bounded.snapshot(at: at.addingTimeInterval(1)).reports[0]
        try require(truncated.state == .truncated && truncated.truncation == .eventLimit
            && truncated.events.filter { $0.position == .after }.count == 64,
            "Post-context limit silently dropped observations or grew without bound")
        try bounded.record(diagnostic(false, phase: .apiRecovery), at: at.addingTimeInterval(2), build: 52, applicationState: .active)
        try bounded.finish(completion, at: at.addingTimeInterval(2), build: 52, applicationState: .active)
        try require(try bounded.snapshot(at: at.addingTimeInterval(2)).reports[0].terminalObservedOutsideWindow,
                    "A terminal event following truncation lost its explicit outside-window marker")
        try require(try bounded.snapshot(at: at.addingTimeInterval(2)).reports[0].recoveryEvidence?.diagnostic.httpStatus == 200,
                    "Bounded context collection dropped same-request final-attempt evidence")
        for index in 0..<12 {
            try bounded.record(diagnostic(true, id: UUID()), at: at.addingTimeInterval(100 + Double(index)), build: 52, applicationState: .active)
        }
        let retained = try bounded.snapshot(at: at.addingTimeInterval(120))
        try require(retained.reports.count == 10 && retained.evictedReportCount == 3,
                    "Fault retention exceeded ten reports or hid eviction")
        try require(try bounded.encodedForExport(at: at.addingTimeInterval(120)).count <= GoogleDriveTransportFaultRecorder.maximumArchiveBytes
            && retained.reports.allSatisfy { (try? TransportCodec.encode($0).count).map { $0 <= GoogleDriveTransportFaultRecorder.maximumReportBytes } == true },
            "Fault archive exceeded its fixed byte limits")

        func rejected(_ name: String, _ data: Data) throws -> Bool {
            let path = url(name)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: path)
            do { _ = try GoogleDriveTransportFaultRecorder(storeURL: path, now: triggered.addingTimeInterval(100)); return false }
            catch { return true }
        }
        var object = try JSONSerialization.jsonObject(with: exported) as! [String: Any]
        var reports = object["reports"] as! [[String: Any]]
        var badCompletion = reports[0]["completion"] as! [String: Any]
        badCompletion["origin"] = "legacy_unknown"; reports[0]["completion"] = badCompletion; object["reports"] = reports
        try require(try rejected("origin-mismatch", JSONSerialization.data(withJSONObject: object)),
                    "A mismatched completion origin was accepted from disk")
        object = try JSONSerialization.jsonObject(with: exported) as! [String: Any]
        reports = object["reports"] as! [[String: Any]]; reports[0]["state"] = "collecting"; object["reports"] = reports
        try require(try rejected("state-mismatch", JSONSerialization.data(withJSONObject: object)),
                    "A collecting report with a closed timestamp was accepted")
        object = try JSONSerialization.jsonObject(with: exported) as! [String: Any]
        reports = object["reports"] as! [[String: Any]]
        var evidence = reports[0]["recoveryEvidence"] as! [String: Any]
        var nonRecovery = evidence["diagnostic"] as! [String: Any]
        nonRecovery["httpStatus"] = 302; evidence["diagnostic"] = nonRecovery
        reports[0]["recoveryEvidence"] = evidence; object["reports"] = reports
        try require(try rejected("false-recovery", JSONSerialization.data(withJSONObject: object)),
                    "A terminal recovered claim without same-request HTTP200 evidence was accepted")
        let missing = try GoogleDriveTransportFaultRecorder(storeURL: url("missing-evidence"), now: at)
        try missing.record(diagnostic(true), at: at, build: 52, applicationState: .active)
        do { try missing.finish(completion, at: at, build: 52, applicationState: .active); throw Failure(message: "Recovery without final evidence was accepted") }
        catch let failure as Failure { throw failure } catch { count += 1 }
        object = try JSONSerialization.jsonObject(with: exported) as! [String: Any]
        reports = object["reports"] as! [[String: Any]]
        var events = reports[0]["events"] as! [[String: Any]]
        var badDiagnostic = events[0]["diagnostic"] as! [String: Any]
        badDiagnostic["errors"] = [["domain": privateMarker, "code": -1200]]
        events[0]["diagnostic"] = badDiagnostic; reports[0]["events"] = events; object["reports"] = reports
        try require(try rejected("private-domain", JSONSerialization.data(withJSONObject: object)),
                    "An arbitrary decoded error-domain string entered a shareable report")
        try require(try rejected("oversized", Data(repeating: 32, count: GoogleDriveTransportFaultRecorder.maximumArchiveBytes + 1)),
                    "An oversized archive was accepted")

        let target = root.appendingPathComponent("private-target.json")
        try exported.write(to: target)
        let symlink = url("symlink")
        try FileManager.default.createDirectory(at: symlink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        do { _ = try GoogleDriveTransportFaultRecorder(storeURL: symlink, now: at); throw Failure(message: "Symbolic archive was read") }
        catch let failure as Failure { throw failure } catch { count += 1 }
        let hardlink = url("hardlink")
        try FileManager.default.createDirectory(at: hardlink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: target, to: hardlink)
        do { _ = try GoogleDriveTransportFaultRecorder(storeURL: hardlink, now: at); throw Failure(message: "Hard-linked archive was read") }
        catch let failure as Failure { throw failure } catch { count += 1 }
        try FileManager.default.removeItem(at: hardlink)
        let fifo = url("fifo")
        try FileManager.default.createDirectory(at: fifo.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard mkfifo(fifo.path, 0o600) == 0 else { throw Failure(message: "Could not create synthetic FIFO") }
        do { _ = try GoogleDriveTransportFaultRecorder(storeURL: fifo, now: at); throw Failure(message: "FIFO archive was read") }
        catch let failure as Failure { throw failure } catch { count += 1 }
        let replacedPath = url("replaced")
        let replaced = try GoogleDriveTransportFaultRecorder(storeURL: replacedPath, now: at)
        try FileManager.default.createSymbolicLink(at: replacedPath, withDestinationURL: target)
        do { try replaced.record(diagnostic(true), at: at, build: 52, applicationState: .active); throw Failure(message: "Unsafe replacement was saved") }
        catch let failure as Failure { throw failure } catch { count += 1 }
        try require(try replaced.snapshot(at: at).reports.isEmpty && Data(contentsOf: target) == exported,
                    "A rejected write mutated the saved snapshot or a linked target")

        let fileRequestID = UUID()
        var fileRequest = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/syntheticFile1?fields=id")!)
        fileRequest.httpMethod = "GET"
        let accepted = try GoogleDriveTransportFaultRecorder(storeURL: url("accepted-404"), now: at)
        try accepted.record(.capture(error: error, request: fileRequest, phase: .apiRequest, requestID: fileRequestID, origin: .natural),
            at: at, build: 52, applicationState: .active)
        try accepted.record(.capture(error: nil, request: fileRequest, phase: .apiRecovery, httpStatus: 404, requestID: fileRequestID, origin: .natural),
            at: at.addingTimeInterval(1), build: 52, applicationState: .active)
        try accepted.finish(.init(requestID: fileRequestID, origin: .natural, attemptCount: 2, outcome: .recovered),
            at: at.addingTimeInterval(1), build: 52, applicationState: .active)
        try require(try accepted.snapshot(at: at.addingTimeInterval(1)).reports[0].completion?.outcome == .recovered,
                    "A caller-accepted file metadata 404 was rejected as same-request recovery")
        var aboutRequest = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/about?fields=user")!)
        aboutRequest.httpMethod = "GET"
        let aboutMissing = try GoogleDriveTransportFaultRecorder(storeURL: url("about-404"), now: at)
        try aboutMissing.record(.capture(error: error, request: aboutRequest, phase: .apiRequest, requestID: fileRequestID, origin: .natural),
            at: at, build: 52, applicationState: .active)
        try aboutMissing.record(.capture(error: nil, request: aboutRequest, phase: .apiRecovery, httpStatus: 404, requestID: fileRequestID, origin: .natural),
            at: at.addingTimeInterval(1), build: 52, applicationState: .active)
        do {
            try aboutMissing.finish(.init(requestID: fileRequestID, origin: .natural, attemptCount: 2, outcome: .recovered),
                at: at.addingTimeInterval(1), build: 52, applicationState: .active)
            throw Failure(message: "An about 404 was stored as recovered")
        } catch let failure as Failure { throw failure } catch { count += 1 }
        let otherID = UUID()
        let unrelatedSuccess = try GoogleDriveTransportFaultRecorder(storeURL: url("other-success"), now: at)
        try unrelatedSuccess.record(.capture(error: error, request: fileRequest, phase: .apiRequest, requestID: fileRequestID, origin: .natural),
            at: at, build: 52, applicationState: .active)
        try unrelatedSuccess.record(.capture(error: nil, request: fileRequest, phase: .apiRecovery, httpStatus: 200, requestID: otherID, origin: .natural),
            at: at.addingTimeInterval(1), build: 52, applicationState: .active)
        do {
            try unrelatedSuccess.finish(.init(requestID: fileRequestID, origin: .natural, attemptCount: 2, outcome: .recovered),
                at: at.addingTimeInterval(1), build: 52, applicationState: .active)
            throw Failure(message: "A different request's HTTP 200 recovered the original failure")
        } catch let failure as Failure { throw failure } catch { count += 1 }
        return count
    }
}
