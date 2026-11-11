import Darwin
import Dispatch
import Foundation
import RecordingCore

/// Local diagnostic runner sharing the iPhone transcriber. Output never includes transcript text.
@main
struct TranscribeOnDevice {
    enum CLIError: Error { case usage, invalidManifest, timeout, sourceChanged }

    static func main() async {
        // Turn interactive cancellation into Swift task cancellation so the shared
        // analyzer can finish and delete its private temporary audio snapshot.
        let commandTask = Task { await runCommand() }
        let sources = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .utility))
            source.setEventHandler { commandTask.cancel() }
            source.resume()
            return source
        }
        await commandTask.value
        sources.forEach { $0.cancel() }
    }

    private static func runCommand() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let transcriber = OnDeviceTranscriber()
        do {
            guard let command = arguments.first else { throw CLIError.usage }
            if command == "status", arguments.count == 1 {
                emit(statusFields(await transcriber.modelStatus()))
                return
            }
            if command == "prepare-model", arguments.count == 1 {
                try await prepareModel(transcriber)
                return
            }
            guard command == "transcribe", arguments.count >= 2,
                  arguments.count == 2 || arguments.count == 4 || arguments.count == 6 else {
                throw CLIError.usage
            }
            let root = URL(fileURLWithPath: arguments[1], isDirectory: true)
            var limit = Int.max
            var timeout: UInt64 = 180
            var index = 2
            while index < arguments.count {
                switch arguments[index] {
                case "--limit":
                    guard let number = Int(arguments[index + 1]), number > 0 else { throw CLIError.usage }
                    limit = number
                case "--timeout-seconds":
                    guard let seconds = UInt64(arguments[index + 1]), seconds > 0, seconds <= 3_600 else {
                        throw CLIError.usage
                    }
                    timeout = seconds
                default: throw CLIError.usage
                }
                index += 2
            }
            let status = await transcriber.modelStatus()
            emit(statusFields(status))
            guard case .ready = status else { exit(2) }
            try Task.checkCancellation()
            try await run(root: root, limit: limit, timeout: timeout, transcriber: transcriber)
        } catch {
            emit(["event": "error", "status": errorStatus(error)])
            exit(1)
        }
    }

    private static func prepareModel(_ transcriber: OnDeviceTranscriber) async throws {
        emit(statusFields(await transcriber.modelStatus()))
        let startedAt = Date()
        let status = try await withThrowingTaskGroup(of: OnDeviceTranscriber.ModelStatus.self) { group in
            group.addTask { try await transcriber.prepareModel() }
            group.addTask {
                try await Task.sleep(nanoseconds: 600 * 1_000_000_000)
                throw CLIError.timeout
            }
            group.addTask {
                while true {
                    try await Task.sleep(nanoseconds: 15 * 1_000_000_000)
                    var fields = statusFields(await transcriber.modelStatus())
                    fields["event"] = "modelPreparation"
                    fields["elapsedSeconds"] = Int(Date().timeIntervalSince(startedAt))
                    emit(fields)
                }
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CLIError.timeout }
            return result
        }
        emit(statusFields(status))
        let verified = await transcriber.modelStatus()
        emit(statusFields(verified))
        guard case .ready = verified else { throw OnDeviceTranscriber.Failure.modelPreparationFailed }
    }

    private static func run(root: URL, limit: Int, timeout: UInt64,
                            transcriber: OnDeviceTranscriber) async throws {
        let fm = FileManager.default
        guard try fm.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw CLIError.invalidManifest
        }
        let manifestDirectory = root.appendingPathComponent("manifests", isDirectory: true)
        guard try fm.attributesOfItem(atPath: manifestDirectory.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw CLIError.invalidManifest
        }
        let manifestURLs = try fm.contentsOfDirectory(at: manifestDirectory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        let manifests = try manifestURLs.map { url -> SegmentManifest in
            guard try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular else {
                throw CLIError.invalidManifest
            }
            let manifest = try TransportCodec.decode(SegmentManifest.self, from: Data(contentsOf: url))
            guard url.lastPathComponent == manifest.id.uuidString.lowercased() + ".json",
                  manifest.fileName == manifest.id.uuidString.lowercased() + ".caf" else {
                throw CLIError.invalidManifest
            }
            return manifest
        }.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            return $0.id.uuidString < $1.id.uuidString
        }
        guard Set(manifests.map(\.id)).count == manifests.count else { throw CLIError.invalidManifest }
        let repository = try TranscriptRepository(root: root)
        let transcriptDirectory = root.appendingPathComponent("transcripts", isDirectory: true)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: transcriptDirectory.path)
        var succeeded = 0, skipped = 0, noSpeech = 0, failed = 0
        for manifest in manifests.prefix(limit) {
            let identifier = manifest.id.uuidString.lowercased()
            let audioURL = root.appendingPathComponent("audio", isDirectory: true).appendingPathComponent(manifest.fileName)
            do {
                try Task.checkCancellation()
                try verifyAudio(audioURL, manifest: manifest)
                if try repository.transcript(for: manifest) != nil {
                    skipped += 1
                    emit(["event": "segment", "id": identifier, "status": "existing_valid", "audioSHA256": manifest.sha256])
                    continue
                }
                emit(["event": "segment", "id": identifier, "status": "started", "audioSHA256": manifest.sha256])
                let transcript = try await withThrowingTaskGroup(of: SegmentTranscript.self) { group in
                    group.addTask {
                        try await transcriber.transcribe(audioURL: audioURL, manifest: manifest)
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: timeout * 1_000_000_000)
                        throw CLIError.timeout
                    }
                    defer { group.cancelAll() }
                    guard let result = try await group.next() else { throw CLIError.timeout }
                    return result
                }
                try transcript.validate(against: manifest)
                try verifyAudio(audioURL, manifest: manifest)
                try repository.save(transcript, for: manifest)
                guard let persisted = try repository.transcript(for: manifest), persisted == transcript else {
                    throw CLIError.sourceChanged
                }
                let transcriptURL = transcriptDirectory.appendingPathComponent(identifier + ".json")
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: transcriptURL.path)
                let persistedFingerprint = try RecordingRepository.fingerprint(of: transcriptURL)
                succeeded += 1
                emit(["event": "segment", "id": identifier, "status": "succeeded",
                      "audioSHA256": manifest.sha256, "transcriptSHA256": persistedFingerprint.sha256,
                      "spanCount": transcript.spans.count, "textBytes": transcript.text.utf8.count])
            } catch {
                let status = errorStatus(error)
                if status == "noSpeech" { noSpeech += 1 } else { failed += 1 }
                var fields: [String: Any] = ["event": "segment", "id": identifier,
                                             "status": status, "audioSHA256": manifest.sha256]
                if let range = error as? OnDeviceTranscriber.InvalidResultRange {
                    fields["timing"] = range.numericDiagnostics
                }
                emit(fields)
                if error is CancellationError { break }
            }
        }
        emit(["event": "summary", "available": manifests.count, "selected": min(manifests.count, limit),
              "succeeded": succeeded, "existingValid": skipped, "noSpeech": noSpeech, "failed": failed])
        if failed > 0 { exit(3) }
    }

    private static func verifyAudio(_ url: URL, manifest: SegmentManifest) throws {
        guard try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular else {
            throw CLIError.invalidManifest
        }
        let fingerprint = try RecordingRepository.fingerprint(of: url)
        guard fingerprint.byteCount == manifest.byteCount, fingerprint.sha256 == manifest.sha256 else {
            throw CLIError.sourceChanged
        }
    }

    private static func statusFields(_ status: OnDeviceTranscriber.ModelStatus) -> [String: Any] {
        switch status {
        case .unsupportedOS: return ["event": "model", "status": "unsupportedOS"]
        case .deviceUnavailable: return ["event": "model", "status": "deviceUnavailable"]
        case .unsupportedLocale: return ["event": "model", "status": "unsupportedLocale"]
        case .notInstalled(let locale): return ["event": "model", "status": "notInstalled", "locale": locale]
        case .downloading(let locale): return ["event": "model", "status": "downloading", "locale": locale]
        case .ready(let locale): return ["event": "model", "status": "ready", "locale": locale]
        }
    }

    private static func errorStatus(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        if let error = error as? CLIError {
            switch error {
            case .usage: return "usage: status | prepare-model | transcribe ROOT [--limit N] [--timeout-seconds N]"
            case .invalidManifest: return "invalidManifest"
            case .timeout: return "timeout"
            case .sourceChanged: return "sourceChanged"
            }
        }
        if let error = error as? OnDeviceTranscriber.InvalidResultRange {
            return "invalidSpan_" + String(error.index)
        }
        if let error = error as? SegmentTranscriptValidationError {
            switch error {
            case .noSpeech: return "noSpeech"
            case .invalidSpan(let index): return "invalidSpan_" + String(index)
            default: return "transcriptValidationFailed"
            }
        }
        if let error = error as? OnDeviceTranscriber.Failure { return String(describing: error) }
        // Framework errors may contain speech or paths in their descriptions. Only emit
        // machine-readable domain/code; never localizedDescription or userInfo.
        let error = error as NSError
        return "error_" + error.domain + "_" + String(error.code)
    }

    private static func emit(_ fields: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else { return }
        print(line)
        fflush(stdout)
    }
}
