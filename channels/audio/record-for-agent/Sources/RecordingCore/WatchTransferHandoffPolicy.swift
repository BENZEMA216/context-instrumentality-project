import Foundation

/// Admission limits for handing already sealed files to the system transport.
/// The caller supplies existing metadata; this policy performs no file access.
public struct WatchTransferHandoffPolicy: Equatable, Sendable {
    public enum Decision: String, Equatable, Sendable {
        case allowed, deadline, nativeCount, capacityUnknown, capacityReserve
        case invalidCandidate, candidateCapacity, unknownQueuedBytes, queuedBytes

        /// Refusing one candidate must not hide smaller healthy history behind
        /// a repeatedly selected newest/oldest candidate. Global limits still stop.
        public var stopsPass: Bool {
            switch self {
            case .invalidCandidate, .candidateCapacity, .queuedBytes: return false
            default: return self != .allowed
            }
        }
    }
    public let maximumOutstandingFiles: Int
    public let maximumQueuedBytes: Int64
    public let maximumPassDuration: TimeInterval = 2
    public let minimumAvailableCapacity: Int64 = 32 * 1_024 * 1_024

    public init(isCharging: Bool, sealedBacklog: Bool = false) {
        let expanded = isCharging || sealedBacklog
        maximumOutstandingFiles = expanded ? 12 : 3
        // Charging admits twelve sealed one-minute PCM files (about 11 MiB
        // each) instead of silently reducing the twelve-file window to five.
        // This is a disk-backed native queue, not an in-memory audio buffer.
        // Keep time, native-count, known-size and free-space checks unchanged.
        maximumQueuedBytes = (expanded ? 192 : 64) * 1_024 * 1_024
    }

    public func permits(candidateBytes: Int64, outstandingBytes: [Int64?],
                        elapsed: TimeInterval, availableCapacity: Int64?) -> Bool {
        decision(candidateBytes: candidateBytes, outstandingBytes: outstandingBytes,
            elapsed: elapsed, availableCapacity: availableCapacity) == .allowed
    }

    public func decision(candidateBytes: Int64, outstandingBytes: [Int64?],
                         elapsed: TimeInterval, availableCapacity: Int64?) -> Decision {
        guard elapsed.isFinite, elapsed >= 0, elapsed < maximumPassDuration else { return .deadline }
        guard outstandingBytes.count < maximumOutstandingFiles else { return .nativeCount }
        guard let availableCapacity else { return .capacityUnknown }
        guard availableCapacity >= minimumAvailableCapacity else { return .capacityReserve }
        guard candidateBytes > 0 else { return .invalidCandidate }
        let (requiredCapacity, capacityOverflow) = candidateBytes.multipliedReportingOverflow(by: 2)
        guard !capacityOverflow, availableCapacity >= requiredCapacity else { return .candidateCapacity }
        var total: Int64 = 0
        for bytes in outstandingBytes {
            guard let bytes, bytes > 0 else { return .unknownQueuedBytes }
            let (next, overflow) = total.addingReportingOverflow(bytes)
            guard !overflow else { return .unknownQueuedBytes }
            total = next
        }
        let (queuedAfterAdmission, overflow) = total.addingReportingOverflow(candidateBytes)
        guard !overflow else { return .queuedBytes }
        // An otherwise admissible large file can occupy an empty queue by itself;
        // requiring it to fit the normal aggregate limit would starve it forever.
        return queuedAfterAdmission <= maximumQueuedBytes || outstandingBytes.isEmpty ? .allowed : .queuedBytes
    }
}
