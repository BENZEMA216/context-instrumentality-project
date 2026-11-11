import Foundation

/// Only failures known to come from the transport may use an opportunity probe.
/// HTTP throttling/server replies and historical unclassified failures retain
/// their original deadlines. This value contains no endpoint or credentials.
public enum GoogleDriveRetryFailureKind: String, Codable, Sendable {
    case recoverableNetwork, other

    public static let recoveryCooldown: TimeInterval = 60

    public static func classify(errorDomain: String, code: Int) -> Self {
        guard errorDomain == NSURLErrorDomain else { return .other }
        switch code {
        case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
             NSURLErrorTimedOut, NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost,
             NSURLErrorDNSLookupFailed, NSURLErrorSecureConnectionFailed,
             NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff,
             NSURLErrorCallIsActive:
            return .recoverableNetwork
        default:
            // Cancellation, certificate/credential failures and malformed URLs
            // do not become network-recovery permission.
            return .other
        }
    }

    public static func cooldownElapsed(since previous: Date?, at now: Date) -> Bool {
        guard now.timeIntervalSince1970.isFinite else { return false }
        guard let previous else { return true }
        // A clock rollback conservatively keeps the cooldown in force.
        return now.timeIntervalSince(previous) >= recoveryCooldown
    }
}
