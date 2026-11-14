/// Resolves overlapping SwiftUI and WatchKit lifecycle inputs without granting
/// foreground maintenance from a background callback. It performs no I/O.
public struct WatchLifecyclePolicy: Sendable {
    public enum Phase: String, Codable, Sendable { case active, inactive, background, unknown }
    public enum Source: String, Codable, Sendable {
        case scene, delegateDidBecomeActive, delegateWillResignActive, delegateDidEnterBackground
    }
    public enum Action: String, Codable, Sendable { case none, enterForeground, leaveForeground }
    public enum Disposition: String, Codable, Sendable {
        case applied, duplicate, sceneStateMismatch, awaitingActiveEdge, delegateStateMismatch
    }
    public struct Decision: Codable, Equatable, Sendable {
        public let source: Source
        public let reportedPhase: Phase
        public let applicationPhase: Phase
        public let disposition: Disposition
        public let foreground: Bool
        public let action: Action
        public let forwardBackground: Bool
    }

    public private(set) var isForeground = false
    private var resignBarrier = false
    private var backgroundDelivered = false

    public init() {}

    /// Sample `applicationPhase` synchronously when processing the callback.
    /// A resign callback precedes WatchKit's state change, so it is authoritative
    /// even while the sampled state is still active. A later scene.active must
    /// see an intervening nonactive state or a genuine active delegate edge.
    public mutating func observe(source: Source, phase: Phase, applicationPhase: Phase) -> Decision {
        if applicationPhase == .inactive || applicationPhase == .background { resignBarrier = false }
        var desiredForeground = isForeground
        var forwardBackground = false
        var disposition: Disposition = .applied
        switch source {
        case .scene:
            guard phase != .unknown, applicationPhase != .unknown else {
                desiredForeground = false
                disposition = .sceneStateMismatch
                break
            }
            // A late active scene can never retain permission once WatchKit
            // already reports nonactive. Conversely, a late inactive scene
            // cannot retire a currently active owner without a resign edge.
            if phase != applicationPhase {
                guard applicationPhase != .active else {
                    return decision(source, phase, applicationPhase, .sceneStateMismatch)
                }
                desiredForeground = false
                disposition = .sceneStateMismatch
                break
            }
            guard phase != .active || !resignBarrier else {
                return decision(source, phase, applicationPhase, .awaitingActiveEdge)
            }
            desiredForeground = phase == .active
        case .delegateDidBecomeActive:
            guard applicationPhase == .active else {
                desiredForeground = false
                disposition = .delegateStateMismatch
                break
            }
            resignBarrier = false
            desiredForeground = true
        case .delegateWillResignActive:
            resignBarrier = true
            desiredForeground = false
        case .delegateDidEnterBackground:
            resignBarrier = false
            desiredForeground = false
            forwardBackground = !backgroundDelivered
            backgroundDelivered = true
        }
        let action: Action = desiredForeground == isForeground ? .none
            : desiredForeground ? .enterForeground : .leaveForeground
        if disposition == .applied, action == .none, !forwardBackground { disposition = .duplicate }
        if action == .enterForeground { backgroundDelivered = false }
        isForeground = desiredForeground
        return Decision(source: source, reportedPhase: phase, applicationPhase: applicationPhase,
            disposition: disposition, foreground: isForeground, action: action,
            forwardBackground: forwardBackground)
    }

    private func decision(_ source: Source, _ phase: Phase, _ applicationPhase: Phase,
                          _ disposition: Disposition) -> Decision {
        Decision(source: source, reportedPhase: phase, applicationPhase: applicationPhase,
            disposition: disposition, foreground: isForeground, action: .none, forwardBackground: false)
    }
}
