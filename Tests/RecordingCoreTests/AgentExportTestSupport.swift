import CoreServices
import XCTest
@testable import RecordingCore

/// The system cases remain real Foundation ZIP integration tests. The command
/// line cases exercise the same production payload and cleanup paths without
/// depending on Foundation's upload-archive service.
enum AgentExportTestArchive {
    case system
    case commandLine

    func createArchive(repository: RecordingRepository, selectedIDs: Set<UUID>,
                       destinationDirectory: URL, now: Date,
                       transcripts: [UUID: SegmentTranscript] = [:]) throws -> URL {
        switch self {
        case .system:
            try Self.requireSystemArchiveCapability()
            // Only the independent text probe may skip. A failure exporting the
            // actual synthetic recording payload must still fail this test.
            return try AgentExportBuilder.createArchive(repository: repository, selectedIDs: selectedIDs,
                destinationDirectory: destinationDirectory, now: now, transcripts: transcripts)
        case .commandLine:
            return try AgentExportBuilder.createArchive(repository: repository, selectedIDs: selectedIDs,
                destinationDirectory: destinationDirectory, now: now, transcripts: transcripts,
                archiveWriter: Self.writeZIP)
        }
    }

    static func writeZIP(payload: URL, result: URL) throws {
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = payload.deletingLastPathComponent()
        zip.arguments = ["-q", "-r", result.path, payload.lastPathComponent]
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationReason == .exit, zip.terminationStatus == 0 else {
            throw CapabilityError.commandLineZIPFailed(zip.terminationStatus)
        }
    }

    /// A controlled text directory isolates system-service availability from
    /// RecordingCore, recording metadata, and the synthetic recording fixture.
    private static func requireSystemArchiveCapability() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AgentExportCapability-" + UUID().uuidString,
                                                              isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let payload = root.appendingPathComponent("synthetic-text", isDirectory: true)
        try fm.createDirectory(at: payload, withIntermediateDirectories: false)
        try Data("synthetic text only\n".utf8).write(to: payload.appendingPathComponent("fixture.txt"))
        let result = root.appendingPathComponent("capability.zip")
        var coordinationError: NSError?
        var copyError: Error?
        var accessorEntered = false
        NSFileCoordinator().coordinate(readingItemAt: payload, options: .forUploading,
                                        error: &coordinationError) { snapshot in
            accessorEntered = true
            // The snapshot URL is only valid during this accessor.
            do { try fm.copyItem(at: snapshot, to: result) }
            catch { copyError = error }
        }
        try requireAvailable(error: coordinationError, accessorEntered: accessorEntered,
                             requireNative: ProcessInfo.processInfo.environment["WR_REQUIRE_NATIVE_ARCHIVE"] == "1")
        if let copyError { throw copyError }
        let attributes = try fm.attributesOfItem(atPath: result.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.int64Value > 0 else {
            throw CapabilityError.missingArchive
        }
    }

    /// Only the observed pre-accessor Cocoa/LaunchServices error is an
    /// environment skip. Permission, file, accessor, and other errors propagate.
    static func requireAvailable(error: NSError?, accessorEntered: Bool, requireNative: Bool) throws {
        if let error {
            let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
            if !requireNative, !accessorEntered,
               error.domain == NSCocoaErrorDomain, error.code == NSFileReadUnknownError,
               underlying?.domain == NSOSStatusErrorDomain,
               underlying?.code == Int(kLSDataUnavailableErr) {
                throw XCTSkip("Independent text-only NSFileCoordinator(.forUploading) probe failed before its accessor: "
                    + "NSCocoaErrorDomain 256 -> NSOSStatusErrorDomain -10813 (kLSDataUnavailableErr). "
                    + "The archive service is unavailable in this environment; service-free ZIP coverage still runs. "
                    + "Rerun in the user session with WR_REQUIRE_NATIVE_ARCHIVE=1 to require native integration.")
            }
            throw error
        }
        guard accessorEntered else { throw CapabilityError.accessorNotEntered }
    }

    private enum CapabilityError: LocalizedError {
        case accessorNotEntered
        case missingArchive
        case commandLineZIPFailed(Int32)

        var errorDescription: String? {
            switch self {
            case .accessorNotEntered:
                return "Foundation archive probe returned no error but never entered its accessor."
            case .missingArchive:
                return "Foundation archive probe did not produce a nonempty regular ZIP file."
            case .commandLineZIPFailed(let status):
                return "Synthetic command-line ZIP writer failed with termination status \(status)."
            }
        }
    }
}
