import Foundation

/// Byte counters from this grant's retained URLSession tasks; no audio or text.
public struct AutomaticDeliveryTransferProgress: Equatable, Sendable {
    public let deliveryID: UUID
    public let bytesSent: Int64
    public let bytesReceived: Int64
    public let attemptCount: Int?

    public init(deliveryID: UUID, bytesSent: Int64, bytesReceived: Int64, attemptCount: Int? = nil) {
        self.deliveryID = deliveryID
        self.bytesSent = bytesSent
        self.bytesReceived = bytesReceived
        self.attemptCount = attemptCount
    }
}

/// An existing system task is not evidence that bytes are still moving. Give a
/// newly scheduled background upload time to start, then watch both request and
/// response progress. The caller cancels only stalled tasks; the normal ordered
/// completion and durable ledger remain responsible for failure and retry.
public struct AutomaticDeliveryTransferLiveness: Sendable {
    public static let checkInterval: TimeInterval = 30
    public static let startTimeout: TimeInterval = 10 * 60
    public static let progressTimeout: TimeInterval = 2 * 60
    public static let resourceTimeout: TimeInterval = 15 * 60

    private struct Observation: Sendable {
        var progress: AutomaticDeliveryTransferProgress
        var lastProgressAt: Date
        var cancellationRequested = false
    }
    private var observations: [UUID: Observation] = [:]

    public init() {}

    public mutating func forget(_ deliveryID: UUID) {
        observations.removeValue(forKey: deliveryID)
    }

    public mutating func stalledDeliveryIDs(transfers: [AutomaticDeliveryTransferProgress],
                                           registeredAt: [UUID: Date], now: Date = Date()) -> Set<UUID> {
        let active = Set(transfers.map(\.deliveryID))
        observations = observations.filter { active.contains($0.key) }
        var stalled: Set<UUID> = []
        for progress in transfers {
            guard let registration = registeredAt[progress.deliveryID],
                  progress.bytesSent >= 0, progress.bytesReceived >= 0 else { continue }
            let hasStarted = progress.bytesSent > 0 || progress.bytesReceived > 0
            var observation = observations[progress.deliveryID] ?? Observation(progress: progress,
                lastProgressAt: hasStarted ? now : min(now, registration))
            if observation.progress != progress || now < observation.lastProgressAt {
                // A lower counter is a replacement task, and clock rollback must
                // never make a fresh/progressing attempt look stalled.
                observation.progress = progress
                observation.lastProgressAt = now
                observation.cancellationRequested = false
            }
            let timeout = hasStarted ? Self.progressTimeout : Self.startTimeout
            if !observation.cancellationRequested,
               now.timeIntervalSince(observation.lastProgressAt) >= timeout {
                stalled.insert(progress.deliveryID)
                observation.cancellationRequested = true
            }
            observations[progress.deliveryID] = observation
        }
        return stalled
    }
}
