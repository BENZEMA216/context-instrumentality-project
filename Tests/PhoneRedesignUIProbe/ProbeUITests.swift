import XCTest

@MainActor final class ProbeUITests: XCTestCase {
    let app = XCUIApplication()
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws {
        let tree = XCTAttachment(string: app.debugDescription);tree.name = "final-hierarchy";tree.lifetime = .keepAlways;add(tree)
        capture("final-screen");app.terminate()
    }
    private func launch(_ scenario: String = "complete", large: Bool = false, dark: Bool = false, draft: Bool = false, receivers: String = "1") {
        app.launchEnvironment = ["PROBE_CONTROLS":"0", "PROBE_PROVIDER_SCENARIO":scenario,
            "PROBE_LARGE_TYPE":large ? "1":"0", "PROBE_DARK":dark ? "1":"0", "PROBE_DRAFT":draft ? "1":"0", "PROBE_RECEIVERS":receivers]
        app.launch()
    }
    private func button(_ id: String) -> XCUIElement { app.buttons[id].firstMatch }
    private func tap(_ id: String) {
        let item = button(id)
        XCTAssertTrue(item.waitForExistence(timeout: 5), id)
        for _ in 0..<12 {
            if item.isHittable { break }
            if item.frame.midY < app.frame.midY { app.swipeDown(velocity: .slow) }
            else { app.swipeUp(velocity: .slow) }
        }
        XCTAssertTrue(item.isHittable, id); item.tap()
    }
    private func capture(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    private func statusElement(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func launchStatusRecovery() {
        app.launchEnvironment = ["PROBE_CONTROLS":"0", "PROBE_RECORD_STATE":"stale",
            "PROBE_SYNC_RESPONSE":"unreachable-then-recovery", "PROBE_STATUS_TRACE":"1"]
        app.launch()
        XCTAssertTrue(button("recording-calendar").waitForExistence(timeout: 5))
        XCTAssertFalse(statusElement("record-status").exists)
        XCTAssertFalse(app.staticTexts["手表状态待更新"].exists)
        tap("record-settings")
        tap("record-settings-watch-status")
        XCTAssertEqual(statusElement("record-status-message").label, "手表状态待更新")
        XCTAssertEqual(statusElement("record-status-guidance").label, "请打开手表 App，确认当前录音状态。")
        tap("record-status-refresh")
        let failure = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "暂时无法联系手表。"),
            object: statusElement("record-status-message"))
        XCTAssertEqual(XCTWaiter.wait(for: [failure], timeout: 4), .completed)
        let guidance = statusElement("record-status-guidance").label
        XCTAssertEqual(guidance, "连接恢复后会自动再试一次。已保存的录音不受影响。")
    }
    func testStatusFailureHasOneRecoveryHintAndRecoversWithoutAnotherTap() {
        launchStatusRecovery()
        capture("status-concise-failure")
        let recovered = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label == %@", "已暂停"),
            object: statusElement("record-status-message"))
        XCTAssertEqual(XCTWaiter.wait(for: [recovered], timeout: 13), .completed)
        XCTAssertFalse(statusElement("record-status-guidance").label.contains("自动再试"))
        XCTAssertTrue(statusElement("probe-status-wait-trace").label.contains("requestStarts=2"))
        XCTAssertTrue(statusElement("probe-status-wait-trace").label.contains("cancelRequests=0"))
        capture("status-recovery-without-another-tap")
    }
    func testClosingStatusFailureRevokesRecoveryAndDoesNotRestoreOldError() {
        launchStatusRecovery()
        tap("record-status-close")
        tap("record-settings-watch-status")
        XCTAssertEqual(statusElement("record-status-message").label, "手表状态待更新")
        let noRetry = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", "requestStarts=2"),
            object: statusElement("probe-status-wait-trace"))
        noRetry.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [noRetry], timeout: 11), .completed)
        XCTAssertTrue(statusElement("probe-status-wait-trace").label.contains("cancelRequests=1"))
        XCTAssertEqual(statusElement("record-status-message").label, "手表状态待更新")
        capture("status-closed-intent-stays-cancelled")
    }
    func testHomeShowsActiveRecordingButKeepsPausedStatusInSettings() {
        launch()
        XCTAssertEqual(statusElement("record-status").label, "录音中")
        app.terminate()
        app.launchEnvironment = ["PROBE_CONTROLS":"0", "PROBE_RECORD_STATE":"paused"]
        app.launch()
        XCTAssertTrue(button("recording-calendar").waitForExistence(timeout: 5))
        XCTAssertFalse(statusElement("record-status").exists)
        tap("record-settings")
        tap("record-settings-watch-status")
        XCTAssertEqual(statusElement("record-status-message").label, "已暂停")
    }
    func testSamePageSelectionPreservesGrantsAndDirectory() {
        launch()
        app.tabBars.buttons["同步"].tap()
        XCTAssertTrue(button("sync-step-3").waitForExistence(timeout: 5))
        let calls = app.staticTexts["probe-cloud-calls"].label
        tap("sync-step-1")
        XCTAssertFalse(button("sync-destination-baidu").isEnabled)
        XCTAssertFalse(button("sync-destination-weiyun").isEnabled)
        capture("97-service-grid")
        tap("sync-destination-google")
        XCTAssertEqual(button("sync-step-2").value as? String, "已展开")
        XCTAssertTrue(app.staticTexts["google-drive-current-state"].exists)
        tap("sync-step-2")
        XCTAssertTrue(app.otherElements["sync-directory"].exists)
        tap("sync-step-3")
        let guide = app.staticTexts["agent-connection-guide"]
        XCTAssertEqual(guide.label, "Google Drive 文件夹 · Record for Agent")
        tap("agent-statement-copy")
        XCTAssertEqual(button("agent-statement-copy").label, "已复制")
        tap("sync-view-directory")
        tap("sync-step-1");XCTAssertEqual(button("sync-step-1").value as? String, "已展开");tap("sync-destination-iCloud")
        XCTAssertTrue(app.staticTexts["icloud-drive-current-state"].exists)
        XCTAssertEqual(app.staticTexts["probe-cloud-calls"].label, calls)
        capture("97-icloud-inline")
        tap("sync-step-3")
        XCTAssertTrue(guide.label.contains("iCloud Drive 文件夹"))
        XCTAssertFalse(guide.label.contains("Google Drive"))
        tap("agent-statement-copy")
        XCTAssertEqual(button("agent-statement-copy").label, "已复制")
    }
    func testSyncStatusPrecedesDatesAndLastDateClearsTabBar() {
        app.launchEnvironment = ["PROBE_CONTROLS": "0", "PROBE_RECORD_STATE": "long-directory"]
        app.launch()
        let syncTab = app.tabBars.buttons["同步"]
        syncTab.tap()

        let status = app.staticTexts["sync-directory-status"]
        let heading = app.staticTexts["按日期查看"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, "系统已确认上传")
        XCTAssertLessThan(status.frame.maxY, heading.frame.minY)
        let dates = app.buttons.matching(identifier: "sync-directory-date")
        XCTAssertEqual(dates.count, 12)
        XCTAssertTrue(dates.firstMatch.label.contains("已收到的音频已上传至 iCloud Drive"))
        let lastDate = dates.element(boundBy: 11)
        for _ in 0..<6 {
            if lastDate.isHittable && lastDate.frame.maxY < syncTab.frame.minY { break }
            app.swipeUp()
        }
        XCTAssertTrue(lastDate.isHittable)
        XCTAssertLessThan(lastDate.frame.maxY, syncTab.frame.minY)
        capture("sync-last-date-above-tab-bar")
        lastDate.tap()
        XCTAssertTrue(app.buttons["关闭"].waitForExistence(timeout: 5))
        XCTAssertTrue(button("sync-recording-row").exists)
    }
    func testInlineRecoveryRequiresConfirmationAndStaysPaused() {
        launch("directory-recovery")
        app.tabBars.buttons["同步"].tap()
        tap("icloud-drive-directory-recovery-review")
        let confirm = app.alerts.buttons["icloud-drive-directory-recovery-confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 4));confirm.tap()
        XCTAssertTrue(app.staticTexts["icloud-drive-sync-state"].label.contains("关闭"))
        XCTAssertEqual(button("sync-step-2").value as? String, "已展开")
        tap("sync-step-3")
        XCTAssertTrue(app.staticTexts["agent-connection-guide"].label.contains("Synthetic iCloud Folder"))
        capture("97-paused-recovery-guide")
    }
    func testSwitchFromPausedCloudToEnabledCloudKeepsConfigurationVisible() {
        launch("directory-recovery")
        app.tabBars.buttons["同步"].tap()
        let calls = app.staticTexts["probe-cloud-calls"].label
        tap("sync-step-1")
        tap("sync-destination-google")
        XCTAssertEqual(button("sync-step-2").value as? String, "已展开")
        XCTAssertNotEqual(button("sync-step-3").value as? String, "已展开")
        XCTAssertTrue(app.staticTexts["google-drive-current-state"].exists)
        XCTAssertEqual(app.staticTexts["probe-cloud-calls"].label, calls)
        capture("101-switch-paused-to-enabled")
    }
    func testCalendarSelectionThenPeriodsAndTruthfulLegend() {
        launch()
        tap("record-calendar-legend")
        XCTAssertTrue(app.alerts.staticTexts.element(matching: NSPredicate(format:"label CONTAINS %@", "不代表手表没有录音")).exists)
        app.alerts.buttons["知道了"].tap()
        tap("recording-calendar")
        XCTAssertTrue(app.buttons["完成"].waitForExistence(timeout: 4))
        app.buttons["完成"].tap()
        tap("record-periods")
        XCTAssertTrue(button("record-period-row").exists)
        XCTAssertTrue(app.staticTexts["record-calendar-selection"].label.contains("手机已收到"))
        capture("97-calendar-periods")
    }
    func testPeriodDetailsWithoutReceiverDoNotClaimAgentDelivery() {
        launch(receivers: "0")
        tap("record-periods")
        tap("record-period-row")
        XCTAssertTrue(app.staticTexts["手机已保存"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.staticTexts["Agent 已收到"].exists)
        XCTAssertFalse(app.staticTexts["接收端已确认"].exists)
        XCTAssertTrue(app.buttons["同步设置"].exists)
        capture("101-period-details")
        app.buttons["完成"].tap()
    }
    func testYesterdayRecordingOpensBothCloudStatesInOneTap() {
        app.launchEnvironment = ["PROBE_CONTROLS": "0", "PROBE_RECORD_STATE": "yesterday-only",
                                 "PROBE_PROVIDER_SCENARIO": "waiting-retry"]
        app.launch()
        XCTAssertTrue(button("record-latest").isHittable)
        XCTAssertTrue(button("record-latest").label.contains("23 秒"))
        tap("record-latest")
        XCTAssertTrue(statusElement("record-period-computer").label.contains("电脑接收端"))
        XCTAssertTrue(statusElement("record-period-icloud").label.contains("手机已收到的音频已上传"))
        XCTAssertTrue(statusElement("record-period-google").label.contains("等待重试"))
        capture("recent-recording-cloud-status")
        tap("同步设置")
        tap("sync-step-1")
        tap("sync-destination-google")
        XCTAssertTrue(app.staticTexts["同步说明"].exists)
        let estimate = app.staticTexts["google-drive-next-attempt-time"]
        XCTAssertTrue(estimate.label.contains("预计重试"))
        XCTAssertTrue(estimate.label.contains("后台执行由系统安排"))
    }

    func testDirectoryGroupsRecordingsAndDistinguishesUploadsFromWholeRecordingCompleteness() {
        app.launchEnvironment = ["PROBE_CONTROLS": "0", "PROBE_RECORD_STATE": "partial-recording-sync"]
        app.launch()
        app.tabBars.buttons["同步"].tap()
        tap("sync-directory-date")
        let recordings = app.buttons.matching(identifier: "sync-recording-row")
        XCTAssertTrue(recordings.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(recordings.count, 2)
        XCTAssertTrue(recordings.element(boundBy: 0).label.contains("已收到的音频已上传至 iCloud Drive"))
        let partial = recordings.element(boundBy: 1)
        XCTAssertTrue(partial.label.contains("同步中"))
        XCTAssertTrue(partial.label.contains("手机已收到约 2 分钟"))
        capture("icloud-recording-sync-directory")
        partial.tap()
        XCTAssertTrue(app.staticTexts["手机已保存"].waitForExistence(timeout: 5))
        XCTAssertTrue(statusElement("record-period-icloud").label.contains("部分音频已上传"))
        XCTAssertTrue(statusElement("record-period-google").exists)
    }

    func testPendingICloudDirectoryOffersReadOnlyCheckWhileSavingIsPaused() {
        launch("paused")
        app.tabBars.buttons["同步"].tap()
        tap("sync-step-2")
        XCTAssertEqual(button("sync-step-2").value as? String, "已折叠")
        let pending = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "4 份已写入文件待云端确认")).firstMatch
        XCTAssertTrue(pending.isHittable)
        XCTAssertTrue(pending.label.contains("持续保存已暂停"))
        let check = button("icloud-drive-check-cloud-readonly")
        XCTAssertTrue(check.isHittable)
        let calls = app.staticTexts["probe-cloud-calls"]
        let before = calls.label
        XCTAssertTrue(before.contains("readOnly=0"))
        check.tap()
        XCTAssertEqual(calls.label, before.replacingOccurrences(of: "readOnly=0", with: "readOnly=1"))
        XCTAssertTrue(pending.label.contains("持续保存已暂停"))
        capture("icloud-directory-read-only-check")
    }
    func testTwoRecordingsInOneWatchSessionHaveSeparatePeriodRows() {
        app.launchEnvironment = ["PROBE_CONTROLS": "0", "PROBE_RECORD_STATE": "two-recording-groups"]
        app.launch()
        tap("record-periods")
        let rows = app.buttons.matching(identifier: "record-period-row")
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.element(boundBy: 0).label.contains("5 分 0 秒"))
        XCTAssertTrue(rows.element(boundBy: 1).label.contains("2 分 0 秒"))
        tap("record-period-row")
        XCTAssertTrue(app.staticTexts["开始录制"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.staticTexts["部分片段尚未传到手机。"].exists)
    }
    func testComputerPairingIsInlineSecureAndRequiresExplicitConsent() {
        launch(draft: true)
        app.tabBars.buttons["同步"].tap()
        tap("sync-step-1");tap("sync-destination-computer")
        let connect = button("pairing-add")
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        XCTAssertFalse(connect.isEnabled)
        XCTAssertFalse(app.debugDescription.contains("SYNTHETIC-NON-AUTHENTICATING-TEST-TOKEN"))
        let payload = app.secureTextFields["pairing-payload"]
        XCTAssertTrue(payload.exists)
        let consent = app.switches["pairing-consent"]
        for _ in 0..<10 {
            if consent.isHittable { break }
            if consent.frame.midY < app.frame.midY { app.swipeDown(velocity: .slow) } else { app.swipeUp(velocity: .slow) }
        }
        XCTAssertTrue(consent.isHittable)
        consent.coordinate(withNormalizedOffset: CGVector(dx:0.9, dy:0.5)).tap()
        XCTAssertTrue(connect.isEnabled)
        tap("pairing-add")
        XCTAssertEqual(button("sync-step-3").value as? String, "已展开")
        XCTAssertEqual(app.staticTexts["agent-connection-guide"].label, "已配对的电脑接收端")
        capture("97-inline-computer-consent")
    }
    func testDarkLargeTypeCanReachStepsAndDisabledServices() {
        launch(large: true, dark: true)
        app.tabBars.buttons["同步"].tap()
        tap("sync-step-1")
        XCTAssertTrue(button("sync-destination-google").exists)
        XCTAssertFalse(button("sync-destination-baidu").isEnabled)
        tap("sync-destination-google")
        tap("sync-step-3")
        tap("agent-statement-copy")
        capture("97-dark-large-guide")
    }
    private func checkInlineKeyboard(large: Bool) {
        for id in ["pairing-name", "pairing-payload"] {
            launch(large: large, dark: large)
            app.tabBars.buttons["同步"].tap()
            tap("sync-step-1");tap("sync-destination-computer")
            let field = id == "pairing-payload" ? app.secureTextFields[id].firstMatch : app.textFields[id].firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            for _ in 0..<12 {
                if field.isHittable { break }
                if field.frame.midY < app.frame.midY { app.swipeDown(velocity: .slow) } else { app.swipeUp(velocity: .slow) }
            }
            XCTAssertTrue(field.isHittable);field.tap()
            let keyboard = app.keyboards.firstMatch
            XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
            let visible = NSPredicate { _, _ in
                let f = field.frame, k = keyboard.frame
                return k.height > 100 && f.minY >= self.app.navigationBars.firstMatch.frame.maxY && f.maxY + 4 <= k.minY
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: visible, object: field)], timeout: 5), .completed)
            field.typeText(id == "pairing-name" ? "Synthetic Name" : "SYNTHETIC-KEYBOARD-INPUT")
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: visible, object: field)], timeout: 5), .completed)
            XCTAssertFalse(app.debugDescription.contains("SYNTHETIC-KEYBOARD-INPUT"))
            capture("97-\(id)-keyboard-\(large ? "large" : "normal")")
            if id == "pairing-name" { app.terminate() }
        }
    }
    func testInlinePairingFieldsStayAboveKeyboard() { checkInlineKeyboard(large: false) }
    func testInlinePairingFieldsStayAboveKeyboardAtMaximumType() { checkInlineKeyboard(large: true) }

}
