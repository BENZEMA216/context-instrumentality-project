import Foundation

/// Bounded metadata observations, never delivery authority. Recording bodies,
/// names, paths, account information and NSError text have no fields here.
/// The delegate records time on its own thread; persistence never hops to main.
public final class PhoneTransferPhaseDiagnostics: @unchecked Sendable {
    public static let maximumBytes = 262_144
    public static let maximumPhoneReceives = 256
    public static let maximumWatchEvents = 512
    public static let fileName = "transfer-phases.json"

    struct Receive: Codable, Equatable {
        let segmentID: UUID
        let sessionID: UUID
        let byteCount: Int64
        var firstDelegateEnteredAtMS: Int64?
        var lastDelegateEnteredAtMS: Int64?
        var stagedAtMS: Int64?
        var durableReceiptAtMS: Int64?
        var durableObservedAtMS: Int64?
        var ackQueuedAtMS: Int64?
        var callbackCount = 0
    }
    struct Report: Codable {
        var schemaVersion = 1
        var role = "phone"
        var audioRead = false
        var includesAudio = false
        var build: String
        // Build names the current Phone projection writer. Retained phase
        // observations can predate an upgrade and never claim that new build.
        var historyIncludesEarlierBuilds = false
        var generatedAtMS: Int64 = 0
        var omittedPhoneReceiveCount = 0
        var omittedWatchEventCount = 0
        var writeFailureCount = 0
        var invalidManifestCallbackCount = 0
        var phoneReceives: [Receive] = []
        var watchEvents: [WatchTransferDiagnostic] = []
        var watchRuntime: WatchRuntimeObservation?
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "WristRecord.phone.transfer-phases", qos: .utility)
    private let writer: (Data) throws -> Void
    private var report: Report
    // Existing digest metadata is used only in memory to bind ACK observations.
    // A restart without a fresh durable observation leaves ACK time unknown.
    private var receiptBindings: [UUID: SegmentReceipt] = [:]
    private var pending = false
    private var running = false

    public convenience init(root: URL) {
        let directory = root.appendingPathComponent("ConnectivityDiagnostics", isDirectory: true)
        let target = directory.appendingPathComponent(Self.fileName)
        let restored: Data?
        if let attributes = try? FileManager.default.attributesOfItem(atPath: target.path),
           attributes[.type] as? FileAttributeType == .typeRegular,
           let size = attributes[.size] as? NSNumber, size.intValue > 0,
           size.intValue <= Self.maximumBytes {
            restored = try? Data(contentsOf: target)
        } else { restored = nil }
        self.init(build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                  restored: restored, writer: { bytes in
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            #if os(iOS) || os(watchOS)
            try bytes.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try bytes.write(to: target, options: .atomic)
            #endif
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        })
    }

    init(build: String, restored: Data? = nil, writer: @escaping (Data) throws -> Void) {
        self.writer = writer
        let safeBuild = !build.isEmpty && build.utf8.count <= 20
            && build.utf8.allSatisfy({ (48...57).contains($0) }) ? build : "unknown"
        report = Report(build: safeBuild)
        if let restored, restored.count <= Self.maximumBytes,
           let previous = try? JSONDecoder().decode(Report.self, from: restored),
           previous.schemaVersion == 1, previous.role == "phone",
           !previous.audioRead, !previous.includesAudio,
           previous.phoneReceives.count <= Self.maximumPhoneReceives,
           previous.watchEvents.count <= Self.maximumWatchEvents,
           previous.omittedPhoneReceiveCount >= 0, previous.omittedWatchEventCount >= 0,
           previous.writeFailureCount >= 0, previous.invalidManifestCallbackCount >= 0,
           previous.phoneReceives.allSatisfy({ $0.byteCount > 0 && $0.callbackCount >= 0 }),
           previous.watchEvents.allSatisfy(Self.validWatchDiagnostic) {
            report = previous
            if report.watchRuntime?.isValid == false { report.watchRuntime = nil }
            report.historyIncludesEarlierBuilds = previous.historyIncludesEarlierBuilds || previous.build != safeBuild
            report.build = safeBuild
            sortWatchObservations()
        }
    }

    public func recordDelegateEntered(manifest: SegmentManifest?, at: Date = Date()) {
        mutate(at: at) {
            guard let manifest, (try? RecordingRepository.validateManifest(manifest)) != nil else {
                increment(&report.invalidManifestCallbackCount); return
            }
            let index = receiveIndex(manifest)
            let time = Self.ms(at)
            if report.phoneReceives[index].firstDelegateEnteredAtMS == nil {
                report.phoneReceives[index].firstDelegateEnteredAtMS = time
            }
            report.phoneReceives[index].lastDelegateEnteredAtMS = time
            increment(&report.phoneReceives[index].callbackCount)
        }
    }

    public func recordStaged(manifest: SegmentManifest, at: Date = Date()) {
        guard (try? RecordingRepository.validateManifest(manifest)) != nil else { return }
        mutate(at: at) {
            let index = receiveIndex(manifest)
            if report.phoneReceives[index].stagedAtMS == nil { report.phoneReceives[index].stagedAtMS = Self.ms(at) }
        }
    }

    public func recordDurableReceipt(manifest: SegmentManifest, receipt: SegmentReceipt, at: Date = Date()) {
        guard (try? RecordingRepository.validateManifest(manifest)) != nil,
              manifest.id == receipt.segmentID, manifest.sha256 == receipt.sha256,
              manifest.byteCount == receipt.byteCount, receipt.byteCount > 0 else { return }
        mutate(at: at) {
            let index = receiveIndex(manifest)
            receiptBindings[manifest.id] = receipt
            if report.phoneReceives[index].durableReceiptAtMS == nil {
                report.phoneReceives[index].durableReceiptAtMS = Self.ms(receipt.receivedAt)
                report.phoneReceives[index].durableObservedAtMS = Self.ms(at)
            }
        }
    }

    public func recordACKQueued(receipt: SegmentReceipt, at: Date = Date()) {
        mutate(at: at) {
            guard receiptBindings[receipt.segmentID] == receipt else { return }
            let matching = report.phoneReceives.indices.filter {
                let row = report.phoneReceives[$0]
                return row.segmentID == receipt.segmentID && row.byteCount == receipt.byteCount
                    && row.durableReceiptAtMS == Self.ms(receipt.receivedAt)
            }
            // Ambiguous identity is unknown, never a made-up phase association.
            guard matching.count == 1, let index = matching.first,
                  report.phoneReceives[index].ackQueuedAtMS == nil else { return }
            report.phoneReceives[index].ackQueuedAtMS = Self.ms(at)
        }
    }

    public func recordWatchRuntime(_ data: Data) {
        guard let value = WatchRuntimeObservation.decode(data) else { return }
        mutateIfChanged(at: Date()) {
            if let previous = report.watchRuntime, !value.supersedes(previous) { return false }
            report.watchRuntime = value
            return true
        }
    }

    public func recordWatchEvent(_ event: RecordingEvent) {
        guard WatchDiagnosticTransferPolicy.mayTransfer(event),
              let value = WatchTransferDiagnostic.parse(event) else { return }
        mutateIfChanged(at: Date()) {
            guard !report.watchEvents.contains(value) else { return false }
            if let incoming = value.refusal, let index = report.watchEvents.firstIndex(where: {
                guard let prior = $0.refusal else { return false }
                return prior.processRunID == incoming.processRunID && prior.generation == incoming.generation
                    && prior.reason == incoming.reason && prior.foreground == incoming.foreground
                    && prior.liveCapture == incoming.liveCapture && prior.nativeCount == incoming.nativeCount
                    && prior.observedAtMS == incoming.observedAtMS
            }), let prior = report.watchEvents[index].refusal {
                // Snapshot counts are cumulative for this exact waiting state.
                // A late replay must neither add them again nor roll them back.
                let incomingCount = incoming.observationCount ?? 1, priorCount = prior.observationCount ?? 1
                let incomingLast = incoming.lastObservedAtMS ?? incoming.observedAtMS
                let priorLast = prior.lastObservedAtMS ?? prior.observedAtMS
                guard incomingCount >= priorCount, incomingLast >= priorLast,
                      incomingCount > priorCount || incomingLast > priorLast else { return false }
                report.watchEvents[index] = value
            } else {
                report.watchEvents.append(value)
            }
            // Late history must not evict a recent expiry/queue observation.
            // Keep oldest source time first so both count and byte caps discard
            // old evidence; receipt/ACK authority is independent of this list.
            sortWatchObservations()
            if report.watchEvents.count > Self.maximumWatchEvents {
                report.watchEvents.removeFirst()
                increment(&report.omittedWatchEventCount)
            }
            return true
        }
    }

    private func sortWatchObservations() {
        report.watchEvents = report.watchEvents.enumerated().sorted {
            let lhs = $0.element.latestObservedAtMS, rhs = $1.element.latestObservedAtMS
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }.map(\.element)
    }

    private func receiveIndex(_ manifest: SegmentManifest) -> Int {
        if let index = report.phoneReceives.firstIndex(where: {
            $0.segmentID == manifest.id && $0.sessionID == manifest.sessionID && $0.byteCount == manifest.byteCount
        }) { return index }
        if report.phoneReceives.count == Self.maximumPhoneReceives {
            receiptBindings.removeValue(forKey: report.phoneReceives.removeFirst().segmentID)
            increment(&report.omittedPhoneReceiveCount)
        }
        report.phoneReceives.append(Receive(segmentID: manifest.id, sessionID: manifest.sessionID, byteCount: manifest.byteCount))
        return report.phoneReceives.count - 1
    }

    private func mutate(at: Date, _ body: () -> Void) {
        mutateIfChanged(at: at) { body(); return true }
    }

    private func mutateIfChanged(at: Date, _ body: () -> Bool) {
        lock.lock()
        guard body() else { lock.unlock(); return }
        report.generatedAtMS = Self.ms(at)
        pending = true
        if !running {
            running = true
            queue.async { [self] in persistPending() }
        }
        lock.unlock()
    }

    private func persistPending() {
        while true {
            lock.lock()
            guard pending else { running = false; lock.unlock(); return }
            pending = false
            do {
                var bytes = try JSONEncoder().encode(report)
                while bytes.count > Self.maximumBytes && !report.watchEvents.isEmpty {
                    report.watchEvents.removeFirst(); increment(&report.omittedWatchEventCount)
                    bytes = try JSONEncoder().encode(report)
                }
                guard bytes.count <= Self.maximumBytes else { throw POSIXError(.EFBIG) }
                lock.unlock()
                do { try writer(bytes) }
                catch { lock.lock(); increment(&report.writeFailureCount); lock.unlock() }
            } catch {
                increment(&report.writeFailureCount)
                lock.unlock()
            }
        }
    }

    func drain() { queue.sync {} }
    func snapshot() -> Report { lock.lock(); defer { lock.unlock() }; return report }
    private static func validWatchDiagnostic(_ value: WatchTransferDiagnostic) -> Bool {
        let detail: String?
        switch value.kind {
        case "watch.transfer_attempt":
            guard value.refusal == nil, value.opportunity == nil else { return false }
            detail = value.attempt?.detail()
        case "watch.transfer_refusal":
            guard value.attempt == nil, value.opportunity == nil else { return false }
            detail = value.refusal?.detail()
        case "watch.transfer_opportunity":
            guard value.attempt == nil, value.refusal == nil else { return false }
            detail = value.opportunity?.detail()
        default: return false
        }
        guard let detail else { return false }
        let event = RecordingEvent(kind: value.kind, detail: detail)
        return WatchDiagnosticTransferPolicy.mayTransfer(event) && WatchTransferDiagnostic.parse(event) == value
    }
    private func increment(_ value: inout Int) { if value < Int.max { value += 1 } }
    private static func ms(_ date: Date) -> Int64 {
        let value = date.timeIntervalSince1970 * 1_000
        guard value.isFinite, value >= 0, value < Double(Int64.max) else { return 0 }
        return Int64(value.rounded(.down))
    }
}
