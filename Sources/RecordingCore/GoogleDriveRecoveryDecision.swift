import Foundation

/// Same-request transport recovery. A later success on a different request ID
/// is not recovery, and local HTTP 200 is not a cloud receipt.
public enum GoogleDriveRecoveryDecision {
    public enum Path: Equatable, Sendable {
        case aboutGET, fileMetadataGET
        /// Only a token endpoint POST with a strictly validated form containing
        /// one grant_type=refresh_token. One-use authorization codes are .other.
        case tokenPOST
        case other
    }
    public enum Fault: Equatable, Sendable {
        case closedNoNotify, naturalTimeout, other
    }
    public enum SecondAttempt: Equatable, Sendable {
        case recovered, httpFailure
    }

    /// Metadata reads and validated refresh-token POSTs can leave room for one
    /// retry. Other grants, uploads, revoke, and mutations keep the full timeout.
    public static func reservesRetry(_ path: Path) -> Bool {
        switch path {
        case .aboutGET, .fileMetadataGET, .tokenPOST: return true
        case .other: return false
        }
    }

    /// First-request idle timeout, with nominal retry room for eligible paths.
    /// This is not a wall-clock attempt deadline: retry eligibility must still
    /// use elapsed time and the caller's current background lease budget.
    public static func firstAttemptTimeout(budget: TimeInterval, path: Path) -> TimeInterval {
        guard budget.isFinite, budget > 0 else { return 0 }
        let capped = min(30, budget)
        guard reservesRetry(path), capped >= 2 else { return capped }
        let reserve = min(8, capped / 2)
        return max(1, capped - reserve)
    }

    /// `remaining` must be measured against the original request deadline after
    /// the first failure. A retry never extends the caller or background lease.
    /// Nil means this failure must not open a second attempt of the same request.
    public static func retryAllowance(path: Path, fault: Fault, remaining: TimeInterval) -> TimeInterval? {
        guard remaining.isFinite, remaining >= 1 else { return nil }
        switch (path, fault) {
        case (.aboutGET, .closedNoNotify), (.aboutGET, .naturalTimeout),
             (.fileMetadataGET, .closedNoNotify), (.fileMetadataGET, .naturalTimeout),
             (.tokenPOST, .naturalTimeout):
            return min(8, remaining)
        default:
            return nil
        }
    }

    /// HTTP 200 recovers. A metadata GET whose caller already accepts 404 does
    /// too. About, uploads, and unaccepted 404 stay failures.
    public static func secondAttempt(_ status: Int, path: Path, callerAcceptsMissingFile: Bool) -> SecondAttempt {
        if status == 200 { return .recovered }
        if status == 404, callerAcceptsMissingFile, path == .fileMetadataGET { return .recovered }
        return .httpFailure
    }

    /// Archive proof is bound to one request and origin. File-metadata 404 is
    /// proof only for the GET the caller already treats as continue.
    public static func provesSameRequestRecovery(httpStatus: Int?, methodIsGET: Bool,
                                                 endpointIsFileMetadata: Bool, phaseIsRecovery: Bool,
                                                 errorsEmpty: Bool, sameRequestAndOrigin: Bool) -> Bool {
        guard phaseIsRecovery, errorsEmpty, sameRequestAndOrigin else { return false }
        if httpStatus == 200 { return true }
        return httpStatus == 404 && methodIsGET && endpointIsFileMetadata
    }
}
