import Foundation

/// Scheduling limits only. Neither a request nor an attempt proves that either
/// device saved audio; the caller must obtain a freshly verified receipt.
public struct PhoneReceiptMaintenancePolicy: Sendable {
    /// Rate-limit discovery only, never a saved tail or an exact receipt.
    /// This is a scheduling hint; it grants no acknowledgement authority.
    public static func shouldDiscoverHistory(lastStartedAt: Date?, now: Date = Date(), forced: Bool = false) -> Bool {
        guard !forced, let lastStartedAt, now >= lastStartedAt else { return true }
        return now.timeIntervalSince(lastStartedAt) >= 5 * 60
    }

    public enum Request: Equatable, Sendable {
        case none
        case legacy
        case targeted(TargetedReceiptRequest)
        case invalidTargeted
    }

    /// Presence wins over the legacy bit, including a wrong value type. A bad
    /// targeted payload must never turn into an expensive historical sweep.
    public static func request(targetedKeyPresent: Bool, targetedData: Data?,
                               legacyRequested: Bool) -> Request {
        if targetedKeyPresent {
            guard let targetedData,
                  let value = try? TransportCodec.decode(TargetedReceiptRequest.self, from: targetedData)
            else { return .invalidTargeted }
            return .targeted(value)
        }
        return legacyRequested ? .legacy : .none
    }

    /// The injected operation is RecordingRepository.verifiedReceipt(for:) in
    /// production. Match only after it has re-established integrity/durability.
    public static func verifiedReceipt(for request: TargetedReceiptRequest,
                                       verify: (UUID) throws -> SegmentReceipt) throws -> SegmentReceipt {
        try request.validate()
        let receipt = try verify(request.segmentID)
        guard request.matches(receipt) else { throw RepositoryError.receiptMismatch }
        return receipt
    }

    public let verificationLimit: Int
    public let targetedLimit: Int
    public private(set) var verificationAttempts = 0
    public private(set) var targetedAttempts = 0
    public private(set) var historicalAttempts = 0
    public private(set) var historicalLimit = 0
    private var generation: Int?
    private var targetedIDs = Set<UUID>()

    public init(verificationLimit: Int = 8, targetedLimit: Int = 1) {
        precondition(verificationLimit > 0 && targetedLimit > 0 && targetedLimit < verificationLimit)
        self.verificationLimit = verificationLimit
        self.targetedLimit = targetedLimit
    }

    /// Repeated callbacks for an existing lease cannot replenish its allowance.
    public mutating func beginLease(generation: Int) {
        if let current = self.generation, generation <= current { return }
        self.generation = generation
        verificationAttempts = 0
        targetedAttempts = 0
        historicalAttempts = 0
        historicalLimit = 0
        targetedIDs.removeAll()
    }

    /// Target-only opportunities grant one historical step. A legacy/manual/BG
    /// request can raise that share within this lease, never reset used budget.
    public mutating func requestHistory(limit: Int, generation: Int) {
        beginLease(generation: generation)
        guard self.generation == generation else { return }
        historicalLimit = max(historicalLimit, min(max(0, limit), verificationLimit))
    }

    public mutating func beginTargetedAttempt(for request: TargetedReceiptRequest,
                                              generation: Int) -> Bool {
        guard self.generation == generation, verificationAttempts < verificationLimit,
              targetedAttempts < targetedLimit, !targetedIDs.contains(request.segmentID) else { return false }
        targetedIDs.insert(request.segmentID)
        targetedAttempts += 1
        verificationAttempts += 1
        return true
    }

    /// Reserve before verifying, so corrupt/missing files consume the same
    /// finite allowance and a failure cannot cause an unbounded retry loop.
    public mutating func beginHistoricalAttempt(generation: Int) -> Bool {
        guard self.generation == generation, verificationAttempts < verificationLimit,
              historicalAttempts < historicalLimit else { return false }
        historicalAttempts += 1
        verificationAttempts += 1
        return true
    }
}
