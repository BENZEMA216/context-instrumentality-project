import Foundation

/// A path observation is only a scheduling hint, never evidence of delivery.
public enum GoogleDriveNetworkPath: Equatable, Sendable {
    case unknown, unavailable, nonCellular, cellular
}

public struct GoogleDriveNetworkPolicy: Equatable, Sendable {
    public let allowsCellularAccess: Bool

    public init(allowsCellularAccess: Bool = false) {
        self.allowsCellularAccess = allowsCellularAccess
    }

    public func permits(_ path: GoogleDriveNetworkPath) -> Bool {
        switch path {
        case .unknown, .unavailable: return false
        case .nonCellular: return true
        case .cellular: return allowsCellularAccess
        }
    }

    public func isWaitingForWiFi(on path: GoogleDriveNetworkPath) -> Bool {
        path == .cellular && !allowsCellularAccess
    }
}

/// No migration write is needed: an absent key retains the historical Wi-Fi
/// policy. This preference does not contain or modify any recording grant.
public final class GoogleDriveNetworkSettings: @unchecked Sendable {
    public static let shared = GoogleDriveNetworkSettings()
    public static let defaultsKey = "GoogleDriveAllowsCellularAccess"
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public var allowsCellularAccess: Bool {
        defaults.object(forKey: Self.defaultsKey) as? Bool ?? false
    }

    public var policy: GoogleDriveNetworkPolicy {
        .init(allowsCellularAccess: allowsCellularAccess)
    }

    public func setAllowsCellularAccess(_ value: Bool) {
        defaults.set(value, forKey: Self.defaultsKey)
    }

    /// Pre-setting builds constrained only the session, leaving each original
    /// request at its permissive default. Upgrade that session only once it and
    /// its durable pipeline have completely drained, never while restoring it.
    public func nativeSessionUsesRequestPolicy(_ identifier: String) -> Bool {
        defaults.object(forKey: "GoogleDriveRequestNetworkPolicyV1." + identifier) as? Bool ?? false
    }

    public func markNativeSessionUsesRequestPolicy(_ identifier: String) {
        defaults.set(true, forKey: "GoogleDriveRequestNetworkPolicyV1." + identifier)
    }
}

/// The first snapshot is not a recovery. Repeated available snapshots cannot
/// produce new opportunities; the caller additionally owns retry cooldowns.
public struct GoogleDriveNetworkPathTransition: Sendable {
    private var previouslyPermitted: Bool?
    public init() {}

    public mutating func observe(_ path: GoogleDriveNetworkPath,
                                 policy: GoogleDriveNetworkPolicy) -> Bool {
        let permitted = policy.permits(path)
        let restored = previouslyPermitted == false && permitted
        previouslyPermitted = permitted
        return restored
    }
}
