import XCTest

@MainActor
final class ProbeUITests: XCTestCase {
    private var app: XCUIApplication!
    private var detailDismissRegionCount = 0
    private let providers = ["google-drive", "icloud-drive"]
    private let googleZero = "resume=0;continue=0;pause=0;enable=0;revoke=0;connect=0"
    private let cloudZero = "resume=0;toggle=0;authorize=0;disconnect=0;connect=0"
    private let enabledGrant = "connected=true;enabled=true;scope=existingAndFuture"
    private let pausedGrant = "connected=true;enabled=false;scope=existingAndFuture"

    func testPausedReadOnlyCloudStatusDoesNotResumeOrChangeGrant() {
        launch("paused")
        open("icloud-drive")
        let check = showButton("icloud-drive-check-cloud-readonly")
        XCTAssertTrue(check.isEnabled)
        check.tap()
        XCTAssertTrue(app.staticTexts["icloud-drive-latest-result"].label.contains("只读检查完成"))
        close("icloud-drive")
        XCTAssertEqual(app.staticTexts["probe-icloud-readonly"].label, "readonly=1")
        assertCalls(google: googleZero, cloud: cloudZero)
        XCTAssertEqual(app.staticTexts["probe-icloud-grant"].label, pausedGrant)
    }

    func testDirectoryRecoveryRequiresExplicitConfirmationAndRemainsPaused() {
        launch("directory-recovery")
        open("icloud-drive")
        presentDialog("icloud-drive-directory-recovery-review")
        let confirm = app.alerts.buttons["icloud-drive-directory-recovery-confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3) && confirm.isHittable)
        XCTAssertTrue(app.alerts.buttons["icloud-drive-directory-recovery-cancel"].firstMatch.isHittable)
        capture("synthetic-directory-recovery-confirmation")
        confirm.tap()
        close("icloud-drive")
        XCTAssertEqual(app.staticTexts["probe-icloud-recovery"].label, "pending=false;confirm=1;cancel=0")
        assertCalls(google: googleZero, cloud: cloudZero)
        XCTAssertEqual(app.staticTexts["probe-icloud-grant"].label, pausedGrant)
    }

    func testDirectoryRecoveryCancelDoesNotEnableOrChangeGrant() {
        launch("directory-recovery")
        open("icloud-drive")
        presentDialog("icloud-drive-directory-recovery-review")
        let cancel = app.alerts.buttons["icloud-drive-directory-recovery-cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 3) && cancel.isHittable)
        cancel.tap()
        close("icloud-drive")
        XCTAssertEqual(app.staticTexts["probe-icloud-recovery"].label, "pending=false;confirm=0;cancel=1")
        assertCalls(google: googleZero, cloud: cloudZero)
        XCTAssertEqual(app.staticTexts["probe-icloud-grant"].label, pausedGrant)
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        if app.state != .notRunning {
            capture("synthetic-final")
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "synthetic-final-accessibility-tree"
            tree.lifetime = .keepAlways
            add(tree)
            app.terminate()
        }
    }

    private func launch(_ scenario: String) {
        app.launchArguments = ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN", "--probe-scenario", scenario]
        app.launch()
        XCTAssertTrue(app.staticTexts["probe-google-grant"].waitForExistence(timeout: 10))
        assertCalls(google: googleZero, cloud: cloudZero)
        capture("synthetic-\(scenario)-home")
    }

    private func capture(_ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
    }

    private func showButton(_ identifier: String) -> XCUIElement {
        let button = app.buttons[identifier].firstMatch
        for _ in 0..<6 {
            if button.exists && button.isHittable { return button }
            app.swipeUp(velocity: .slow)
        }
        XCTFail("Production button is not hittable: \(identifier)")
        return button
    }

    private func open(_ provider: String) {
        let row = showButton(provider + "-row")
        let title = provider == "google-drive" ? "Google Drive" : "iCloud Drive"
        let label = row.staticTexts[title].firstMatch
        XCTAssertTrue(label.exists && label.isHittable, "Connection title is not hittable")
        // Use the visible title within the real Button instead of its broad
        // accessibility wrapper's default center. This is a single real tap.
        label.tap()
        XCTAssertTrue(app.buttons[provider + "-close"].firstMatch.waitForExistence(timeout: 5))
        capture("synthetic-\(provider)-detail")
    }

    private func close(_ provider: String) {
        let button = app.buttons[provider + "-close"].firstMatch
        for _ in 0..<6 {
            if button.exists && button.isHittable { break }
            app.scrollViews.firstMatch.swipeDown(velocity: .slow)
        }
        XCTAssertTrue(button.exists && button.isHittable, "Detail close button is not hittable")
        button.tap()
        XCTAssertTrue(app.staticTexts["probe-google-grant"].waitForExistence(timeout: 5))
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
            object: app.buttons[provider + "-close"].firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
    }

    private func assertCalls(google: String, cloud: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(app.staticTexts["probe-google-calls"].label, google, file: file, line: line)
        XCTAssertEqual(app.staticTexts["probe-icloud-calls"].label, cloud, file: file, line: line)
    }

    private func assertGrants(_ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        for provider in ["google", "icloud"] {
            XCTAssertEqual(app.staticTexts["probe-\(provider)-grant"].label, expected, file: file, line: line)
        }
    }

    private func toggle(_ provider: String) -> XCUIElement {
        let element = app.switches[provider + "-toggle"].firstMatch
        for _ in 0..<6 {
            if element.exists && element.isHittable { return element }
            app.swipeUp(velocity: .slow)
        }
        XCTFail("Production toggle is not hittable: \(provider)")
        return element
    }

    private func assertNoDisconnectConfirmation(_ provider: String, file: StaticString = #filePath, line: UInt = #line) {
        let confirm = app.buttons[provider + "-disconnect-confirm"].firstMatch
        XCTAssertFalse(confirm.waitForExistence(timeout: 1),
            "Check action unexpectedly opened disconnect confirmation", file: file, line: line)
    }

    private func presentDialog(_ identifier: String) {
        let button = showButton(identifier)
        // Scrolling to the entry can expand medium -> large, changing the
        // underlying detail's system layers. Measure only after that scrolling.
        detailDismissRegionCount = app.otherElements.matching(identifier: "PopoverDismissRegion").count
        button.tap()
    }

    private func cancelDialog(actionID: String, cancelID: String) {
        let action = app.buttons[actionID].firstMatch
        let dismissal = app.otherElements["PopoverDismissRegion"].firstMatch
        // Compact system popovers may expose no cancel action. Dismiss outside
        // the smallest sheet containing this dialog action, never destructively.
        let candidates = app.sheets.containing(.button, identifier: actionID).allElementsBoundByIndex
        let sheet = candidates.min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        let cancel = app.buttons[cancelID].firstMatch
        if cancel.waitForExistence(timeout: 1), cancel.isHittable {
            cancel.tap()
        } else {
            XCTAssertTrue(dismissal.waitForExistence(timeout: 3))
            guard let sheet else { XCTFail("System dialog sheet missing"); return }
            let outside = CGPoint(x: app.frame.minX + 1, y: sheet.frame.midY)
            XCTAssertFalse(sheet.frame.contains(outside))
            app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: outside.x - app.frame.minX, dy: outside.y - app.frame.minY)).tap()
        }
        var layers = [action]
        if let sheet { layers.append(sheet) }
        var waits = layers.map { XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: $0) }
        // The underlying detail sheet has its own persistent dismissal regions.
        // Only the confirmation's additional layer must leave, restoring the
        // count observed before the confirmation was presented.
        let baseline = detailDismissRegionCount
        waits.append(XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            app.otherElements.matching(identifier: "PopoverDismissRegion").count == baseline
        }, object: app))
        let result = XCTWaiter.wait(for: waits, timeout: 5)
        let state = XCTAttachment(string: "action=\(action.exists);dismissRegionCount=\(app.otherElements.matching(identifier: "PopoverDismissRegion").count);baseline=\(baseline);sheet=\(sheet?.exists ?? false)")
        state.name = "synthetic-after-cancel-system-layers"
        state.lifetime = .keepAlways
        add(state)
        XCTAssertEqual(result, .completed)
    }

    private func cancelVisibleRecoveryAlert(_ provider: String, actionID: String, cancelID: String) {
        let alert = app.alerts.containing(.button, identifier: actionID).firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3), "Recovery must use the standard native alert")
        let action = alert.buttons[actionID].firstMatch
        let cancel = alert.buttons[cancelID].firstMatch
        XCTAssertTrue(action.exists && action.isHittable)
        XCTAssertTrue(cancel.exists && cancel.isHittable,
            "Cancel must be visible; an outside-popover tap is not an acceptable substitute")
        capture("synthetic-\(provider)-recovery-alert-visible-cancel")
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "synthetic-\(provider)-recovery-alert-accessibility-tree"
        tree.lifetime = .keepAlways
        add(tree)
        cancel.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: alert)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
        XCTAssertFalse(app.buttons[actionID].firstMatch.exists)
        // A folder picker would present another modal and obscure this detail's
        // controls. Cancellation must restore the existing detail, without that
        // presentation or any library connect/authorize call.
        XCTAssertTrue(app.buttons[provider + "-close"].firstMatch.isHittable)
        XCTAssertEqual(app.otherElements.matching(identifier: "PopoverDismissRegion").count, detailDismissRegionCount)
        capture("synthetic-\(provider)-recovery-alert-cancelled-no-picker")
    }

    private func enableToggle(_ provider: String) {
        let row = toggle(provider)
        let control = row.switches.firstMatch
        XCTAssertTrue(control.exists && control.isHittable, "Native switch control is not hittable")
        XCTAssertEqual(row.value as? String, "0")
        // SwiftUI exposes a wide labeled Switch wrapper and a narrower actual
        // switch. Tap the actual control exactly once, not the wrapper's label.
        control.tap()
        // Merely touching an off switch must not start uploads. A second,
        // explicit confirmation names the original account/folder and scope.
        XCTAssertEqual(row.value as? String, "0")
        let confirm = app.buttons[provider + "-resume-confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        XCTAssertEqual(row.value as? String, "1")
    }

    private func assertNoRecordingCounts(file: StaticString = #filePath, line: UInt = #line) {
        let count = try! NSRegularExpression(pattern: "[0-9]+\\s*(段|个|/)|原录音|待确认")
        let exposed = app.staticTexts.allElementsBoundByIndex.filter { !$0.identifier.hasPrefix("probe-") && $0.isHittable }
        for element in exposed {
            let text = element.label
            XCTAssertNil(count.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                "Completed UI exposed a recording/file count: \(text)", file: file, line: line)
        }
    }

    func testPausedRowsOnlyOpenDetailsWithoutResuming() {
        launch("paused")
        assertGrants(pausedGrant)
        for provider in providers {
            open(provider)
            XCTAssertEqual(toggle(provider).value as? String, "0")
            close(provider)
            assertCalls(google: googleZero, cloud: cloudZero)
            assertGrants(pausedGrant)
        }
    }

    func testExplicitToggleContinuesOnlyTheExistingScope() {
        launch("paused")
        open("google-drive")
        enableToggle("google-drive")
        close("google-drive")
        XCTAssertEqual(app.staticTexts["probe-google-grant"].label, enabledGrant)
        assertCalls(google: "resume=0;continue=1;pause=0;enable=0;revoke=0;connect=0", cloud: cloudZero)
        open("icloud-drive")
        enableToggle("icloud-drive")
        close("icloud-drive")
        assertGrants(enabledGrant)
        assertCalls(google: "resume=0;continue=1;pause=0;enable=0;revoke=0;connect=0",
            cloud: "resume=0;toggle=1;authorize=0;disconnect=0;connect=0")
    }

    func testCompletedRowsAndDetailsHideRecordingCounts() {
        launch("complete")
        assertNoRecordingCounts()
        for provider in providers {
            open(provider)
            XCTAssertTrue(app.staticTexts[provider + "-latest-result"].exists)
            assertNoRecordingCounts()
            capture("synthetic-\(provider)-complete-no-counts")
            close(provider)
        }
        assertCalls(google: googleZero, cloud: cloudZero)
    }

    func testUnfinishedWorkShowsNoticeAndStatusExplanation() {
        launch("pending")
        for provider in providers {
            open(provider)
            XCTAssertTrue(app.staticTexts[provider + "-latest-result"].firstMatch.exists)
            showButton(provider + "-status").tap()
            let alert = app.alerts.firstMatch
            XCTAssertTrue(alert.waitForExistence(timeout: 3))
            capture("synthetic-\(provider)-status-explanation")
            alert.buttons.firstMatch.tap()
            close(provider)
        }
        assertCalls(google: googleZero, cloud: cloudZero)
    }

    func testCheckRunsOnlyResumeWithoutOpeningDisconnect() {
        launch("pending")
        open("icloud-drive")
        showButton("icloud-drive-check").tap()
        assertNoDisconnectConfirmation("icloud-drive")
        close("icloud-drive")
        assertGrants(enabledGrant)
        assertCalls(google: googleZero, cloud: "resume=1;toggle=0;authorize=0;disconnect=0;connect=0")
    }

    func testDisconnectCancellationPreservesScopeAndEnabledState() {
        launch("pending")
        for provider in providers {
            open(provider)
            presentDialog(provider + "-disconnect")
            XCTAssertTrue(app.buttons[provider + "-disconnect-confirm"].firstMatch.waitForExistence(timeout: 3))
            capture("synthetic-\(provider)-disconnect-confirmation")
            cancelDialog(actionID: provider + "-disconnect-confirm", cancelID: provider + "-disconnect-cancel")
            close(provider)
            assertCalls(google: googleZero, cloud: cloudZero)
            assertGrants(enabledGrant)
        }
        // Exactly one subsequent tap; no retry can conceal a dismissed overlay.
        open("icloud-drive")
        showButton("icloud-drive-check").tap()
        assertNoDisconnectConfirmation("icloud-drive")
        close("icloud-drive")
        assertCalls(google: googleZero, cloud: "resume=1;toggle=0;authorize=0;disconnect=0;connect=0")
        assertGrants(enabledGrant)
    }

    func testGoogleScopeNeedsChoiceAndThenExplicitEnable() {
        launch("unscoped")
        open("google-drive")
        let enable = showButton("google-drive-enable")
        XCTAssertFalse(enable.isEnabled)
        showButton("google-drive-scope").tap()
        let futureID = app.buttons["google-drive-scope-future"].firstMatch
        let futureLabel = app.buttons["仅新录音"].firstMatch
        let future = futureID.waitForExistence(timeout: 2) ? futureID : futureLabel
        XCTAssertTrue(future.waitForExistence(timeout: 3))
        future.tap()
        close("google-drive")
        XCTAssertEqual(app.staticTexts["probe-google-grant"].label, "connected=true;enabled=false;scope=none")
        assertCalls(google: googleZero, cloud: cloudZero)
        open("google-drive")
        // Detail selection is intentionally ephemeral: choose again explicitly.
        showButton("google-drive-scope").tap()
        let option = futureID.waitForExistence(timeout: 2) ? futureID : futureLabel
        option.tap()
        XCTAssertTrue(showButton("google-drive-enable").isEnabled)
        showButton("google-drive-enable").tap()
        close("google-drive")
        XCTAssertEqual(app.staticTexts["probe-google-grant"].label, "connected=true;enabled=true;scope=futureOnly")
        assertCalls(google: "resume=0;continue=0;pause=0;enable=1;revoke=0;connect=0", cloud: cloudZero)
    }

    func testICloudScopeCancellationThenExplicitChoice() {
        launch("unscoped")
        open("icloud-drive")
        presentDialog("icloud-drive-choose-scope")
        XCTAssertTrue(app.buttons["icloud-drive-scope-future"].firstMatch.waitForExistence(timeout: 3))
        cancelDialog(actionID: "icloud-drive-scope-future", cancelID: "icloud-drive-scope-cancel")
        close("icloud-drive")
        XCTAssertEqual(app.staticTexts["probe-icloud-grant"].label, "connected=true;enabled=false;scope=none")
        assertCalls(google: googleZero, cloud: cloudZero)
        open("icloud-drive")
        presentDialog("icloud-drive-choose-scope")
        let all = app.buttons["icloud-drive-scope-all"].firstMatch
        XCTAssertTrue(all.waitForExistence(timeout: 3))
        all.tap()
        close("icloud-drive")
        XCTAssertEqual(app.staticTexts["probe-icloud-grant"].label, enabledGrant)
        assertCalls(google: googleZero, cloud: "resume=0;toggle=0;authorize=1;disconnect=0;connect=0")
    }

    func testOnlyConfirmedDisconnectChangesGrant() {
        launch("pending")
        open("icloud-drive")
        presentDialog("icloud-drive-disconnect")
        let confirm = app.buttons["icloud-drive-disconnect-confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        close("icloud-drive")
        XCTAssertEqual(app.staticTexts["probe-icloud-grant"].label, "connected=false;enabled=false;scope=existingAndFuture")
        assertCalls(google: googleZero, cloud: "resume=0;toggle=0;authorize=0;disconnect=1;connect=0")
    }

    func testResumeCancellationLeavesBothExistingGrantsPaused() {
        launch("paused")
        for provider in providers {
            open(provider)
            let row = toggle(provider)
            detailDismissRegionCount = app.otherElements.matching(identifier: "PopoverDismissRegion").count
            row.switches.firstMatch.tap()
            let confirm = app.buttons[provider + "-resume-confirm"].firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 3))
            XCTAssertEqual(row.value as? String, "0")
            // Test cancellation of the real production alert without invoking
            // either library's upload/resume method.
            cancelDialog(actionID: provider + "-resume-confirm", cancelID: provider + "-resume-cancel")
            close(provider)
            assertCalls(google: googleZero, cloud: cloudZero)
            assertGrants(pausedGrant)
        }
    }

    func testRevocationPendingMeansLocallyStoppedAndExplainsBusyAction() {
        launch("revoking-busy")
        open("google-drive")
        let sync = app.descendants(matching: .any).matching(identifier: "google-drive-sync-state").firstMatch
        XCTAssertTrue(sync.exists)
        XCTAssertTrue(sync.label.contains("停止") || app.staticTexts["本机已停止"].exists)
        let retry = showButton("google-drive-retry-revoke")
        XCTAssertFalse(retry.isEnabled)
        XCTAssertTrue(app.staticTexts["google-drive-revoke-disabled-reason"].firstMatch.exists)
        close("google-drive")
        assertCalls(google: googleZero, cloud: cloudZero)
        XCTAssertEqual(app.staticTexts["probe-google-grant"].label,
            "connected=false;enabled=false;scope=existingAndFuture")
    }

    func testFolderMismatchIsNotConnectedAndReselectionCancellationHasNoEffect() {
        launch("folder-mismatch")
        open("icloud-drive")
        let authorization = app.staticTexts["icloud-drive-authorization-state"].firstMatch
        XCTAssertTrue(authorization.exists)
        XCTAssertFalse(authorization.label.contains("已连接"))
        let check = showButton("icloud-drive-check")
        XCTAssertFalse(check.isEnabled)
        XCTAssertTrue(app.staticTexts["icloud-drive-check-disabled-reason"].firstMatch.exists)
        presentDialog("icloud-drive-reconnect")
        let confirm = app.buttons["icloud-drive-reselect-confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        cancelDialog(actionID: "icloud-drive-reselect-confirm", cancelID: "icloud-drive-reselect-cancel")
        close("icloud-drive")
        assertCalls(google: googleZero, cloud: cloudZero)
        XCTAssertEqual(app.staticTexts["probe-icloud-grant"].label, pausedGrant)
    }


    func testGoogleReconnectAlertCancellationDoesNotStartAuthentication() {
        launch("auth-error")
        let original = "connected=false;enabled=false;scope=existingAndFuture"
        XCTAssertEqual(app.staticTexts["probe-google-grant"].label, original)
        open("google-drive")
        presentDialog("google-drive-reconnect")
        cancelVisibleRecoveryAlert("google-drive", actionID: "google-drive-reconnect-confirm",
            cancelID: "google-drive-reconnect-cancel")
        close("google-drive")
        assertCalls(google: googleZero, cloud: cloudZero)
        XCTAssertEqual(app.staticTexts["probe-google-grant"].label, original)
        XCTAssertEqual(app.staticTexts["probe-icloud-grant"].label, enabledGrant)
    }

    func testICloudReselectionAlertCancellationDoesNotOpenFolderPicker() {
        launch("folder-mismatch")
        XCTAssertEqual(app.staticTexts["probe-icloud-grant"].label, pausedGrant)
        open("icloud-drive")
        presentDialog("icloud-drive-reconnect")
        cancelVisibleRecoveryAlert("icloud-drive", actionID: "icloud-drive-reselect-confirm",
            cancelID: "icloud-drive-reselect-cancel")
        close("icloud-drive")
        assertCalls(google: googleZero, cloud: cloudZero)
        XCTAssertEqual(app.staticTexts["probe-google-grant"].label, enabledGrant)
        XCTAssertEqual(app.staticTexts["probe-icloud-grant"].label, pausedGrant)
    }

    func testLegacyRevocationHasHonestRecoveryWithoutSilentReauthorization() {
        launch("revoking-legacy")
        open("google-drive")
        XCTAssertFalse(showButton("google-drive-retry-revoke").isEnabled)
        XCTAssertTrue(app.links["google-drive-manage-permissions"].exists
            || app.buttons["google-drive-manage-permissions"].exists)
        presentDialog("google-drive-reconnect")
        XCTAssertTrue(app.buttons["google-drive-reconnect-confirm"].firstMatch.waitForExistence(timeout: 3))
        cancelDialog(actionID: "google-drive-reconnect-confirm", cancelID: "google-drive-reconnect-cancel")
        close("google-drive")
        assertCalls(google: googleZero, cloud: cloudZero)
        XCTAssertEqual(app.staticTexts["probe-google-grant"].label,
            "connected=false;enabled=false;scope=existingAndFuture")
    }

}
