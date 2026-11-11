import Foundation

/// A resumable-session status is not a cloud receipt. HTTP 200 still needs
/// file metadata. 404 and 410 mean that session URL must not stay preferred.
public enum GoogleDriveCompletedReadBack: Equatable, Sendable {
    case remote(GoogleDriveRemoteFile)
    case pending
    case sessionExpired
}

public enum GoogleDriveResumableReadBack: Equatable, Sendable {
    case needsMetadata
    case pending
    case sessionExpired

    public static func classify(status: Int) -> Self {
        switch status {
        case 200, 201: return .needsMetadata
        case 404, 410: return .sessionExpired
        default: return .pending
        }
    }
}

/// The first live resumable session may continue ahead of unprepared audio.
/// A missing URL does not.
public enum GoogleDriveAudioTurn {
    public static func preparedSessionIndex(_ hasUploadURL: [Bool]) -> Int? {
        hasUploadURL.firstIndex(of: true)
    }
}
