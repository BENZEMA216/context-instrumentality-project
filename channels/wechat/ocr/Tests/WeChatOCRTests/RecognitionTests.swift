import AppKit
import XCTest
@testable import WeChatOCR

final class RecognitionTests: XCTestCase {
    private let header = "0.34,0.02,0.46,0.15"
    private let messages = "0.32,0.23,0.65,0.46"

    private func syntheticWindow() throws -> CGImage {
        let w = 1320, h = 850
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()
        let font = NSFont(name: "PingFangSC-Regular", size: 42) ?? .systemFont(ofSize: 42)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        func draw(_ text: String, x: CGFloat, top: CGFloat) {
            (text as NSString).draw(at: CGPoint(x: x, y: CGFloat(h) - top - 60), withAttributes: attrs)
        }
        draw("项目会议", x: 480, top: 54)
        draw("会议安排", x: 500, top: 230)
        draw("Project Monday", x: 610, top: 380)
        draw("Sidebar private", x: 16, top: 230)
        draw("Draft private", x: 490, top: 720)
        NSGraphicsContext.restoreGraphicsState()
        return try XCTUnwrap(bitmap.cgImage)
    }

    func testVisionSyntheticChineseAndEnglishInSelectedRegion() throws {
        let spec = try CaptureSpec(title: "项目会议", header: header, messages: messages)
        let result = try Recognition.read(syntheticWindow(), spec: spec)
        XCTAssertEqual(result.status, "ok")
        let lines = try XCTUnwrap(result.lines)
        XCTAssertEqual(lines.map(\.text), ["会议安排", "Project Monday"])
        XCTAssertLessThan(lines[0].y, lines[1].y)
        for line in lines {
            XCTAssertTrue((0...1).contains(line.confidence))
            XCTAssertTrue((0...1).contains(line.x) && (0...1).contains(line.y))
            XCTAssertLessThanOrEqual(line.x + line.width, 1)
            XCTAssertLessThanOrEqual(line.y + line.height, 1)
        }
    }

    func testNonmatchingHeaderLeaksNoBodyOrRecognizedTitle() throws {
        let spec = try CaptureSpec(title: "项目", header: header, messages: messages)
        let result = try Recognition.read(syntheticWindow(), spec: spec)
        XCTAssertEqual(result.reason, "title_mismatch")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: String])
        XCTAssertEqual(object, ["status": "skipped", "reason": "title_mismatch"])
    }

    func testOverlappingOrOutOfBoundsRegionsAndInvalidDimensionsRejected() {
        for invalid in ["0.32,0.1,0.65,0.46", "0.32,0.23,0.75,0.46", "nan,0.2,0.2,0.5",
                        "0,0,1,1", "0.32,0.23,-0.4,0.46"] {
            XCTAssertThrowsError(try CaptureSpec(title: "group", header: header, messages: invalid))
        }
        XCTAssertThrowsError(try WindowTarget.parseSize("512x0"))
        XCTAssertThrowsError(try WindowTarget.parseSize("0.5,0.5"))
        XCTAssertNoThrow(try WindowTarget.parseSize("1200x800"))
    }

    func testCalibratedPointersUseWindowRelativeTopLeftOnAnotherDisplay() throws {
        let bounds = CGRect(x: -200, y: 40, width: 800, height: 400)
        let value = try Calibration.rect(CGPoint(x: 0, y: 80), CGPoint(x: 160, y: 240), in: bounds)
        XCTAssertEqual(value, "0.250000,0.100000,0.200000,0.400000")
        XCTAssertThrowsError(try Calibration.rect(.zero, CGPoint(x: 10, y: 100), in: bounds))
    }
}
