// Appended to the temporary PhoneConnectivity.swift by verify.py so these
// wrappers exercise the production private helpers without changing their scope.

final class AutomaticSyncControlTestAccess {
    private let control: PhoneAutomaticSyncControl

    init(root: URL) {
        control = PhoneAutomaticSyncControl(root: root)
    }

    var needsRetry: Bool { control.needsRetry }

    func prepare(hasBacklog: Bool, now: Date) throws -> (id: UUID, payload: [String: Any])? {
        guard let plan = try control.prepare(hasBacklog: hasBacklog, now: now) else { return nil }
        return (id: plan.id, payload: plan.payload)
    }

    func localAttemptCompleted(contextAccepted: Bool, nativeQueued: Bool = true) throws {
        try control.localAttemptCompleted(contextAccepted: contextAccepted, nativeQueued: nativeQueued)
    }

    func nativeCompleted(requestID: UUID?, failed: Bool, now: Date) throws {
        try control.nativeCompleted(requestID: requestID, failed: failed, now: now)
    }
}

final class TransferProgressMetadataTestAccess {
    private let metadata: PhoneTransferProgressMetadata

    init(root: URL) {
        metadata = PhoneTransferProgressMetadata(root: root)
    }

    func setForeground(_ value: Bool) {
        metadata.setForeground(value, session: nil)
    }

    func controlEvent(_ kind: String, requestID: UUID?) {
        guard let value = PhoneTransferProgressMetadata.ControlKind(rawValue: kind) else {
            preconditionFailure("Unknown production control kind: \(kind)")
        }
        metadata.controlEvent(value, requestID: requestID)
    }

    func controlRetryPending(_ pending: Bool) {
        metadata.controlRetryPending(pending)
    }

    func controlError(_ error: Error) {
        metadata.controlError(error)
    }

    func backgroundSchedulerEvent(kind: String, detail: String) {
        metadata.backgroundSchedulerEvent(kind, detail: detail)
    }

    func incomingPersisted(_ receipt: SegmentReceipt, receiptWasPresent: Bool?) {
        metadata.incomingPersisted(receipt, receiptWasPresent: receiptWasPresent)
    }

    func receiptSent(_ receipt: SegmentReceipt, immediate: Bool) {
        metadata.receiptSent(receipt, immediate: immediate)
    }

    func nativeReceiptCompleted(_ receipt: SegmentReceipt, succeeded: Bool) {
        metadata.nativeReceiptCompleted(receipt, succeeded: succeeded)
    }

    func drain(completion: @escaping @Sendable () -> Void) {
        metadata.probeDrain(completion: completion)
    }

    func publishMaximumCounterBoundary() {
        metadata.probeMaximumCounterBoundary()
    }
}

extension PhoneTransferProgressMetadata {
    fileprivate func probeDrain(completion: @escaping @Sendable () -> Void) {
        queue.async(flags: .barrier, execute: completion)
    }

    // Seed only in-memory observation metadata at its representable boundary;
    // the unchanged production encoder and atomic writer still publish it.
    fileprivate func probeMaximumCounterBoundary() {
        lock.lock(); defer { lock.unlock() }
        reportSequence = Int.max
        incomingPersistedCount = Int.max
        newIncomingCount = Int.max
        existingIncomingCount = Int.max
        unclassifiedIncomingCount = Int.max
        ackBackgroundEnqueuedCount = Int.max
        ackImmediateSentCount = Int.max
        ackNativeCompletedCount = Int.max
        ackNativeFailedCount = Int.max
        lastIncomingPersistedAtMS = Int64.max
        lastNewIncomingAtMS = Int64.max
        lastAckBackgroundEnqueuedAtMS = Int64.max
        lastAckImmediateSentAtMS = Int64.max
        lastAckNativeCompletedAtMS = Int64.max
        lastAckNativeFailedAtMS = Int64.max
        control.counts = control.counts.mapValues { _ in Int.max }
        control.lastAtMS = control.lastAtMS.mapValues { _ in Int64.max }
        control.lastErrorDomain = String(repeating: "\u{0}", count: 96)
        control.lastErrorCode = Int.min
        control.lastErrorAtMS = Int64.max
        backgroundScheduler.counts = backgroundScheduler.counts.mapValues { _ in Int.max }
        backgroundScheduler.lastAtMS = backgroundScheduler.lastAtMS.mapValues { _ in Int64.max }
        recentEvents = recentEvents.map { Event(kind: .ackBackgroundEnqueued, observedAtMS: Int64.max,
            segmentID: $0.segmentID, sha256: $0.sha256, byteCount: Int64.max,
            receiptReceivedAtMS: Int64.max, receiptWasPresent: false) }
        enqueueLocked()
    }
}

extension PhoneConnectivity {
    // The event-directory reader is not a snapshot API. Observe test predicates
    // on the same owner queue as appendEvent, including any related queue files.
    func probeReadOnWork<T>(_ body: () throws -> T) rethrows -> T {
        try work.sync(execute: body)
    }

    func probeRequestWatchSync(sendImmediate: Bool = true, now: Date = Date()) {
        work.async { [self] in requestWatchSync(sendImmediate: sendImmediate, now: now) }
    }
}
