import CoreGraphics
import Foundation
import Vision

struct Observation: Encodable {
    let text: String
    let x, y, width, height: Double
    let confidence: Float
}

struct CaptureResult: Encodable {
    let status: String
    let reason: String?
    let lines: [Observation]?

    static func skipped(_ reason: String) -> CaptureResult {
        CaptureResult(status: "skipped", reason: reason, lines: nil)
    }
}

enum CaptureError: Error {
    case arguments, imageSize, crop
}

struct CaptureSpec {
    let title: String
    let header, messages: CGRect

    init(title: String, header: String, messages: String) throws {
        func region(_ value: String) throws -> CGRect {
            let fields = value.split(separator: ",", omittingEmptySubsequences: false)
            let n = fields.compactMap { Double($0) }
            guard fields.count == 4, n.count == 4, n.allSatisfy(\.isFinite),
                  n[0] >= 0, n[1] >= 0, n[2] > 0, n[3] > 0,
                  n[0] + n[2] <= 1, n[1] + n[3] <= 1 else { throw CaptureError.arguments }
            return CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
        }
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.header = try region(header)
        self.messages = try region(messages)
        guard !self.title.isEmpty, self.title.count <= 256,
              self.header.maxY <= self.messages.minY,
              self.header.midX >= self.messages.minX, self.header.midX <= self.messages.maxX,
              self.messages.minX > 0, self.messages.maxY < 1
        else { throw CaptureError.arguments }
    }
}

enum Recognition {
    // Both crops come from one frame. A conversation switch between two independent screenshots
    // could otherwise pair a matching header with messages from a different conversation.
    static func read(_ frame: CGImage, spec: CaptureSpec) throws -> CaptureResult {
        func crop(_ region: CGRect) throws -> CGImage {
            let w = Double(frame.width), h = Double(frame.height)
            let x = ceil(region.minX * w), y = ceil(region.minY * h)
            let rect = CGRect(x: x, y: y, width: floor(region.maxX * w) - x,
                              height: floor(region.maxY * h) - y)
            guard rect.width >= 1, rect.height >= 1,
                  let image = frame.cropping(to: rect) else { throw CaptureError.crop }
            return image
        }
        let header = try recognize(crop(spec.header))
        guard header.count == 1, header[0].confidence >= 0.8,
              header[0].text == spec.title else { return .skipped("title_mismatch") }
        let lines = try recognize(crop(spec.messages))
        return CaptureResult(status: "ok", reason: nil, lines: lines)
    }

    private static func recognize(_ image: CGImage) throws -> [Observation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        // Preserve names, dates and identifiers as recognized; never run an LLM or cloud OCR.
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
        return (request.results ?? []).compactMap { result -> Observation? in
            guard let candidate = result.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let b = result.boundingBox
            let x = min(1, max(0, b.minX)), y = min(1, max(0, 1 - b.maxY))
            return Observation(text: text, x: x, y: y, width: min(b.width, 1 - x),
                               height: min(b.height, 1 - y), confidence: candidate.confidence)
        }.sorted { ($0.y, $0.x) < ($1.y, $1.x) }
    }
}
