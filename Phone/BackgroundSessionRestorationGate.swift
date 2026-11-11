import Foundation

struct BackgroundSessionEvent: Sendable {
    let identifier: String
    let token: UUID?
}

/// Delegate ingress and UIKit handoff run on different executors. Capture the
/// token before any actor hop or persistence wait, and remember only ambiguity,
/// never an old drain that could fulfill a future system completion.
final class BackgroundSessionEventTracker: @unchecked Sendable {
    static let shared = BackgroundSessionEventTracker()
    private let lock = NSLock()
    private var current: [String: UUID] = [:]
    private var unclaimed = Set<String>()

    func arm(_ identifier: String) -> UUID {
        lock.lock(); defer { lock.unlock() }
        if let token = current[identifier] { return token }
        let token = UUID(); current[identifier] = token; return token
    }
    func capture(_ identifier: String) -> BackgroundSessionEvent {
        lock.lock(); defer { lock.unlock() }
        let token = current[identifier]
        if token == nil { unclaimed.insert(identifier) }
        return .init(identifier: identifier, token: token)
    }
    func needsInvalidation(_ identifier: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; return unclaimed.contains(identifier)
    }
    func markAmbiguous(_ identifier: String) {
        lock.lock(); unclaimed.insert(identifier); lock.unlock()
    }
    func matches(_ identifier: String, token: UUID?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return token != nil && current[identifier] == token
    }
    func complete(_ identifier: String, token: UUID, invalidated: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard current[identifier] == token else { return false }
        current.removeValue(forKey: identifier)
        if invalidated { unclaimed.remove(identifier) }
        return true
    }
}

@MainActor
final class BackgroundSessionRestorationGate {
    nonisolated let eventTracker: BackgroundSessionEventTracker
    private let isForeground: () -> Bool
    private let now: () -> TimeInterval
    private var restorers: [String: () -> Void] = [:]
    private var handlers: [String: [() -> Void]] = [:]
    private var handoffs: [String: UUID] = [:]
    private var processing: [UUID: (deadline: TimeInterval, cancelled: @Sendable () -> Bool)] = [:]
    private var registrationFinished = false
    private let diagnosticRun = String(UUID().uuidString.prefix(8)).lowercased()
    private var diagnosticHandler: ((String, String) -> Void)?
    private var pendingDiagnostics: [(String, String)] = []
    private var ownerOrdinals: [String: Int] = [:]
    private var waveOrdinals: [String: Int] = [:]
    private var waveStarted: [String: TimeInterval] = [:]
    private var nextOwner = 0
    private var nextWave = 0
    var invalidateUnrestorable: ((String) -> Void)?
    var restoreUnknown: ((String) -> Void)?

    init(isForeground: @escaping () -> Bool, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         eventTracker: BackgroundSessionEventTracker = .shared) {
        self.isForeground = isForeground; self.now = now; self.eventTracker = eventTracker
    }
    /// Aliases are random per process plus monotonic counters, never a hash or
    /// encoding of a session, account, source, or native handoff token.
    func setDiagnosticHandler(_ handler: @escaping (String, String) -> Void) {
        diagnosticHandler = handler
        let buffered = pendingDiagnostics; pendingDiagnostics.removeAll()
        buffered.forEach { handler($0.0, $0.1) }
    }
    private func diagnose(_ identifier: String, _ event: String, reason: String = "none", count: Int = 0) {
        recordDiagnostic(event, detail: diagnosticDetail(identifier, reason: reason, count: count))
    }
    private func diagnosticDetail(_ identifier: String, reason: String, count: Int) -> String {
        if ownerOrdinals[identifier] == nil { nextOwner += 1; ownerOrdinals[identifier] = nextOwner }
        let age = waveStarted[identifier].map { max(0, Int((now() - $0) * 1_000)) } ?? 0
        return "run=\(diagnosticRun) owner_seq=\(ownerOrdinals[identifier] ?? 0)"
            + " wave_seq=\(waveOrdinals[identifier] ?? 0) reason=\(reason) count=\(count) age_ms=\(age)"
    }
    private func recordDiagnostic(_ event: String, detail: String) {
        let kind = "phone.background_handoff_" + event
        if let diagnosticHandler { diagnosticHandler(kind, detail) }
        else {
            if pendingDiagnostics.count == 8 { pendingDiagnostics.removeFirst() }
            pendingDiagnostics.append((kind, detail))
        }
    }
    func canRestore(_ identifier: String) -> Bool {
        if isForeground() || hasPendingCompletion(identifier) { return true }
        let time = now()
        return processing.values.contains { $0.deadline > time && !$0.cancelled() }
    }
    func registerRestore(_ identifier: String, restore: @escaping () -> Void) {
        restorers[identifier] = restore
        if canRestore(identifier) { restore() }
    }
    func unregisterRestore(_ identifier: String) {
        restorers.removeValue(forKey: identifier)
        if registrationFinished && hasPendingCompletion(identifier) { restoreUnknown?(identifier) }
    }
    func finishRegistration() { registrationFinished = true; restorePermitted() }
    func restorePermitted() {
        for identifier in Array(restorers.keys) where canRestore(identifier) { restorers[identifier]?() }
        if registrationFinished {
            for identifier in Array(handlers.keys) where restorers[identifier] == nil { restoreUnknown?(identifier) }
        }
    }
    func beginProcessing(isCancelled: @escaping @Sendable () -> Bool) -> UUID {
        let token = UUID(); processing[token] = (now() + 120, isCancelled)
        restorePermitted(); return token
    }
    func endProcessing(_ token: UUID) { processing.removeValue(forKey: token) }
    func receive(_ identifier: String, completion: @escaping () -> Void) {
        // Arm before reconstruction. A cold session's first new event can then
        // identify this handler, even if its delegate fires synchronously.
        _ = eventTracker.arm(identifier)
        if !hasPendingCompletion(identifier) {
            nextWave += 1; waveOrdinals[identifier] = nextWave; waveStarted[identifier] = now()
        }
        handlers[identifier, default: []].append(completion)
        diagnose(identifier, "registered", count: handlers[identifier]?.count ?? 0)
        if let restore = restorers[identifier] { restore() }
        else if registrationFinished { restoreUnknown?(identifier) }
    }
    func hasPendingCompletion(_ identifier: String) -> Bool { handlers[identifier]?.isEmpty == false }
    func requiresInvalidation(_ identifier: String) -> Bool { eventTracker.needsInvalidation(identifier) }
    func cancelUnrestorable(_ identifier: String) { invalidateUnrestorable?(identifier) }
    func beginHandoff(_ identifier: String) -> UUID {
        if let token = handoffs[identifier] { return token }
        let token = eventTracker.arm(identifier); handoffs[identifier] = token
        diagnose(identifier, "invalidation_wait_started")
        return token
    }
    /// Exact native invalidation plus its ordered local persistence is the only
    /// way to clear ambiguity. A previous unclaimed drain cannot complete it.
    func completeHandoff(_ identifier: String, token: UUID) {
        guard handoffs[identifier] == token,
              eventTracker.complete(identifier, token: token, invalidated: true) else {
            diagnose(identifier, "rejected", reason: "stale_invalidation"); return
        }
        handoffs.removeValue(forKey: identifier)
        diagnose(identifier, "invalidation_wait_finished")
        completeHandlers(identifier, reason: "native_invalidated")
    }
    func finish(_ identifier: String, token: UUID?) {
        guard hasPendingCompletion(identifier) else { diagnose(identifier, "rejected", reason: "no_handler"); return }
        guard handoffs[identifier] == nil else { diagnose(identifier, "rejected", reason: "invalidation_hold"); return }
        guard eventTracker.matches(identifier, token: token), !requiresInvalidation(identifier) else {
            eventTracker.markAmbiguous(identifier)
            diagnose(identifier, "rejected", reason: token == nil ? "unclaimed" : "stale_token")
            restorers[identifier]?()
            return
        }
        guard let token, eventTracker.complete(identifier, token: token, invalidated: false) else { return }
        diagnose(identifier, "fresh_drain")
        completeHandlers(identifier, reason: "fresh_drain")
    }
    private func completeHandlers(_ identifier: String, reason: String) {
        let completions = handlers.removeValue(forKey: identifier) ?? []
        let detail = diagnosticDetail(identifier, reason: reason, count: completions.count)
        waveStarted.removeValue(forKey: identifier)
        completions.forEach { $0() }
        if !completions.isEmpty { recordDiagnostic("completion_called", detail: detail) }
    }
}
