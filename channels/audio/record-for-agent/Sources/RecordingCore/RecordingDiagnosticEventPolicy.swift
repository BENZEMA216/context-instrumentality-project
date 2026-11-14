import Foundation

/// The default view is an explicitly partial observation, not a complete audit.
public struct RecordingDiagnosticEventSelection: Codable, Equatable, Sendable {
    public enum Scope: String, Codable, Sendable { case recent, fullHistory = "full_history" }
    public enum IndexSource: String, Codable, Sendable {
        case coldDirectoryMetadata = "cold_directory_metadata", warmInMemory = "warm_in_memory"
        case fullHistory = "full_history"
    }
    public enum SelectionBasis: String, Codable, Sendable {
        case fileModificationTime = "file_modification_time", allMetadataFiles = "all_metadata_files"
    }
    public let scope: Scope
    public let requestedStartAt: Date?
    public let requestedEndAt: Date?
    public let returnedEventCount: Int
    public let decodedFileCount: Int
    /// Nil for the legacy full-history reader, which does not collect byte accounting.
    public let eventBytesRead: Int?
    public let totalEventFileCount: Int?
    public let omittedEventFileCount: Int?
    public let truncated: Bool
    public let historyCoverageKnown: Bool
    public let candidateLimitReached: Bool
    public let byteLimitReached: Bool
    public let eventLimitReached: Bool
    public let metadataEnumerationLimitReached: Bool
    public let indexSource: IndexSource
    public let selectionBasis: SelectionBasis
    public let inspectedDirectoryEntryCount: Int
    public let invalidMetadataFileCount: Int
    /// Candidate mtime selection cannot establish complete business-time coverage.
    public let candidateMetadataStable: Bool
    public let maximumCandidateCount: Int
    public let maximumEventBytes: Int
    public let faultKindRuleVersion: Int
    public let recognizedFaultCandidateCount: Int
    public let recognizedFaultsIncludedCount: Int
    public let faultContextEventCount: Int
    public let faultContextWindowSeconds: Int

    static func fullHistory(count: Int) -> Self {
        .init(scope: .fullHistory, requestedStartAt: nil, requestedEndAt: nil,
              returnedEventCount: count, decodedFileCount: count, eventBytesRead: nil,
              totalEventFileCount: count, omittedEventFileCount: 0, truncated: false,
              historyCoverageKnown: true, candidateLimitReached: false, byteLimitReached: false,
              eventLimitReached: false, metadataEnumerationLimitReached: false,
              indexSource: .fullHistory, selectionBasis: .allMetadataFiles,
              inspectedDirectoryEntryCount: count, invalidMetadataFileCount: 0,
              candidateMetadataStable: true, maximumCandidateCount: count, maximumEventBytes: 0,
              faultKindRuleVersion: 1, recognizedFaultCandidateCount: 0,
              recognizedFaultsIncludedCount: 0, faultContextEventCount: 0, faultContextWindowSeconds: 60)
    }
}

public struct RecordingDiagnosticEventSnapshot: Sendable {
    public let events: [RecordingEvent]
    public let eventSelection: RecordingDiagnosticEventSelection
}

/// No persisted index is maintained: appending an event still writes only its
/// existing event JSON. This small metadata cache is solely a diagnostic hint.
struct RecordingDiagnosticEventCandidate: Equatable {
    let name: String
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let byteCount: Int64
    let inode: UInt64

    func newer(than other: Self) -> Bool {
        if modifiedSeconds != other.modifiedSeconds { return modifiedSeconds > other.modifiedSeconds }
        if modifiedNanoseconds != other.modifiedNanoseconds { return modifiedNanoseconds > other.modifiedNanoseconds }
        return name > other.name
    }
}

struct RecordingDiagnosticEventDirectoryStamp: Equatable {
    let device: UInt64
    let inode: UInt64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
}

struct RecordingDiagnosticEventIndex {
    static let maximumCandidates = 2_000
    static let maximumDirectoryEntries = 100_000
    var stamp: RecordingDiagnosticEventDirectoryStamp
    var candidates: [RecordingDiagnosticEventCandidate]
    var totalEventFileCount: Int?
    var inspectedDirectoryEntryCount: Int
    var invalidMetadataFileCount: Int
    var enumerationLimited: Bool
    var stable: Bool

    mutating func noteAppend(_ candidate: RecordingDiagnosticEventCandidate,
                             stamp nextStamp: RecordingDiagnosticEventDirectoryStamp) {
        candidates.append(candidate)
        candidates.sort { $0.newer(than: $1) }
        if candidates.count > Self.maximumCandidates { candidates.removeLast() }
        totalEventFileCount = totalEventFileCount.map { $0 + 1 }
        inspectedDirectoryEntryCount += 1
        stamp = nextStamp
    }
}

/// Exact event kinds produced by capture/transfer code. Free text and suffix
/// matching never elevate a record to a fault or imply that recovery succeeded.
enum RecordingDiagnosticEventPolicy {
    static let maximumBytes = 2_097_152
    static let defaultCandidateCount = 1_000
    static let defaultEventCount = 500
    static let faultKinds: Set<String> = [
        "phone.error", "phone.ack_failed", "phone.watch_backlog_evidence_failed",
        "phone.drive_background_request_failed",
        "phone.old_sync_request_failed", "phone.bg_submit_failed", "capture_interrupted",
        "audio_gap", "recovered_unknown_interval", "watch_activation_failed",
        "file_transfer_callback_lookup_failed", "file_transfer_failed", "phone_receipt_request_failed",
        "event_transfer_failed", "file_retry_state_load_failed", "file_scheduling_state_load_failed",
        "file_sync_failed", "watch.background_refresh_state_failed", "file_retry_state_save_failed",
        "file_scheduling_state_save_failed", "phone_receipt_request_immediate_failed",
        "file_transfer_ack_check_failed"
    ]

    static func select(_ candidates: [RecordingEvent], limit: Int) -> (events: [RecordingEvent], faultCount: Int,
                                                                       includedFaultCount: Int, contextCount: Int) {
        let ordered = candidates.sorted { $0.timestamp == $1.timestamp
            ? $0.id.uuidString > $1.id.uuidString : $0.timestamp > $1.timestamp }
        let faults = ordered.filter { faultKinds.contains($0.kind) }
        let contextBudget = min(limit, max(1, limit / 5))
        // Reserve room for a trigger and its closest preceding/following
        // observation. Dense later noise cannot consume the entire allowance.
        let anchors = Array(faults.prefix(min(20, max(1, contextBudget / 3))))
        var selected = anchors
        var ids = Set(anchors.map(\.id))
        func include(_ event: RecordingEvent?) {
            guard selected.count < contextBudget, let event, !ids.contains(event.id) else { return }
            selected.append(event); ids.insert(event.id)
        }
        for anchor in anchors {
            include(ordered.first { !ids.contains($0.id) && $0.timestamp < anchor.timestamp &&
                anchor.timestamp.timeIntervalSince($0.timestamp) <= 60 })
            include(ordered.last { !ids.contains($0.id) && $0.timestamp > anchor.timestamp &&
                $0.timestamp.timeIntervalSince(anchor.timestamp) <= 60 })
        }
        var neighbours: [(event: RecordingEvent, distance: TimeInterval)] = []
        for event in ordered where !ids.contains(event.id) {
            let distance = anchors.map { abs($0.timestamp.timeIntervalSince(event.timestamp)) }.min() ?? .infinity
            if distance <= 60 { neighbours.append((event, distance)) }
        }
        neighbours.sort { lhs, rhs in
            if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }
            if lhs.event.timestamp != rhs.event.timestamp { return lhs.event.timestamp > rhs.event.timestamp }
            return lhs.event.id.uuidString > rhs.event.id.uuidString
        }
        for (event, _) in neighbours.prefix(max(0, contextBudget - selected.count)) {
            include(event)
        }
        let contextCount = selected.count
        for event in ordered where selected.count < limit && !ids.contains(event.id) {
            selected.append(event); ids.insert(event.id)
        }
        return (selected.sorted { $0.timestamp == $1.timestamp
            ? $0.id.uuidString < $1.id.uuidString : $0.timestamp < $1.timestamp },
                faults.count, selected.filter { faultKinds.contains($0.kind) }.count, contextCount)
    }
}

/// A bounded min-heap retains the newest metadata without materializing or
/// sorting every historical event body (or every filename) on a cold library.
struct RecordingDiagnosticEventCandidateHeap {
    var values: [RecordingDiagnosticEventCandidate] = []
    let limit: Int

    mutating func insert(_ candidate: RecordingDiagnosticEventCandidate) {
        if values.count < limit {
            values.append(candidate)
            var child = values.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard values[parent].newer(than: values[child]) else { break }
                values.swapAt(parent, child); child = parent
            }
        } else if let oldest = values.first, candidate.newer(than: oldest) {
            values[0] = candidate
            var parent = 0
            while parent * 2 + 1 < values.count {
                let left = parent * 2 + 1, right = left + 1
                let child = right < values.count && values[left].newer(than: values[right]) ? right : left
                guard values[parent].newer(than: values[child]) else { break }
                values.swapAt(parent, child); parent = child
            }
        }
    }
}
