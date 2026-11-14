import Foundation
import RecordingCore

/// Compile with the exact pure presentation/share types extracted from Library.
/// The UIKit coordinator and all requests/devices remain outside this test.
enum GoogleDriveTransportFaultPresentationCases {
    private struct Failure: Error { let message: String }

    static func run() throws -> Int {
        var count = 0
        func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try condition() else { throw Failure(message: message) }; count += 1
        }
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let requestID = UUID()
        let request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/about?fields=user(permissionId)")!)
        let diagnostic = GoogleDriveTransportDiagnostic.capture(error: URLError(.secureConnectionFailed),
            request: request, phase: .apiRequest, requestID: requestID, origin: .natural)
        let trigger = GoogleDriveTransportFaultReport.Event(timestamp: at, build: 52, applicationState: .background,
            position: .trigger, diagnostic: diagnostic)
        var report = GoogleDriveTransportFaultReport(id: UUID(), primaryRequestID: requestID, correlationAvailable: true, origin: .natural,
            triggeredAt: at, windowEndsAt: at.addingTimeInterval(60), state: .collecting, closedAt: nil,
            truncation: nil, completion: nil, completionObservedAt: nil, completionApplicationState: nil,
            completionBuild: nil, terminalObservedOutsideWindow: false, recoveryEvidence: nil, events: [trigger])
        func archive(_ report: GoogleDriveTransportFaultReport?, evicted: Int = 0) -> GoogleDriveTransportFaultArchive {
            .init(schemaVersion: 1, contextScope: .currentProcessTransport, evictedReportCount: evicted,
                  reports: report.map { [$0] } ?? [])
        }
        let empty = GoogleDriveTransportFaultPresentation(archive: archive(nil))
        try require(empty.count == 0 && empty.latestAt == nil && empty.summary == "尚无故障记录。",
                    "Empty fault history must not imply a failure or recovery")
        let pending = GoogleDriveTransportFaultPresentation(archive: archive(report))
        try require(pending.count == 1 && pending.latestAt == at && pending.summary.contains("正在收集同次请求"),
                    "A correlated live fault must remain pending")
        report.state = .windowElapsed; report.closedAt = report.windowEndsAt
        let expired = GoogleDriveTransportFaultPresentation(archive: archive(report))
        try require(expired.summary.contains("观察窗口已结束") && expired.summary.contains("恢复结果未确认")
            && !expired.summary.contains("已自动恢复"), "Window expiry was mislabeled as recovery")
        report.state = .interrupted
        let interrupted = GoogleDriveTransportFaultPresentation(archive: archive(report))
        try require(interrupted.summary.contains("已中断") && interrupted.summary.contains("缺失区间未补填")
            && !interrupted.summary.contains("已自动恢复"), "Restart interruption was presented as a completed log")
        report.state = .truncated; report.truncation = .eventLimit
        try require(GoogleDriveTransportFaultPresentation(archive: archive(report)).summary.contains("标记截断"),
                    "Dropped context was not disclosed")
        report.completion = .init(requestID: requestID, origin: .natural, attemptCount: 2, outcome: .recovered)
        report.recoveryEvidence = .init(timestamp: at.addingTimeInterval(1), build: 52, applicationState: .background,
            position: .after, diagnostic: GoogleDriveTransportDiagnostic.capture(error: nil, request: request,
                phase: .apiRecovery, httpStatus: 200, requestID: requestID, origin: .natural))
        let recovered = GoogleDriveTransportFaultPresentation(archive: archive(report))
        try require(recovered.summary.contains("连接请求已自动恢复") && !recovered.summary.contains("上传完成"),
                    "Connection recovery must not claim business upload completion")
        try require(recovered.summary.contains("标记截断"), "Recovered request hid a truncated context window")
        report.state = .interrupted
        try require(GoogleDriveTransportFaultPresentation(archive: archive(report)).summary.contains("已中断"),
                    "A terminal request result must not fill an unobserved restart interval")

        for outcome in [GoogleDriveRequestCompletion.Outcome.cancelled, .httpFailure, .notEligible, .budgetExpired,
                        .callerBudgetRejected, .recoveryFailed, .invalidResponse] {
            report.completion = .init(requestID: requestID, origin: .natural, attemptCount: 1, outcome: outcome)
            try require(!GoogleDriveTransportFaultPresentation(archive: archive(report)).summary.contains("已自动恢复"),
                        "A non-recovered completion was shown as recovered")
        }
        let uncorrelated = GoogleDriveTransportFaultReport(id: UUID(), primaryRequestID: nil, correlationAvailable: false, origin: .legacyUnknown,
            triggeredAt: at, windowEndsAt: at.addingTimeInterval(60), state: .windowElapsed, closedAt: at.addingTimeInterval(60),
            truncation: nil, completion: nil, completionObservedAt: nil, completionApplicationState: nil,
            completionBuild: nil, terminalObservedOutsideWindow: false, recoveryEvidence: nil, events: [trigger])
        try require(GoogleDriveTransportFaultPresentation(archive: archive(uncorrelated)).summary.contains("未能关联"),
                    "An unrelated success must not establish recovery without a request identity")
        let bounded = GoogleDriveTransportFaultPresentation(archive: archive(report, evicted: 12))
        try require(bounded.count == 1 && bounded.summary.contains("更早 12 份已超出保留范围"),
                    "Retention loss must remain distinct from retained fault count")

        let share = GoogleDriveTransportFaultShareReport(archive: archive(report), storageFailureObserved: true)
        let bytes = try TransportCodec.encode(share)
        let json = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        try require(json["storageFailureObserved"] as? Bool == true && json["schemaVersion"] as? Int == 1,
                    "A persistence gap was not disclosed in the typed share envelope")
        try require((json["reports"] as? [[String: Any]])?.count == 1,
                    "Sharing did not preserve the immutable typed snapshot")
        try require(!String(decoding: bytes, as: UTF8.self).contains("https://") && !bounded.summary.contains(requestID.uuidString),
                    "A raw request URL or diagnostic identity entered presentation text")
        report.state = .truncated; report.truncation = .eventLimit
        let retained = GoogleDriveTransportFaultShareReport(archive: archive(report, evicted: 12),
            storageFailureObserved: true)
        let attached = GoogleDriveDiagnosticFaultSnapshot(status: .included, capturedAt: at,
            storageFailureObserved: true, report: retained, error: nil)
        let attachedJSON = try JSONSerialization.jsonObject(with: TransportCodec.encode(attached)) as! [String: Any]
        try require(attachedJSON["status"] as? String == "included"
            && attachedJSON["readOnly"] as? Bool == true
            && attachedJSON["contextWindowUpdatedForExport"] as? Bool == false,
            "Ordinary diagnostics did not preserve the read-only context boundary")
        let attachedReport = attachedJSON["report"] as? [String: Any]
        try require(attachedReport?["storageFailureObserved"] as? Bool == true
            && attachedReport?["evictedReportCount"] as? Int == 12
            && (attachedReport?["reports"] as? [[String: Any]])?.first?["primaryRequestID"] as? String
                == requestID.uuidString,
            "Ordinary diagnostics lost retained correlation or storage/retention limits")
        try require(attached.summary.contains("1 份上下文已截断")
            && attached.summary.contains("更早 12 份") && attached.summary.contains("记录可能不完整"),
            "Ordinary diagnostic summary hid truncation, retention or persistence gaps")
        let unavailable = GoogleDriveDiagnosticFaultSnapshot(status: .unavailable, capturedAt: at,
            storageFailureObserved: false, report: nil, error: .recorderUnavailable)
        let none = GoogleDriveDiagnosticFaultSnapshot(status: .noRetainedFaults, capturedAt: at,
            storageFailureObserved: false, report: nil, error: nil)
        let unavailableJSON = try JSONSerialization.jsonObject(with: TransportCodec.encode(unavailable)) as! [String: Any]
        try require(unavailableJSON["error"] as? String == "recorder_unavailable"
            && unavailableJSON["report"] == nil && unavailable.summary != none.summary,
            "An unavailable fault recorder was presented as empty history")
        return count
    }
}
