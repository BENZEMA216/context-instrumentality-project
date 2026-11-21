import AppKit
import CoreGraphics
import Foundation
import ScreenCaptureKit

struct WindowTarget: Equatable {
    let id: CGWindowID
    let pid: pid_t
    let bounds: CGRect

    static let bundleID = "com.tencent.xinWeChat"

    @MainActor static func frontmost() -> WindowTarget? {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session[kCGSessionLoginDoneKey as String] as? Bool == true,
              session["CGSSessionScreenIsLocked"] as? Bool != true,
              let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == bundleID,
              app.isActive, !app.isHidden,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                       kCGNullWindowID) as? [[String: Any]],
              let first = windows.first(where: {
                  ($0[kCGWindowLayer as String] as? Int) == 0 &&
                      ($0[kCGWindowAlpha as String] as? Double ?? 0) > 0
              }),
              first[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier,
              let id = first[kCGWindowNumber as String] as? CGWindowID,
              let geometry = first[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: geometry as CFDictionary),
              bounds.width > 0, bounds.height > 0
        else { return nil }
        return WindowTarget(id: id, pid: app.processIdentifier, bounds: bounds)
    }

    func sizeString() -> String {
        "\(Int(bounds.width.rounded()))x\(Int(bounds.height.rounded()))"
    }

    static func parseSize(_ value: String) throws -> CGSize {
        let pieces = value.split(separator: "x", omittingEmptySubsequences: false)
        guard pieces.count == 2, let w = Int(pieces[0]), let h = Int(pieces[1]),
              (1...32768).contains(w), (1...32768).contains(h) else { throw CaptureError.arguments }
        return CGSize(width: w, height: h)
    }

    @MainActor static func capture(spec: CaptureSpec, size: CGSize, windowID: CGWindowID,
                                   processID: pid_t) async throws -> CaptureResult {
        guard let target = frontmost() else { return .skipped("no_foreground_wechat") }
        guard target.id == windowID, target.pid == processID else { return .skipped("different_window") }
        guard target.bounds.size == size else { return .skipped("window_resized") }
        // A periodic poll must never bring up the system permission prompt.
        guard CGPreflightScreenCaptureAccess() else { return .skipped("screen_permission_required") }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: {
            $0.windowID == target.id && $0.owningApplication?.processID == target.pid &&
                $0.owningApplication?.bundleIdentifier == bundleID && $0.windowLayer == 0 &&
                $0.isActive && $0.isOnScreen && $0.frame == target.bounds
        }), content.displays.contains(where: {
            $0.frame.contains(window.frame) && CGDisplayIsAsleep($0.displayID) == 0
        }), target == frontmost() else { return .skipped("window_unavailable") }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.ignoreShadowsSingleWindow = true
        config.ignoreGlobalClipSingleWindow = false
        config.showsCursor = false
        config.capturesAudio = false
        if #available(macOS 14.2, *) { config.includeChildWindows = false }
        let scale = Double(filter.pointPixelScale)
        guard scale.isFinite, (1...4).contains(scale) else { throw CaptureError.imageSize }
        config.width = Int((window.frame.width * scale).rounded())
        config.height = Int((window.frame.height * scale).rounded())
        // Keep the window frame in memory only. Two OCR crops of this identical frame prevent
        // a chat switch from associating unrelated messages with a previously captured title.
        let frame = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        guard target == frontmost(), frame.width == config.width, frame.height == config.height
        else { return .skipped("window_changed") }
        let result = try Recognition.read(frame, spec: spec)
        guard target == frontmost() else { return .skipped("window_changed") }
        return result
    }
}

struct Calibration: Encodable {
    let status = "ok"
    let header, messages, window_size: String
    let window_id: CGWindowID
    let process_id: pid_t

    static func rect(_ first: CGPoint, _ last: CGPoint, in bounds: CGRect) throws -> String {
        guard bounds.contains(first), bounds.contains(last),
              last.x > first.x, last.y > first.y else { throw CaptureError.arguments }
        // Round down the far edges, never enlarge the selected pixel area due to formatting.
        let units = 1_000_000.0
        let x = ceil((first.x - bounds.minX) / bounds.width * units)
        let y = ceil((first.y - bounds.minY) / bounds.height * units)
        let w = floor((last.x - bounds.minX) / bounds.width * units) - x
        let h = floor((last.y - bounds.minY) / bounds.height * units) - y
        return [x, y, w, h].map { String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), $0 / units) }.joined(separator: ",")
    }

    @MainActor static func run() async throws -> Result<Calibration, Skip> {
        log("打开目标微信会话，保持窗口尺寸和位置。每次提示后有 5 秒移动鼠标，不用点击。顺序为标题左上、标题右下、消息区左上、消息区右下。")
        try await Task.sleep(nanoseconds: 5_000_000_000)
        guard let target = WindowTarget.frontmost() else { return .failure(Skip(reason: "no_foreground_wechat")) }
        var points: [CGPoint] = []
        for label in ["① 标题文字左上角", "② 标题文字右下角", "③ 消息区域左上角（排除侧栏）", "④ 消息区域右下角（排除输入框）"] {
            log("请将鼠标停在\(label)，5 秒后取点。")
            NSSound.beep()
            for _ in 0..<5 {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                guard target == WindowTarget.frontmost() else { return .failure(Skip(reason: "window_changed")) }
            }
            guard let point = CGEvent(source: nil)?.location, target.bounds.contains(point)
            else { return .failure(Skip(reason: "point_outside_window")) }
            points.append(point)
        }
        do {
            let header = try rect(points[0], points[1], in: target.bounds)
            let messages = try rect(points[2], points[3], in: target.bounds)
            _ = try CaptureSpec(title: "calibration", header: header, messages: messages)
            return .success(Calibration(header: header, messages: messages, window_size: target.sizeString(),
                                        window_id: target.id, process_id: target.pid))
        } catch { return .failure(Skip(reason: "invalid_regions")) }
    }
}

struct Skip: Error {
    let reason: String
}
