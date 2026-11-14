import Foundation

/// A disposable, bounded metadata projection. Never writes to the recording event
/// journal and never participates in recording durability or transfer ownership.
public final class WatchTransferDiagnosticStore: @unchecked Sendable {
    public static let maximumEvents = 256
    public static let maximumBytes = 256 * 1_024
    public struct Statistics: Equatable, Sendable {
        public let eventCount: Int
        public let readCount: Int
        public let writeCount: Int
        public let persistedBytes: Int
    }
    private struct Snapshot: Codable {
        let version: Int
        let events: [RecordingEvent]
    }
    private let lock = NSLock()
    private let clock: () -> Date
    private let directory: URL
    private let file: URL
    private var current: [RecordingEvent] = []
    private var published: [RecordingEvent] = []
    private var dirty = false
    private var writable = true
    private var lastWriteAttempt: Date?
    private var reads = 0
    private var writes = 0
    private var bytes = 0

    public init(root: URL, clock: @escaping () -> Date = { Date() }) {
        self.clock = clock
        directory = root.appendingPathComponent("ConnectivityDiagnostics", isDirectory: true)
        file = directory.appendingPathComponent("watch-transfer-v1.json")
        restore()
    }

    public var statistics: Statistics {
        lock.lock(); defer { lock.unlock() }
        return Statistics(eventCount: current.count, readCount: reads, writeCount: writes, persistedBytes: bytes)
    }

    public func record(_ event: RecordingEvent) {
        lock.lock(); defer { lock.unlock() }
        guard let value = WatchTransferDiagnostic.parse(event) else { return }
        var immediate = true
        if let refusal = value.refusal {
            let key = refusalKey(refusal)
            if let index = current.firstIndex(where: {
                guard let other = WatchTransferDiagnostic.parse($0)?.refusal else { return false }
                return refusalKey(other) == key
            }), let previous = WatchTransferDiagnostic.parse(current[index])?.refusal {
                let count = previous.observationCount ?? 1
                let merged = WatchTransferRefusalDiagnostic(reason: previous.reason,
                    observedAtMS: previous.observedAtMS, generation: previous.generation,
                    foreground: previous.foreground, liveCapture: previous.liveCapture,
                    nativeCount: previous.nativeCount, processRunID: previous.processRunID,
                    observationCount: count == Int.max ? count : count + 1,
                    lastObservedAtMS: max(previous.lastObservedAtMS ?? previous.observedAtMS,
                                          refusal.lastObservedAtMS ?? refusal.observedAtMS))
                guard let detail = merged.detail() else { return }
                current[index] = RecordingEvent(kind: event.kind, detail: detail, timestamp: event.timestamp)
                immediate = false
            } else {
                current.append(event)
            }
        } else if let attempt = value.attempt, attempt.phase == .progress {
            if let index = current.firstIndex(where: {
                guard let other = WatchTransferDiagnostic.parse($0)?.attempt else { return false }
                return other.phase == .progress && other.attemptID == attempt.attemptID
                    && other.processRunID == attempt.processRunID
            }), let previous = WatchTransferDiagnostic.parse(current[index])?.attempt {
                if unchangedProgress(previous, attempt) {
                    // An actual observation is a chance to flush pending refusal
                    // counts, but unchanged native progress never creates a revision.
                    publishIfNeeded(immediate: false)
                    return
                }
                current[index] = event
                immediate = false
            } else {
                current.append(event)
            }
        } else {
            guard !current.contains(where: { $0.id == event.id }) else { return }
            current.append(event)
        }
        if current.count > Self.maximumEvents {
            current = orderedByObservation(current)
            current.removeFirst(current.count - Self.maximumEvents)
        }
        dirty = true
        publishIfNeeded(immediate: immediate)
    }

    /// Replays only published revisions already in memory. Reading a batch does
    /// not enumerate or read any recording journal directory or snapshot file.
    public func events(excluding: Set<UUID> = [], limit: Int = 30) -> [RecordingEvent] {
        lock.lock(); defer { lock.unlock() }
        let count = max(0, min(limit, Self.maximumEvents))
        guard count > 0 else { return [] }
        let eligible = published.filter { !excluding.contains($0.id) }
        // The all-members call only builds an identity set; avoid decoding or
        // sorting when no member needs to wait for a later batch.
        guard eligible.count > count else { return eligible }
        return Array(orderedByObservation(eligible).suffix(count).reversed())
    }

    private func orderedByObservation(_ events: [RecordingEvent]) -> [RecordingEvent] {
        var values: [(index: Int, event: RecordingEvent, time: Int64)] = []
        for (index, event) in events.enumerated() {
            values.append((index, event, WatchTransferDiagnostic.parse(event)?.latestObservedAtMS ?? 0))
        }
        values.sort { $0.time == $1.time ? $0.index < $1.index : $0.time < $1.time }
        return values.map(\.event)
    }

    private func refusalKey(_ value: WatchTransferRefusalDiagnostic) -> String {
        WatchTransferRefusalDiagnostic(reason: value.reason, observedAtMS: 1,
            generation: value.generation, foreground: value.foreground, liveCapture: value.liveCapture,
            nativeCount: value.nativeCount, processRunID: value.processRunID).detailKey
    }

    private func unchangedProgress(_ lhs: WatchTransferAttemptDiagnostic, _ rhs: WatchTransferAttemptDiagnostic) -> Bool {
        lhs.segmentID == rhs.segmentID && lhs.sourceCategory == rhs.sourceCategory && lhs.protection == rhs.protection
            && lhs.enqueuedAtMS == rhs.enqueuedAtMS && lhs.generation == rhs.generation
            && lhs.foreground == rhs.foreground && lhs.liveCapture == rhs.liveCapture
            && lhs.completed == rhs.completed && lhs.total == rhs.total && lhs.outcome == rhs.outcome
    }

    private func publishIfNeeded(immediate: Bool) {
        guard dirty, writable else { return }
        let now = clock()
        guard immediate || lastWriteAttempt.map({ now.timeIntervalSince($0) >= 60 }) ?? true else { return }
        lastWriteAttempt = now
        do {
            guard try safeLocation() else { writable = false; return }
            let fm = FileManager.default
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            var data = try JSONEncoder().encode(Snapshot(version: 1, events: current))
            if data.count > Self.maximumBytes { current = orderedByObservation(current) }
            while data.count > Self.maximumBytes && !current.isEmpty {
                current.removeFirst()
                data = try JSONEncoder().encode(Snapshot(version: 1, events: current))
            }
            // This best-effort projection intentionally adds no fsync barriers to
            // the capture/transfer critical path. Atomic replacement is sufficient.
            #if os(iOS) || os(watchOS)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: file, options: .atomic)
            #endif
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            published = current
            dirty = false
            writes += 1
            bytes = data.count
        } catch {
            // Business work continues. Existing published evidence stays intact;
            // later real observations may retry with the same bounded snapshot.
        }
    }

    private func safeLocation() throws -> Bool {
        if let attributes = try RecordingMetadataAccess.attributesIfPresent(at: directory),
           attributes[.type] as? FileAttributeType != .typeDirectory { return false }
        if let attributes = try RecordingMetadataAccess.attributesIfPresent(at: file),
           attributes[.type] as? FileAttributeType != .typeRegular { return false }
        return true
    }

    private func restore() {
        do {
            guard try safeLocation() else { writable = false; return }
            guard let data = try RecordingMetadataAccess.readIfPresent(at: file, maximumBytes: Self.maximumBytes) else { return }
            reads += 1
            guard data.count <= Self.maximumBytes,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == ["version", "events"],
                  let rawEvents = object["events"] as? [[String: Any]],
                  rawEvents.allSatisfy({ Set($0.keys).isSubset(of: ["id", "timestamp", "sessionID", "kind", "detail", "intervalStart", "intervalEnd"]) }) else {
                writable = false; return
            }
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            guard snapshot.version == 1, snapshot.events.count <= Self.maximumEvents,
                  Set(snapshot.events.map(\.id)).count == snapshot.events.count,
                  snapshot.events.allSatisfy({ WatchTransferDiagnostic.parse($0) != nil }) else { writable = false; return }
            current = snapshot.events
            published = snapshot.events
            bytes = data.count
            lastWriteAttempt = clock()
        } catch {
            // Preserve malformed/unsupported evidence rather than overwriting it.
            writable = false
        }
    }
}

private extension WatchTransferRefusalDiagnostic {
    var detailKey: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(data: (try? encoder.encode(self)) ?? Data(), encoding: .utf8) ?? ""
    }
}
