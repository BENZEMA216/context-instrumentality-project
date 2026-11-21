import AppKit
import Foundation

func log(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

@main
struct WeChatOCR {
    static let usage = """
    wechat-ocr calibrate
    wechat-ocr request-permission
    wechat-ocr capture --title TITLE --header x,y,w,h --messages x,y,w,h --window-size WIDTHxHEIGHT --window-id WINDOW_ID --process-id PID
    Rectangles are normalized to the selected window, with a top-left origin. Window size is in points.
    """

    static func output<T: Encodable>(_ value: T) throws {
        var data = try JSONEncoder().encode(value)
        data.append(0x0a)
        FileHandle.standardOutput.write(data)
    }

    @MainActor static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            switch args.first {
            case "calibrate" where args.count == 1:
                switch try await Calibration.run() {
                case .success(let calibration): try output(calibration)
                case .failure(let skip): try output(CaptureResult.skipped(skip.reason))
                }
            case "request-permission" where args.count == 1:
                let granted = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
                try output(["status": granted ? "ok" : "skipped", "reason": granted ? "authorized" : "screen_permission_required"])
            case "capture" where args.count == 13:
                var options: [String: String] = [:]
                for offset in stride(from: 1, to: args.count, by: 2) {
                    guard options.updateValue(args[offset + 1], forKey: args[offset]) == nil else { throw CaptureError.arguments }
                }
                guard let title = options["--title"], let header = options["--header"],
                      let messages = options["--messages"], let size = options["--window-size"],
                      let id = options["--window-id"].flatMap(UInt32.init), id > 0,
                      let pid = options["--process-id"].flatMap(Int32.init), pid > 0 else { throw CaptureError.arguments }
                let spec = try CaptureSpec(title: title, header: header, messages: messages)
                try output(await WindowTarget.capture(spec: spec, size: WindowTarget.parseSize(size),
                                                      windowID: id, processID: pid))
            case "--help", "-h": print(usage)
            default: throw CaptureError.arguments
            }
        } catch CaptureError.arguments {
            log(usage)
            exit(2)
        } catch {
            log("Window capture or on-device text recognition failed.")
            exit(1)
        }
    }
}
