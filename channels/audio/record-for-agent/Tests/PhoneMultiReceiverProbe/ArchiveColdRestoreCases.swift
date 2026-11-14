import Foundation
import RecordingCore

/// Holds actual transport enumeration, while queueing and persistence remain the
/// production Store. No replacement coordinator or queue algorithm is tested.
final class HeldArchiveEnumeration: AutomaticReceiverTransport, @unchecked Sendable {
    let base: ControlledTransport
    let recovery: DeliveryLeaseGate?
    let progress: DeliveryLeaseGate?
    private let lock = NSLock()
    private var recoveryClaimed = false
    private var progressClaimed = false
    init(_ base: ControlledTransport, recovery: DeliveryLeaseGate? = nil, progress: DeliveryLeaseGate? = nil) {
        self.base = base; self.recovery = recovery; self.progress = progress
    }
    var identifier: String { base.identifier }
    private func claim(_ isRecovery: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if isRecovery {
            guard !recoveryClaimed else { return false }; recoveryClaimed = true
        } else {
            guard !progressClaimed else { return false }; progressClaimed = true
        }
        return true
    }
    func activeDeliveryIDs() async -> Set<UUID> {
        if let recovery, claim(true) { _ = await recovery.acquire() }
        return await base.activeDeliveryIDs()
    }
    func activeTransfers() async -> [AutomaticDeliveryTransferProgress] {
        if let progress, claim(false) { _ = await progress.acquire() }
        return await base.activeTransfers()
    }
    func cancelTransfer(ifUnchanged value: AutomaticDeliveryTransferProgress) async -> Bool {
        await base.cancelTransfer(ifUnchanged: value)
    }
    func upload(deliveryID: UUID, attemptCount: Int, archiveURL: URL, sha256: String) throws {
        try base.upload(deliveryID: deliveryID, attemptCount: attemptCount, archiveURL: archiveURL, sha256: sha256)
    }
    func cancelAll() { base.cancelAll() }
    func cancelTransfers() async { await base.cancelTransfers() }
    func invalidateAndDrain() async { await base.invalidateAndDrain() }
}

extension Probe {
    @MainActor func executeArchiveColdRestoreCases() async {
        await run("archive_cold_live_wc_lease_materializes_future_and_uploads_without_handler") { f in
            let gate = BackgroundSessionRestorationGate(isForeground: { false }, eventTracker: .init())
            let payload = self.payload("archive-cold-live")
            let worker = try f.isolatedWorker(payload, restorationGate: gate,
                beginExecution: { _ in SyntheticDeliveryLease() })
            defer { worker.retire() }
            let source = try f.addRecording(0) // Arrives after includeFuture grant creation.
            worker.discover(manifests: [source], receivedSegmentIDs: [source.id])
            try await self.eventually("cold finite lease upload", { f.factory.all.first?.uploads.count == 1 })
            let ledger = try f.ledger(payload.receiverID)
            let identifier = f.factory.all[0].identifier
            try self.check(ledger.includeFuture && ledger.eligibleFutureIDs.contains(source.id)
                && ledger.authorizedIDs.contains(source.id) && ledger.jobs.count == 1,
                "A received future source must be durable before native registration")
            try self.check(!gate.canRestore(identifier) && !gate.hasPendingCompletion(identifier)
                && f.factory.all.count == 1 && f.factory.all[0].cancellationCount == 0,
                "Finite WC execution must not forge a parent token, handler, or second owner")
        }
        await run("archive_cold_nil_lease_reconciles_locally_without_native_permission") { f in
            let gate = BackgroundSessionRestorationGate(isForeground: { false }, eventTracker: .init())
            let payload = self.payload("archive-cold-nil")
            let worker = try f.isolatedWorker(payload, restorationGate: gate, beginExecution: { _ in nil })
            defer { worker.retire() }
            let source = try f.addRecording(0)
            worker.discover(manifests: [source], receivedSegmentIDs: [source.id])
            await worker.waitForPreparation()
            let ledger = try f.ledger(payload.receiverID)
            try self.check(ledger.authorizedIDs.contains(source.id) && ledger.jobs.count == 1,
                "The existing non-iOS nil-lease local policy must not depend on transport")
            try self.check(f.factory.all.isEmpty && !worker.preparationSucceeded && worker.hasPendingDelivery,
                "A nil test lease is not actual iOS permission to restore a cold session")
        }
        await run("archive_cold_denied_lease_changes_neither_queue_nor_native") { f in
            let gate = BackgroundSessionRestorationGate(isForeground: { false }, eventTracker: .init())
            let payload = self.payload("archive-cold-denied")
            let worker = try f.isolatedWorker(payload, restorationGate: gate,
                beginExecution: { _ in SyntheticDeliveryLease(permitted: false) })
            defer { worker.retire() }
            let source = try f.addRecording(0)
            worker.discover(manifests: [source], receivedSegmentIDs: [source.id])
            await worker.waitForPreparation()
            try self.check(try f.ledger(payload.receiverID).jobs.isEmpty,
                "Denied execution cannot materialize new authorization")
            try self.check(f.factory.all.isEmpty && !worker.preparationSucceeded && worker.hasPendingDelivery,
                "Denied execution leaves retryable local discovery without a native owner")
        }
        await run("archive_cold_enumeration_expiry_keeps_source_and_resumes_once") { f in
            let gate = BackgroundSessionRestorationGate(isForeground: { false }, eventTracker: .init())
            let held = DeliveryLeaseGate(), leases = DeliveryLeaseGate()
            let payload = self.payload("archive-cold-expiry")
            let factory = f.factory
            let worker = try f.isolatedWorker(payload, restorationGate: gate,
                clientFactory: { credentials, complete, finished in
                    let base = try factory.make(credentials, complete, finished) as! ControlledTransport
                    return HeldArchiveEnumeration(base, progress: held)
                }, beginExecution: { _ in await leases.acquire() })
            defer { worker.retire() }
            let source = try f.addRecording(0)
            worker.discover(manifests: [source], receivedSegmentIDs: [source.id])
            try await self.eventually("actual WC lease requested", { leases.count == 1 })
            let expired = SyntheticDeliveryLease(); leases.release(expired)
            try await self.eventually("native enumeration held", { held.count == 1 })
            expired.end(); held.release(SyntheticDeliveryLease())
            await worker.waitForPreparation()
            try self.check(f.factory.all.count == 1 && f.factory.all[0].uploads.isEmpty,
                "Enumeration returning after expiration cannot register an archive")
            try self.check(try f.ledger(payload.receiverID).authorizedIDs.contains(source.id),
                "Already reconciled source must remain durable on lease expiration")
            worker.resume()
            try await self.eventually("new actual opportunity requested", { leases.count == 1 })
            leases.release(SyntheticDeliveryLease())
            try await self.eventually("same native owner uploads once", { f.factory.all[0].uploads.count == 1 })
            try self.check(f.factory.all.count == 1, "A fresh opportunity reuses the existing exact session")
        }
        await run("archive_cold_enumeration_pause_blocks_late_registration") { f in
            let gate = BackgroundSessionRestorationGate(isForeground: { false }, eventTracker: .init())
            let held = DeliveryLeaseGate(), factory = f.factory
            let payload = self.payload("archive-cold-pause")
            let worker = try f.isolatedWorker(payload, restorationGate: gate,
                clientFactory: { credentials, complete, finished in
                    let base = try factory.make(credentials, complete, finished) as! ControlledTransport
                    return HeldArchiveEnumeration(base, progress: held)
                }, beginExecution: { _ in SyntheticDeliveryLease() })
            defer { worker.retire() }
            let source = try f.addRecording(0)
            worker.discover(manifests: [source], receivedSegmentIDs: [source.id])
            try await self.eventually("cold enumeration before pause", { held.count == 1 })
            worker.setEnabled(false); held.release(SyntheticDeliveryLease())
            try await self.settle()
            try self.check(!worker.isEnabled && f.factory.all.count == 1 && f.factory.all[0].uploads.isEmpty
                && f.factory.all[0].cancellationCount == 1,
                "Pause generation must fence held enumeration and cancel only its native owner")
            try self.check(try f.ledger(payload.receiverID).jobs.count == 1,
                "Pausing retains the received source and durable queued work")
        }
        await run("archive_cold_enumeration_retire_blocks_late_registration") { f in
            let gate = BackgroundSessionRestorationGate(isForeground: { false }, eventTracker: .init())
            let held = DeliveryLeaseGate(), factory = f.factory
            let payload = self.payload("archive-cold-retire")
            let worker = try f.isolatedWorker(payload, restorationGate: gate,
                clientFactory: { credentials, complete, finished in
                    let base = try factory.make(credentials, complete, finished) as! ControlledTransport
                    return HeldArchiveEnumeration(base, progress: held)
                }, beginExecution: { _ in SyntheticDeliveryLease() })
            let source = try f.addRecording(0)
            worker.discover(manifests: [source], receivedSegmentIDs: [source.id])
            try await self.eventually("cold enumeration before revoke", { held.count == 1 })
            worker.retire(); held.release(SyntheticDeliveryLease())
            try await self.settle()
            try self.check(!worker.isPaired && f.factory.all.count == 1 && f.factory.all[0].uploads.isEmpty,
                "Revoked scope cannot register from a late enumeration")
        }
        await run("archive_cold_factory_sync_pause_drains_unpublished_owner_before_resume") { f in
            let gate = BackgroundSessionRestorationGate(isForeground: { false }, eventTracker: .init())
            let factory = f.factory, payload = self.payload("archive-cold-factory-pause")
            var worker: PhoneReceiverDeliveryStore!
            var pauseOnCreate = true
            factory.holdNewInvalidation = true
            worker = try f.isolatedWorker(payload, restorationGate: gate,
                clientFactory: { credentials, complete, finished in
                    let base = try factory.make(credentials, complete, finished)
                    if pauseOnCreate { pauseOnCreate = false; worker.setEnabled(false) }
                    return base
                }, beginExecution: { _ in SyntheticDeliveryLease() })
            defer { worker.retire() }
            let source = try f.addRecording(0)
            worker.discover(manifests: [source], receivedSegmentIDs: [source.id])
            try await self.eventually("synchronous pause callback", { f.factory.all.count == 1 && !worker.isEnabled })
            try await self.eventually("unpublished native owner invalidating", { f.factory.all[0].cancellationCount == 1 })
            try self.check(f.factory.all[0].uploads.isEmpty && f.factory.all[0].cancellationCount == 1,
                "A factory callback changing generation must invalidate its unpublished transport")
            worker.setEnabled(true)
            try await self.settle()
            try self.check(f.factory.all.count == 1 && f.factory.all[0].uploads.isEmpty,
                "Resume cannot construct a same-identifier owner before the discarded session drains")
            f.factory.all[0].releaseInvalidation()
            try await self.eventually("new owner after unpublished drain", {
                f.factory.all.count == 2 && f.factory.all[1].uploads.count == 1
            })
            try self.check(f.factory.all[0].uploads.isEmpty,
                "Only the replacement owner can register the durable source")
        }
        await run("archive_cold_factory_sync_restore_has_single_owner") { f in
            let gate = BackgroundSessionRestorationGate(isForeground: { false }, eventTracker: .init())
            let factory = f.factory, payload = self.payload("archive-cold-factory-restore")
            var worker: PhoneReceiverDeliveryStore!, identifier = ""
            worker = try f.isolatedWorker(payload, restorationGate: gate,
                clientFactory: { credentials, complete, finished in
                    identifier = AutomaticReceiverClient.sessionIdentifier(for: credentials.scope)
                    _ = worker.restoreBackgroundSession(identifier)
                    return try factory.make(credentials, complete, finished)
                }, beginExecution: { _ in SyntheticDeliveryLease() })
            defer { worker.retire() }
            let source = try f.addRecording(0)
            worker.discover(manifests: [source], receivedSegmentIDs: [source.id])
            try await self.eventually("single factory owner upload", { f.factory.all.first?.uploads.count == 1 })
            try await self.settle()
            try self.check(f.factory.all.count == 1 && !gate.canRestore(identifier),
                "Synchronous restore callback must not create a duplicate session or processing permission")
        }
        await run("archive_cold_factory_sync_retire_retains_owner_until_late_handler_drain") { f in
            let gate = BackgroundSessionRestorationGate(isForeground: { false }, eventTracker: .init())
            let factory = f.factory, payload = self.payload("archive-cold-factory-retire")
            var worker: PhoneReceiverDeliveryStore!, unknown = 0, completed = 0
            factory.holdNewInvalidation = true
            gate.restoreUnknown = { _ in unknown += 1 }
            worker = try f.isolatedWorker(payload, restorationGate: gate,
                clientFactory: { credentials, complete, finished in
                    let base = try factory.make(credentials, complete, finished)
                    worker.retire()
                    return base
                }, beginExecution: { _ in SyntheticDeliveryLease() })
            gate.finishRegistration()
            let source = try f.addRecording(0)
            worker.discover(manifests: [source], receivedSegmentIDs: [source.id])
            try await self.eventually("retired unpublished owner invalidating", {
                factory.all.first?.cancellationCount == 1
            })
            gate.receive(factory.all[0].identifier) { completed += 1 }
            try await self.settle()
            try self.check(!worker.isPaired && unknown == 0 && completed == 0 && factory.all.count == 1,
                "Late UIKit handler cannot fall back to a second owner while a retired constructor drains")
            factory.all[0].releaseInvalidation()
            try await self.eventually("retired unpublished handler drained", { completed == 1 })
            try await self.settle()
            try self.check(unknown == 0 && factory.all.count == 1 && factory.all[0].uploads.isEmpty,
                "Retired constructor unregisters only after exact native drain and never reconnects")
        }
        await run("archive_cold_local_reconcile_during_existing_recovery_has_single_owner") { f in
            var foreground = true
            let gate = BackgroundSessionRestorationGate(isForeground: { foreground }, eventTracker: .init())
            let held = DeliveryLeaseGate(), factory = f.factory
            let payload = self.payload("archive-cold-existing-recovery")
            let worker = try f.isolatedWorker(payload, restorationGate: gate,
                clientFactory: { credentials, complete, finished in
                    let base = try factory.make(credentials, complete, finished) as! ControlledTransport
                    return HeldArchiveEnumeration(base, recovery: held)
                }, beginExecution: { _ in SyntheticDeliveryLease() })
            defer { worker.retire() }
            try await self.eventually("existing recovery held", { held.count == 1 })
            foreground = false
            let source = try f.addRecording(0)
            worker.discover(manifests: [source], receivedSegmentIDs: [source.id])
            try await self.eventually("local source materialized while native recovery held", {
                try f.ledger(payload.receiverID).authorizedIDs.contains(source.id)
            })
            try self.check(try f.ledger(payload.receiverID).authorizedIDs.contains(source.id),
                "An outstanding native recovery cannot block local includeFuture materialization")
            try self.check(f.factory.all.count == 1 && f.factory.all[0].uploads.isEmpty,
                "Existing native recovery keeps exclusive ownership")
            held.release(SyntheticDeliveryLease())
            try await self.eventually("original recovery resumes upload", { f.factory.all[0].uploads.count == 1 })
            try self.check(f.factory.all.count == 1, "Recovery and discovery cannot construct different owners")
        }
        await run("archive_cold_ambiguous_wave_returns_before_own_handoff_drain") { f in
            let tracker = BackgroundSessionEventTracker()
            let gate = BackgroundSessionRestorationGate(isForeground: { false }, eventTracker: tracker)
            let payload = self.payload("archive-cold-ambiguous")
            let factory = f.factory
            var completed = 0, didIntroduceOldIngress = false
            factory.holdNewInvalidation = true
            let worker = try f.isolatedWorker(payload, restorationGate: gate,
                clientFactory: { credentials, complete, finished in
                    let identifier = AutomaticReceiverClient.sessionIdentifier(for: credentials.scope)
                    if !didIntroduceOldIngress {
                        didIntroduceOldIngress = true
                        _ = tracker.capture(identifier)
                        gate.receive(identifier) { completed += 1 }
                    }
                    return try factory.make(credentials, complete, finished)
                }, beginExecution: { _ in SyntheticDeliveryLease() })
            defer { worker.retire() }
            let scope = try f.pairing(payload.receiverID).credentials.scope
            let identifier = AutomaticReceiverClient.sessionIdentifier(for: scope)
            let source = try f.addRecording(0)
            worker.discover(manifests: [source], receivedSegmentIDs: [source.id])
            try await self.eventually("worker initiates its own handoff without self-wait", {
                f.factory.all.first?.cancellationCount == 1
            })
            try self.check(completed == 0 && f.factory.all.count == 1,
                "Ambiguous wave cannot complete or replace its owner before ordered invalidation")
            f.factory.all[0].releaseInvalidation()
            try await self.eventually("ordered handler completes without self wait", { completed == 1 })
            try await self.eventually("replacement uploads once", { f.factory.all.count == 2 && f.factory.all[1].uploads.count == 1 })
            try self.check(f.factory.all[0].uploads.isEmpty && f.factory.all[1].identifier == identifier,
                "Invalidation keeps the same grant and never reuses the old transport")
        }
    }
}
