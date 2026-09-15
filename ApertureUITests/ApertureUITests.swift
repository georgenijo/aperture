import XCTest

final class ApertureUITests: XCTestCase {
  private func launch(emptyLibrary: Bool = false, seededLibrary: Bool = false) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-ui-test-camera-denied"]
    if emptyLibrary {
      app.launchArguments.append("-ui-test-empty-library")
    }
    if seededLibrary {
      app.launchArguments.append("-ui-test-seeded-library")
    }
    app.launch()
    return app
  }

  func testDeniedCameraKeepsLabAndSettingsAvailable() {
    let app = launch()

    XCTAssertTrue(app.staticTexts["Camera access is off"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["camera-lab"].exists)
    XCTAssertTrue(app.buttons["camera-settings"].exists)

    app.buttons["camera-lab"].tap()
    XCTAssertTrue(app.navigationBars["The Lab"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Close Lab"].exists)
    app.buttons["Close Lab"].tap()

    app.buttons["camera-settings"].tap()
    XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["Done"].exists)
  }

  func testEmptyLabOpensAndClosesWithEmptyState() {
    let app = launch(emptyLibrary: true)

    XCTAssertTrue(app.buttons["camera-lab"].waitForExistence(timeout: 10))
    app.buttons["camera-lab"].tap()

    XCTAssertTrue(app.descendants(matching: .any)["lab-empty"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Nothing developed yet"].exists)
    app.buttons["Close Lab"].tap()
    XCTAssertTrue(app.buttons["camera-settings"].waitForExistence(timeout: 5))
  }

  func testSettingsExposeCoreControls() {
    let app = launch()

    XCTAssertTrue(app.buttons["camera-settings"].waitForExistence(timeout: 10))
    app.buttons["camera-settings"].tap()

    XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.switches["Light Leaks"].exists)
    XCTAssertTrue(app.switches["Haptics"].exists)
    XCTAssertTrue(app.switches["Preserve Original"].exists)
    XCTAssertTrue(app.switches["Auto-save Developed Media"].exists)
    XCTAssertTrue(app.staticTexts["Processing stays on this iPhone"].exists)
    XCTAssertTrue(app.staticTexts["No accounts, analytics, ads, or uploads"].exists)
  }

  func testSeededLibrarySupportsDetailShareSelectionAndDeleteConfirmation() {
    let app = launch(seededLibrary: true)
    let seedID = "A7B4A9E8-3F04-4B3A-9DD4-6EAFB4F4A198"

    XCTAssertTrue(app.buttons["camera-lab"].waitForExistence(timeout: 10))
    app.buttons["camera-lab"].tap()
    XCTAssertTrue(app.navigationBars["The Lab"].waitForExistence(timeout: 10))

    let item = app.buttons["lab-item-\(seedID)"]
    XCTAssertTrue(item.waitForExistence(timeout: 10))
    item.tap()
    XCTAssertTrue(app.buttons["detail-share"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["detail-export"].exists)
    XCTAssertTrue(app.buttons["detail-delete"].exists)

    app.navigationBars.buttons.element(boundBy: 0).tap()
    XCTAssertTrue(app.buttons["lab-select"].waitForExistence(timeout: 10))
    app.buttons["lab-select"].tap()
    XCTAssertTrue(app.buttons["lab-item-\(seedID)"].waitForExistence(timeout: 5))
    app.buttons["lab-item-\(seedID)"].tap()
    XCTAssertTrue(app.buttons["lab-export"].exists)
    XCTAssertTrue(app.buttons["lab-share"].exists)
    XCTAssertTrue(app.buttons["lab-delete"].exists)

    app.buttons["lab-delete"].tap()
    XCTAssertTrue(app.buttons["lab-delete-confirm"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Delete this media?"].exists)
  }
}
