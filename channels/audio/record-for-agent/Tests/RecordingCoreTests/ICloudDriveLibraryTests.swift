import Darwin
import Foundation
import XCTest
@testable import RecordingCore

/// Synthetic local files only. Passing these tests says nothing about actual
/// iCloud upload, a real device, or completeness of an authorized recording day.
final class ICloudDriveLibraryTests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)
    private var temporary: [URL] = []
    override func tearDownWithError() throws {
        for url in temporary { try? FileManager.default.removeItem(at: url) }
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("icloud-core-synthetic-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        temporary.append(url); return url
    }
    private func manifest(_ data: Data = Data("synthetic audio".utf8), id: UUID = UUID(), start: Date? = nil,
                          location: SegmentLocation? = nil, sequence: Int = 0,
                          group: RecordingGroup? = nil) -> SegmentManifest {
        let start = start ?? instant
        return .init(id: id, sessionID: UUID(), sequence: sequence, startedAt: start, endedAt: start.addingTimeInterval(10),
                     sampleRate: 16_000, frameCount: 160_000, fileName: id.uuidString.lowercased() + ".caf",
                     byteCount: Int64(data.count), sha256: ICloudDriveLibraryLedger.digest(data),
                     timeZoneIdentifier: "Asia/Shanghai", location: location, recordingGroup: group)
    }
    private func transcript(_ manifest: SegmentManifest, text: String = "合成测试：确认同步后再整理。", offset: TimeInterval = 1) -> SegmentTranscript {
        .init(segmentID: manifest.id, audioSHA256: manifest.sha256, locale: "zh-CN", engine: "synthetic",
              createdAt: instant.addingTimeInterval(offset), text: text, spans: [])
    }
    private func ledger(_ manifests: [SegmentManifest]) throws -> ICloudDriveLibraryLedger {
        var value = ICloudDriveLibraryLedger()
        try value.authorize(.existingAndFuture, knownIDs: Set(manifests.map(\.id)), at: instant)
        try value.discover(manifests: manifests, receivedIDs: Set(manifests.map(\.id)))
        return value
    }
    private func source(_ data: Data) throws -> URL {
        let url = try directory().appendingPathComponent("source.caf")
        try data.write(to: url, options: [.withoutOverwriting]); return url
    }
    private func files(_ url: URL) -> [String] {
        (FileManager.default.enumerator(atPath: url.path)?.allObjects as? [String] ?? []).sorted()
    }
    private final class Budget: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private let limit: Int
        init(_ limit: Int) { self.limit = limit }
        func next() -> Bool { lock.lock(); defer { lock.unlock() }; count += 1; return count <= limit }
        var observations: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    func testNoGrantHasNoJobsAndPauseDoesNotAuthorize() throws {
        let manifest = manifest()
        var value = ICloudDriveLibraryLedger()
        try value.discover(manifests: [manifest], receivedIDs: [manifest.id])
        XCTAssertTrue(value.jobs.isEmpty); XCTAssertFalse(value.enabled)
        XCTAssertThrowsError(try value.setEnabled(true))
        XCTAssertThrowsError(try value.discoverTranscript(transcript(manifest), for: manifest))
        try value.validate()
    }

    func testFutureOnlyExcludesBaselineAndLateOldDataAndRequiresDurableReceivedID() throws {
        let known = manifest(start: instant.addingTimeInterval(1))
        let late = manifest(start: instant.addingTimeInterval(-1))
        let boundary = manifest(start: instant)
        let unreceived = manifest(start: instant.addingTimeInterval(2))
        var value = ICloudDriveLibraryLedger()
        try value.authorize(.futureOnly, knownIDs: [known.id], at: instant)
        try value.discover(manifests: [known, late, boundary, unreceived], receivedIDs: [known.id, late.id, boundary.id])
        XCTAssertEqual(value.jobs.map(\.id), [boundary.id])
        try value.setEnabled(false)
        try value.discover(manifests: [unreceived], receivedIDs: [unreceived.id])
        XCTAssertEqual(value.jobs.count, 1)
        let restored = try TransportCodec.decode(ICloudDriveLibraryLedger.self, from: TransportCodec.encode(value))
        try restored.validate(); XCTAssertEqual(restored, value)
        XCTAssertThrowsError(try value.authorize(.existingAndFuture, knownIDs: []))
    }

    func testChangedManifestDiscoveryIsAtomic() throws {
        let original = manifest(), other = manifest()
        var value = try ledger([original]); let before = value
        let changed = SegmentManifest(id: original.id, sessionID: original.sessionID, sequence: 1,
            startedAt: original.startedAt, endedAt: original.endedAt, sampleRate: original.sampleRate,
            frameCount: original.frameCount, fileName: original.fileName, byteCount: original.byteCount, sha256: original.sha256)
        XCTAssertThrowsError(try value.discover(manifests: [other, changed], receivedIDs: [other.id, changed.id]))
        XCTAssertEqual(value, before)
    }

    func testBaselineEncodingIsCanonicalAndLegacyUnsortedArrayPreservesGrant() throws {
        let ids = ["FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF",
                   "00000000-0000-0000-0000-000000000001",
                   "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"].map { UUID(uuidString: $0)! }
        var value = ICloudDriveLibraryLedger(libraryID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!)
        try value.authorize(.futureOnly, knownIDs: Set(ids), at: instant)
        try value.setEnabled(false)
        let encoded = try TransportCodec.encode(value)
        let canonical = #"{"authorizedAt":1800000000000,"baselineIDs":["00000000-0000-0000-0000-000000000001","AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA","FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"],"enabled":false,"jobs":[],"libraryID":"BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB","recordingScope":"futureOnly","schemaVersion":1}"#
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), canonical,
            "A fixed byte expectation must hold independently of this process's Set hash seed.")
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(legacy["baselineIDs"] as? [String], ids.map(\.uuidString).sorted())
        legacy["baselineIDs"] = ids.map(\.uuidString)
        let restored = try TransportCodec.decode(ICloudDriveLibraryLedger.self,
            from: JSONSerialization.data(withJSONObject: legacy))
        try restored.validate()
        XCTAssertEqual(restored, value, "Migration must preserve the grant, baseline exclusion and paused state.")
        XCTAssertEqual(try TransportCodec.encode(restored), encoded)
        var reversed = ICloudDriveLibraryLedger(libraryID: value.libraryID)
        try reversed.authorize(.futureOnly, knownIDs: Set(ids.reversed()), at: instant)
        try reversed.setEnabled(false)
        XCTAssertEqual(try TransportCodec.encode(reversed), encoded)
    }

    func testExportCommitIsContentAddressedPrivateAndStripsLocation() throws {
        let data = Data("synthetic audio".utf8)
        let original = manifest(data, location: .init(latitude: 31, longitude: 121, horizontalAccuracy: 10, capturedAt: instant))
        var value = try ledger([original]); let root = try directory(); let source = try source(data)
        let writer = ICloudDriveExportWriter(root: root, libraryID: value.libraryID)
        XCTAssertThrowsError(try writer.validateMarker())
        XCTAssertTrue(files(root).isEmpty, "Read-only marker validation must not create a folder.")
        let receipt = try writer.export(job: value.jobs[0], audioURL: source)
        try value.recordExported(receipt)
        XCTAssertEqual(value.exportedAudioCount, 1); XCTAssertFalse(value.hasPendingFiles)
        XCTAssertEqual(receipt.artifacts.count, 2)
        let exportedManifest = try XCTUnwrap(receipt.artifacts.first { $0.kind == .manifest })
        let bytes = try Data(contentsOf: writer.libraryURL.appendingPathComponent(exportedManifest.relativePath))
        let decoded = try TransportCodec.decode(SegmentManifest.self, from: bytes)
        XCTAssertNil(decoded.location); XCTAssertEqual(decoded.timeZoneIdentifier, "Asia/Shanghai")
        XCTAssertNotNil(original.location); XCTAssertEqual(try Data(contentsOf: source), data)
        XCTAssertTrue(FileManager.default.fileExists(atPath: writer.libraryURL.appendingPathComponent(receipt.relativePath).path))
        XCTAssertEqual(receipt.exportDigest, ICloudDriveLibraryLedger.exportDigest(receipt.artifacts))
        let restored = try TransportCodec.decode(ICloudDriveLibraryLedger.self, from: TransportCodec.encode(value))
        try restored.validate(); XCTAssertEqual(restored, value)
    }

    func testRetryIsIdempotentAndDoesNotDuplicateCommit() throws {
        let data = Data("retry".utf8), root = try directory(), input = try source(Data("retry".utf8))
        var value = try ledger([manifest(data)])
        let writer = ICloudDriveExportWriter(root: root, libraryID: value.libraryID)
        let first = try writer.export(job: value.jobs[0], audioURL: input); try value.recordExported(first)
        let before = files(root)
        let again = try writer.export(job: value.jobs[0], audioURL: input); try value.recordExported(again)
        XCTAssertEqual(first.exportDigest, again.exportDigest); XCTAssertEqual(files(root), before)
        XCTAssertEqual(files(root).filter { $0.hasPrefix(writer.libraryURL.lastPathComponent + "/commits/") && $0.hasSuffix(".json") }.count, 1)
    }

    func testGroupedAudioUsesRecordedTimeAndPreservesExistingLibraryReceipts() throws {
        let data = Data("grouped synthetic audio".utf8)
        let root = try directory(), input = try source(data)
        let legacy = manifest(data)
        var value = try ledger([legacy])
        let writer = ICloudDriveExportWriter(root: root, libraryID: value.libraryID)
        let legacyReceipt = try writer.export(job: value.jobs[0], audioURL: input)
        try value.recordExported(legacyReceipt)
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let group = RecordingGroup(startedAt: start, timeZone: TimeZone(secondsFromGMT: 8 * 3600)!, firstSequence: 12)
        let part = manifest(data, start: start.addingTimeInterval(60), sequence: 13, group: group)
        try value.discover(manifests: [legacy, part], receivedIDs: [legacy.id, part.id])

        let job = try XCTUnwrap(value.jobs.first { $0.id == part.id })
        let audio = try XCTUnwrap(job.artifacts.first { $0.kind == .audio })
        XCTAssertEqual(audio.relativePath, "audio/2023-11-15_06-13-20+0800_\(group.id.uuidString.lowercased())/"
            + "2023-11-15_06-14-20+0800_part002_\(part.id.uuidString.lowercased()).caf")
        let receipt = try writer.export(job: job, audioURL: input)
        try value.recordExported(receipt)
        let restored = try TransportCodec.decode(ICloudDriveLibraryLedger.self, from: TransportCodec.encode(value))
        try restored.validate()
        XCTAssertEqual(restored.exportedAudioCount, 2)
        XCTAssertEqual(try writer.export(job: restored.jobs[0], audioURL: input).exportDigest, legacyReceipt.exportDigest)
        XCTAssertEqual(try writer.export(job: restored.jobs[1], audioURL: input).exportDigest, receipt.exportDigest)
        XCTAssertEqual(GoogleDriveLibraryLedger.exportManifest(part).recordingGroup, group)
    }

    func testLateTranscriptCreatesVersionWithoutRehashingUnchangedAudio() throws {
        let data = Data(repeating: 7, count: 8 * 1_024 * 1_024), root = try directory(), input = try source(Data(repeating: 7, count: 8 * 1_024 * 1_024))
        let original = manifest(data); var value = try ledger([original])
        let writer = ICloudDriveExportWriter(root: root, libraryID: value.libraryID)
        try value.recordExported(writer.export(job: value.jobs[0], audioURL: input))
        let firstTranscript = transcript(original)
        try value.discoverTranscript(firstTranscript, for: original)
        let budget = Budget(40)
        let first = try writer.export(job: value.jobs[0], audioURL: input, transcript: firstTranscript, while: budget.next)
        XCTAssertLessThan(budget.observations, 40, "Rehashing 8 MiB would exceed this chunk budget.")
        try value.recordExported(first)
        XCTAssertEqual(value.exportedTranscriptCount, 1); XCTAssertFalse(value.hasPendingFiles)
        let secondTranscript = transcript(original, text: "合成测试：更新后的转写。", offset: 2)
        try value.discoverTranscript(secondTranscript, for: original)
        let second = try writer.export(job: value.jobs[0], audioURL: input, transcript: secondTranscript)
        try value.recordExported(second)
        XCTAssertNotEqual(first.transcriptVersionSHA256, second.transcriptVersionSHA256)
        XCTAssertTrue(FileManager.default.fileExists(atPath: writer.libraryURL.appendingPathComponent(first.relativePath).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: writer.libraryURL.appendingPathComponent(second.relativePath).path))
        XCTAssertEqual(value.jobs[0].artifacts.filter { $0.kind == .transcriptJSON }.count, 2)
        let textArtifact = try XCTUnwrap(second.artifacts.first { $0.kind == .transcriptText })
        XCTAssertEqual(try Data(contentsOf: writer.libraryURL.appendingPathComponent(textArtifact.relativePath)), Data((secondTranscript.text + "\n").utf8))
    }

    func testLateTranscriptWithChangedAudioIdentityRequiresExplicitRevalidationWithoutOpeningIt() throws {
        let data = Data("synthetic known export".utf8), root = try directory(), input = try source(data)
        let original = manifest(data); var value = try ledger([original])
        let writer = ICloudDriveExportWriter(root: root, libraryID: value.libraryID)
        let first = try writer.export(job: value.jobs[0], audioURL: input)
        try value.recordExported(first)
        let item = try XCTUnwrap(first.artifacts.first { $0.kind == .audio })
        let target = writer.libraryURL.appendingPathComponent(item.relativePath)
        let originalFiles = files(root)
        // chmod changes ctime without changing content, mtime, inode or size.
        // Mode 000 also makes an accidental open/hash fail with a different
        // error, so requiresRevalidation must be returned before any read.
        XCTAssertEqual(chmod(target.path, 0), 0)
        defer { _ = chmod(target.path, 0o600) }
        let text = transcript(original)
        try value.discoverTranscript(text, for: original)
        XCTAssertThrowsError(try writer.export(job: value.jobs[0], audioURL: input, transcript: text)) {
            XCTAssertEqual($0 as? ICloudDriveLibraryError, .requiresRevalidation)
        }
        XCTAssertEqual(files(root), originalFiles, "No replacement, new transcript or commit is installed.")
        XCTAssertEqual(value.exportedTranscriptCount, 0)
        XCTAssertTrue(value.hasPendingFiles)
        XCTAssertEqual(chmod(target.path, 0o600), 0)
        XCTAssertEqual(try Data(contentsOf: target), data)
    }

    func testTargetedLocalRevalidationChecksBytesPreservesCommitAndNeverReexportsMissingAudio() throws {
        let data = Data("synthetic known export".utf8), root = try directory(), input = try source(data)
        let original = manifest(data); var value = try ledger([original])
        let writer = ICloudDriveExportWriter(root: root, libraryID: value.libraryID)
        let first = try writer.export(job: value.jobs[0], audioURL: input)
        try value.recordExported(first)
        let item = try XCTUnwrap(first.artifacts.first { $0.kind == .audio })
        let target = writer.libraryURL.appendingPathComponent(item.relativePath)
        let commit = writer.libraryURL.appendingPathComponent(first.relativePath)
        let committed = try Data(contentsOf: commit)
        XCTAssertEqual(chmod(target.path, 0o640), 0)
        let repaired = try writer.export(job: value.jobs[0], audioURL: input, revalidateLocalAudio: true)
        XCTAssertNotEqual(first.localFileIdentities[item.key], repaired.localFileIdentities[item.key])
        XCTAssertEqual(try Data(contentsOf: commit), committed)
        try value.recordExported(repaired)
        var before = stat()
        XCTAssertEqual(lstat(target.path, &before), 0)
        let handle = try FileHandle(forWritingTo: target)
        try handle.write(contentsOf: Data(repeating: 88, count: data.count)); try handle.close()
        var times = [before.st_atimespec, before.st_mtimespec]
        XCTAssertEqual(utimensat(AT_FDCWD, target.path, &times, 0), 0)
        // Same inode, size and restored mtime is not enough to trust the hash.
        XCTAssertThrowsError(try writer.export(job: value.jobs[0], audioURL: input, revalidateLocalAudio: true)) {
            XCTAssertEqual($0 as? ICloudDriveLibraryError, .conflict)
        }
        XCTAssertEqual(try Data(contentsOf: target), Data(repeating: 88, count: data.count))
        XCTAssertEqual(try Data(contentsOf: commit), committed)
        try FileManager.default.removeItem(at: target)
        XCTAssertThrowsError(try writer.export(job: value.jobs[0], audioURL: input, revalidateLocalAudio: true)) {
            XCTAssertEqual($0 as? ICloudDriveLibraryError, .requiresRevalidation)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testDeviceIdentityDriftRequiresExplicitTargetHashAndPreservesCommit() throws {
        let data = Data("synthetic device drift".utf8), root = try directory(), input = try source(data)
        var value = try ledger([manifest(data)])
        let writer = ICloudDriveExportWriter(root: root, libraryID: value.libraryID)
        let first = try writer.export(job: value.jobs[0], audioURL: input)
        try value.recordExported(first)
        let item = try XCTUnwrap(first.artifacts.first { $0.kind == .audio })
        let target = writer.libraryURL.appendingPathComponent(item.relativePath)
        let commit = writer.libraryURL.appendingPathComponent(first.relativePath)
        let committed = try Data(contentsOf: commit)
        // Simulate persisted evidence from a different device number without
        // changing the destination inode, size, mtime or synthetic bytes.
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: TransportCodec.encode(value.jobs[0])) as? [String: Any])
        var identities = try XCTUnwrap(encoded["exportedFiles"] as? [String: [String: Any]])
        identities[item.key]?["device"] = first.localFileIdentities[item.key]!.device ^ 4
        encoded["exportedFiles"] = identities
        let stale = try TransportCodec.decode(ICloudDriveLibraryJob.self, from: JSONSerialization.data(withJSONObject: encoded))
        XCTAssertThrowsError(try writer.export(job: stale, audioURL: input)) {
            XCTAssertEqual($0 as? ICloudDriveLibraryError, .requiresRevalidation)
        }
        for field in ["inode", "byteCount", "modificationSeconds"] {
            var changed = identities
            let previous = try XCTUnwrap(changed[item.key]?[field] as? NSNumber)
            changed[item.key]?[field] = previous.int64Value + 1
            var changedJob = encoded; changedJob["exportedFiles"] = changed
            let ineligible = try TransportCodec.decode(ICloudDriveLibraryJob.self,
                from: JSONSerialization.data(withJSONObject: changedJob))
            XCTAssertThrowsError(try writer.export(job: ineligible, audioURL: input, revalidateLocalAudio: true)) {
                XCTAssertEqual($0 as? ICloudDriveLibraryError, .requiresRevalidation, field)
            }
        }
        try FileManager.default.removeItem(at: input)
        let repaired = try writer.export(job: stale, audioURL: input, revalidateLocalAudio: true)
        XCTAssertEqual(repaired.localFileIdentities[item.key], first.localFileIdentities[item.key])
        XCTAssertEqual(try Data(contentsOf: commit), committed)
        // A changed device number must never bypass the content digest check.
        var before = stat()
        XCTAssertEqual(lstat(target.path, &before), 0)
        let handle = try FileHandle(forWritingTo: target)
        try handle.write(contentsOf: Data(repeating: 88, count: data.count)); try handle.close()
        var times = [before.st_atimespec, before.st_mtimespec]
        XCTAssertEqual(utimensat(AT_FDCWD, target.path, &times, 0), 0)
        XCTAssertThrowsError(try writer.export(job: stale, audioURL: input, revalidateLocalAudio: true)) {
            XCTAssertEqual($0 as? ICloudDriveLibraryError, .conflict)
        }
        XCTAssertEqual(try Data(contentsOf: commit), committed)
        try FileManager.default.removeItem(at: target)
        XCTAssertThrowsError(try writer.export(job: stale, audioURL: input, revalidateLocalAudio: true)) {
            XCTAssertEqual($0 as? ICloudDriveLibraryError, .requiresRevalidation)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testPendingTranscriptVersionsCoalesceButCommittedVersionsRemain() throws {
        let original = manifest(); var value = try ledger([original])
        try value.discoverTranscript(transcript(original, text: "第一版"), for: original)
        try value.discoverTranscript(transcript(original, text: "第二版", offset: 2), for: original)
        XCTAssertEqual(value.jobs[0].artifacts.count, 4)
        XCTAssertEqual(value.jobs[0].artifacts.first { $0.kind == .transcriptJSON }?.sha256,
                       ICloudDriveLibraryLedger.digest(try TransportCodec.encode(transcript(original, text: "第二版", offset: 2))))
    }

    func testBatchTranscriptDiscoveryMatchesSingleAPI() throws {
        let originals = (0..<3).map { _ in manifest() }
        let items = originals.map { (transcript: transcript($0), manifest: $0) }
        var batch = try ledger(originals), singles = batch
        try batch.discoverTranscripts(items)
        for item in items { try singles.discoverTranscript(item.transcript, for: item.manifest) }
        XCTAssertEqual(batch, singles)
        XCTAssertEqual(batch.jobs.map { $0.artifacts.count }, [4, 4, 4])
        try batch.validate()
    }

    func testUnchanged288TranscriptBatchLeaves437JobLedgerUnchanged() throws {
        let originals = (0..<437).map { _ in manifest() }
        let items = originals.prefix(288).map { (transcript: transcript($0), manifest: $0) }
        var value = try ledger(originals)
        try value.discoverTranscripts(items)
        let before = value
        try value.discoverTranscripts(items)
        XCTAssertEqual(value, before)
        try value.discoverTranscripts([])
        XCTAssertEqual(value, before)
        var restored = try TransportCodec.decode(ICloudDriveLibraryLedger.self, from: TransportCodec.encode(value))
        try restored.discoverTranscripts(items)
        XCTAssertEqual(restored, before)
        XCTAssertEqual(value.jobs.filter { $0.artifacts.count == 4 }.count, 288)
        XCTAssertEqual(value.jobs.filter { $0.artifacts.count == 2 }.count, 149)
    }

    func testBatchTranscriptDiscoveryRollsBackEveryMemberOnBadTranscript() throws {
        let first = manifest(), second = manifest(), unrelated = manifest()
        var value = try ledger([first, second]); let before = value
        XCTAssertThrowsError(try value.discoverTranscripts([
            (transcript: transcript(first), manifest: first),
            (transcript: transcript(unrelated), manifest: second)
        ])) { error in
            XCTAssertEqual(error as? SegmentTranscriptValidationError, .segmentMismatch)
        }
        XCTAssertEqual(value, before)
        let wrongAudio = SegmentTranscript(segmentID: second.id, audioSHA256: String(repeating: "0", count: 64),
            locale: "zh-CN", engine: "synthetic", createdAt: instant, text: "错误音频绑定", spans: [])
        XCTAssertThrowsError(try value.discoverTranscripts([
            (transcript: transcript(first), manifest: first),
            (transcript: wrongAudio, manifest: second)
        ])) { error in
            XCTAssertEqual(error as? SegmentTranscriptValidationError, .audioMismatch)
        }
        XCTAssertEqual(value, before)
    }

    func testBatchTranscriptDiscoveryRejectsUnauthorizedAndChangedManifestAtomically() throws {
        let first = manifest(), second = manifest(), unreceived = manifest()
        var unauthorized = ICloudDriveLibraryLedger(); let noGrant = unauthorized
        XCTAssertThrowsError(try unauthorized.discoverTranscripts([(transcript(first), first)]))
        XCTAssertEqual(unauthorized, noGrant)
        var value = try ledger([first, second]); let before = value
        let changed = SegmentManifest(id: second.id, sessionID: second.sessionID, sequence: 1,
            startedAt: second.startedAt, endedAt: second.endedAt, sampleRate: second.sampleRate,
            frameCount: second.frameCount, fileName: second.fileName, byteCount: second.byteCount, sha256: second.sha256)
        for denied in [changed, unreceived] {
            XCTAssertThrowsError(try value.discoverTranscripts([
                (transcript: transcript(first), manifest: first),
                (transcript: transcript(denied), manifest: denied)
            ])) { error in
                XCTAssertEqual(error as? ICloudDriveLibraryError, .notAuthorized)
            }
            XCTAssertEqual(value, before)
        }
        try value.setEnabled(false); let paused = value
        XCTAssertThrowsError(try value.discoverTranscripts([(transcript(first), first)]))
        XCTAssertEqual(value, paused)
    }

    func testUnchangedAndEmptyBatchesStillValidateDecodedLedger() throws {
        let first = manifest(), second = manifest()
        var value = try ledger([first, second])
        let item = (transcript: transcript(first), manifest: first)
        try value.discoverTranscripts([item])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: TransportCodec.encode(value)) as? [String: Any])
        var jobs = try XCTUnwrap(object["jobs"] as? [[String: Any]])
        var artifacts = try XCTUnwrap(jobs[1]["artifacts"] as? [[String: Any]])
        artifacts[0]["relativePath"] = "../outside.caf"
        jobs[1]["artifacts"] = artifacts; object["jobs"] = jobs
        var bad = try TransportCodec.decode(ICloudDriveLibraryLedger.self, from: JSONSerialization.data(withJSONObject: object))
        let before = bad
        XCTAssertThrowsError(try bad.discoverTranscripts([item])) { error in
            XCTAssertEqual(error as? ICloudDriveLibraryError, .invalidState)
        }
        XCTAssertEqual(bad, before)
        XCTAssertThrowsError(try bad.discoverTranscripts([])) { error in
            XCTAssertEqual(error as? ICloudDriveLibraryError, .invalidState)
        }
        XCTAssertEqual(bad, before)
        XCTAssertThrowsError(try bad.discoverTranscript(item.transcript, for: item.manifest))
        XCTAssertEqual(bad, before)
    }

    func testBatchLateVersionsRetainCommittedHistoryAndCoalesceOnlyPendingVersions() throws {
        let data = Data("batch history".utf8), original = manifest(Data("batch history".utf8))
        var value = try ledger([original])
        let writer = ICloudDriveExportWriter(root: try directory(), libraryID: value.libraryID)
        let committed = transcript(original, text: "已提交版本")
        try value.discoverTranscripts([(committed, original)])
        let receipt = try writer.export(job: value.jobs[0], audioURL: source(data), transcript: committed)
        try value.recordExported(receipt)
        let previousKeys = value.jobs[0].exportedKeys, previousFiles = value.jobs[0].exportedFiles
        let superseded = transcript(original, text: "未提交中间版本", offset: 2)
        let latest = transcript(original, text: "晚到最新版本", offset: 3)
        try value.discoverTranscripts([(superseded, original), (latest, original)])
        XCTAssertEqual(value.jobs[0].exportedKeys, previousKeys)
        XCTAssertEqual(value.jobs[0].exportedFiles, previousFiles)
        XCTAssertTrue(receipt.artifacts.allSatisfy(value.jobs[0].artifacts.contains))
        let versions = value.jobs[0].artifacts.filter { $0.kind == .transcriptJSON }.map(\.sha256)
        let expected = try [committed, latest].map { ICloudDriveLibraryLedger.digest(try TransportCodec.encode($0)) }
        XCTAssertEqual(Set(versions), Set(expected))
        XCTAssertFalse(versions.contains(ICloudDriveLibraryLedger.digest(try TransportCodec.encode(superseded))))
        XCTAssertEqual(value.jobs[0].artifacts.count, 6)
        try value.validate()
    }

    func testChangedDestinationRequiresRevalidationEvenWhenMtimeWasRestored() throws {
        let data = Data("original".utf8), root = try directory(), input = try source(Data("original".utf8))
        let original = manifest(data); var value = try ledger([original])
        let writer = ICloudDriveExportWriter(root: root, libraryID: value.libraryID)
        let first = try writer.export(job: value.jobs[0], audioURL: input); try value.recordExported(first)
        let audio = try XCTUnwrap(first.artifacts.first { $0.kind == .audio })
        let output = writer.libraryURL.appendingPathComponent(audio.relativePath)
        let oldDate = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: output.path)[.modificationDate] as? Date)
        try Data("tampered".utf8).write(to: output)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: output.path)
        let late = transcript(original); try value.discoverTranscript(late, for: original)
        XCTAssertThrowsError(try writer.export(job: value.jobs[0], audioURL: input, transcript: late)) { error in
            XCTAssertEqual(error as? ICloudDriveLibraryError, .requiresRevalidation)
        }
        XCTAssertEqual(try Data(contentsOf: output), Data("tampered".utf8), "A conflict is never overwritten.")
    }

    func testMissingKnownAudioDoesNotReexportDuringLateText() throws {
        let data = Data("retained".utf8), root = try directory(), input = try source(Data("retained".utf8))
        let original = manifest(data); var value = try ledger([original])
        let writer = ICloudDriveExportWriter(root: root, libraryID: value.libraryID)
        let receipt = try writer.export(job: value.jobs[0], audioURL: input)
        try value.recordExported(receipt)
        let audio = try XCTUnwrap(receipt.artifacts.first { $0.kind == .audio })
        let target = writer.libraryURL.appendingPathComponent(audio.relativePath)
        try FileManager.default.removeItem(at: target)
        let text = transcript(original); try value.discoverTranscript(text, for: original)
        XCTAssertThrowsError(try writer.export(job: value.jobs[0], audioURL: input, transcript: text)) {
            XCTAssertEqual($0 as? ICloudDriveLibraryError, .requiresRevalidation)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "No implicit recording reexport.")
        XCTAssertEqual(value.exportedTranscriptCount, 0)
    }

    func testWrongSourceAndSourceSymlinkNeverCommit() throws {
        let original = manifest(Data("expected".utf8)), root = try directory()
        let value = try ledger([original])
        let writer = ICloudDriveExportWriter(root: root, libraryID: value.libraryID)
        let badInput = try source(Data("badbytes".utf8))
        XCTAssertThrowsError(try writer.export(job: value.jobs[0], audioURL: badInput))
        XCTAssertFalse(files(root).contains { $0.hasPrefix(writer.libraryURL.lastPathComponent + "/commits/") })
        let correct = try source(Data("expected".utf8))
        let link = correct.deletingLastPathComponent().appendingPathComponent("link.caf")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: correct)
        XCTAssertThrowsError(try writer.export(job: value.jobs[0], audioURL: link))
    }

    func testCachedTargetReplacedBySymlinkIsRejectedBeforeReuse() throws {
        let data = Data("retained".utf8), root = try directory(), input = try source(Data("retained".utf8))
        let original = manifest(data); var value = try ledger([original])
        let writer = ICloudDriveExportWriter(root: root, libraryID: value.libraryID)
        let receipt = try writer.export(job: value.jobs[0], audioURL: input)
        try value.recordExported(receipt)
        let audio = try XCTUnwrap(receipt.artifacts.first { $0.kind == .audio })
        let target = writer.libraryURL.appendingPathComponent(audio.relativePath)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: input)
        let text = transcript(original); try value.discoverTranscript(text, for: original)
        XCTAssertThrowsError(try writer.export(job: value.jobs[0], audioURL: input, transcript: text)) { error in
            XCTAssertEqual(error as? ICloudDriveLibraryError, .unsafePath)
        }
        XCTAssertEqual(try Data(contentsOf: input), data)
    }

    func testForeignMarkerUnmarkedFolderAndDestinationSymlinkAreRejected() throws {
        let original = manifest(), value = try ledger([original]), root = try directory()
        let writer = ICloudDriveExportWriter(root: root, libraryID: value.libraryID)
        try FileManager.default.createDirectory(at: writer.libraryURL, withIntermediateDirectories: false)
        XCTAssertThrowsError(try writer.validateMarker(createIfMissing: true))
        let markerURL = writer.libraryURL.appendingPathComponent("library.json")
        try TransportCodec.encode(ICloudDriveLibraryMarker(libraryID: UUID())).write(to: markerURL)
        XCTAssertThrowsError(try writer.validateMarker())
        try FileManager.default.removeItem(at: markerURL)
        try TransportCodec.encode(ICloudDriveLibraryMarker(libraryID: value.libraryID)).write(to: markerURL)
        let unrelated = try directory(), sentinel = unrelated.appendingPathComponent("sentinel")
        try Data("untouched".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: writer.libraryURL.appendingPathComponent("audio"), withDestinationURL: unrelated)
        XCTAssertThrowsError(try writer.export(job: value.jobs[0], audioURL: source(Data("synthetic audio".utf8))))
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("untouched".utf8))
        XCTAssertEqual(files(unrelated), ["sentinel"])
    }

    func testCancelBeforeStartWritesNothingAndDuringCopyNeverCommits() throws {
        let data = Data(repeating: 9, count: 2 * 1_024 * 1_024), root = try directory(), input = try source(Data(repeating: 9, count: 2 * 1_024 * 1_024))
        let value = try ledger([manifest(data)])
        let writer = ICloudDriveExportWriter(root: root, libraryID: value.libraryID)
        XCTAssertThrowsError(try writer.export(job: value.jobs[0], audioURL: input, while: { false }))
        XCTAssertTrue(files(root).isEmpty)
        let budget = Budget(20)
        XCTAssertThrowsError(try writer.export(job: value.jobs[0], audioURL: input, while: budget.next)) { error in
            XCTAssertEqual(error as? ICloudDriveLibraryError, .cancelled)
        }
        XCTAssertFalse(files(root).contains { $0.hasSuffix(".caf") || $0.contains(".partial-") || $0.contains("/commits/") })
        let receipt = try writer.export(job: value.jobs[0], audioURL: input)
        XCTAssertEqual(receipt.artifacts.count, 2, "Interrupted exports can retry without an unmarked-folder trap.")
    }

    func testExportReceiptCannotBeAppliedToAnotherLibraryOrForgedPath() throws {
        let data = Data("receipt".utf8), original = manifest(Data("receipt".utf8)), root = try directory(), input = try source(Data("receipt".utf8))
        var first = try ledger([original]), second = try ledger([original])
        let writer = ICloudDriveExportWriter(root: root, libraryID: first.libraryID)
        XCTAssertThrowsError(try writer.export(job: second.jobs[0], audioURL: input))
        XCTAssertTrue(files(root).isEmpty, "A job from a different grant must not create a library.")
        let receipt = try writer.export(job: first.jobs[0], audioURL: input)
        var other = second
        XCTAssertThrowsError(try other.recordExported(receipt))
        try first.recordExported(receipt); XCTAssertEqual(first.exportedAudioCount, 1)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: TransportCodec.encode(first)) as? [String: Any])
        var jobs = try XCTUnwrap(object["jobs"] as? [[String: Any]])
        var artifacts = try XCTUnwrap(jobs[0]["artifacts"] as? [[String: Any]])
        artifacts[0]["relativePath"] = "../outside.caf"; jobs[0]["artifacts"] = artifacts; object["jobs"] = jobs
        let bad = try TransportCodec.decode(ICloudDriveLibraryLedger.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try bad.validate()); XCTAssertEqual(data.count, 7)
    }

    func testCommitAndMarkerProofRequiresBytesNotAMatchingFileName() throws {
        let data = Data("synthetic audio".utf8), original = manifest(data), root = try directory(), input = try source(data)
        let value = try ledger([original])
        let writer = ICloudDriveExportWriter(root: root, libraryID: value.libraryID)
        let receipt = try writer.export(job: value.jobs[0], audioURL: input)
        let commit = try Data(contentsOf: writer.libraryURL.appendingPathComponent(receipt.relativePath))
        XCTAssertTrue(ICloudDriveLibraryLedger.provesCommit(commit, relativePath: receipt.relativePath, job: value.jobs[0]))
        XCTAssertFalse(ICloudDriveLibraryLedger.provesCommit(Data(receipt.relativePath.utf8), relativePath: receipt.relativePath, job: value.jobs[0]),
                       "A path string is not a commit.")
        XCTAssertFalse(ICloudDriveLibraryLedger.provesCommit(commit, relativePath: "commits/" + original.id.uuidString.lowercased() + "/other.json", job: value.jobs[0]))
        var flipped = commit
        flipped[flipped.index(before: flipped.endIndex)] ^= 0x01
        XCTAssertFalse(ICloudDriveLibraryLedger.provesCommit(flipped, relativePath: receipt.relativePath, job: value.jobs[0]))
        let other = try ledger([manifest(Data("other synthetic".utf8))])
        XCTAssertFalse(ICloudDriveLibraryLedger.provesCommit(commit, relativePath: receipt.relativePath, job: other.jobs[0]))
        let marker = try Data(contentsOf: writer.libraryURL.appendingPathComponent("library.json"))
        XCTAssertTrue(ICloudDriveLibraryLedger.provesMarker(marker, libraryID: value.libraryID))
        XCTAssertFalse(ICloudDriveLibraryLedger.provesMarker(marker, libraryID: UUID()))
        XCTAssertFalse(ICloudDriveLibraryLedger.provesMarker(Data("library.json".utf8), libraryID: value.libraryID))
    }

    func testCommitProofRejectsOnlyLibraryIdentityChanged() throws {
        let data = Data("same synthetic segment and artifacts".utf8)
        let original = manifest(data), value = try ledger([original])
        let writer = ICloudDriveExportWriter(root: try directory(), libraryID: value.libraryID)
        let receipt = try writer.export(job: value.jobs[0], audioURL: source(data))
        let valid = try TransportCodec.encode(receipt)
        XCTAssertTrue(ICloudDriveLibraryLedger.provesCommit(valid, relativePath: receipt.relativePath, job: value.jobs[0]))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        object["libraryID"] = UUID().uuidString.lowercased()
        let changed = try JSONSerialization.data(withJSONObject: object)
        let foreign = try TransportCodec.decode(ICloudDriveExportReceipt.self, from: changed)
        XCTAssertEqual(foreign.segmentID, receipt.segmentID)
        XCTAssertEqual(foreign.artifacts, receipt.artifacts)
        XCTAssertEqual(foreign.exportDigest, receipt.exportDigest)
        XCTAssertEqual(foreign.relativePath, receipt.relativePath)
        XCTAssertNotEqual(foreign.libraryID, value.libraryID)
        XCTAssertFalse(ICloudDriveLibraryLedger.provesCommit(changed, relativePath: receipt.relativePath, job: value.jobs[0]),
                       "The same segment, digest and commit path do not prove another library's receipt.")
        var unchanged = value
        XCTAssertThrowsError(try unchanged.recordExported(foreign))
        XCTAssertEqual(unchanged, value)
    }
}
