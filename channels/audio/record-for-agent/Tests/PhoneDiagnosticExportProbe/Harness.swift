import Foundation
import RecordingCore

struct GoogleDriveDiagnosticFaultSnapshot: Encodable, Sendable {
    enum Status: String, Encodable { case unavailable }
    enum Failure: String, Encodable { case libraryUnavailable }
    let status: Status
    let capturedAt: Date
    let storageFailureObserved: Bool
    let report: String?
    let error: Failure?
    var summary: String { "Google 故障记录不可用。" }
}
struct PhoneStatusDiagnosticSnapshot: Encodable, Sendable { let remoteHistoryObserved = false }
struct SafeDrive {
    var syntheticReport: String?
    func diagnosticFaultSnapshot() -> GoogleDriveDiagnosticFaultSnapshot {
        .init(status: .unavailable, capturedAt: Date(), storageFailureObserved: false, report: syntheticReport, error: .libraryUnavailable)
    }
}
@MainActor final class SafeICloud {
    var observation: ICloudDriveDiagnosticObservation?
    var connected = true
    var enabled = true
    var snapshots = 0
    func diagnosticSnapshot(at now: Date = Date()) -> ICloudDriveDiagnosticSnapshot {
        snapshots += 1
        return .init(observation: observation, at: now, connected: connected, enabled: enabled)
    }
    // An export must have no reason to invoke any active operation.
    func resume() { preconditionFailure("diagnostics must not start worker/provider/audio activity") }
}
@MainActor struct PersonalLibrary {
    var drive = SafeDrive()
    let iCloudDrive = SafeICloud()
}
final class SafeConnectivity: @unchecked Sendable {
    func statusDiagnosticSnapshot() -> PhoneStatusDiagnosticSnapshot { .init() }
}
struct Connection { var snapshot: RecorderSnapshot?; var reachable = false }

@MainActor final class DiagnosticStoreProbe {
    var manifests: [SegmentManifest] = []
    var receivedSegmentIDs: Set<UUID> = []
    var hasLibrarySnapshot = false
    var events: [RecordingEvent] = []
    var storageError: String? = "PRIVATE_STORAGE_PATH"
    var connection = Connection()
    var exportURL: URL?
    var isPreparingDiagnostics = false
    var diagnosticPreparationIncludesFullHistory = false
    var diagnosticExportSummary: String?
    var diagnosticExportError: String?
    var diagnosticIssueID: String?
    var diagnosticBuild: String?
    var diagnosticTimingSummary: String?
    var personalLibrary: PersonalLibrary? = PersonalLibrary()
    private var repository: RecordingRepository?
    private let root: URL
    private let diagnosticWork = DispatchQueue(label: "probe.recent")
    private let fullDiagnosticWork = DispatchQueue(label: "probe.full")
    private var librarySnapshotObservedAt: Date?
    private let diagnosticProcessRunID = UUID()
    private var diagnosticLifecycle: DiagnosticShareLifecycle?
    private var diagnosticStartedUptime: TimeInterval?
    private var diagnosticLifecycleStorageFailed = false
    private var connectivity: SafeConnectivity? = SafeConnectivity()
    init(root: URL, repository: RecordingRepository?) { self.root = root; self.repository = repository }
/* PRODUCTION_METHODS */
}
/* PRODUCTION_BUNDLE */

@main enum Probe {
    @MainActor static func wait(_ store: DiagnosticStoreProbe) async throws {
        let until = Date().addingTimeInterval(15)
        while store.isPreparingDiagnostics && Date() < until { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!store.isPreparingDiagnostics)
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let repository = try RecordingRepository(root: root)
        // If the export accidentally reinstates metadataSnapshot or its old
        // diagnostic variant, these selected invalid records force a failure.
        for name in ["manifests", "receipts"] {
            try Data("MALFORMED_PRIVATE_METADATA".utf8).write(to: root.appendingPathComponent(name).appendingPathComponent(UUID().uuidString.lowercased() + ".json"))
        }
        let secret = "PRIVATE_EVENT_DETAIL_TOKEN"
        try repository.appendEvent(.init(kind: "audio_gap", detail: secret, sessionID: UUID()))
        let store = DiagnosticStoreProbe(root: root, repository: repository)
        let iCloud = store.personalLibrary!.iCloudDrive
        let originalObservation = Date().addingTimeInterval(-12)
        iCloud.observation = .init(observedAt: originalObservation,
            counts: .init(providerConfirmedFiles: 2, pendingProviderFiles: 3,
                          needsIdentityRevalidationSources: 1, identityMismatchFiles: 1))
        store.prepareDiagnostics(); try await wait(store)
        precondition(store.exportURL != nil && store.diagnosticExportError == nil)
        precondition(store.diagnosticExportSummary!.contains("手表缓存状态缺失"))
        let reportURL = store.exportURL!
        let text = String(decoding: try Data(contentsOf: reportURL), as: UTF8.self)
        precondition(!text.contains(secret) && !text.contains("PRIVATE_STORAGE_PATH") && !text.contains("MALFORMED_PRIVATE_METADATA"))
        precondition(text.contains("capture_gap") && text.contains("not_observed"))
        let recentEnvelope = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        let recentICloud = recentEnvelope["iCloudDriveStatus"] as! [String: Any]
        precondition(recentICloud["status"] as? String == "needs_identity_revalidation")
        precondition(recentICloud["availability"] as? String == "cached")
        precondition(recentICloud["providerAccessedForExport"] as? Bool == false)
        precondition(recentICloud["workerStartedForExport"] as? Bool == false)
        precondition(recentICloud["audioContentVerified"] as? Bool == false)
        precondition(iCloud.snapshots == 1 && iCloud.observation?.observedAt == originalObservation)
        store.diagnosticSharePresented(); store.diagnosticShareCompleted(completed: false)
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(store.diagnosticTimingSummary!.contains("未完成或已取消，未确认发送"))
        precondition(store.diagnosticTimingSummary!.contains("文件就绪"))
        // An explicit full-history request still avoids the invalid manifests.
        store.prepareDiagnostics(includeFullHistory: true); try await wait(store)
        precondition(store.exportURL != nil && store.diagnosticExportError == nil)
        let fullEnvelope = try JSONSerialization.jsonObject(with: Data(contentsOf: store.exportURL!)) as! [String: Any]
        let fullICloud = fullEnvelope["iCloudDriveStatus"] as! [String: Any]
        precondition(fullICloud["status"] as? String == "needs_identity_revalidation")
        precondition(fullICloud["observedAt"] as? Double == recentICloud["observedAt"] as? Double)
        precondition(iCloud.snapshots == 2 && iCloud.observation?.observedAt == originalObservation)
        // The complete final bundle, not each individual attachment, is capped.
        store.personalLibrary!.drive.syntheticReport = String(repeating: "x", count: DiagnosticReportStorage.maximumReportBytes)
        store.prepareDiagnostics(); try await wait(store)
        precondition(store.exportURL == nil && store.diagnosticExportError != nil)
        precondition(iCloud.snapshots == 3)
        store.personalLibrary!.drive.syntheticReport = nil
        store.prepareDiagnostics(); try await wait(store)
        precondition(store.exportURL != nil && store.diagnosticExportError == nil)
        // A storage failure must invalidate the old URL before reporting error.
        let exportDirectory = store.exportURL!.deletingLastPathComponent()
        try FileManager.default.removeItem(at: exportDirectory)
        let other = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: exportDirectory, withDestinationURL: other)
        store.prepareDiagnostics(); try await wait(store)
        precondition(store.exportURL == nil && store.diagnosticExportError != nil)
        precondition(!store.diagnosticExportError!.contains(root.path))
        try FileManager.default.removeItem(at: exportDirectory)
        let missing = DiagnosticStoreProbe(root: root, repository: nil)
        missing.personalLibrary = nil
        missing.prepareDiagnostics(); try await wait(missing)
        precondition(missing.exportURL != nil && missing.diagnosticExportError == nil)
        let missingText = String(decoding: try Data(contentsOf: missing.exportURL!), as: UTF8.self)
        precondition(missingText.contains("library_unavailable"))
        precondition(missingText.contains("\"completeHistoryObserved\":false"))
        let missingEnvelope = try JSONSerialization.jsonObject(with: Data(missingText.utf8)) as! [String: Any]
        let missingICloud = missingEnvelope["iCloudDriveStatus"] as! [String: Any]
        precondition(missingICloud["availability"] as? String == "not_observed")
        precondition(missingICloud["status"] as? String == "unknown")
        print("{\"passed\":true,\"scenarios\":8,\"productionStoreMethodsExtractedUnchanged\":true,\"deviceAccess\":false,\"audioFilesCreatedOrRead\":false,\"iCloudWorkerOrProviderCallsForExport\":0,\"finalBundleByteCapTested\":true}")
    }
}
