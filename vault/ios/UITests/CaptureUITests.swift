import CryptoKit
import XCTest

final class CaptureUITests: XCTestCase {
    func testPairSelectAndRetainPublicKey() throws {
        let app = XCUIApplication()
        app.launch()
        if app.buttons["更换"].exists { app.buttons["更换"].tap() }
        let field = app.textFields["pairCode"]
        XCTAssertTrue(field.waitForExistence(timeout: 6))
        let publicBytes = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
        let code = "CV1." + publicBytes.base64EncodedString()
        let expected = SHA256.hash(data: publicBytes).prefix(8).map { String(format: "%02x", $0) }.joined()
        field.tap()
        field.typeText(code)
        app.buttons["保存配对"].tap()
        XCTAssertEqual(app.staticTexts["fingerprint"].label, expected)
        XCTAssertTrue(app.buttons["从文件选取"].exists)
        XCTAssertTrue(app.buttons["扫描证件"].exists)
        XCTAssertFalse(app.buttons["加密并存入文件"].isEnabled)
        app.buttons["category"].tap()
        app.buttons["工资证明"].tap()
        XCTAssertEqual(app.textFields["documentLabel"].value as? String, "工资证明")
        app.terminate()
        app.launch()
        XCTAssertEqual(app.staticTexts["fingerprint"].label, expected)
    }

    func testFilesRoundTrip() throws {
        guard let pair = ProcessInfo.processInfo.environment["CONTEXT_VAULT_TEST_PAIR"] else {
            throw XCTSkip("Run the Files round trip with Tests/verify_files.py on a dedicated simulator.")
        }
        let app = XCUIApplication()
        app.launch()
        if app.buttons["更换"].exists { app.buttons["更换"].tap() }
        let field = app.textFields["pairCode"]
        field.tap()
        field.typeText(pair)
        app.buttons["保存配对"].tap()
        app.buttons["从文件选取"].tap()
        let browse = app.buttons["Browse"]
        if browse.waitForExistence(timeout: 3) { browse.tap() }
        if browse.exists && !app.staticTexts["On My iPhone"].exists { browse.tap() }
        let location = app.staticTexts["On My iPhone"]
        if location.waitForExistence(timeout: 3) { location.tap() }
        let name = ProcessInfo.processInfo.environment["CONTEXT_VAULT_TEST_FIXTURE"] ?? "ContextVaultSynthetic"
        let fixture = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        XCTAssertTrue(fixture.waitForExistence(timeout: 8), app.debugDescription)
        fixture.tap()
        let export = app.buttons["加密并存入文件"]
        expectation(for: NSPredicate(format: "isEnabled == true"), evaluatedWith: export)
        waitForExpectations(timeout: 6)
        export.tap()
        let save = app.buttons["Save"]
        XCTAssertTrue(save.waitForExistence(timeout: 6), app.debugDescription)
        let cancel = app.buttons["Cancel"]
        if cancel.exists {
            cancel.tap()
        } else {
            let navigation = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"]
            let start = navigation.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            let bottom = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.93))
            start.press(forDuration: 0.1, thenDragTo: bottom)
        }
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: save)
        waitForExpectations(timeout: 6)
        XCTAssertTrue(export.isEnabled)
        export.tap()
        XCTAssertTrue(save.waitForExistence(timeout: 6), app.debugDescription)
        save.tap()
        let notice = app.staticTexts["notice"]
        XCTAssertTrue(notice.waitForExistence(timeout: 8))
        XCTAssertTrue(notice.label.contains("加密文件已保存"))
        XCTAssertFalse(export.isEnabled)
    }
}
