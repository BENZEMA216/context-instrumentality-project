import Foundation

/// Background delivery and immediate wake opportunities have separate cooldowns.
/// A queued system message must not suppress an immediate delivery attempt.
public struct BackgroundReceiptRequestPolicy: Sendable {
    public static let interval: TimeInterval = 5 * 60
    private var lastBackgroundRequestUptime: TimeInterval?
    private var lastImmediateRequestUptime: TimeInterval?

    public init() {}

    /// alreadyQueued must match the current request identity. An old head or a
    /// legacy request cannot indefinitely suppress a different exact target.
    public mutating func beginBackgroundRequest(hasPendingSegments: Bool, alreadyQueued: Bool,
                                                uptime: TimeInterval) -> Bool {
        guard hasPendingSegments, !alreadyQueued else { return false }
        return Self.beginAttempt(lastUptime: &lastBackgroundRequestUptime, uptime: uptime)
    }

    public mutating func beginImmediateRequest(hasPendingSegments: Bool, activated: Bool,
                                               reachable: Bool, uptime: TimeInterval) -> Bool {
        // Unreachable is not an attempt and does not start the cooldown, so the
        // next reachable wake can send. A message actually handed to the
        // session, including one that later fails, still consumes the cooldown.
        guard hasPendingSegments, activated, reachable else { return false }
        return Self.beginAttempt(lastUptime: &lastImmediateRequestUptime, uptime: uptime)
    }

    private static func beginAttempt(lastUptime: inout TimeInterval?, uptime: TimeInterval) -> Bool {
        guard uptime.isFinite, uptime >= 0 else { return false }
        if let previous = lastUptime {
            if uptime < previous {
                // Re-anchor a discontinuous clock without producing a burst.
                lastUptime = uptime
                return false
            }
            guard uptime - previous >= Self.interval else { return false }
        }
        lastUptime = uptime
        return true
    }
}
