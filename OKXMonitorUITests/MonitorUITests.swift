import XCTest

@MainActor
final class MonitorUITests: XCTestCase {
    func testDemoTabsAndCredentialForm() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["先看示範畫面"].waitForExistence(timeout: 15))
        app.buttons["先看示範畫面"].tap()
        XCTAssertTrue(app.staticTexts["總資產（USD）"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["$41,122.72"].exists)
        XCTAssertTrue(app.staticTexts["賺幣"].exists)
        capture("01-balances", app: app)
        app.buttons["永續合約"].tap()
        XCTAssertTrue(app.staticTexts["BTC-USDT-SWAP"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["0.1 BTC"].exists)
        capture("02-perpetuals", app: app)
        app.buttons["雙幣贏"].tap()
        XCTAssertTrue(app.staticTexts["進行中"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["0.35%"].exists)
        XCTAssertTrue(app.staticTexts["18.42%"].exists)
        XCTAssertTrue(app.staticTexts["共 1 筆 · 1 頁 · 已結束 0 筆"].exists)
        capture("03-dual-investment", app: app)
        app.descendants(matching: .any).matching(identifier: "詳細資料").firstMatch.tap()
        XCTAssertTrue(app.staticTexts["申購時間"].waitForExistence(timeout: 5))
        app.buttons["期權"].tap()
        XCTAssertTrue(app.staticTexts["BTC-USD-261225-90000-C"].waitForExistence(timeout: 5))
        capture("04-options", app: app)
        app.buttons["API 設定"].firstMatch.tap()
        XCTAssertTrue(app.secureTextFields["apiKey"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.secureTextFields["secretKey"].exists)
        XCTAssertTrue(app.secureTextFields["passphrase"].exists)
        capture("05-settings-fields", app: app)
        app.swipeUp()
        XCTAssertTrue(app.buttons["儲存並讀取帳戶"].exists)
        XCTAssertFalse(app.buttons["儲存並讀取帳戶"].isEnabled)
        capture("06-settings-actions", app: app)
        app.buttons["離開示範模式"].tap()
        XCTAssertTrue(app.buttons["先看示範畫面"].waitForExistence(timeout: 5))
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
