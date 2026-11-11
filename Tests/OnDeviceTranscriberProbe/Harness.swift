import Foundation
import CoreMedia
import RecordingCore

// Compiled with the unmodified production OnDeviceTranscriber.swift. Only its
// shared coordinator and timing validator run; no Speech models, files or audio are opened.
enum Outcome: String, Sendable { case success, invalidSpan, noSpeech, framework, cancelled, other }
enum Role: Sendable { case producer, consumer }

actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        guard !opened else { return }
        opened = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

actor ControlledAnalyzer {
    let peerReady = Gate()
    let bothReady = Gate()
    let cancelled = Gate()
    let releaseOriginalError = Gate()
    private var waiting = 0
    private var cleanupCalls = 0
    func awaitCancellation() async throws {
        waiting += 1
        await peerReady.open()
        if waiting == 2 { await bothReady.open() }
        await cancelled.wait()
        throw CancellationError()
    }
    func cancel() async {
        cleanupCalls += 1
        let first = cleanupCalls == 1
        await cancelled.open()
        await releaseOriginalError.open()
        // Real cleanup suspends. Hold the initiating cleanup long enough for
        // the cancelled peer to complete, rather than assuming a task order.
        if first { try? await Task.sleep(nanoseconds: 20_000_000) }
    }
    func count() -> Int { cleanupCalls }
}

struct Observed: Sendable {
    let outcome: Outcome
    let spans: [SegmentTranscript.Span]
    let invalidSpanIndex: Int?
    let frameworkCode: Int?
}

func observe(_ error: Error) -> Observed {
    if error is CancellationError { return .init(outcome: .cancelled, spans: [], invalidSpanIndex: nil, frameworkCode: nil) }
    if let error = error as? SegmentTranscriptValidationError {
        switch error {
        case .noSpeech: return .init(outcome: .noSpeech, spans: [], invalidSpanIndex: nil, frameworkCode: nil)
        case .invalidSpan(let index): return .init(outcome: .invalidSpan, spans: [], invalidSpanIndex: index, frameworkCode: nil)
        default: break
        }
    }
    let value = error as NSError
    if value.domain == "SyntheticSpeechFailure", value.code == 17 {
        return .init(outcome: .framework, spans: [], invalidSpanIndex: nil, frameworkCode: 17)
    }
    return .init(outcome: .other, spans: [], invalidSpanIndex: nil, frameworkCode: nil)
}

func realFailure(_ expected: Outcome) throws {
    switch expected {
    case .invalidSpan: throw SegmentTranscriptValidationError.invalidSpan(index: 3)
    case .noSpeech: throw SegmentTranscriptValidationError.noSpeech
    case .framework: throw NSError(domain: "SyntheticSpeechFailure", code: 17)
    default: throw CancellationError()
    }
}

func coordinator(produce: @escaping @Sendable () async throws -> Void,
                 consume: @escaping @Sendable () async throws -> [SegmentTranscript.Span],
                 analyzer: ControlledAnalyzer) async -> Observed {
    do {
        let spans = try await OnDeviceTranscriber.collectAnalyzerResults(
            produce: produce, consume: consume, cancel: { await analyzer.cancel() })
        return .init(outcome: .success, spans: spans, invalidSpanIndex: nil, frameworkCode: nil)
    } catch { return observe(error) }
}

func failureRace(role: Role, expected: Outcome) async -> (Observed, Int) {
    let analyzer = ControlledAnalyzer()
    let result = await coordinator(produce: {
        if case .producer = role {
            await analyzer.peerReady.wait()
            try realFailure(expected)
        } else { try await analyzer.awaitCancellation() }
    }, consume: {
        if case .consumer = role {
            await analyzer.peerReady.wait()
            try realFailure(expected)
        } else { try await analyzer.awaitCancellation() }
        return []
    }, analyzer: analyzer)
    return (result, await analyzer.count())
}

func cancellationBeforeFrameworkError() async -> Observed {
    let analyzer = ControlledAnalyzer()
    return await coordinator(produce: {
        // The backend already has a real error to deliver. A result stream may
        // report cancellation first, as documented by SpeechAnalyzer.
        await analyzer.releaseOriginalError.wait()
        try realFailure(.framework)
    }, consume: {
        throw CancellationError()
    }, analyzer: analyzer)
}

func externalCancellation() async -> Observed {
    let analyzer = ControlledAnalyzer()
    let task = Task {
        await coordinator(produce: {
            try await analyzer.awaitCancellation()
        }, consume: {
            try await analyzer.awaitCancellation()
            return []
        }, analyzer: analyzer)
    }
    await analyzer.bothReady.wait()
    task.cancel()
    return await task.value
}

func successfulStreams() async -> (Observed, Int) {
    let analyzer = ControlledAnalyzer()
    let readerStarted = Gate(), inputFinished = Gate()
    let result = await coordinator(produce: {
        await readerStarted.wait()
        await inputFinished.open()
    }, consume: {
        await readerStarted.open()
        await inputFinished.wait()
        return [.init(start: 0, end: 0.5, text: "synthetic")]
    }, analyzer: analyzer)
    return (result, await analyzer.count())
}

@main
struct Harness {
    static func main() async {
        var assertions = 0
        var failures: [[String: String]] = []
        var observedCounts: [String: Int] = [:]
        func check(_ value: Bool, _ label: String, _ actual: String) {
            assertions += 1
            if !value { failures.append(["case": label, "actual": actual]) }
        }
        let instant = Date(timeIntervalSince1970: 1_800_000_000)
        let id = UUID()
        let manifest = SegmentManifest(id: id, sessionID: UUID(), sequence: 0,
            startedAt: instant, endedAt: instant.addingTimeInterval(17.067),
            sampleRate: 48_000, frameCount: 819_200, fileName: id.uuidString.lowercased() + ".caf",
            byteCount: 3_280_896, sha256: String(repeating: "a", count: 64))
        let audioEnd = CMTime(value: 819_200, timescale: 48_000)
        do {
            let bounds = try OnDeviceTranscriber.validatedResultRange(
                CMTimeRange(start: .zero, end: audioEnd), manifest: manifest, index: 0)
            check(bounds.start == 0 && bounds.end == manifest.duration, "exact_frame_end_accepted", "timing")
        } catch { check(false, "exact_frame_end_accepted", "rejected") }
        // The observed SDK endpoint is rounded on a 16 kHz grid. Its exact
        // rational end exceeds this 48 kHz source by one source frame.
        let sdkEnd = CMTime(value: 273_067, timescale: 16_000)
        do {
            let bounds = try OnDeviceTranscriber.validatedResultRange(
                CMTimeRange(start: CMTime(value: 150_720, timescale: 16_000), end: sdkEnd),
                manifest: manifest, index: 1)
            check(bounds.start == 9.42 && bounds.end == manifest.duration,
                  "observed_sdk_grid_end_normalized", "timing")
            let value = SegmentTranscript(segmentID: manifest.id, audioSHA256: manifest.sha256,
                locale: "zh-CN", engine: "synthetic-test", text: "synthetic",
                spans: [.init(start: bounds.start, end: bounds.end, text: "synthetic")])
            try value.validate(against: manifest)
            check(true, "normalized_result_passes_unchanged_core", "validated")
        } catch {
            check(false, "observed_sdk_grid_end_normalized", "rejected")
            check(false, "normalized_result_passes_unchanged_core", "rejected")
        }
        let invalidRanges = [
            CMTimeRange(start: CMTime(value: 480_000, timescale: 48_000),
                        end: CMTime(value: 819_201, timescale: 48_000)),
            CMTimeRange(start: CMTime(value: -1, timescale: 48_000), end: audioEnd),
            CMTimeRange(start: .invalid, duration: .invalid),
            CMTimeRange(start: .zero, end: CMTime(value: 273_068, timescale: 16_000)),
            CMTimeRange(start: .zero, end: CMTime(value: 819_201, timescale: 48_000)),
            CMTimeRange(start: .zero, end: .positiveInfinity),
            CMTimeRange(start: CMTime(value: 1, timescale: 1), duration: CMTime(value: -1, timescale: 1)),
            CMTimeRange(start: sdkEnd, duration: .zero),
        ]
        let allowedKeys: Set<String> = ["spanIndex", "frameCount", "sampleRate", "manifestDuration",
            "startValue", "startTimescale", "endValue", "endTimescale", "rangeDurationValue",
            "rangeDurationTimescale", "startIsFinite", "endIsFinite", "startSeconds", "endSeconds"]
        for (index, range) in invalidRanges.enumerated() {
            do {
                _ = try OnDeviceTranscriber.validatedResultRange(range, manifest: manifest, index: 1)
                check(false, "invalid_range_rejected", "accepted")
            } catch let error as OnDeviceTranscriber.InvalidResultRange {
                check(error.index == 1 && error.frameCount == 819_200 && error.sampleRate == 48_000,
                      "timing_error_keeps_source_numbers", "timing")
                let fields = error.numericDiagnostics
                check(Set(fields.keys).isSubset(of: allowedKeys), "numeric_diagnostic_whitelist", "keys")
                check(JSONSerialization.isValidJSONObject(fields), "numeric_diagnostic_json_finite", "json")
                if index == 0 {
                    check(error.endValue == 819_201 && error.endTimescale == 48_000 &&
                          error.end > error.manifestDuration,
                          "one_frame_overflow_keeps_exact_range", "rational")
                }
            } catch { check(false, "invalid_range_rejected", "wrong_error") }
        }
        for _ in 0..<20 {
            for (role, expected) in [(Role.consumer, Outcome.invalidSpan), (.producer, .noSpeech), (.consumer, .framework)] {
                let (result, cleanups) = await failureRace(role: role, expected: expected)
                observedCounts["failure_" + expected.rawValue + "_observed_" + result.outcome.rawValue, default: 0] += 1
                check(result.outcome == expected, "preserve_" + expected.rawValue, result.outcome.rawValue)
                check(cleanups == 1, "single_parent_cleanup", String(cleanups))
                if expected == .invalidSpan { check(result.invalidSpanIndex == 3, "preserve_span_index", String(result.invalidSpanIndex ?? -1)) }
                if expected == .framework { check(result.frameworkCode == 17, "preserve_framework_code", String(result.frameworkCode ?? -1)) }
            }
            let late = await cancellationBeforeFrameworkError()
            observedCounts["cancel_first_observed_" + late.outcome.rawValue, default: 0] += 1
            check(late.outcome == .framework && late.frameworkCode == 17, "cancel_first_keeps_real_error", late.outcome.rawValue)
            let external = await externalCancellation()
            check(external.outcome == .cancelled, "external_cancel_stays_cancelled", external.outcome.rawValue)
            let (success, cleanups) = await successfulStreams()
            check(success.outcome == .success && success.spans == [.init(start: 0, end: 0.5, text: "synthetic")],
                  "both_streams_complete", success.outcome.rawValue)
            check(cleanups == 0, "success_never_cancels", String(cleanups))
        }
        let report: [String: Any] = [
            "scope": "actual_production_shared_coordinator_synthetic_closures",
            "status": failures.isEmpty ? "passed" : "failed",
            "caseCount": 8, "rounds": 20, "assertionCount": assertions,
            "observedCounts": observedCounts, "failures": failures,
            "audioOrModelsUsed": false,
        ]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([10]))
        if !failures.isEmpty { exit(1) }
    }
}
