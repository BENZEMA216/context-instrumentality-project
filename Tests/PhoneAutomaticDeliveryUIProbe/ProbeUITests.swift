import XCTest

@MainActor
final class ProbeUITests: XCTestCase {
    private var app: XCUIApplication!
    private var measurements: [[String: Any]] = []
    private var keyboardVisibilityMeasurements: [[String: Any]] = []

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
    }

    override func tearDownWithError() throws {
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "final-accessibility-tree"
        tree.lifetime = .keepAlways
        add(tree)
        screenshot("final-screen")
        for (name, values) in [("frame-measurements", measurements),
                               ("keyboard-visibility-measurements", keyboardVisibilityMeasurements)] where !values.isEmpty {
            let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        app.terminate()
    }

    private func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func show(_ id: String) -> XCUIElement {
        let target = element(id)
        for _ in 0..<12 {
            if target.exists && target.isHittable { return target }
            if target.exists && !target.frame.isEmpty && target.frame.midY < app.frame.midY {
                app.swipeDown(velocity: .slow)
            } else {
                app.swipeUp(velocity: .slow)
            }
        }
        XCTFail("Could not reveal \(id)")
        return target
    }

    private func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }

    private func waitUntil(_ date: Date, file: StaticString = #filePath, line: UInt = #line) {
        let elapsed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in Date() >= date }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [elapsed], timeout: max(0, date.timeIntervalSinceNow) + 2),
                       .completed, file: file, line: line)
    }

    private func openRecordStatus(file: StaticString = #filePath, line: UInt = #line) {
        let opener = show("record-status-open")
        XCTAssertTrue(opener.isHittable, file: file, line: line)
        opener.tap()
        XCTAssertTrue(element("record-status-message").waitForExistence(timeout: 3), file: file, line: line)
        XCTAssertTrue(element("record-status-guidance").exists, file: file, line: line)
        XCTAssertTrue(app.buttons["record-status-refresh"].exists, file: file, line: line)
        XCTAssertTrue(app.buttons["record-status-close"].exists, file: file, line: line)
        XCTAssertFalse(app.buttons["完成"].exists, "Status sheet closes with its close control", file: file, line: line)
    }

    private func closeRecordStatus(file: StaticString = #filePath, line: UInt = #line) {
        app.buttons["record-status-close"].tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                  object: element("record-status-message"))
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 3), .completed, file: file, line: line)
    }

    private func pullRecordStatus(file: StaticString = #filePath, line: UInt = #line) {
        let scroll = app.scrollViews["record-home-scroll"]
        XCTAssertTrue(scroll.isHittable, file: file, line: line)
        let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.17))
        let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.94))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
    }

    private func swipeDismissRecordStatus(file: StaticString = #filePath, line: UInt = #line) {
        let heading = element("record-status-heading")
        XCTAssertTrue(heading.isHittable, file: file, line: line)
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.96))
        heading.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                  object: element("record-status-message"))
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 3), .completed, file: file, line: line)
    }

    private func waitForRecordRefreshToFinish(timeout: TimeInterval = 10,
                                               file: StaticString = #filePath, line: UInt = #line) {
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"),
                                                 object: app.buttons["record-status-refresh"])
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: timeout), .completed, file: file, line: line)
    }

    private func savedDurationValue(file: StaticString = #filePath, line: UInt = #line) -> String {
        let label = show("record-duration").label
        let pieces = label.split(separator: "，", maxSplits: 1)
        XCTAssertEqual(pieces.count, 2, "Duration needs its spoken title and value", file: file, line: line)
        return pieces.last.map(String.init) ?? ""
    }

    private func calendarDayIdentifier(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "record-calendar-day-%04d-%02d-%02d",
                      components.year!, components.month!, components.day!)
    }

    private func assertNoZeroRecordingSummary(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(element("record-duration").exists, "No saved audio is not a confirmed zero-duration report",
                       file: file, line: line)
        XCTAssertFalse(element("record-delivery-summary").exists, file: file, line: line)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", ".*连续\\s*0\\s*天.*"))
            .firstMatch.exists, file: file, line: line)
    }

    private func waitForStableFrame(_ id: String) {
        let target = element(id)
        var previous = target.frame
        var stableSamples = 0
        for _ in 0..<25 {
            settle()
            let current = target.frame
            let delta = max(abs(previous.minX - current.minX), abs(previous.minY - current.minY),
                            abs(previous.width - current.width), abs(previous.height - current.height))
            stableSamples = delta < 0.01 ? stableSamples + 1 : 0
            if stableSamples >= 3 { return }
            previous = current
        }
        XCTFail("Explicit user animation did not settle for \(id)")
    }

    private func frames(_ ids: [String]) -> [String: CGRect] {
        Dictionary(uniqueKeysWithValues: ids.map { id in
            XCTAssertTrue(element(id).exists, "Missing measurement anchor \(id)")
            XCTAssertFalse(element(id).frame.isEmpty, "Empty measurement anchor \(id)")
            return (id, element(id).frame)
        })
    }

    private func assertStable(_ baseline: [String: CGRect], phase: String) {
        for (id, old) in baseline {
            let new = element(id).frame
            let delta = max(abs(old.minX - new.minX), abs(old.minY - new.minY),
                            abs(old.width - new.width), abs(old.height - new.height))
            measurements.append(["anchor": id, "phase": phase, "maximumDeltaPoints": delta,
                                 "before": String(describing: old), "after": String(describing: new)])
            XCTAssertLessThanOrEqual(delta, 1, "\(id) moved during \(phase): \(old) -> \(new)")
        }
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launchSync() {
        app.launch()
        let tab = app.tabBars.buttons["同步"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.tap()
        XCTAssertTrue(element("automatic-delivery-list").waitForExistence(timeout: 5))
    }

    private func openPairing() {
        show("pairing-open").tap()
        XCTAssertTrue(element("pairing-form-heading").waitForExistence(timeout: 5))
    }

    private func closeSheet() {
        let close = app.buttons["关闭"].firstMatch
        XCTAssertTrue(close.exists)
        close.tap()
        settle()
    }

    private func assertSecurePayloadFilled(_ field: XCUIElement,
                                           file: StaticString = #filePath, line: UInt = #line) {
        let value = field.value as? String ?? ""
        let isMask = !value.isEmpty && value.allSatisfy { "•●*".contains($0) }
        XCTAssertTrue(value == "已填写配对信息" || isMask,
                      "Secure payload must expose only a filled hint or bullet mask", file: file, line: line)
        XCTAssertFalse(app.debugDescription.contains("SYNTHETIC-NON-AUTHENTICATING-TEST-TOKEN"),
                       "The synthetic token must never enter the accessibility tree", file: file, line: line)
    }

    private func confirmDisconnect(file: StaticString = #filePath, line: UInt = #line) {
        // The management row remains in the AX tree behind the popover. Match
        // the actual confirmation action by excluding that row's identifier.
        let action = app.buttons.matching(NSPredicate(
            format: "label == %@ AND identifier != %@", "断开连接", "receiver-remove")).firstMatch
        XCTAssertTrue(action.waitForExistence(timeout: 3), file: file, line: line)
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: action)
        XCTAssertEqual(XCTWaiter.wait(for: [hittable], timeout: 3), .completed,
                       "Disconnect confirmation must be visible before tapping", file: file, line: line)
        action.tap()
    }

    private func cancelDisconnect(file: StaticString = #filePath, line: UInt = #line) {
        let cancel = app.buttons["取消"].firstMatch
        if cancel.waitForExistence(timeout: 1), cancel.isHittable {
            cancel.tap()
            return
        }
        // iOS 26.4 on this compact simulator exposes a confirmation popover
        // with no Cancel action. The recorded AX tree exposes its dismiss region
        // and a Sheet at x=67, so tap only outside that Sheet's actual frame.
        let dismissal = app.otherElements.matching(identifier: "PopoverDismissRegion").firstMatch
        let sheet = app.sheets.matching(NSPredicate(format: "label BEGINSWITH %@", "断开与")).firstMatch
        XCTAssertTrue(dismissal.waitForExistence(timeout: 3), file: file, line: line)
        XCTAssertTrue(sheet.waitForExistence(timeout: 3), file: file, line: line)
        let frame = sheet.frame
        let outside = CGPoint(x: max(app.frame.minX + 1, frame.minX / 2), y: frame.midY)
        XCTAssertFalse(frame.contains(outside), "Cancellation must be outside the destructive popover",
                       file: file, line: line)
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: outside.x, dy: outside.y)).tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: sheet)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 3), .completed, file: file, line: line)
    }

    private func tapSwitchThumb() {
        let toggle = show("receiver-toggle")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        settle()
    }

    private func assertInsideScreen(_ ids: [String]) {
        for id in ids {
            let frame = show(id).frame
            XCTAssertGreaterThanOrEqual(frame.minX, app.frame.minX - 1, id)
            XCTAssertLessThanOrEqual(frame.maxX, app.frame.maxX + 1, id)
        }
    }

    func testDiagnosticsExportSeparatesRecentAndFullHistoryAndShowsFailure() {
        app.launchEnvironment["PROBE_CONTROLS"] = "0"
        app.launchEnvironment["PROBE_DRIVE_FAULT"] = "none"
        app.launchEnvironment["PROBE_RECORD_STATE"] = "unknown-saved"
        func openDiagnostics() {
            app.launch()
            let settings = element("record-settings")
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            settings.tap()
            let diagnostics = app.buttons["日志与诊断"].firstMatch
            XCTAssertTrue(diagnostics.waitForExistence(timeout: 5))
            diagnostics.tap()
            XCTAssertTrue(element("diagnostics-generate-recent").waitForExistence(timeout: 5))
        }
        openDiagnostics()
        XCTAssertFalse(element("diagnostics-export-summary").exists,
                       "Opening diagnostics must not implicitly export all history")
        XCTAssertFalse(element("diagnostics-issue-id").exists)
        XCTAssertFalse(element("diagnostics-generate-full-history").exists,
                       "Full history must remain behind its separate explicit disclosure")
        XCTAssertEqual(show("diagnostics-privacy").label,
                       "不含音频、转写正文、位置、账号或凭据。不发起同步，也不重新校验录音。")
        XCTAssertTrue(show("diagnostics-watch-scope").label.contains("缺失或过时会注明"))
        XCTAssertTrue(show("diagnostics-share-guidance").label.contains("不代表报告已发送"))
        show("diagnostics-generate-recent").tap()
        XCTAssertTrue(element("ActivityListView").waitForExistence(timeout: 5),
                      "One explicit recent-report tap must generate and present the native share UI")
        let recentCaption = element("LP.CaptionBar.TopCaption")
        XCTAssertTrue(recentCaption.waitForExistence(timeout: 3))
        XCTAssertTrue(recentCaption.label.hasPrefix("synthetic-issue-recent-"))
        screenshot("diagnostics-recent-one-tap-system-share")
        let cancelShare = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "关闭", "Close")).firstMatch
        XCTAssertTrue(cancelShare.waitForExistence(timeout: 3))
        cancelShare.tap()
        let shareDismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                       object: element("ActivityListView"))
        XCTAssertEqual(XCTWaiter.wait(for: [shareDismissed], timeout: 3), .completed)
        let cancelledTiming = show("diagnostics-timing")
        let cancellationRecorded = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "已取消分享；未发送。"), object: cancelledTiming)
        XCTAssertEqual(XCTWaiter.wait(for: [cancellationRecorded], timeout: 3), .completed,
                       "Cancelling the system panel must not be recorded as a completed activity")
        XCTAssertTrue(show("diagnostics-issue-id").label.hasPrefix("问题编号："))
        // No destination is selected and no report is sent.
        app.terminate()

        openDiagnostics()
        show("diagnostics-history-options").tap()
        show("diagnostics-generate-full-history").tap()
        // The result lives in the report card above this explicit history
        // section. List may remove that offscreen card from its AX tree; the
        // generic show helper otherwise scrolls toward the bottom forever.
        for _ in 0..<5 {
            if element("diagnostics-export-summary").exists { break }
            app.swipeDown(velocity: .fast)
        }
        XCTAssertEqual(show("diagnostics-export-summary").label,
                       "完整历史：合成日志 24 条，未截断。未读取音频或转写。")
        XCTAssertTrue(show("diagnostics-issue-id").label.hasPrefix("问题编号："))
        XCTAssertEqual(show("diagnostics-build").label, "构建 UI-PROBE")
        XCTAssertFalse(element("ActivityListView").exists,
                       "Preparing full history must not automatically share it")
        screenshot("diagnostics-explicit-history-scope")
        show("diagnostics-share-prepared").tap()
        XCTAssertTrue(element("ActivityListView").waitForExistence(timeout: 5))
        let fullCaption = element("LP.CaptionBar.TopCaption")
        XCTAssertTrue(fullCaption.waitForExistence(timeout: 3))
        XCTAssertTrue(fullCaption.label.hasPrefix("synthetic-issue-full-history-"))
        app.terminate()

        app.launchEnvironment["PROBE_DIAGNOSTICS"] = "export_error"
        openDiagnostics()
        XCTAssertTrue(show("diagnostics-share-prepared").exists,
                      "The fixture deliberately starts with an older export")
        show("diagnostics-generate-recent").tap()
        XCTAssertEqual(show("diagnostics-export-error").label, "合成诊断导出失败；没有使用旧文件。")
        XCTAssertFalse(element("diagnostics-export-summary").exists)
        XCTAssertFalse(element("diagnostics-share-prepared").exists,
                       "Failed generation must not offer a stale diagnostic file")
        XCTAssertFalse(element("ActivityListView").exists,
                       "Failure must not automatically present the old file")
    }

    func testFaultReportShareNeedsOneTapAndShowsExportFailure() {
        app.launchEnvironment["PROBE_CONTROLS"] = "0"
        func openDiagnostics() {
            app.launch()
            let settings = element("record-settings")
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            settings.tap()
            let diagnostics = app.buttons["日志与诊断"].firstMatch
            XCTAssertTrue(diagnostics.waitForExistence(timeout: 5))
            diagnostics.tap()
            XCTAssertTrue(element("diagnostics-generate-recent").waitForExistence(timeout: 5))
        }

        app.launchEnvironment["PROBE_DRIVE_FAULT"] = "none"
        openDiagnostics()
        XCTAssertFalse(show("google-drive-share-fault-log").isEnabled,
                       "No frozen failure must leave sharing disabled")
        XCTAssertTrue(app.staticTexts["尚无故障记录。"].exists)
        app.terminate()

        app.launchEnvironment["PROBE_DRIVE_FAULT"] = "retained"
        openDiagnostics()
        let share = show("google-drive-share-fault-log")
        XCTAssertTrue(share.isEnabled)
        share.tap()
        XCTAssertTrue(element("ActivityListView").waitForExistence(timeout: 5),
                      "One tap must present the actual system activity controller")
        let caption = element("LP.CaptionBar.TopCaption")
        XCTAssertTrue(caption.waitForExistence(timeout: 3))
        XCTAssertTrue(caption.label.hasPrefix("synthetic-fault-"),
                      "The system share sheet must contain this tap's synthetic JSON snapshot")
        screenshot("synthetic-fault-system-share")
        // Do not choose a destination or send even the synthetic JSON.
        app.terminate()

        app.launchEnvironment["PROBE_DRIVE_FAULT"] = "export_error"
        openDiagnostics()
        show("google-drive-share-fault-log").tap()
        let error = element("google-drive-fault-export-error")
        XCTAssertTrue(error.waitForExistence(timeout: 3))
        XCTAssertEqual(error.label, "合成导出失败；已有故障记录保留。")
        XCTAssertFalse(element("ActivityListView").exists,
                       "A failed snapshot must not present a stale export")
    }

    func testCloudSyncHomeShowsConnectionsWithoutTotals() {
        app.launchEnvironment["PROBE_RECEIVERS"] = "1"
        app.launchEnvironment["PROBE_CONTROLS"] = "0"
        launchSync()
        XCTAssertTrue(app.staticTexts["保存给 Agent"].exists)
        XCTAssertTrue(element("google-drive-connection").isHittable)
        XCTAssertTrue(element("icloud-drive-connection").isHittable)
        XCTAssertTrue(element("receiver-manage").isHittable)
        XCTAssertFalse(app.staticTexts["今日已收到"].exists)
        XCTAssertFalse(element("receiver-counts").exists)
        screenshot("design13-sync-home-light")
        show("sync-add-connection").tap()
        XCTAssertTrue(app.navigationBars["添加连接"].waitForExistence(timeout: 3))
        XCTAssertTrue(element("pairing-connect").exists)
        screenshot("design13-add-connection-light")
        closeSheet()
        show("receiver-manage").tap()
        XCTAssertTrue(element("receiver-toggle").waitForExistence(timeout: 3))
        XCTAssertEqual(element("receiver-toggle").value as? String, "1")
        show("receiver-toggle").tap()
        XCTAssertEqual(element("receiver-toggle").value as? String, "0")
        closeSheet()
        show("receiver-manage").tap()
        XCTAssertEqual(element("receiver-toggle").value as? String, "0", "Opening a paused row must not resume")
        screenshot("design13-receiver-paused-detail")
    }

    func testCloudSyncEmptyAndTools() {
        app.launchEnvironment["PROBE_RECEIVERS"] = "0"
        app.launchEnvironment["PROBE_CLOUDS"] = "0"
        app.launchEnvironment["PROBE_CONTROLS"] = "0"
        launchSync()
        XCTAssertTrue(app.staticTexts["还没有连接"].exists)
        screenshot("design13-sync-empty-light")
        show("legacy-library-tools").tap()
        XCTAssertTrue(app.navigationBars["录音库工具"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["复制 Agent 连接指引"].exists)
        XCTAssertTrue(app.staticTexts["agent-connection-guide"].label.contains("尚无可提供的云盘位置"))
    }

    func testAgentGuideUsesConnectedCloudLocations() {
        app.launchEnvironment["PROBE_RECEIVERS"] = "0"
        app.launchEnvironment["PROBE_CONTROLS"] = "0"
        launchSync()
        show("legacy-library-tools").tap()
        let guide = app.staticTexts["agent-connection-guide"]
        XCTAssertTrue(guide.waitForExistence(timeout: 3))
        XCTAssertTrue(guide.label.contains("https://drive.google.com/drive/folders/synthetic-library"))
        XCTAssertTrue(guide.label.contains("iCloud Drive 文件夹名称：合成录音"))
        XCTAssertFalse(guide.label.contains("MCP"))
        show("agent-statement-copy").tap()
        XCTAssertTrue(app.buttons["已复制连接指引"].exists)
    }

    func testCloudSyncHomeDarkAccessibilityLayout() {
        app.launchEnvironment["PROBE_RECEIVERS"] = "2"
        app.launchEnvironment["PROBE_CONTROLS"] = "0"
        app.launchEnvironment["PROBE_DARK"] = "1"
        app.launchEnvironment["PROBE_LARGE_TYPE"] = "1"
        launchSync()
        _ = show("icloud-drive-connection")
        screenshot("design13-sync-home-dark-accessibility")
        assertInsideScreen(["icloud-drive-connection"])
        show("sync-add-connection").tap()
        XCTAssertTrue(app.navigationBars["添加连接"].waitForExistence(timeout: 3))
    }

    func testRecordEmptyScreenshot() {
        app.launchEnvironment = ["PROBE_RECORD_STATE": "empty", "PROBE_RECEIVERS": "0", "PROBE_CONTROLS": "0"]
        app.launch()
        XCTAssertTrue(app.staticTexts["开始今天的记录"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["如何开始"].exists)
        assertNoZeroRecordingSummary()
        screenshot("v4-record-empty-light")
        app.buttons["如何开始"].tap()
        XCTAssertTrue(app.staticTexts["在手表上开始录音"].waitForExistence(timeout: 3))
        app.buttons["知道了"].tap()
        XCTAssertTrue(app.staticTexts["开始今天的记录"].waitForExistence(timeout: 3))
        assertNoZeroRecordingSummary()
    }

    func testRecordUnknownAndStaleEmptyDoNotInventZeroDuration() {
        for (index, state) in ["unknown", "stale-empty"].enumerated() {
            if index > 0 { app.terminate() }
            app.launchEnvironment = ["PROBE_RECORD_STATE": state, "PROBE_RECEIVERS": "0", "PROBE_CONTROLS": "0"]
            app.launch()
            XCTAssertTrue(app.staticTexts["等待手表更新"].waitForExistence(timeout: 5))
            assertNoZeroRecordingSummary()
            XCTAssertFalse(app.staticTexts["开始今天的记录"].exists)
            let today = show(calendarDayIdentifier(Date()))
            XCTAssertTrue(today.label.contains("待更新"), "Unknown recording status must remain unknown in the calendar")
            screenshot("record-\(state)-light")
            openRecordStatus()
            XCTAssertEqual(element("record-status-message").label, "手表状态待更新")
            XCTAssertEqual(element("record-status-history").exists, state != "unknown",
                           "A missing snapshot must not fabricate a previous report")
            closeRecordStatus()
            assertNoZeroRecordingSummary()
        }
    }

    func testRecordFreshRecordingWaitsForFirstSavedSegment() {
        app.launchEnvironment = ["PROBE_RECORD_STATE": "recording-empty", "PROBE_RECEIVERS": "0", "PROBE_CONTROLS": "0"]
        app.launch()
        XCTAssertTrue(app.staticTexts["录音中"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "首段录音保存"))
            .firstMatch.exists)
        assertNoZeroRecordingSummary()
        screenshot("record-first-segment-pending-light")
        openRecordStatus()
        XCTAssertEqual(element("record-status-message").label, "录音中")
        closeRecordStatus()
        assertNoZeroRecordingSummary()
    }

    func testRecordLibraryReadFailureScreenshot() {
        app.launchEnvironment = ["PROBE_LIBRARY_FAILED": "1", "PROBE_CONTROLS": "0"]
        app.launch()
        let duration = element("record-duration")
        XCTAssertTrue(duration.waitForExistence(timeout: 5))
        XCTAssertEqual(duration.label, "本机录音暂不可用")
        XCTAssertEqual(duration.value as? String, "—")
        XCTAssertTrue(element("record-library-failed").exists)
        XCTAssertTrue(app.staticTexts["本机录音暂时无法读取。下拉仅更新手表状态。"].exists)
        XCTAssertFalse(element("record-library-loading").exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "正在读取")).firstMatch.exists)
        XCTAssertFalse(element("record-delivery-summary").exists)
        XCTAssertFalse(element("recording-calendar").exists)
        XCTAssertFalse(element("record-periods").exists)
        screenshot("v4-record-library-read-failure-light")
    }

    func testRecordPopulatedAndCalendarScreenshot() {
        app.launchEnvironment = ["PROBE_RECEIVERS": "2", "PROBE_CONTROLS": "0"]
        app.launch()
        XCTAssertTrue(element("record-duration").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["录音中"].exists)
        XCTAssertFalse(savedDurationValue().isEmpty)
        XCTAssertEqual(app.buttons.matching(identifier: "record-period-row").count, 0,
                       "Recording periods are collapsed on initial presentation")
        screenshot("v4-record-populated-light")
        let periods = show("record-periods")
        if periods.frame.maxY > app.tabBars.firstMatch.frame.minY {
            app.swipeUp(velocity: .slow)
        }
        XCTAssertLessThanOrEqual(periods.frame.maxY, app.tabBars.firstMatch.frame.minY,
                                "The complete periods control must scroll above the bottom navigation")
        screenshot("record-periods-above-bottom-navigation")
        periods.tap()
        XCTAssertEqual(app.buttons.matching(identifier: "record-period-row").count, 3)
        screenshot("v4-record-calendar-and-periods-light")
        XCTAssertTrue(element("recording-calendar").exists)
        show("record-period-row").tap()
        XCTAssertTrue(app.navigationBars["录音时段"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["查看同步"].exists)
        app.buttons["完成"].tap()
        show("record-delivery-summary").tap()
        XCTAssertTrue(element("automatic-delivery-list").waitForExistence(timeout: 5))
    }

    func testRecordStaleScreenshot() {
        app.launchEnvironment = ["PROBE_RECORD_STATE": "stale", "PROBE_CONTROLS": "0", "PROBE_DARK": "1"]
        app.launch()
        XCTAssertTrue(element("record-duration").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["手表状态待更新"].exists)
        XCTAssertTrue(app.staticTexts["今日已保存"].exists)
        XCTAssertTrue(show(calendarDayIdentifier(Date())).label.contains("状态待更新"),
                      "Saved duration must not hide today's unconfirmed status from VoiceOver")
        XCTAssertFalse(app.buttons["恢复录音"].exists, "A stale snapshot cannot prove interruption")
        screenshot("record-stale-dark")
        openRecordStatus()
        XCTAssertEqual(element("record-status-message").label, "手表状态待更新")
        XCTAssertTrue(element("record-status-guidance").label.contains("确认当前录音状态"))
        screenshot("record-status-collapsed-dark")
        show("record-status-history").tap()
        XCTAssertTrue(app.staticTexts["这是手表上次报告的状态。"].exists)
        screenshot("record-status-history-dark")
    }

    func testRecordCalendarSelectionControlsOnlySelectedDayPeriods() {
        app.launchEnvironment = ["PROBE_RECORD_STATE": "recorded", "PROBE_CONTROLS": "0"]
        app.launch()
        XCTAssertTrue(element("record-duration").waitForExistence(timeout: 5))
        let today = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: today)!
        let todayStart = Calendar.current.startOfDay(for: today)
        let weekdayRow = (Calendar.current.component(.weekday, from: today) + 5) % 7
        let firstVisibleDay = Calendar.current.date(byAdding: .day, value: -56 - weekdayRow, to: todayStart)!
        let futureDays = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "record-calendar-day-", "未来日期"))
        XCTAssertEqual(futureDays.count, 0, "Future placeholders must not become visible or accessible dates")
        let visibleDays = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "record-calendar-day-"))
        XCTAssertEqual(visibleDays.count, 57 + weekdayRow, "Exactly nine week columns ending this week")
        XCTAssertTrue(element(calendarDayIdentifier(firstVisibleDay)).exists)
        XCTAssertFalse(element(calendarDayIdentifier(Calendar.current.date(byAdding: .day, value: -1, to: firstVisibleDay)!)).exists)
        XCTAssertFalse(element(calendarDayIdentifier(Calendar.current.date(byAdding: .day, value: 1, to: today)!)).exists)
        let todayCell = show(calendarDayIdentifier(today))
        XCTAssertEqual(todayCell.frame.maxX, visibleDays.allElementsBoundByIndex.map { $0.frame.maxX }.max()!, accuracy: 1,
                       "Today must be in the rightmost week")
        XCTAssertTrue(element("record-calendar-count").label.contains("近 9 周"))
        XCTAssertTrue(element("record-calendar-range").exists)
        XCTAssertFalse(element("record-calendar-today").exists, "Today needs no return action")
        XCTAssertEqual(app.buttons.matching(identifier: "record-period-row").count, 0)
        show("record-periods").tap()
        XCTAssertEqual(app.buttons.matching(identifier: "record-period-row").count, 3)
        show("record-periods").tap()
        XCTAssertEqual(app.buttons.matching(identifier: "record-period-row").count, 0)

        show(calendarDayIdentifier(yesterday)).tap()
        XCTAssertTrue(element(calendarDayIdentifier(yesterday)).isSelected)
        XCTAssertFalse(element("record-calendar-selection").label.contains("今天"))
        show("record-periods").tap()
        XCTAssertEqual(app.buttons.matching(identifier: "record-period-row").count, 0,
                       "Yesterday must not inherit today's three periods")
        XCTAssertTrue(app.staticTexts["这一天暂无已保存的录音时段"].exists)
        screenshot("record-selected-yesterday-empty-periods")
        show("record-periods").tap()

        let returnToToday = show("record-calendar-today")
        XCTAssertTrue(returnToToday.isEnabled)
        returnToToday.tap()
        XCTAssertTrue(element(calendarDayIdentifier(today)).isSelected)
        XCTAssertTrue(element("record-calendar-selection").label.contains("今天"))
        XCTAssertFalse(element("record-calendar-today").exists)
        XCTAssertEqual(app.buttons.matching(identifier: "record-period-row").count, 0,
                       "Changing dates keeps periods collapsed")
        show("record-periods").tap()
        XCTAssertEqual(app.buttons.matching(identifier: "record-period-row").count, 3)
        screenshot("record-selected-today-three-periods")
    }

    func testRecordStatusFreshFailuresAndStaleFailuresStayDistinct() {
        for (index, state) in ["paused", "interrupted", "failed", "stale-interrupted"].enumerated() {
            if index > 0 { app.terminate() }
            app.launchEnvironment = ["PROBE_RECORD_STATE": state, "PROBE_CONTROLS": "0"]
            app.launch()
            XCTAssertTrue(element("record-duration").waitForExistence(timeout: 5))
            let duration = savedDurationValue()
            openRecordStatus()
            let message = element("record-status-message").label
            let guidance = element("record-status-guidance").label
            if state == "stale-interrupted" {
                XCTAssertEqual(message, "手表状态待更新")
                XCTAssertTrue(guidance.contains("确认当前录音状态"))
                XCTAssertFalse(guidance.contains("恢复录音"), "A stale failure report is history, not current failure")
            } else if state == "paused" {
                XCTAssertTrue(message.contains("暂停"))
                XCTAssertTrue(guidance.contains("继续"))
            } else {
                XCTAssertEqual(message, "录音已中断")
                XCTAssertTrue(guidance.contains("恢复录音"))
            }
            XCTAssertTrue(element("record-status-history").exists)
            screenshot("record-status-\(state)")
            closeRecordStatus()
            XCTAssertEqual(savedDurationValue(), duration, "Opening status must not change recorded audio")
        }
    }

    func testRecordCrossDayPeriodRangeMatchesSelectionInListAndDetail() {
        app.launchEnvironment = ["PROBE_RECORD_STATE": "cross-day-period", "PROBE_CONTROLS": "0"]
        app.launch()
        XCTAssertTrue(element("record-duration").waitForExistence(timeout: 5))
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        show(calendarDayIdentifier(yesterday)).tap()
        show("record-periods").tap()
        XCTAssertEqual(app.buttons.matching(identifier: "record-period-row").count, 1)
        let row = show("record-period-row")
        // Clock text follows the simulator's 12/24-hour preference. Check the
        // boundary semantically, then require the detail to reproduce it exactly.
        let expected = row.label.components(separatedBy: "、").first ?? ""
        XCTAssertTrue(expected.contains("9:00 — 次日 "), "The range must start on the selected day: \(row.label)")
        XCTAssertTrue(expected.hasSuffix("00:00") || expected.hasSuffix("12:00"),
                      "The range must stop at selected day's midnight: \(row.label)")
        XCTAssertTrue(row.label.contains("22 分"), "Only the selected day's 20 + 2 minutes count")
        XCTAssertFalse(row.label.contains("00:02"), "The next day's end time cannot leak into yesterday")
        screenshot("record-cross-day-selected-yesterday-list")
        row.tap()
        XCTAssertTrue(app.navigationBars["录音时段"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts[expected].exists, "The detail must use exactly the same selected-day range")
        screenshot("record-cross-day-selected-yesterday-detail")
        app.buttons["完成"].tap()
        show("record-calendar-today").tap()
        show("record-periods").tap()
        let todayRow = show("record-period-row")
        let todayRange = todayRow.label.components(separatedBy: "、").first ?? ""
        let todayBounds = todayRange.components(separatedBy: " — ")
        XCTAssertEqual(todayBounds.count, 2)
        XCTAssertTrue(todayBounds[0].hasSuffix("00:00") || todayBounds[0].hasSuffix("12:00"))
        XCTAssertTrue(todayBounds[1].hasSuffix("00:02") || todayBounds[1].hasSuffix("12:02"))
        XCTAssertFalse(todayRange.contains("次日"))
        XCTAssertFalse(todayRow.label.contains("09:00"), "Yesterday's session start cannot leak into today")
        XCTAssertTrue(todayRow.label.contains("2 分"))
        screenshot("record-cross-day-selected-today-list")
    }

    func testRecordHomePullRefreshWaitsForReportAndShowsResult() {
        app.launchEnvironment = ["PROBE_RECORD_STATE": "stale", "PROBE_SYNC_RESPONSE": "report",
                                 "PROBE_CONTROLS": "0", "PROBE_STATUS_TRACE": "1"]
        app.launch()
        XCTAssertTrue(element("record-duration").waitForExistence(timeout: 5))
        let duration = savedDurationValue()
        XCTAssertFalse(element("record-home-status-feedback").exists)
        pullRecordStatus()
        let feedback = element("record-home-status-feedback")
        XCTAssertTrue(feedback.waitForExistence(timeout: 2))
        // XCTest's native gesture waits for refresh animation quiescence. The
        // lifecycle trace establishes that the async wait actually completed,
        // rather than the framework cancelling it and dropping the feedback.
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "查询完成"),
                                                 object: feedback)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 6), .completed)
        XCTAssertTrue(feedback.label.contains("已收到手表录音状态"))
        let waitFinished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "waitFinishes=1"),
                                                     object: element("probe-status-wait-trace"))
        XCTAssertEqual(XCTWaiter.wait(for: [waitFinished], timeout: 2), .completed)
        XCTAssertTrue(element("probe-status-wait-trace").label.contains("requestStarts=1"))
        XCTAssertTrue(element("probe-status-wait-trace").label.contains("cancelRequests=0"))
        XCTAssertEqual(savedDurationValue(), duration)
        XCTAssertTrue(app.staticTexts["已暂停"].exists)
        screenshot("record-home-pull-report-received")
    }

    func testRecordHomePullRefreshShowsFailuresWithoutChangingSavedState() {
        let cases = [("unsupported", "当前手表版本不支持只读状态查询"),
                     ("no-response", "暂未收到状态更新")]
        for (index, value) in cases.enumerated() {
            if index > 0 { app.terminate() }
            app.launchEnvironment = ["PROBE_RECORD_STATE": "stale", "PROBE_SYNC_RESPONSE": value.0,
                                     "PROBE_CONTROLS": "0", "PROBE_STATUS_TRACE": "1"]
            app.launch()
            XCTAssertTrue(element("record-duration").waitForExistence(timeout: 5))
            let duration = savedDurationValue()
            let started = Date()
            pullRecordStatus()
            let feedback = element("record-home-status-feedback")
            XCTAssertTrue(feedback.waitForExistence(timeout: 2))
            let failed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "查询失败"),
                                                   object: feedback)
            XCTAssertEqual(XCTWaiter.wait(for: [failed], timeout: 10), .completed)
            XCTAssertTrue(feedback.label.contains(value.1))
            XCTAssertTrue(feedback.label.contains("已保存的录音不受影响"))
            if value.0 == "no-response" { XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 7) }
            let waitFinished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "waitFinishes=1"),
                                                         object: element("probe-status-wait-trace"))
            XCTAssertEqual(XCTWaiter.wait(for: [waitFinished], timeout: 2), .completed)
            XCTAssertTrue(element("probe-status-wait-trace").label.contains("cancelRequests=0"))
            XCTAssertEqual(savedDurationValue(), duration)
            XCTAssertTrue(app.staticTexts["手表状态待更新"].exists)
            screenshot("record-home-pull-\(value.0)-failed")
        }
    }

    func testRecordHomeLeavingPageCancelsOwnedRefresh() {
        app.launchEnvironment = ["PROBE_RECORD_STATE": "stale", "PROBE_SYNC_RESPONSE": "no-response",
                                 "PROBE_CONTROLS": "0", "PROBE_STATUS_TRACE": "1",
                                 "PROBE_LEAVE_HOME_DURING_STATUS": "1"]
        app.launch()
        XCTAssertTrue(element("record-duration").waitForExistence(timeout: 5))
        let duration = savedDurationValue()
        pullRecordStatus()
        let feedback = element("record-home-status-feedback")
        // The synthetic native-tab transition exercises production onDisappear
        // while XCTest is waiting for refresh quiescence. The trace checks the
        // owned task cancellation; it does not claim a user tab-tap was tested.
        let cancelled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "cancelRequests=1"),
                                                  object: element("probe-status-wait-trace"))
        XCTAssertEqual(XCTWaiter.wait(for: [cancelled], timeout: 3), .completed)
        app.tabBars.buttons["记录"].tap()
        XCTAssertFalse(feedback.exists, "Leaving the page cancels its owned request and clears waiting feedback")
        XCTAssertEqual(savedDurationValue(), duration)

        pullRecordStatus()
        XCTAssertTrue(feedback.waitForExistence(timeout: 2))
        XCTAssertTrue(element("probe-status-wait-trace").label.contains("requestStarts=2"))
        let failed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "查询失败"),
                                               object: feedback)
        XCTAssertEqual(XCTWaiter.wait(for: [failed], timeout: 10), .completed)
        XCTAssertTrue(feedback.label.contains("暂未收到状态更新"))
        XCTAssertTrue(element("probe-status-wait-trace").label.contains("cancelRequests=1"),
                      "Framework refresh-action cancellation must not cancel a new page-owned query")
        XCTAssertEqual(savedDurationValue(), duration)
        screenshot("record-home-left-and-reopened")
    }

    func testRecordStatusUnsupportedWatchAndMissingReportAreExplicitFailures() {
        let cases = [("unsupported", "当前手表版本不支持只读状态查询"),
                     ("no-report", "手表尚无可用的录音状态报告"),
                     ("stale-report", "手表返回的是上次报告")]
        for (index, value) in cases.enumerated() {
            if index > 0 { app.terminate() }
            app.launchEnvironment = ["PROBE_RECORD_STATE": "stale", "PROBE_SYNC_RESPONSE": value.0,
                                     "PROBE_CONTROLS": "0"]
            app.launch()
            XCTAssertTrue(element("record-duration").waitForExistence(timeout: 5))
            let duration = savedDurationValue()
            openRecordStatus()
            app.buttons["record-status-refresh"].tap()
            waitForRecordRefreshToFinish(timeout: 4)
            XCTAssertTrue(element("record-status-message").label.contains(value.1))
            XCTAssertEqual(element("record-status-guidance").label, "已保存的录音不受影响。")
            XCTAssertTrue(app.buttons["record-status-refresh"].isHittable)
            screenshot("record-status-explicit-\(value.0)")
            closeRecordStatus()
            XCTAssertEqual(savedDurationValue(), duration)
            XCTAssertTrue(app.staticTexts["手表状态待更新"].exists,
                          "A rejected query must not manufacture a new recording state")
        }
    }

    func testRecordStatusRefreshAcceptsNewReportButNotEarlyACK() {
        for (index, response) in ["report", "ack-then-report"].enumerated() {
            if index > 0 { app.terminate() }
            app.launchEnvironment = ["PROBE_RECORD_STATE": "stale", "PROBE_SYNC_RESPONSE": response, "PROBE_CONTROLS": "0"]
            app.launch()
            XCTAssertTrue(element("record-duration").waitForExistence(timeout: 5))
            let duration = savedDurationValue()
            openRecordStatus()
            let started = Date()
            app.buttons["record-status-refresh"].tap()
            if response == "ack-then-report" {
                waitUntil(started.addingTimeInterval(1.25))
                XCTAssertFalse(app.buttons["record-status-refresh"].isEnabled,
                               "The ACK at 0.25s cannot finish waiting for the report at 4s")
                XCTAssertFalse(element("record-status-message").label.contains("暂停"))
            }
            waitForRecordRefreshToFinish(timeout: 7)
            XCTAssertTrue(element("record-status-message").label.contains("暂停"))
            if response == "ack-then-report" {
                XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 3)
            }
            screenshot("record-status-\(response)-received")
            closeRecordStatus()
            XCTAssertEqual(savedDurationValue(), duration, "A fresh status report adds no audio duration")
        }
    }

    func testRecordStatusRefreshRejectsNewerButStillStaleReport() {
        app.launchEnvironment = ["PROBE_RECORD_STATE": "stale", "PROBE_SYNC_RESPONSE": "newer-stale-then-report", "PROBE_CONTROLS": "0"]
        app.launch()
        XCTAssertTrue(element("record-duration").waitForExistence(timeout: 5))
        let duration = savedDurationValue()
        openRecordStatus()
        let started = Date()
        app.buttons["record-status-refresh"].tap()
        waitUntil(started.addingTimeInterval(1.25))
        XCTAssertFalse(app.buttons["record-status-refresh"].isEnabled,
                       "A newer timestamp is insufficient while its report remains stale")
        XCTAssertFalse(element("record-status-message").label.contains("暂停"))
        screenshot("record-status-newer-stale-still-waiting")
        waitForRecordRefreshToFinish(timeout: 7)
        XCTAssertTrue(element("record-status-message").label.contains("暂停"))
        closeRecordStatus()
        XCTAssertEqual(savedDurationValue(), duration)
    }

    func testRecordStatusRefreshTimeoutPreservesSavedAudioAndCaptureState() {
        for (index, state) in ["recorded", "stale"].enumerated() {
            if index > 0 { app.terminate() }
            app.launchEnvironment = ["PROBE_RECORD_STATE": state, "PROBE_SYNC_RESPONSE": "no-response", "PROBE_CONTROLS": "0"]
            app.launch()
            XCTAssertTrue(element("record-duration").waitForExistence(timeout: 5))
            let duration = savedDurationValue()
            openRecordStatus()
            let started = Date()
            app.buttons["record-status-refresh"].tap()
            waitUntil(started.addingTimeInterval(1.25))
            XCTAssertFalse(app.buttons["record-status-refresh"].isEnabled,
                           "Neither a request ACK nor an already-fresh baseline report satisfies refresh")
            waitForRecordRefreshToFinish(timeout: 10)
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 7,
                                        "Refresh must wait for its eight-second deadline")
            XCTAssertTrue(element("record-status-message").label.contains("暂未收到"))
            screenshot("record-status-\(state)-timeout")
            closeRecordStatus()
            XCTAssertEqual(savedDurationValue(), duration)
            XCTAssertTrue(app.staticTexts[state == "recorded" ? "录音中" : "手表状态待更新"].exists,
                          "A refresh timeout must not manufacture a new capture state")
        }
    }

    func testRecordStatusConnectionRecoveryClearsErrorWithoutAnotherTap() {
        app.launchEnvironment = ["PROBE_RECORD_STATE": "stale", "PROBE_SYNC_RESPONSE": "unreachable-then-recovery",
                                 "PROBE_CONTROLS": "0", "PROBE_STATUS_TRACE": "1"]
        app.launch()
        XCTAssertTrue(element("record-duration").waitForExistence(timeout: 5))
        let duration = savedDurationValue()
        openRecordStatus()
        app.buttons["record-status-refresh"].tap()
        let failed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "暂时无法联系手表"),
                                               object: element("record-status-message"))
        XCTAssertEqual(XCTWaiter.wait(for: [failed], timeout: 3), .completed)
        XCTAssertTrue(element("record-status-guidance").label.contains("连接恢复后会自动再试一次"))
        screenshot("record-status-recovery-initial-failure")
        let recovered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "已暂停"),
                                                  object: element("record-status-message"))
        XCTAssertEqual(XCTWaiter.wait(for: [recovered], timeout: 13), .completed)
        XCTAssertTrue(app.buttons["record-status-refresh"].isEnabled)
        XCTAssertFalse(element("record-status-guidance").label.contains("自动再试"))
        XCTAssertTrue(element("probe-status-wait-trace").label.contains("requestStarts=2"))
        XCTAssertTrue(element("probe-status-wait-trace").label.contains("cancelRequests=0"))
        screenshot("record-status-recovery-cleared-error")
        closeRecordStatus()
        XCTAssertEqual(savedDurationValue(), duration)
    }

    func testRecordStatusClosingFailedIntentRevokesAutomaticRecovery() {
        app.launchEnvironment = ["PROBE_RECORD_STATE": "stale", "PROBE_SYNC_RESPONSE": "unreachable-then-recovery",
                                 "PROBE_CONTROLS": "0", "PROBE_STATUS_TRACE": "1"]
        app.launch()
        XCTAssertTrue(element("record-duration").waitForExistence(timeout: 5))
        openRecordStatus()
        app.buttons["record-status-refresh"].tap()
        let failed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "暂时无法联系手表"),
                                               object: element("record-status-message"))
        XCTAssertEqual(XCTWaiter.wait(for: [failed], timeout: 3), .completed)
        let failureSeen = Date()
        closeRecordStatus()
        openRecordStatus()
        XCTAssertEqual(element("record-status-message").label, "手表状态待更新")
        waitUntil(failureSeen.addingTimeInterval(11))
        XCTAssertEqual(element("record-status-message").label, "手表状态待更新")
        XCTAssertTrue(element("probe-status-wait-trace").label.contains("requestStarts=1"))
        XCTAssertTrue(element("probe-status-wait-trace").label.contains("cancelRequests=1"))
        screenshot("record-status-closed-intent-no-retry")
        closeRecordStatus()
    }

    func testRecordStatusCloseReopenCancelsPreviousRefreshTimeout() {
        app.launchEnvironment = ["PROBE_RECORD_STATE": "stale", "PROBE_SYNC_RESPONSE": "no-response", "PROBE_CONTROLS": "0"]
        app.launch()
        XCTAssertTrue(element("record-duration").waitForExistence(timeout: 5))
        let duration = savedDurationValue()
        openRecordStatus()
        let previousRequest = Date()
        app.buttons["record-status-refresh"].tap()
        waitUntil(previousRequest.addingTimeInterval(0.75))
        closeRecordStatus()
        openRecordStatus()
        XCTAssertTrue(app.buttons["record-status-refresh"].isEnabled,
                      "A reopened sheet must not retain a dismissed presentation's local wait")
        XCTAssertEqual(element("record-status-message").label, "手表状态待更新")

        waitUntil(previousRequest.addingTimeInterval(3))
        let currentRequest = Date()
        app.buttons["record-status-refresh"].tap()
        waitUntil(previousRequest.addingTimeInterval(8.75))
        XCTAssertFalse(app.buttons["record-status-refresh"].isEnabled,
                       "The previous presentation's deadline must not end this request")
        screenshot("record-status-reopened-after-old-deadline")
        // Leave room for UIKit event delivery and XCTest's polling interval;
        // the assertions still reject an early timeout from the old sheet.
        waitForRecordRefreshToFinish(timeout: 10)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(currentRequest), 7)
        XCTAssertTrue(element("record-status-message").label.contains("暂未收到状态更新"))
        closeRecordStatus()
        XCTAssertEqual(savedDurationValue(), duration)
    }

    func testRecordStatusSwipeDismissCancelsRequestBeforeReopening() {
        app.launchEnvironment = ["PROBE_RECORD_STATE": "stale", "PROBE_SYNC_RESPONSE": "no-response",
                                 "PROBE_CONTROLS": "0"]
        app.launch()
        XCTAssertTrue(element("record-duration").waitForExistence(timeout: 5))
        let duration = savedDurationValue()
        openRecordStatus()
        let previousRequest = Date()
        app.buttons["record-status-refresh"].tap()
        waitUntil(previousRequest.addingTimeInterval(0.75))
        swipeDismissRecordStatus()
        XCTAssertFalse(element("record-home-status-feedback").exists,
                       "Native dismissal cancels the pending sheet query and its feedback")
        openRecordStatus()
        XCTAssertTrue(app.buttons["record-status-refresh"].isEnabled)
        XCTAssertEqual(element("record-status-message").label, "手表状态待更新")
        waitUntil(previousRequest.addingTimeInterval(3))
        let currentRequest = Date()
        app.buttons["record-status-refresh"].tap()
        waitUntil(previousRequest.addingTimeInterval(8.75))
        XCTAssertFalse(app.buttons["record-status-refresh"].isEnabled,
                       "The dismissed query's old deadline cannot end the reopened query")
        waitForRecordRefreshToFinish(timeout: 10)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(currentRequest), 7)
        XCTAssertTrue(element("record-status-message").label.contains("暂未收到状态更新"))
        closeRecordStatus()
        XCTAssertEqual(savedDurationValue(), duration)
        screenshot("record-status-swipe-dismiss-reopen")
    }

    func testRecordStatusUnrelatedLateReportCannotSatisfyTimedOutQuery() {
        app.launchEnvironment = ["PROBE_RECORD_STATE": "stale", "PROBE_SYNC_RESPONSE": "late-report", "PROBE_CONTROLS": "0"]
        app.launch()
        XCTAssertTrue(element("record-duration").waitForExistence(timeout: 5))
        let duration = savedDurationValue()
        openRecordStatus()
        let started = Date()
        app.buttons["record-status-refresh"].tap()
        waitForRecordRefreshToFinish(timeout: 10)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 7)
        XCTAssertTrue(element("record-status-message").label.contains("暂未收到状态更新"),
                       "The eight-second UI deadline must precede the report scheduled at ten seconds")
        screenshot("record-status-late-report-timeout")

        waitUntil(started.addingTimeInterval(11))
        XCTAssertTrue(element("record-status-message").label.contains("暂未收到"),
                      "An unrelated fresh snapshot cannot change a terminated query into success")
        XCTAssertEqual(element("record-status-guidance").label, "已保存的录音不受影响。")
        XCTAssertTrue(app.buttons["record-status-refresh"].isEnabled)
        screenshot("record-status-unrelated-late-report-query-still-failed")
        closeRecordStatus()
        XCTAssertEqual(savedDurationValue(), duration, "A late status report adds no saved audio")
        XCTAssertTrue(app.staticTexts["已暂停"].exists)
    }

    func testSyncReceiverCountScreenshots() {
        for count in 0...2 {
            if count > 0 { app.terminate() }
            app.launchEnvironment = ["PROBE_RECEIVERS": String(count), "PROBE_CONTROLS": "0"]
            launchSync()
            XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "receiver-card").count, count)
            if count == 0 { XCTAssertTrue(app.staticTexts["连接你的 Agent"].exists) }
            else { XCTAssertTrue(element("receiver-counts").exists) }
            screenshot("v4-sync-\(count)-receivers-light")
        }
    }

    func testRecordAndSyncDarkAccessibilityScreenshots() {
        app.launchEnvironment = ["PROBE_RECEIVERS": "2", "PROBE_CONTROLS": "0", "PROBE_LARGE_TYPE": "1", "PROBE_DARK": "1"]
        app.launch()
        XCTAssertTrue(element("record-duration").waitForExistence(timeout: 5))
        screenshot("v4-record-populated-dark-ax5")
        assertInsideScreen(["record-duration", "record-delivery-summary", "recording-calendar"])
        screenshot("v4-record-calendar-dark-ax5")
        app.tabBars.buttons["同步"].tap()
        _ = show("icloud-drive-connection")
        screenshot("v4-sync-two-receivers-dark-ax5")
        assertInsideScreen(["icloud-drive-connection", "sync-add-connection"])
        app.tabBars.buttons["记录"].tap()
        openRecordStatus()
        assertInsideScreen(["record-status-message", "record-status-guidance", "record-status-refresh", "record-status-close"])
        screenshot("record-status-dark-ax5")
    }

    func testStateLoopKeepsCardAndFormStable() {
        launchSync()
        _ = show("receiver-toggle")
        let card = frames(["receiver-card", "receiver-status", "receiver-counts"])
        for index in 0..<9 {
            element("probe-next").tap()
            settle()
            assertStable(card, phase: "card-step-\(index)")
        }
        screenshot("v4-receiver-after-nine-phases")
        element("probe-cycle").tap()
        openPairing()
        _ = show("pairing-payload")
        waitForStableFrame("pairing-payload")
        let form = frames(["pairing-form-heading", "pairing-name", "pairing-payload"])
        for index in 0..<9 {
            settle()
            assertStable(form, phase: "form-cycle-\(index)")
        }
        screenshot("v4-pairing-form-during-background-updates")
    }

    func testSavedReceiverPairingDoesNotClaimCurrentConnection() {
        launchSync()
        show("receiver-manage").tap()
        XCTAssertTrue(element("receiver-reachability").waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["电脑接收端 · 配对已保存"].exists)
        XCTAssertTrue(app.staticTexts["当前可达性未确认"].exists)
        XCTAssertTrue(app.buttons["发送待同步录音"].exists)
        XCTAssertTrue(app.staticTexts["此操作会发送手机已收到的待同步录音，不是连接检查。"].exists)
        XCTAssertTrue(app.buttons["检查连接"].exists)
        XCTAssertTrue(app.staticTexts["只检查接收程序与配对授权，不发送录音。"].exists)
        screenshot("receiver-saved-pairing-reachability-unknown")
    }

    func testReceiverConnectionFailureShowsDatedWarningAndReadOnlyAction() {
        app.launchEnvironment["PROBE_RECEIVER_HEALTH"] = "timeout"
        launchSync()
        show("receiver-manage").tap()
        XCTAssertTrue(element("receiver-reachability").waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["连接检查：连接电脑超时"].exists)
        XCTAssertTrue(element("receiver-probe-time").exists)
        XCTAssertTrue(element("receiver-connection-hint").label.contains("本地网络"))
        XCTAssertTrue(element("receiver-transfer-result").exists)
        XCTAssertFalse(element("receiver-transfer-time").exists,
            "A failed connection probe cannot invent a transfer result or transfer timestamp")
        show("receiver-check-connection").tap()
        XCTAssertTrue(app.staticTexts["连接检查：连接电脑超时"].exists)
        screenshot("receiver-timeout-warning-and-read-only-check")
    }

    func testReceiverSuccessfulProbeDoesNotHideFailedTransfer() {
        app.launchEnvironment["PROBE_RECEIVER_HEALTH"] = "reachable-transfer-failed"
        launchSync()
        show("receiver-manage").tap()
        XCTAssertTrue(element("receiver-reachability").waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["检查时可连接"].exists)
        XCTAssertTrue(element("receiver-probe-time").exists)
        XCTAssertTrue(element("receiver-transfer-time").exists)
        XCTAssertTrue(app.staticTexts["失败 · 连接电脑超时"].exists)
        XCTAssertTrue(element("receiver-connection-hint").label.contains("本地网络"))
        show("receiver-check-connection").tap()
        XCTAssertTrue(app.staticTexts["失败 · 连接电脑超时"].exists,
            "A healthy status-only request is not evidence of a stored recording")
        screenshot("receiver-reachable-check-with-failed-transfer")
    }

    func testManagementDetailsPauseResumeAndRemovalCancelOrFailure() {
        app.launchEnvironment["PROBE_FAIL_REMOVAL"] = "1"
        launchSync()
        tapSwitchThumb()
        XCTAssertEqual(element("receiver-toggle").value as? String, "0")
        tapSwitchThumb()
        XCTAssertEqual(element("receiver-toggle").value as? String, "1")
        show("receiver-manage").tap()
        show("receiver-details").tap()
        XCTAssertTrue(app.navigationBars["同步详情"].waitForExistence(timeout: 3))
        screenshot("v4-sync-details")
        app.navigationBars.buttons["同步管理"].tap()
        show("receiver-connection-info").tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "synthetic-receiver.invalid")).firstMatch.waitForExistence(timeout: 3))
        screenshot("v4-sync-connection-info")
        app.navigationBars.buttons["同步管理"].tap()
        show("receiver-remove").tap()
        screenshot("v4-disconnect-confirmation")
        cancelDisconnect()
        XCTAssertTrue(element("receiver-remove").exists)
        show("receiver-remove").tap()
        confirmDisconnect()
        XCTAssertTrue(element("receiver-removal-error").waitForExistence(timeout: 3))
        screenshot("v4-disconnect-failure-preserves-management")
        closeSheet()
        XCTAssertTrue(element("receiver-card").exists)
        XCTAssertEqual(element("receiver-toggle").value as? String, "0")
    }

    func testDisconnectAffectsOnlyChosenSyntheticReceiver() {
        app.launchEnvironment["PROBE_RECEIVERS"] = "2"
        launchSync()
        show("receiver-manage").tap()
        show("receiver-remove").tap()
        confirmDisconnect()
        XCTAssertTrue(element("receiver-card").waitForExistence(timeout: 3))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "receiver-card").count, 1)
        XCTAssertEqual(element("receiver-toggle").value as? String, "0", "The other receiver keeps its own pause setting")
        screenshot("v4-disconnect-one-preserves-other-paused-receiver")
    }

    func testPairingDraftRequiresConsentAndPreservesTokenPrivacy() {
        launchSync()
        element("probe-draft").tap()
        openPairing()
        let connect = show("pairing-add")
        XCTAssertTrue(app.staticTexts["fresh-fixture.invalid"].exists)
        XCTAssertFalse(connect.isEnabled, "Loading a draft must not grant full-library consent")
        assertSecurePayloadFilled(element("pairing-payload"))
        XCTAssertFalse(app.debugDescription.contains("SYNTHETIC-NON-AUTHENTICATING-TEST-TOKEN"))
        screenshot("v4-pairing-review-before-consent")
        let consent = show("pairing-consent")
        consent.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(connect.isEnabled)
        screenshot("v4-pairing-review-after-consent")
        connect.tap()
        XCTAssertTrue(element("automatic-delivery-list").waitForExistence(timeout: 3))
        XCTAssertFalse(element("pairing-payload").exists)
    }

    func testUserInputSurvivesUpdates() throws {
        launchSync()
        element("probe-cycle").tap()
        openPairing()
        let name = show("pairing-name")
        name.tap()
        name.typeText("Synthetic Name")
        let payload = show("pairing-payload")
        payload.tap()
        // Completing valid JSON only AFTER blur/refocus proves the original
        // prefix survived. A constant masked accessibility value cannot prove it.
        let value: [String: Any] = [
            "schemaVersion": 1, "endpoint": "https://edited-fixture.invalid:9443",
            "receiverID": "33333333-4444-4555-8666-777777777777",
            "token": "SYNTHETIC-NON-AUTHENTICATING-TEST-TOKEN",
            "certificateSHA256": String(repeating: "a", count: 64)
        ]
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        let complete = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertEqual(complete.last, "}")
        payload.typeText(String(complete.dropLast()))
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        XCTAssertEqual(name.value as? String, "Synthetic Name")
        assertSecurePayloadFilled(payload)
        XCTAssertFalse(element("pairing-add").exists, "Incomplete JSON must not be ready for consent")
        finishPairingKeyboard()
        XCTAssertEqual(name.value as? String, "Synthetic Name")
        assertSecurePayloadFilled(payload)
        screenshot("v4-typed-input-after-done")

        payload.tap()
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        // Tap the actual software-keyboard key after refocus, retaining the
        // semantic check that the whole original JSON prefix survived.
        keyboard.keys["more"].tap()
        keyboard.buttons["shift"].tap()
        XCTAssertTrue(keyboard.keys["}"].waitForExistence(timeout: 3))
        keyboard.keys["}"].tap()
        finishPairingKeyboard()
        XCTAssertEqual(name.value as? String, "Synthetic Name")
        assertSecurePayloadFilled(payload)
        XCTAssertFalse(app.debugDescription.contains(complete))
        XCTAssertTrue(app.staticTexts["edited-fixture.invalid"].waitForExistence(timeout: 3),
                      "The original payload must survive blur/refocus and accept an appended suffix")
        XCTAssertFalse(show("pairing-load-draft").isEnabled, "Typed input must disable draft replacement")
        XCTAssertTrue(element("pairing-consent").exists)
        XCTAssertFalse(show("pairing-add").isEnabled, "Valid edited input still requires explicit consent")
        screenshot("v4-typed-input-after-refocus-append")
    }

    private func finishPairingKeyboard(file: StaticString = #filePath, line: UInt = #line) {
        let done = app.buttons.matching(NSPredicate(format: "label == %@", "完成"))
            .allElementsBoundByIndex.first { $0.isHittable }
        let button = try? XCTUnwrap(done, "Keyboard Done action must be visible", file: file, line: line)
        guard let button else { return }
        button.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                  object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 3), .completed,
                       "Done must dismiss the software keyboard", file: file, line: line)
    }

    func testReminderViewUsesOnlySyntheticSettings() {
        app.launchEnvironment["PROBE_CONTROLS"] = "0"
        app.launch()
        show("record-settings").tap()
        show("record-reminder").tap()
        let toggle = show("daily-reminder-toggle")
        XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertTrue(app.staticTexts["合成提醒设置；未请求通知权限或创建通知。"].exists)
        screenshot("v4-reminder-synthetic-settings")
    }

    private func visibleKeyboardSuggestionFrame(above keysFrame: CGRect) -> CGRect? {
        // iOS exposes its prediction/Passwords strip separately from Keyboard.
        // Its real AX frame, not an assumed fixed height, limits visible content.
        let predictions = app.otherElements.matching(
            NSPredicate(format: "label == %@", "键入预测字词")).allElementsBoundByIndex
        let passwords = app.buttons.matching(
            NSPredicate(format: "label IN %@", ["Passwords", "密码"])).allElementsBoundByIndex
        let screen = app.frame
        return (predictions + passwords).compactMap { candidate -> CGRect? in
            guard candidate.exists else { return nil }
            let frame = candidate.frame
            guard !frame.isEmpty, frame.intersects(screen),
                  frame.minX < keysFrame.maxX, frame.maxX > keysFrame.minX,
                  frame.minY < keysFrame.minY, frame.maxY <= keysFrame.minY + 1 else { return nil }
            return frame
        }.min { $0.minY < $1.minY }
    }

    private func assertFocusedFieldAboveKeyboard(_ id: String, phase: String,
                                                file: StaticString = #filePath, line: UInt = #line) {
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5),
                      "This check requires the software keyboard", file: file, line: line)
        let field = element(id)
        var previousField = field.frame
        var previousKeyboard = keyboard.frame
        var previousOccludedTop = min(previousKeyboard.minY,
                                      visibleKeyboardSuggestionFrame(above: previousKeyboard)?.minY
                                      ?? previousKeyboard.minY)
        var stableSamples = 0
        for _ in 0..<25 {
            settle()
            let nextField = field.frame
            let nextKeyboard = keyboard.frame
            let nextOccludedTop = min(nextKeyboard.minY,
                                      visibleKeyboardSuggestionFrame(above: nextKeyboard)?.minY
                                      ?? nextKeyboard.minY)
            let delta = max(abs(previousField.minY - nextField.minY),
                            abs(previousField.maxY - nextField.maxY),
                            abs(previousKeyboard.minY - nextKeyboard.minY),
                            abs(previousKeyboard.maxY - nextKeyboard.maxY),
                            abs(previousOccludedTop - nextOccludedTop))
            stableSamples = delta < 0.5 ? stableSamples + 1 : 0
            previousField = nextField
            previousKeyboard = nextKeyboard
            previousOccludedTop = nextOccludedTop
            if stableSamples >= 3 { break }
        }
        let fieldFrame = field.frame
        let keysFrame = keyboard.frame
        let suggestionFrame = visibleKeyboardSuggestionFrame(above: keysFrame)
        let occludedTop = min(keysFrame.minY, suggestionFrame?.minY ?? keysFrame.minY)
        let navigationBar = app.navigationBars.firstMatch
        let visibleTop = navigationBar.exists ? navigationBar.frame.maxY : app.frame.minY
        let gap = occludedTop - fieldFrame.maxY
        keyboardVisibilityMeasurements.append([
            "field": id, "phase": phase,
            "fieldFrame": String(describing: fieldFrame),
            "keysFrame": String(describing: keysFrame),
            "suggestionFrame": suggestionFrame.map { String(describing: $0) } ?? "none",
            "occludedTop": occludedTop,
            "visibleTop": visibleTop, "gapAboveKeyboardPoints": gap,
            "stableSamples": stableSamples
        ])
        screenshot("\(id)-keyboard-\(phase)")
        XCTAssertGreaterThanOrEqual(stableSamples, 3, "Keyboard layout did not settle",
                                    file: file, line: line)
        XCTAssertFalse(fieldFrame.isEmpty, file: file, line: line)
        XCTAssertGreaterThan(keysFrame.height, 100,
                             "A hardware-keyboard suggestion bar is not sufficient",
                             file: file, line: line)
        XCTAssertGreaterThanOrEqual(fieldFrame.minY, visibleTop,
                                    "The focused field is hidden above the visible list",
                                    file: file, line: line)
        XCTAssertGreaterThanOrEqual(gap, 4,
                                    "The complete focused field must remain above the keyboard and suggestion strip",
                                    file: file, line: line)
        XCTAssertGreaterThanOrEqual(fieldFrame.minX, app.frame.minX, file: file, line: line)
        XCTAssertLessThanOrEqual(fieldFrame.maxX, app.frame.maxX, file: file, line: line)
    }

    private func checkFocusedPairingFieldsAboveKeyboard() {
        for (index, fixture) in [("pairing-name", "Synthetic Name"),
                                 ("pairing-payload", "typed-payload")].enumerated() {
            if index > 0 { app.terminate() }
            launchSync()
            element("probe-cycle").tap()
            openPairing()
            let (id, text) = fixture
            let field = show(id)
            waitForStableFrame(id)
            XCTAssertTrue(field.isHittable)
            screenshot("\(id)-before-focus")
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            assertFocusedFieldAboveKeyboard(id, phase: "focused")
            field.typeText(text)
            let originalValue = field.value as? String
            if id == "pairing-name" { XCTAssertEqual(originalValue, text) }
            else { assertSecurePayloadFilled(field) }
            RunLoop.current.run(until: Date().addingTimeInterval(1.5))
            assertFocusedFieldAboveKeyboard(id, phase: "typed-during-transfers")
            XCTAssertEqual(field.value as? String, originalValue,
                           "Background updates must preserve active input")
        }
    }

    func testFocusedPairingFieldsRemainAboveKeyboard() {
        checkFocusedPairingFieldsAboveKeyboard()
    }

    func testFocusedPairingFieldsRemainAboveKeyboardAtMaximumTextSize() {
        app.launchEnvironment["PROBE_LARGE_TYPE"] = "1"
        app.launchEnvironment["PROBE_DARK"] = "1"
        checkFocusedPairingFieldsAboveKeyboard()
    }
}
