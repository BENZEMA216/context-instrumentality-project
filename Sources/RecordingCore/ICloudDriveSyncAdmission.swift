import Foundation

/// New exports and identity repairs share one bounded round. A conflicted head
/// leaves the new-export queue; repair rotation stays fair.
public enum ICloudDriveExportAdmission {
    public static func admitsNewExport(pendingExport: Bool, needsRepair: Bool, conflictBlocked: Bool) -> Bool {
        pendingExport && !needsRepair && !conflictBlocked
    }
    public static func admitsRepair(pendingExport: Bool, needsRepair: Bool, conflictBlocked: Bool) -> Bool {
        needsRepair || (conflictBlocked && pendingExport)
    }
}

/// `provider_uploaded` requires a matching export identity or a validated
/// marker/commit body. A provider flag alone, or a missing stamp, is pending.
public enum ICloudDriveProviderAdmission {
    public static func providerUploaded(identityMatches: Bool?, contentValidated: Bool,
                                        providerReportsUploaded: Bool, stampStable: Bool) -> Bool {
        guard providerReportsUploaded, stampStable else { return false }
        if let identityMatches { return identityMatches }
        return contentValidated
    }

    /// Preserve a historical observation only when a fresh local stamp still
    /// matches. Current confirmation additionally requires provider metadata
    /// rechecking after the notification; this local check cannot prove it.
    public static func retainUploadedAfterProviderChange(previouslyConfirmed: Bool, stampMatches: Bool) -> Bool {
        previouslyConfirmed && stampMatches
    }
}
