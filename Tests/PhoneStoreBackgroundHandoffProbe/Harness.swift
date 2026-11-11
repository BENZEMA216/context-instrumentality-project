import Foundation

// These in-memory model/API adapters deliberately have no audio URL or reader.
private struct SegmentManifest: Equatable, Sendable { let id: UUID; let startedAt: Date }
private struct SegmentReceipt: Sendable { let segmentID: UUID }
private struct RecordingTransferEvidenceSnapshot: Sendable {
    let manifests: [SegmentManifest]; let receipts: [SegmentReceipt]
}
private final class RecordingRepository: @unchecked Sendable {
    let snapshot: RecordingTransferEvidenceSnapshot
    var failure = false
    var duringRead: (() -> Void)?
    private(set) var readCount = 0
    init(_ manifests: [SegmentManifest]) {
        snapshot = .init(manifests: manifests, receipts: manifests.map { .init(segmentID: $0.id) })
    }
    func transferEvidenceSnapshot() throws -> RecordingTransferEvidenceSnapshot {
        readCount += 1; duringRead?()
        if failure { throw NSError(domain: "SyntheticMetadata", code: 1) }
        return snapshot
    }
}
private struct WatchResult { let succeeded: Bool; let needsMore: Bool }
@MainActor private final class PhoneConnectivity {
    var waiting: ((WatchResult) -> Void)?
    private(set) var foregroundCalls = 0
    private(set) var observationCalls = 0
    func appDidBecomeActive() { foregroundCalls += 1 }
    func observeVerifiedMetadata(onThrottle: (@Sendable (Int) -> Void)? = nil) { observationCalls += 1; if observationCalls > 1 { onThrottle?(17) } }
    private(set) var diagnostics: [String] = []
    func performBackgroundMaintenance(cancellation: PhoneBackgroundCancellation,
        resultCompletion: @escaping (WatchResult) -> Void) { waiting = resultCompletion }
    func finish() { let callback = waiting; waiting = nil; callback?(.init(succeeded: true, needsMore: false)) }
    func recordBackgroundDiagnostic(kind: String, detail: String) { diagnostics.append(kind) }
}
@MainActor private final class Worker {
    private(set) var discovered: [UUID] = []
    private(set) var resumeCalls = 0
    private(set) var observationCalls = 0
    func resume() { resumeCalls += 1 }
    func didBecomeActive() { resume() }
    func observeVerifiedMetadata(onThrottle: (@Sendable (Int) -> Void)? = nil) { observationCalls += 1; if observationCalls > 1 { onThrottle?(17) } }
    private(set) var prepared: [[UUID]] = []
    private(set) var systemPermits: [Bool] = []
    var hasPendingWork = false
    var hasPendingExportWork = false
    var hasPendingDelivery = false
    var hold = false
    var result = true
    func discover(manifests: [SegmentManifest], receivedIDs: Set<UUID>) {
        discovered = manifests.filter { receivedIDs.contains($0.id) }.map(\.id)
    }
    func discover(manifests: [SegmentManifest], receivedSegmentIDs: Set<UUID>) {
        discover(manifests: manifests, receivedIDs: receivedSegmentIDs)
    }
    func prepareBackgroundDelivery(isCancelled: @escaping @Sendable () -> Bool,
                                   systemGranted: Bool = false) async -> Bool {
        prepared.append(discovered); systemPermits.append(systemGranted)
        while hold && !isCancelled() { try? await Task.sleep(nanoseconds: 1_000_000) }
        return !isCancelled() && result
    }
}
@MainActor private final class PersonalLibraryStore {
    let drive = Worker(); let iCloudDrive = Worker()
}
@MainActor private final class AutomaticDeliveryBackgroundEvents {
    static let shared = AutomaticDeliveryBackgroundEvents()
    private(set) var active = Set<UUID>()
    func beginProcessing(isCancelled: @escaping @Sendable () -> Bool) -> UUID {
        let id = UUID(); active.insert(id); return id
    }
    func endProcessing(_ id: UUID) { active.remove(id) }
}
@MainActor private enum PhoneBackgroundSync {
    private(set) static var noteCount = 0
    static func noteNewWork() { noteCount += 1 }
}
@MainActor private final class StoreProbe {
    var connectivity: PhoneConnectivity?
    var repository: RecordingRepository?
    var automaticDelivery: Worker?
    var personalLibrary: PersonalLibraryStore?
    var manifests: [SegmentManifest] = []
    var receivedSegmentIDs = Set<UUID>()
    var hasLibrarySnapshot = false
    var observationPreparationMessage = ""
    private var observationPreparationRequest = UUID()
    private var observationPreparationCooldownSeconds = 0
    private(set) var reloadCalls = 0
    func reload() { reloadCalls += 1 }
    var librarySnapshotObservedAt: Date?
    let work = DispatchQueue(label: "synthetic.store.metadata")
    init(_ repository: RecordingRepository) {
        self.repository = repository; connectivity = PhoneConnectivity()
        automaticDelivery = Worker(); personalLibrary = PersonalLibraryStore()
    }
// PRODUCTION_STORE_BACKGROUND_METHODS
}
@MainActor private final class Outcome: @unchecked Sendable {
    var values: [(Bool, Bool)] = []
    nonisolated func append(_ succeeded: Bool, _ pending: Bool) {
        Task { @MainActor in self.values.append((succeeded, pending)) }
    }
}
@main private struct Probe {
    @MainActor static var assertions = 0
    @MainActor static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        assertions += 1
        if !value() { throw NSError(domain: "StoreHandoffProbe", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    @MainActor static func eventually(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !condition() {
            if ProcessInfo.processInfo.systemUptime > deadline { throw NSError(domain: "StoreHandoffTimeout", code: 1) }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    @MainActor static func main() async throws {
        let observationRepo = RecordingRepository([]), observationOnly = StoreProbe(observationRepo)
        observationOnly.prepareObservationSnapshots()
        try check(observationOnly.connectivity?.observationCalls == 1
            && observationOnly.personalLibrary?.drive.observationCalls == 1
            && observationOnly.personalLibrary?.iCloudDrive.observationCalls == 1,
            "Manual observation requests each existing metadata owner exactly once")
        try check(observationOnly.reloadCalls == 0 && observationRepo.readCount == 0
            && observationOnly.connectivity?.foregroundCalls == 0
            && observationOnly.automaticDelivery?.resumeCalls == 0
            && observationOnly.personalLibrary?.drive.resumeCalls == 0
            && observationOnly.personalLibrary?.iCloudDrive.resumeCalls == 0,
            "Manual observation cannot reload, discover, resume, or manufacture a lifecycle event")
        observationOnly.prepareObservationSnapshots()
        try await eventually { observationOnly.observationPreparationMessage.contains("17 秒后可再次准备") }
        try check(observationOnly.observationPreparationMessage.hasPrefix("刚刚已准备"),
            "Publisher throttle feedback reaches the manual button with its actual remaining seconds")
        let foreground = StoreProbe(RecordingRepository([]))
        foreground.didBecomeActive()
        try check(foreground.reloadCalls == 1 && foreground.connectivity?.foregroundCalls == 1,
            "Foreground observation preserves one real reload and connectivity activation")
        try check(foreground.automaticDelivery?.resumeCalls == 1
            && foreground.personalLibrary?.drive.resumeCalls == 1 && foreground.personalLibrary?.iCloudDrive.resumeCalls == 1,
            "Foreground observation must not duplicate any worker resume")
        try check(foreground.connectivity?.observationCalls == 1
            && foreground.personalLibrary?.drive.observationCalls == 1 && foreground.personalLibrary?.iCloudDrive.observationCalls == 1
            && foreground.automaticDelivery?.observationCalls == 0,
            "Foreground must call exactly the three metadata observation entry points")
        foreground.connectivity = nil; foreground.automaticDelivery = nil; foreground.personalLibrary = nil
        foreground.didBecomeActive()
        try check(foreground.reloadCalls == 2, "Foreground observations must tolerate unavailable library dependencies")
        let old = SegmentManifest(id: UUID(), startedAt: Date(timeIntervalSince1970: 100))
        let new = SegmentManifest(id: UUID(), startedAt: Date(timeIntervalSince1970: 200))
        let coldRepo = RecordingRepository([old]), coldStore = StoreProbe(coldRepo), coldOutcome = Outcome()
        let coldGeneration = PhoneBackgroundSync.noteCount
        coldStore.performBackgroundSync(cancellation: PhoneBackgroundCancellation(), completion: coldOutcome.append)
        coldStore.connectivity!.finish(); try await eventually { !coldOutcome.values.isEmpty }
        try check(coldStore.hasLibrarySnapshot && coldStore.receivedSegmentIDs == [old.id]
            && coldStore.personalLibrary!.drive.discovered == [old.id]
            && coldStore.personalLibrary!.iCloudDrive.discovered == [old.id],
            "Cold restoration eventually hands metadata to both workers without gating ledger work")
        try check(PhoneBackgroundSync.noteCount == coldGeneration && coldOutcome.values[0].0 && !coldOutcome.values[0].1,
            "Cold historical snapshot is not new external work and cannot manufacture an empty fallback loop")
        let repo = RecordingRepository([old, new]), store = StoreProbe(repo), outcome = Outcome()
        store.manifests = [old]; store.receivedSegmentIDs = [old.id]; store.hasLibrarySnapshot = true
        store.automaticDelivery!.hold = true
        store.personalLibrary!.drive.hold = true; store.personalLibrary!.iCloudDrive.hold = true
        // Provider pending differs from pending local export. Both cloud local
        // preparations can succeed while a future OS opportunity is still due.
        store.personalLibrary!.iCloudDrive.hasPendingWork = true
        let discoveryEntered = DispatchSemaphore(value: 0), releaseDiscovery = DispatchSemaphore(value: 0)
        repo.duringRead = { discoveryEntered.signal(); _ = releaseDiscovery.wait(timeout: .now() + 3) }
        let generation = PhoneBackgroundSync.noteCount
        store.performBackgroundSync(cancellation: PhoneBackgroundCancellation(), completion: outcome.append)
        try check(store.personalLibrary!.drive.prepared.isEmpty, "Cloud cannot prepare before Watch maintenance has completed")
        store.connectivity!.finish()
        try await eventually { !store.personalLibrary!.drive.prepared.isEmpty && !store.personalLibrary!.iCloudDrive.prepared.isEmpty }
        try check(store.personalLibrary!.drive.prepared[0].isEmpty
            && store.personalLibrary!.iCloudDrive.prepared[0].isEmpty,
            "Both cloud ledger turns start even while cold snapshot is blocked")
        try check(repo.readCount == 0 && store.automaticDelivery!.prepared.isEmpty,
            "Shared-lock source enumeration and receiver scans wait until both cloud ledger turns finish")
        store.personalLibrary!.drive.hold = false; store.personalLibrary!.iCloudDrive.hold = false
        releaseDiscovery.signal()
        try await eventually { store.hasLibrarySnapshot && store.receivedSegmentIDs == [old.id, new.id] }
        try check(store.personalLibrary!.drive.discovered == [old.id, new.id]
            && store.personalLibrary!.iCloudDrive.discovered == [old.id, new.id],
            "New receipt metadata still reaches both cloud queues during their parent opportunity")
        try check(store.hasLibrarySnapshot && store.receivedSegmentIDs == [old.id, new.id]
            && PhoneBackgroundSync.noteCount == generation + 1, "New metadata updates cache and invalidates an older empty background completion once")
        try check(outcome.values.isEmpty, "Slow automatic delivery cannot prevent both independent cloud tasks from starting")
        try check(store.personalLibrary!.iCloudDrive.systemPermits == [true] && store.personalLibrary!.drive.systemPermits == [true], "Only the actual BG task supplies both cloud workers system-granted execution permission")
        try await eventually { !store.automaticDelivery!.prepared.isEmpty }
        try check(store.automaticDelivery!.prepared[0] == [old.id, new.id],
            "Receiver preparation still receives the refreshed durable receipt snapshot")
        store.automaticDelivery!.hold = false
        try await eventually { !outcome.values.isEmpty }
        try check(outcome.values.count == 1 && outcome.values[0].0 && outcome.values[0].1,
            "Provider pending preserves needsMore even after all bounded preparations succeed")
        try check(repo.readCount == 1 && AutomaticDeliveryBackgroundEvents.shared.active.isEmpty,
            "Exactly one metadata snapshot is read and its processing registration is released")
        repo.duringRead = nil
        let unchanged = Outcome(), unchangedGeneration = PhoneBackgroundSync.noteCount
        store.personalLibrary!.iCloudDrive.hasPendingWork = false
        store.performBackgroundSync(cancellation: PhoneBackgroundCancellation(), completion: unchanged.append)
        store.connectivity!.finish(); try await eventually { !unchanged.values.isEmpty }
        try check(PhoneBackgroundSync.noteCount == unchangedGeneration && unchanged.values[0].0 && !unchanged.values[0].1,
            "An unchanged truly settled pass can complete without self-invalidating its generation")
        try await verifyFailure(cancelBeforeCallback: true, cancelDuringRead: false, metadataFailure: false)
        try await verifyFailure(cancelBeforeCallback: false, cancelDuringRead: true, metadataFailure: false)
        try await verifyFailure(cancelBeforeCallback: false, cancelDuringRead: false, metadataFailure: true)
        print("PASS Store production foreground observation and background handoff assertions=\(assertions); device=false audio=false cloud=false")
    }
    @MainActor static func verifyFailure(cancelBeforeCallback: Bool, cancelDuringRead: Bool, metadataFailure: Bool) async throws {
        let repo = RecordingRepository([]), store = StoreProbe(repo), cancellation = PhoneBackgroundCancellation(), outcome = Outcome()
        repo.failure = metadataFailure
        if cancelDuringRead { repo.duringRead = { cancellation.cancel() } }
        store.performBackgroundSync(cancellation: cancellation, completion: outcome.append)
        if cancelBeforeCallback { cancellation.cancel() }
        store.connectivity!.finish(); try await eventually { !outcome.values.isEmpty }
        try check(!outcome.values[0].0 && outcome.values[0].1,
            "Cancellation or metadata failure cannot invent a successful empty handoff")
        if cancelBeforeCallback {
            try check(store.personalLibrary!.drive.prepared.isEmpty && store.personalLibrary!.iCloudDrive.prepared.isEmpty,
                "Cloud preparation cannot begin after parent cancellation")
        }
        try check(!store.hasLibrarySnapshot && AutomaticDeliveryBackgroundEvents.shared.active.isEmpty,
            "Failed discovery leaves no fake snapshot and balances processing registration")
    }
}
