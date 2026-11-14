import Foundation
import Darwin

public enum RecordingMetadataAccessError: Error {
    case invalidFileType
    case sizeLimitExceeded
}

/// A missing scheduling file may be initialized, but an inaccessible one must
/// remain untouched. These helpers never inspect recording content.
public enum RecordingMetadataAccess {
    public static func isMissing(_ error: Error) -> Bool {
        let value = error as NSError
        if value.domain == NSPOSIXErrorDomain { return value.code == Int(ENOENT) }
        return value.domain == NSCocoaErrorDomain
            && (value.code == NSFileReadNoSuchFileError || value.code == NSFileNoSuchFileError)
    }

    public static func exists(at url: URL) throws -> Bool {
        var attributes = stat()
        guard Darwin.lstat(url.path, &attributes) == 0 else {
            if errno == ENOENT { return false }
            throw posixError()
        }
        return true
    }

    public static func attributesIfPresent(at url: URL) throws -> [FileAttributeKey: Any]? {
        do { return try FileManager.default.attributesOfItem(atPath: url.path) }
        catch {
            if isMissing(error) { return nil }
            throw error
        }
    }

    /// Does not follow links or block opening a FIFO. The descriptor binds size,
    /// type and reads to the same file; the byte limit also applies if it grows.
    public static func readIfPresent(at url: URL, maximumBytes: Int) throws -> Data? {
        guard maximumBytes >= 0 else { throw RecordingMetadataAccessError.sizeLimitExceeded }
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw posixError()
        }
        defer { Darwin.close(descriptor) }
        var attributes = stat()
        guard Darwin.fstat(descriptor, &attributes) == 0 else { throw posixError() }
        guard attributes.st_mode & S_IFMT == S_IFREG else {
            throw RecordingMetadataAccessError.invalidFileType
        }
        guard attributes.st_size >= 0, attributes.st_size <= maximumBytes else {
            throw RecordingMetadataAccessError.sizeLimitExceeded
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
            if count == 0 { return result }
            guard count <= maximumBytes - result.count else {
                throw RecordingMetadataAccessError.sizeLimitExceeded
            }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
