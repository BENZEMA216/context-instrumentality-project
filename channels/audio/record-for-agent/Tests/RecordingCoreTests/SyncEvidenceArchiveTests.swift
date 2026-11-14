import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import RecordingCore

/// All identities, receipts and filesystem objects in this suite are synthetic.
/// No repository, recorder, audio validator, network client or real library runs.
final class SyncEvidenceArchiveTests: XCTestCase {
    private var root: URL!
    private let libraryID = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    private let instant: Int64 = 1_793_183_000_000

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("sync-evidence-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }

    private var directory: URL { root.appendingPathComponent("SyncEvidence/google_drive") }
    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    private var statusURL: URL { directory.appendingPathComponent("status.json") }
    private var captureURL: URL { directory.appendingPathComponent("metadata-capture.json") }
    private var captureStatusURL: URL { directory.appendingPathComponent("capture-status.json") }
    private func archive() -> SyncEvidenceArchive { .init(root: root, stream: "google_drive", build: "61") }

    private func source(_ number: Int, sha256: String? = nil, origin: String = "authorized_ledger",
                        artifacts: [SyncEvidenceArtifact]? = nil) -> SyncEvidenceSource {
        let id = UUID(uuidString: String(format: "20000000-0000-4000-8000-%012d", number))!
        let hash = sha256 ?? String(format: "%064x", number + 1)
        return .init(segmentID: id, sha256: hash, byteCount: Int64(number + 128), startedAtMS: instant + Int64(number),
            origin: origin, receiptAtMS: instant + 1_000,
            artifacts: artifacts ?? [.init(kind: "audio", sha256: hash, byteCount: Int64(number + 128),
                state: "remote_verified", recordedAtMS: instant + 2_000, origin: "restored_ledger")])
    }

    private func context(count: Int = 1, scope: String = "phone_authorized_discovered",
                         mode: String? = "existingAndFuture", failureCode: String? = nil,
                         counts: [String: Int]? = nil) -> SyncEvidenceContext {
        .init(scope: scope, libraryID: libraryID, scopeMode: mode, enabled: true, discoveryComplete: true,
              counts: counts ?? ["authorized_source_count": count], failureCode: failureCode)
    }

    private func object(at file: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }

    private func writeObject(_ value: [String: Any], to file: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: file, options: .atomic)
    }

    private func status() throws -> [String: Any] { try object(at: statusURL) }

    private enum CaptureFailure: Error { case invalid }
    private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    private func digest(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
    /// Independent test reader: one saved blob plus its genuine publication status.
    /// It never opens archive page paths, so later generation cleanup cannot help it.
    private func verifyCapture(_ bytes: Data, statusBytes: Data) throws -> [String: Any] {
        guard bytes.count <= SyncEvidenceArchive.maximumCaptureBytes,
              let capture = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let outer = try JSONSerialization.jsonObject(with: statusBytes) as? [String: Any],
              outer["available"] as? Bool == true, outer["failureCode"] == nil,
              outer["captureSHA256"] as? String == digest(bytes), outer["captureByteCount"] as? Int == bytes.count,
              capture["schemaVersion"] as? Int == 2, capture["build"] as? String == "61",
              capture["stream"] as? String == "google_drive", capture["audioRead"] as? Bool == false,
              capture["includesAudio"] as? Bool == false, capture["available"] as? Bool == true,
              let generation = capture["generationID"] as? String, UUID(uuidString: generation) != nil,
              outer["generationID"] as? String == generation,
              let index = capture["index"] as? [String: Any], let innerStatus = capture["status"] as? [String: Any],
              index["generationID"] as? String == generation, innerStatus["generationID"] as? String == generation,
              innerStatus["available"] as? Bool == true, innerStatus["failureCode"] == nil,
              index["generatedAtMS"] as? Int64 == capture["generatedAtMS"] as? Int64,
              let refs = index["pages"] as? [[String: Any]], let pages = capture["pages"] as? [[String: Any]],
              pages.count == refs.count else { throw CaptureFailure.invalid }
        var sourceCount = 0
        for (offset, pair) in zip(refs, pages).enumerated() {
            let (ref, page) = pair
            guard let name = ref["name"] as? String, page["name"] as? String == name,
                  name == "g-" + generation.lowercased() + String(format: "-p-%04d.json", offset),
                  let encoded = page["bytesBase64"] as? String, let raw = Data(base64Encoded: encoded),
                  raw.count <= SyncEvidenceArchive.maximumPageBytes,
                  raw.count == ref["byteCount"] as? Int, digest(raw) == ref["sha256"] as? String,
                  let body = try JSONSerialization.jsonObject(with: raw) as? [String: Any],
                  body["generationID"] as? String == generation, body["page"] as? Int == offset,
                  let rows = body["rows"] as? [[String: Any]], rows.count == ref["sourceCount"] as? Int else { throw CaptureFailure.invalid }
            sourceCount += rows.count
        }
        guard sourceCount == index["sourceCount"] as? Int else { throw CaptureFailure.invalid }
        return capture
    }

    private func reboundCaptureStatus(_ bytes: Data, original: Data) throws -> Data {
        var value = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        value["captureSHA256"] = digest(bytes); value["captureByteCount"] = bytes.count
        return try json(value)
    }

    private func assertUnavailable(previous: Data, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try Data(contentsOf: indexURL), previous, "A failed observation replaced the published generation", file: file, line: line)
        let value = try status()
        XCTAssertEqual(value["available"] as? Bool, false, file: file, line: line)
        XCTAssertNil(value["generationID"], file: file, line: line)
        XCTAssertGreaterThan(value["failureCount"] as? Int ?? 0, 0, file: file, line: line)
    }

    private func observationContext() -> SyncEvidenceContext {
        .init(scope: "phone_authorized_discovered", libraryID: libraryID, scopeMode: "existingAndFuture",
              authorizedAtMS: instant - 100, enabled: true, discoveryComplete: true,
              counts: ["authorized_source_count": 1, "artifact_count": 1,
                       "remote_verified_artifact_count": 1, "pending_artifact_count": 0])
    }
    func testVerifiedObservationPreservesEntireBusinessPublicationAndRebindsNewProcess() throws {
        let store = archive()
        try store.publish(rows: [source(0)], context: observationContext())
        let leaves = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let before = try Dictionary(uniqueKeysWithValues: leaves.map { ($0, try Data(contentsOf: directory.appendingPathComponent($0))) })
        let process = UUID()
        XCTAssertTrue(store.observe(processRunID: process))
        let firstBytes = try Data(contentsOf: directory.appendingPathComponent(VerifiedObservationPublisher.fileName))
        let first = try JSONDecoder().decode(VerifiedObservationPublisher.Receipt.self, from: firstBytes)
        XCTAssertEqual(first.observerProcessRunID, process)
        XCTAssertEqual(first.sourceGeneratedAtMS, try XCTUnwrap(store.load()).index.generatedAtMS)
        XCTAssertEqual(Set(first.files.map(\.name)), ["metadata-capture.json", "capture-status.json"])
        XCTAssertFalse(store.observe(processRunID: process), "Repeated foreground hooks must be throttled")
        XCTAssertEqual(firstBytes, try Data(contentsOf: directory.appendingPathComponent(VerifiedObservationPublisher.fileName)))
        let newProcess = UUID()
        XCTAssertTrue(archive().observe(processRunID: newProcess))
        let restored = try JSONDecoder().decode(VerifiedObservationPublisher.Receipt.self,
            from: Data(contentsOf: directory.appendingPathComponent(VerifiedObservationPublisher.fileName)))
        XCTAssertEqual(restored.observerProcessRunID, newProcess)
        XCTAssertEqual(restored.identity, first.identity)
        XCTAssertEqual(restored.files, first.files)
        for (leaf, bytes) in before { XCTAssertEqual(bytes, try Data(contentsOf: directory.appendingPathComponent(leaf))) }
    }

    func testBuild87ArchivePackagesExactCaptureAndFailureOrRestartInvalidatesItsPointer() throws {
        let store = SyncEvidenceArchive(root: root, stream: "google_drive", build: "87")
        try store.publish(rows: [source(0)], context: observationContext())
        let capture = try Data(contentsOf: captureURL), captureStatus = try Data(contentsOf: captureStatusURL)
        let process = UUID()
        XCTAssertTrue(store.observe(processRunID: process))
        let pointerURL = directory.appendingPathComponent("snapshot-index.json")
        let first = try JSONDecoder().decode(ImmutableObservationSnapshotPublisher.Index.self,
            from: Data(contentsOf: pointerURL))
        XCTAssertTrue(first.available)
        let generation = directory.appendingPathComponent("SnapshotGenerations").appendingPathComponent(try XCTUnwrap(first.generationID))
        XCTAssertEqual(try Data(contentsOf: generation.appendingPathComponent("metadata-capture.json")), capture)
        XCTAssertEqual(try Data(contentsOf: generation.appendingPathComponent("capture-status.json")), captureStatus)
        store.markUnavailable()
        let failed = try JSONDecoder().decode(ImmutableObservationSnapshotPublisher.Index.self,
            from: Data(contentsOf: pointerURL))
        XCTAssertFalse(failed.available); XCTAssertNotEqual(failed.fenceID, first.fenceID)
        XCTAssertEqual(try Data(contentsOf: generation.appendingPathComponent("metadata-capture.json")), capture)
        try store.publish(rows: [source(0)], context: observationContext())
        XCTAssertTrue(store.observe(processRunID: process, sourceDidChange: true))
        let recovered = try JSONDecoder().decode(ImmutableObservationSnapshotPublisher.Index.self,
            from: Data(contentsOf: pointerURL))
        XCTAssertEqual(recovered.fenceID, failed.fenceID)
        let restarted = SyncEvidenceArchive(root: root, stream: "google_drive", build: "87")
        let startup = try JSONDecoder().decode(ImmutableObservationSnapshotPublisher.Index.self,
            from: Data(contentsOf: pointerURL))
        XCTAssertFalse(startup.available); XCTAssertEqual(startup.failureCode, "observer_startup")
        XCTAssertNotEqual(startup.fenceID, recovered.fenceID)
        withExtendedLifetime(restarted) { }
    }

    func testVerifiedObservationRejectsTamperedPublicationWithoutBusinessWrites() throws {
        for leaf in ["index.json", "status.json", "metadata-capture.json", "capture-status.json", "page"] {
            let store = archive()
            try store.publish(rows: [source(0)], context: observationContext())
            XCTAssertTrue(store.observe(processRunID: UUID()))
            let receiptURL = directory.appendingPathComponent(VerifiedObservationPublisher.fileName)
            let previous = try Data(contentsOf: receiptURL)
            let name = leaf == "page" ? try XCTUnwrap(store.load()).index.pages[0].name : leaf
            let file = directory.appendingPathComponent(name)
            try Data("{}".utf8).write(to: file)
            let before = try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(atPath: directory.path)
                .filter { !$0.hasPrefix("verified-observation") }.map { ($0, try Data(contentsOf: directory.appendingPathComponent($0))) })
            XCTAssertFalse(archive().observe(processRunID: UUID()), leaf)
            XCTAssertEqual(previous, try Data(contentsOf: receiptURL))
            let status = try JSONDecoder().decode(VerifiedObservationPublisher.Status.self,
                from: Data(contentsOf: directory.appendingPathComponent(VerifiedObservationPublisher.statusName)))
            XCTAssertFalse(status.available)
            for (name, bytes) in before { XCTAssertEqual(bytes, try Data(contentsOf: directory.appendingPathComponent(name))) }
            try FileManager.default.removeItem(at: directory)
        }
    }

    func testVerifiedObservationRejectsMismatchedCaptureEvenWithReboundHash() throws {
        let store = archive()
        try store.publish(rows: [source(0)], context: observationContext())
        var envelope = try object(at: captureURL)
        var index = try XCTUnwrap(envelope["index"] as? [String: Any])
        index["generatedAtMS"] = instant; envelope["index"] = index
        let bytes = try json(envelope)
        let status = try reboundCaptureStatus(bytes, original: Data(contentsOf: captureStatusURL))
        try bytes.write(to: captureURL); try status.write(to: captureStatusURL)
        XCTAssertFalse(store.observe(processRunID: UUID()))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(VerifiedObservationPublisher.fileName).path))
    }

    func testSchemaTwoPublishesCorrelatedReceiptAndReadsLegacySchemaOneWithoutBackfill() throws {
        let row = source(0)
        let correlation = GoogleDriveUploadCorrelation(segmentID: row.segmentID, kind: .audio, manifestSHA256: row.sha256)
        let artifact = SyncEvidenceArtifact(kind: "audio", sha256: row.sha256, byteCount: row.byteCount,
            state: "remote_verified", recordedAtMS: instant + 2_000, origin: "observed_callback", uploadCorrelation: correlation)
        let store = archive()
        try store.publish(rows: [source(0, artifacts: [artifact])], context: context())
        let published = try XCTUnwrap(store.load())
        XCTAssertEqual(published.index.schemaVersion, 2)
        XCTAssertEqual(published.rows[0].artifacts[0].uploadCorrelation, correlation)
        XCTAssertEqual(try object(at: captureURL)["schemaVersion"] as? Int, 2)
        XCTAssertEqual(try object(at: statusURL)["schemaVersion"] as? Int, 2)

        var index = try object(at: indexURL)
        var refs = try XCTUnwrap(index["pages"] as? [[String: Any]])
        let pageURL = directory.appendingPathComponent(try XCTUnwrap(refs[0]["name"] as? String))
        var page = try object(at: pageURL)
        var rows = try XCTUnwrap(page["rows"] as? [[String: Any]])
        var artifacts = try XCTUnwrap(rows[0]["artifacts"] as? [[String: Any]])
        artifacts[0].removeValue(forKey: "uploadCorrelation")
        rows[0]["artifacts"] = artifacts; page["rows"] = rows; page["schemaVersion"] = 1
        let bytes = try json(page); try bytes.write(to: pageURL)
        refs[0]["byteCount"] = bytes.count; refs[0]["sha256"] = digest(bytes)
        index["pages"] = refs; index["schemaVersion"] = 1; try writeObject(index, to: indexURL)
        let legacy = try XCTUnwrap(store.load())
        XCTAssertEqual(legacy.index.schemaVersion, 1)
        XCTAssertNil(legacy.rows[0].artifacts[0].uploadCorrelation)
        XCTAssertEqual(GoogleDriveUploadRecoveryEvidence.evaluate(failureCorrelation: correlation,
            naturalTimeout: true, failureAtMS: instant, receipt: legacy.rows[0].artifacts[0]), .insufficientEvidence)
    }

    func testArchiveRejectsReceiptCorrelatedToAnotherSourceOrSharedRefresh() throws {
        let row = source(0)
        for correlation in [GoogleDriveUploadCorrelation.shared,
                            .init(segmentID: UUID(), kind: .audio, manifestSHA256: row.sha256)] {
            let artifact = SyncEvidenceArtifact(kind: "audio", sha256: row.sha256, byteCount: row.byteCount,
                state: "remote_verified", recordedAtMS: instant, origin: "observed_callback", uploadCorrelation: correlation)
            XCTAssertThrowsError(try archive().publish(rows: [source(0, artifacts: [artifact])], context: context()))
        }
    }

    func testMoreThanSixSourcesPageCompletelyAndReloadAfterRestart() throws {
        let rows = (0..<137).map { source($0) }
        let first = archive()
        XCTAssertNil(try first.load())
        try first.publish(rows: rows.reversed(), context: context(count: rows.count))
        let snapshot = try XCTUnwrap(archive().load())
        XCTAssertEqual(snapshot.rows, rows)
        XCTAssertEqual(snapshot.index.sourceCount, 137)
        XCTAssertEqual(snapshot.index.pages.map(\.sourceCount), [64, 64, 9])
        XCTAssertEqual(snapshot.index.context.libraryID, libraryID)
        XCTAssertTrue(snapshot.index.context.discoveryComplete)
        for page in snapshot.index.pages {
            let bytes = try Data(contentsOf: directory.appendingPathComponent(page.name))
            XCTAssertEqual(bytes.count, page.byteCount)
            XCTAssertLessThanOrEqual(bytes.count, SyncEvidenceArchive.maximumPageBytes)
            XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), page.sha256)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(page.name).path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
        XCTAssertEqual(try status()["generationID"] as? String, snapshot.index.generationID.uuidString)
        XCTAssertEqual(try status()["available"] as? Bool, true)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testMissingPageCannotReturnAnApparentlyCompleteSubset() throws {
        let store = archive()
        try store.publish(rows: (0..<130).map { source($0) }, context: context(count: 130))
        let snapshot = try XCTUnwrap(store.load())
        try FileManager.default.removeItem(at: directory.appendingPathComponent(snapshot.index.pages[1].name))
        XCTAssertThrowsError(try archive().load())
    }

    func testChangedPageBytesAreRejectedEvenAtTheSameLength() throws {
        let store = archive()
        try store.publish(rows: [source(0)], context: context())
        let snapshot = try XCTUnwrap(store.load())
        let page = directory.appendingPathComponent(snapshot.index.pages[0].name)
        var bytes = try Data(contentsOf: page)
        bytes[bytes.count / 2] ^= 1
        try bytes.write(to: page)
        XCTAssertThrowsError(try archive().load())
    }

    func testIndexSourceCountAndPageReferenceCountsMustMatchActualRows() throws {
        let store = archive()
        try store.publish(rows: [source(0)], context: context())
        let original = try Data(contentsOf: indexURL)
        for field in ["sourceCount", "pageSourceCount", "byteCount", "sha256"] {
            try original.write(to: indexURL)
            var index = try object(at: indexURL)
            if field == "sourceCount" { index[field] = 2 }
            else {
                var refs = try XCTUnwrap(index["pages"] as? [[String: Any]])
                refs[0][field == "pageSourceCount" ? "sourceCount" : field] = field == "sha256" ? String(repeating: "f", count: 64) : 2
                index["pages"] = refs
            }
            try writeObject(index, to: indexURL)
            XCTAssertThrowsError(try archive().load(), field)
        }
    }

    func testDuplicateIDWithAnotherDigestRejectsWholePublicationAndKeepsPreviousGeneration() throws {
        let store = archive()
        try store.publish(rows: [source(0)], context: context())
        let previous = try Data(contentsOf: indexURL)
        XCTAssertThrowsError(try store.publish(rows: [source(1), source(1, sha256: String(repeating: "e", count: 64))], context: context(count: 2)))
        try assertUnavailable(previous: previous)
        XCTAssertEqual(try archive().load()?.rows, [source(0)])
    }

    func testInvalidMetadataAndSourceCapacityFailureKeepPreviousIndexAndReportUnavailable() throws {
        let store = archive()
        try store.publish(rows: [source(0)], context: context())
        let previous = try Data(contentsOf: indexURL)
        XCTAssertThrowsError(try store.publish(rows: [source(1, sha256: "bad")], context: context()))
        try assertUnavailable(previous: previous)
        XCTAssertThrowsError(try store.publish(rows: (0...SyncEvidenceArchive.maximumSources).map { source($0) },
                                              context: context(count: SyncEvidenceArchive.maximumSources + 1)))
        try assertUnavailable(previous: previous)
        XCTAssertEqual(try status()["failureCode"] as? String, "capacity_exceeded")
        XCTAssertEqual(try archive().load()?.rows, [source(0)], "An unavailable status preserves history without declaring it current")
    }

    func testOneSourceLargerThanAWholePageRejectsWithoutTruncation() throws {
        let store = archive()
        try store.publish(rows: [source(0)], context: context())
        let previous = try Data(contentsOf: indexURL)
        let artifacts = (0..<258).map { number in
            SyncEvidenceArtifact(kind: "transcriptText", sha256: String(format: "%064x", number + 10),
                byteCount: Int64.max, state: "provider_uploaded", recordedAtMS: Int64.max,
                observedAtMS: Int64.max, origin: "stored_receipt_metadata")
        }
        let oversized = source(1, artifacts: artifacts)
        XCTAssertGreaterThan(try JSONEncoder().encode(oversized).count, SyncEvidenceArchive.maximumPageBytes,
                             "The fixture must actually exceed the byte limit, rather than only a row-count limit")
        XCTAssertThrowsError(try store.publish(rows: [oversized], context: context()))
        try assertUnavailable(previous: previous)
        XCTAssertEqual(try status()["failureCode"] as? String, "capacity_exceeded")
        XCTAssertEqual(try archive().load()?.rows, [source(0)])
    }

    func testExplicitUnavailablePreservesHistoricalGenerationAndLaterSuccessPublishesFreshGeneration() throws {
        let store = archive()
        try store.publish(rows: [source(0)], context: context())
        let snapshot = try XCTUnwrap(store.load())
        let previous = try Data(contentsOf: indexURL)
        store.markUnavailable()
        try assertUnavailable(previous: previous)
        try store.publish(rows: [source(0), source(1)], context: context(count: 2))
        XCTAssertNotEqual(try store.load()?.index.generationID, snapshot.index.generationID)
        XCTAssertEqual(try status()["available"] as? Bool, true)
    }

    func testPageFromOldGenerationCannotBeMixedIntoNewIndex() throws {
        let store = archive()
        try store.publish(rows: [source(0)], context: context())
        let old = try object(at: indexURL)
        try store.publish(rows: [source(1)], context: context())
        var current = try object(at: indexURL)
        current["pages"] = old["pages"]
        try writeObject(current, to: indexURL)
        XCTAssertThrowsError(try archive().load())
    }

    func testUnpublishedOrphanPageIsNeverReadAndOnlyTwoPublishedGenerationsRemain() throws {
        let store = archive()
        try store.publish(rows: [source(0)], context: context())
        let first = try XCTUnwrap(store.load()).index
        try store.publish(rows: [source(1)], context: context())
        let second = try XCTUnwrap(store.load()).index
        let orphan = directory.appendingPathComponent("g-ffffffff-ffff-4fff-8fff-ffffffffffff-p-0000.json")
        try Data("not a published page".utf8).write(to: orphan)
        XCTAssertEqual(try archive().load()?.rows, [source(1)])
        try store.publish(rows: [source(2)], context: context())
        let third = try XCTUnwrap(store.load()).index
        XCTAssertEqual(try archive().load()?.rows, [source(2)])
        for page in first.pages { XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(page.name).path)) }
        for page in second.pages + third.pages { XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(page.name).path)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }

    func testIndexAndPageRejectSymlinksHardLinksAndFIFOsWithoutBlocking() throws {
        for targetKind in ["index", "page"] {
            for alias in ["symlink", "hardlink", "fifo"] {
                let fixture = root.appendingPathComponent(targetKind + "-" + alias)
                try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
                let store = SyncEvidenceArchive(root: fixture, stream: "google_drive", build: "61")
                try store.publish(rows: [source(0)], context: context())
                let snapshot = try XCTUnwrap(store.load())
                let base = fixture.appendingPathComponent("SyncEvidence/google_drive")
                let target = base.appendingPathComponent(targetKind == "index" ? "index.json" : snapshot.index.pages[0].name)
                let preserved = fixture.appendingPathComponent("preserved.json")
                try FileManager.default.moveItem(at: target, to: preserved)
                if alias == "symlink" { try FileManager.default.createSymbolicLink(at: target, withDestinationURL: preserved) }
                else if alias == "hardlink" { try FileManager.default.linkItem(at: preserved, to: target) }
                else { XCTAssertEqual(Darwin.mkfifo(target.path, 0o600), 0) }
                XCTAssertThrowsError(try store.load(), targetKind + ":" + alias)
                XCTAssertTrue(FileManager.default.fileExists(atPath: preserved.path))
            }
        }
    }

    func testPublishingRefusesAliasedIndexWithoutReplacingTheAlias() throws {
        let store = archive()
        try store.publish(rows: [source(0)], context: context())
        let preserved = root.appendingPathComponent("preserved-index.json")
        try FileManager.default.moveItem(at: indexURL, to: preserved)
        try FileManager.default.createSymbolicLink(at: indexURL, withDestinationURL: preserved)
        let original = try Data(contentsOf: preserved)
        XCTAssertThrowsError(try store.publish(rows: [source(1)], context: context()))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: indexURL.path), preserved.path)
        XCTAssertEqual(try Data(contentsOf: preserved), original)
        XCTAssertEqual(try status()["available"] as? Bool, false)
    }

    func testMetadataProjectionDoesNotAccessOrModifySimulatedAudio() throws {
        let segments = root.appendingPathComponent("segments")
        try FileManager.default.createDirectory(at: segments, withIntermediateDirectories: true)
        let audio = segments.appendingPathComponent("unreadable.caf")
        let bytes = Data("SYNTHETIC_AUDIO_SENTINEL_NEVER_INCLUDED".utf8)
        try bytes.write(to: audio)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: audio.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: audio.path) }
        let fifo = segments.appendingPathComponent("would_block_if_audio_is_opened.caf")
        XCTAssertEqual(Darwin.mkfifo(fifo.path, 0o600), 0)
        let before = try FileManager.default.attributesOfItem(atPath: audio.path)
        let store = archive()
        try store.publish(rows: (0..<70).map { source($0) }, context: context(count: 70))
        XCTAssertEqual(try archive().load()?.rows.count, 70)
        let after = try FileManager.default.attributesOfItem(atPath: audio.path)
        for key: FileAttributeKey in [.size, .modificationDate, .systemFileNumber, .posixPermissions] {
            XCTAssertEqual(String(describing: before[key]), String(describing: after[key]), key.rawValue)
        }
        for leaf in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            XCTAssertFalse(try Data(contentsOf: directory.appendingPathComponent(leaf)).contains(bytes))
        }
    }

    func testBoundedContextAccommodatesRepairDiagnosticsAndRejectsOverflow() throws {
        let store = archive()
        var counts = Dictionary(uniqueKeysWithValues: (0..<63).map { ("diagnostic_\($0)", 0) })
        counts["authorized_source_count"] = 1
        try store.publish(rows: [source(0)], context: context(counts: counts))
        XCTAssertEqual(try store.load()?.context.counts, counts)
        counts["overflow"] = 0
        XCTAssertThrowsError(try store.publish(rows: [source(0)], context: context(counts: counts)))
    }

    func testMetadataFieldsRejectPathsURLsAccountsControlCharactersAndOversizedWords() throws {
        let store = archive()
        try store.publish(rows: [source(0)], context: context())
        let previous = try Data(contentsOf: indexURL)
        for text in ["../segments/source.caf", "/Users/private", "https://drive.google.com/private", "private@example.test", "token\nvalue", "", String(repeating: "a", count: 65)] {
            XCTAssertThrowsError(try store.publish(rows: [source(0, origin: text)], context: context()), "source origin " + text)
            XCTAssertThrowsError(try store.publish(rows: [source(0)], context: context(scope: text)), "context scope " + text)
            let artifact = SyncEvidenceArtifact(kind: "audio", sha256: source(0).sha256, byteCount: 128,
                                                state: text, origin: "restored_ledger")
            XCTAssertThrowsError(try store.publish(rows: [source(0, artifacts: [artifact])], context: context()), "artifact state " + text)
        }
        XCTAssertThrowsError(try store.publish(rows: [source(0)], context: context(counts: ["private@example.test": 1])))
        XCTAssertThrowsError(try store.publish(rows: [source(0)], context: context(counts: ["authorized_source_count": -1])))
        try assertUnavailable(previous: previous)
    }

    func testSourceOriginAndArtifactKindStateOriginUseClosedVocabularies() throws {
        let store = archive()
        try store.publish(rows: [source(0)], context: context())
        let previous = try Data(contentsOf: indexURL)
        XCTAssertThrowsError(try store.publish(rows: [source(0, origin: "unknown_origin")], context: context()))
        for field in ["kind", "state", "origin"] {
            let artifact = SyncEvidenceArtifact(kind: field == "kind" ? "arbitrary_file" : "audio",
                sha256: source(0).sha256, byteCount: 128,
                state: field == "state" ? "invented_success" : "remote_verified",
                origin: field == "origin" ? "private_account_name" : "restored_ledger")
            XCTAssertThrowsError(try store.publish(rows: [source(0, artifacts: [artifact])], context: context()), field)
        }
        try assertUnavailable(previous: previous)
    }

    func testBothTranscriptKindsSurvivePagingAndRestartWithoutTextBodies() throws {
        let artifacts = ["transcriptJSON", "transcriptText"].enumerated().map { offset, kind in
            SyncEvidenceArtifact(kind: kind, sha256: String(format: "%064x", offset + 500), byteCount: 400,
                                 state: "pending", origin: "authorized_ledger")
        }
        let row = source(0, artifacts: artifacts)
        try archive().publish(rows: [row], context: context())
        XCTAssertEqual(try archive().load()?.rows, [row])
    }

    func testICloudDiagnosticsRetainGatedChecksWithoutPromotingProviderConfirmation() throws {
        let store = SyncEvidenceArchive(root: root, stream: "icloud_drive", build: "88")
        for gate in SyncEvidenceICloudProviderGate.allCases {
            let artifact = SyncEvidenceArtifact(kind: "audio", sha256: source(0).sha256, byteCount: 128,
                state: gate == .awaitingLocalExport ? "pending" : "local_exported", origin: "authorized_ledger",
                localExportedAtMS: gate == .awaitingLocalExport ? nil : instant,
                providerCheckedAtMS: instant + 1_000, providerResult: .uploaded, providerGate: gate)
            try store.publish(rows: [source(0, artifacts: [artifact])], context: context())
            let restored = try XCTUnwrap(store.load()?.rows.first?.artifacts.first)
            XCTAssertEqual(restored, artifact)
            XCTAssertNotEqual(restored.state, "provider_uploaded", "A retained positive cannot bypass its current gate")
        }
        let old = SyncEvidenceArtifact(kind: "audio", sha256: source(0).sha256, byteCount: 128,
            state: "provider_uploaded", recordedAtMS: instant, observedAtMS: instant + 1_000, origin: "provider_metadata")
        let bytes = try JSONEncoder().encode(old)
        let decoded = try JSONDecoder().decode(SyncEvidenceArtifact.self, from: bytes)
        XCTAssertEqual(decoded, old)
        XCTAssertNil(decoded.providerResult, "Migration must not invent a typed check from an old positive")
        XCTAssertNil(decoded.localExportedAtMS)
        try store.publish(rows: [source(0, artifacts: [decoded])], context: context())
    }

    func testICloudDiagnosticsRejectInvalidTimesUnpairedChecksAndFalseCurrentClaims() throws {
        let store = SyncEvidenceArchive(root: root, stream: "icloud_drive", build: "88")
        func artifact(time: Int64? = 1_793_183_000_000, result: ICloudDriveProviderObservationStatus? = .uploaded,
                      gate: SyncEvidenceICloudProviderGate? = .current, state: String = "local_exported") -> SyncEvidenceArtifact {
            .init(kind: "audio", sha256: source(0).sha256, byteCount: 128, state: state,
                observedAtMS: instant, origin: "provider_metadata", localExportedAtMS: instant,
                providerCheckedAtMS: time, providerResult: result, providerGate: gate)
        }
        for invalid in [artifact(time: -1), artifact(time: Int64.max), artifact(time: nil),
                        artifact(result: nil), artifact(gate: nil),
                        artifact(gate: .unchecked, state: "provider_uploaded"),
                        artifact(result: .notUploaded, state: "provider_uploaded"),
                        artifact(time: instant + 1, state: "provider_uploaded")] {
            XCTAssertThrowsError(try store.publish(rows: [source(0, artifacts: [invalid])], context: context()))
        }
        let valid = artifact(state: "provider_uploaded")
        try store.publish(rows: [source(0, artifacts: [valid])], context: context())
        XCTAssertThrowsError(try archive().publish(rows: [source(0, artifacts: [valid])], context: context()),
                             "iCloud-only metadata must not appear on Google artifacts")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(valid)) as? [String: Any])
        for field in ["providerResult", "providerGate"] {
            var changed = object; changed[field] = "private@example.test/recording.caf"
            XCTAssertThrowsError(try JSONDecoder().decode(SyncEvidenceArtifact.self,
                from: JSONSerialization.data(withJSONObject: changed)), "Only closed categories may decode")
        }
        object["localExportedAtMS"] = -1
        let invalid = try JSONDecoder().decode(SyncEvidenceArtifact.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try store.publish(rows: [source(0, artifacts: [invalid])], context: context()))
    }

    func testFutureGrantBoundaryAndBaselinePersistAcrossRestartAndRejectInvalidBaseline() throws {
        let store = archive()
        let baseline = [source(3).segmentID, source(1).segmentID]
        let grant = SyncEvidenceContext(scope: "phone_authorized_discovered", libraryID: libraryID,
            scopeMode: "futureOnly", authorizedAtMS: instant, baselineIDs: baseline, enabled: true,
            discoveryComplete: false, counts: ["authorized_source_count": 1])
        try store.publish(rows: [source(4)], context: grant)
        let restored = try XCTUnwrap(archive().load())
        XCTAssertEqual(restored.context.authorizedAtMS, instant)
        XCTAssertEqual(restored.context.baselineIDs, baseline.sorted { $0.uuidString < $1.uuidString })
        XCTAssertEqual(restored.context.scopeMode, "futureOnly")
        XCTAssertFalse(restored.context.discoveryComplete, "A complete page collection cannot promote incomplete Phone discovery")
        let previous = try Data(contentsOf: indexURL)
        for (time, ids) in [(instant, [source(1).segmentID, source(1).segmentID]), (-1, baseline)] {
            let invalid = SyncEvidenceContext(scope: "phone_authorized_discovered", libraryID: libraryID,
                scopeMode: "futureOnly", authorizedAtMS: time, baselineIDs: ids, enabled: true,
                discoveryComplete: false)
            XCTAssertThrowsError(try store.publish(rows: [source(4)], context: invalid))
            try assertUnavailable(previous: previous)
        }
    }

    func testUnsafeStreamNeverCreatesPathsWhenPublishOrMarkUnavailableFails() throws {
        let unsafe = "../../outside-evidence"
        let outside = root.appendingPathComponent("outside-evidence")
        let store = SyncEvidenceArchive(root: root, stream: unsafe, build: "private@example.test")
        XCTAssertThrowsError(try store.publish(rows: [source(0)], context: context()))
        store.markUnavailable()
        XCTAssertThrowsError(try store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path), "Failure reporting must not turn an invalid stream into a write path")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("SyncEvidence").path))
    }

    func testLoadRejectsAnAliasedArchiveDirectory() throws {
        let external = root.appendingPathComponent("external")
        let selected = root.appendingPathComponent("selected")
        for folder in [external, selected] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let store = SyncEvidenceArchive(root: external, stream: "google_drive", build: "61")
        try store.publish(rows: [source(0)], context: context())
        try FileManager.default.createSymbolicLink(at: selected.appendingPathComponent("SyncEvidence"),
                                                  withDestinationURL: external.appendingPathComponent("SyncEvidence"))
        XCTAssertThrowsError(try SyncEvidenceArchive(root: selected, stream: "google_drive", build: "61").load())
    }

    func testSameLibraryCannotPublishAnotherAudioIdentityForAnExistingSource() throws {
        let store = archive()
        try store.publish(rows: [source(0)], context: context())
        let previous = try Data(contentsOf: indexURL)
        XCTAssertThrowsError(try store.publish(rows: [source(0, sha256: String(repeating: "f", count: 64))], context: context()))
        try assertUnavailable(previous: previous)
    }

    func testSingleFileCaptureKeepsOriginalPublishedGenerationAfterTwelvePageCleanups() throws {
        let store = archive(), rows = (0..<137).map { source($0) }
        try store.publish(rows: rows, context: context(count: rows.count))
        let saved = try Data(contentsOf: captureURL), savedStatus = try Data(contentsOf: captureStatusURL)
        let original = try verifyCapture(saved, statusBytes: savedStatus)
        XCTAssertEqual(try json(try XCTUnwrap(original["index"])), try json(try object(at: indexURL)))
        XCTAssertEqual(try json(try XCTUnwrap(original["status"])), try json(try object(at: statusURL)))
        let first = try XCTUnwrap(store.load()).index
        for turn in 0..<12 {
            try store.publish(rows: rows + [source(200 + turn)], context: context(count: rows.count + 1))
        }
        for page in first.pages { XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(page.name).path)) }
        XCTAssertEqual(try verifyCapture(saved, statusBytes: savedStatus)["generationID"] as? String, first.generationID.uuidString)
        let current = try verifyCapture(Data(contentsOf: captureURL), statusBytes: Data(contentsOf: captureStatusURL))
        XCTAssertNotEqual(current["generationID"] as? String, first.generationID.uuidString)
        for file in [captureURL, captureStatusURL] {
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        }
    }

    func testCaptureBindingRejectsLengthHashGenerationAndMixedPageTampering() throws {
        try archive().publish(rows: (0..<70).map { source($0) }, context: context(count: 70))
        let original = try Data(contentsOf: captureURL), outer = try Data(contentsOf: captureStatusURL)
        for field in ["outer_hash", "outer_length", "index_generation", "status_generation", "page_generation", "page_length", "page_hash", "page_name"] {
            var value = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
            var outerValue = try XCTUnwrap(JSONSerialization.jsonObject(with: outer) as? [String: Any])
            if field == "outer_hash" { outerValue["captureSHA256"] = String(repeating: "f", count: 64) }
            else if field == "outer_length" { outerValue["captureByteCount"] = original.count + 1 }
            else if field == "index_generation" || field == "status_generation" {
                let key = field == "index_generation" ? "index" : "status"
                var nested = try XCTUnwrap(value[key] as? [String: Any]); nested["generationID"] = UUID().uuidString; value[key] = nested
            } else {
                var index = try XCTUnwrap(value["index"] as? [String: Any])
                var refs = try XCTUnwrap(index["pages"] as? [[String: Any]])
                var pages = try XCTUnwrap(value["pages"] as? [[String: Any]])
                if field == "page_generation" {
                    var body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(pages[0]["bytesBase64"] as? String)))) as? [String: Any])
                    body["generationID"] = UUID().uuidString
                    let raw = try json(body); pages[0]["bytesBase64"] = raw.base64EncodedString()
                    refs[0]["byteCount"] = raw.count; refs[0]["sha256"] = digest(raw)
                } else if field == "page_length" { refs[0]["byteCount"] = 1 }
                else if field == "page_hash" { refs[0]["sha256"] = String(repeating: "f", count: 64) }
                else { pages[0]["name"] = pages[1]["name"] }
                index["pages"] = refs; value["index"] = index; value["pages"] = pages
            }
            let changed = try json(value)
            let changedOuter = field.hasPrefix("outer_") ? try json(outerValue) : try reboundCaptureStatus(changed, original: outer)
            XCTAssertThrowsError(try verifyCapture(changed, statusBytes: changedOuter), field)
        }
    }

    func testCaptureCapacityFailureDoesNotFailOrdinaryArchiveAndReplacesOldBlobWithUnavailable() throws {
        let store = archive()
        try store.publish(rows: [source(0)], context: context())
        let old = try Data(contentsOf: captureURL)
        let artifacts = (0..<12).map { number in
            SyncEvidenceArtifact(kind: "audio", sha256: String(format: "%064x", number + 500), byteCount: Int64.max,
                state: "provider_uploaded", recordedAtMS: Int64.max, observedAtMS: Int64.max, origin: "stored_receipt_metadata")
        }
        let rows = (0..<2_200).map { source($0, artifacts: artifacts) }
        XCTAssertNoThrow(try store.publish(rows: rows, context: context(count: rows.count)))
        let index = try XCTUnwrap(store.load()).index
        XCTAssertEqual(index.sourceCount, rows.count)
        XCTAssertGreaterThan(index.pages.reduce(0) { $0 + (($1.byteCount + 2) / 3) * 4 }, SyncEvidenceArchive.maximumCaptureBytes)
        XCTAssertEqual(try status()["available"] as? Bool, true)
        let unavailable = try object(at: captureURL)
        XCTAssertNotEqual(try Data(contentsOf: captureURL), old)
        XCTAssertEqual(unavailable["available"] as? Bool, false)
        XCTAssertEqual(unavailable["failureCode"] as? String, "capacity_exceeded")
        XCTAssertNil(unavailable["index"])
        let sidecar = try object(at: captureStatusURL)
        XCTAssertEqual(sidecar["available"] as? Bool, false)
        XCTAssertEqual(sidecar["failureCode"] as? String, "capacity_exceeded")
        XCTAssertNil(sidecar["generationID"])
        XCTAssertThrowsError(try verifyCapture(Data(contentsOf: captureURL), statusBytes: Data(contentsOf: captureStatusURL)))
        try store.publish(rows: [source(0)], context: context())
        _ = try verifyCapture(Data(contentsOf: captureURL), statusBytes: Data(contentsOf: captureStatusURL))
    }

    func testCaptureWriteRefusesAliasesAndDirectoriesWithoutFailingArchive() throws {
        for kind in ["symlink", "hardlink", "fifo", "directory"] {
            let fixture = root.appendingPathComponent("capture-" + kind)
            try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
            let store = SyncEvidenceArchive(root: fixture, stream: "google_drive", build: "61")
            try store.publish(rows: [source(0)], context: context())
            let base = fixture.appendingPathComponent("SyncEvidence/google_drive"), target = base.appendingPathComponent("metadata-capture.json")
            let old = try Data(contentsOf: target), preserved = fixture.appendingPathComponent("preserved.json")
            try FileManager.default.moveItem(at: target, to: preserved)
            if kind == "symlink" { try FileManager.default.createSymbolicLink(at: target, withDestinationURL: preserved) }
            else if kind == "hardlink" { try FileManager.default.linkItem(at: preserved, to: target) }
            else if kind == "fifo" { XCTAssertEqual(Darwin.mkfifo(target.path, 0o600), 0) }
            else { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false) }
            XCTAssertNoThrow(try store.publish(rows: [source(0), source(1)], context: context(count: 2)), kind)
            XCTAssertEqual(try store.load()?.rows.count, 2, kind)
            XCTAssertEqual(try object(at: base.appendingPathComponent("status.json"))["available"] as? Bool, true, kind)
            XCTAssertEqual(try object(at: base.appendingPathComponent("capture-status.json"))["available"] as? Bool, false, kind)
            XCTAssertEqual(try Data(contentsOf: preserved), old, kind)
        }
    }

    func testCaptureStatusWriteFailureIndependentlyInvalidatesBlobWithoutFailingArchive() throws {
        let store = archive()
        try store.publish(rows: [source(0)], context: context())
        let old = try Data(contentsOf: captureURL), preserved = root.appendingPathComponent("preserved-capture-status.json")
        try FileManager.default.moveItem(at: captureStatusURL, to: preserved)
        try FileManager.default.createSymbolicLink(at: captureStatusURL, withDestinationURL: preserved)
        let originalStatus = try Data(contentsOf: preserved)
        XCTAssertNoThrow(try store.publish(rows: [source(0), source(1)], context: context(count: 2)))
        XCTAssertEqual(try store.load()?.rows.count, 2)
        XCTAssertNotEqual(try Data(contentsOf: captureURL), old)
        let unavailable = try object(at: captureURL)
        XCTAssertEqual(unavailable["available"] as? Bool, false)
        XCTAssertEqual(unavailable["failureCode"] as? String, "capture_unavailable")
        XCTAssertNil(unavailable["index"])
        XCTAssertEqual(try Data(contentsOf: preserved), originalStatus)
        XCTAssertNotEqual(try status()["generationID"] as? String, try object(at: preserved)["generationID"] as? String,
                          "A collector must independently reject an aliased/unwritable status and never claim current authorization from old sidecars")
        store.markUnavailable()
        XCTAssertEqual(try object(at: captureURL)["available"] as? Bool, false)
        XCTAssertEqual(try object(at: captureURL)["failureCode"] as? String, "evidence_unavailable")
        XCTAssertEqual(try Data(contentsOf: preserved), originalStatus, "Invalidation must not follow a status alias")
    }

    func testExplicitAndOrdinaryFailuresInvalidateCaptureAndRecoveryPublishesFreshBlob() throws {
        let store = archive()
        try store.publish(rows: [source(0)], context: context())
        let old = try Data(contentsOf: captureURL)
        store.markUnavailable()
        XCTAssertNotEqual(try Data(contentsOf: captureURL), old)
        XCTAssertEqual(try object(at: captureURL)["available"] as? Bool, false)
        XCTAssertEqual(try object(at: captureStatusURL)["available"] as? Bool, false)
        XCTAssertThrowsError(try verifyCapture(old, statusBytes: Data(contentsOf: captureStatusURL)))
        try store.publish(rows: [source(0)], context: context())
        let restored = try Data(contentsOf: captureURL)
        _ = try verifyCapture(restored, statusBytes: Data(contentsOf: captureStatusURL))
        XCTAssertThrowsError(try store.publish(rows: [source(0, sha256: "invalid")], context: context()))
        XCTAssertNotEqual(try Data(contentsOf: captureURL), restored)
        XCTAssertEqual(try object(at: captureURL)["available"] as? Bool, false)
        XCTAssertEqual(try object(at: captureStatusURL)["available"] as? Bool, false)
        XCTAssertEqual(try status()["available"] as? Bool, false)
    }

    func testCaptureSupportsEmptyAndAllThreeMetadataStreams() throws {
        try archive().publish(rows: [], context: context(count: 0))
        let empty = try verifyCapture(Data(contentsOf: captureURL), statusBytes: Data(contentsOf: captureStatusURL))
        XCTAssertEqual((empty["pages"] as? [Any])?.count, 0)
        for stream in ["phone_receipts", "google_drive", "icloud_drive"] {
            let store = SyncEvidenceArchive(root: root, stream: stream, build: "61")
            try store.publish(rows: [source(0)], context: context())
            let base = root.appendingPathComponent("SyncEvidence/" + stream)
            let bytes = try Data(contentsOf: base.appendingPathComponent("metadata-capture.json"))
            let capture = try object(at: base.appendingPathComponent("metadata-capture.json"))
            let outer = try object(at: base.appendingPathComponent("capture-status.json"))
            XCTAssertEqual(capture["stream"] as? String, stream)
            XCTAssertEqual(outer["stream"] as? String, stream)
            XCTAssertEqual(outer["available"] as? Bool, true)
            XCTAssertEqual(outer["captureSHA256"] as? String, digest(bytes))
            XCTAssertEqual(outer["captureByteCount"] as? Int, bytes.count)
            XCTAssertEqual(capture["generationID"] as? String, outer["generationID"] as? String)
        }
    }

    private final class CaptureObservation: @unchecked Sendable {
        private let lock = NSLock()
        private var running = true
        private var reads = 0
        private var failures = 0
        func isRunning() -> Bool { lock.lock(); defer { lock.unlock() }; return running }
        func record(valid: Bool) { lock.lock(); defer { lock.unlock() }; reads += 1; if !valid { failures += 1 } }
        func stop() { lock.lock(); defer { lock.unlock() }; running = false }
        func result() -> (reads: Int, failures: Int) { lock.lock(); defer { lock.unlock() }; return (reads, failures) }
    }

    func testContinuousSuccessfulPublicationsNeverCreateAnUnavailableCaptureWindow() throws {
        let store = archive(), rows = (0..<137).map { source($0) }
        try store.publish(rows: rows, context: context(count: rows.count))
        let capturedURL = captureURL, observedStatusURL = captureStatusURL
        let observations = CaptureObservation(), started = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            started.signal()
            while observations.isRunning() {
                do {
                    let capture = try JSONSerialization.jsonObject(with: Data(contentsOf: capturedURL)) as? [String: Any]
                    let status = try JSONSerialization.jsonObject(with: Data(contentsOf: observedStatusURL)) as? [String: Any]
                    let index = capture?["index"] as? [String: Any], embedded = capture?["status"] as? [String: Any]
                    observations.record(valid: capture?["available"] as? Bool == true && status?["available"] as? Bool == true
                        && capture?["generationID"] as? String == index?["generationID"] as? String
                        && capture?["generationID"] as? String == embedded?["generationID"] as? String)
                } catch { observations.record(valid: false) }
                Thread.sleep(forTimeInterval: 0.0005)
            }
            finished.signal()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
        for turn in 0..<12 { try store.publish(rows: rows + [source(200 + turn)], context: context(count: rows.count + 1)) }
        observations.stop()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertGreaterThan(observations.result().reads, 0)
        XCTAssertEqual(observations.result().failures, 0,
                       "A historical self-contained generation stays readable during ordinary newer publications")
    }
}
