import XCTest
import Darwin
@testable import RecordingCore

final class RecordingMetadataAccessTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testOnlyMissingMetadataReturnsNil() throws {
        let file = root.appendingPathComponent("state.json")
        XCTAssertNil(try RecordingMetadataAccess.readIfPresent(at: file, maximumBytes: 32))
        XCTAssertFalse(try RecordingMetadataAccess.exists(at: file))
        let bytes = Data("{\"position\":7}".utf8)
        try bytes.write(to: file)
        XCTAssertEqual(try RecordingMetadataAccess.readIfPresent(at: file, maximumBytes: 32), bytes)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        XCTAssertThrowsError(try RecordingMetadataAccess.readIfPresent(at: file, maximumBytes: 32)) {
            XCTAssertFalse(RecordingMetadataAccess.isMissing($0))
        }
    }

    func testInaccessibleParentIsNotMissingMetadata() throws {
        let file = root.appendingPathComponent("state.json")
        try Data("original".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: root.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path) }
        XCTAssertThrowsError(try RecordingMetadataAccess.exists(at: file))
        XCTAssertThrowsError(try RecordingMetadataAccess.readIfPresent(at: file, maximumBytes: 32))
    }

    func testReaderRejectsLinksDirectoriesFifosAndOversizedFiles() throws {
        let file = root.appendingPathComponent("state.json")
        try Data(repeating: 1, count: 33).write(to: file)
        XCTAssertThrowsError(try RecordingMetadataAccess.readIfPresent(at: file, maximumBytes: 32))
        XCTAssertThrowsError(try RecordingMetadataAccess.readIfPresent(at: root, maximumBytes: 32))
        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertThrowsError(try RecordingMetadataAccess.readIfPresent(at: link, maximumBytes: 64))
        let fifo = root.appendingPathComponent("fifo.json")
        XCTAssertEqual(Darwin.mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try RecordingMetadataAccess.readIfPresent(at: fifo, maximumBytes: 64))
        XCTAssertEqual(try Data(contentsOf: file).count, 33)
    }

    func testOtherFileSystemErrorsAreNotMissing() {
        for code in [EACCES, EIO, ENOTDIR, ELOOP] {
            XCTAssertFalse(RecordingMetadataAccess.isMissing(NSError(domain: NSPOSIXErrorDomain, code: Int(code))))
        }
        XCTAssertFalse(RecordingMetadataAccess.isMissing(NSError(domain: NSCocoaErrorDomain,
            code: NSFileReadNoPermissionError, userInfo: [NSUnderlyingErrorKey:
                NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))])))
    }
}
