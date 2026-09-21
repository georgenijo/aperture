import XCTest

@MainActor
final class ApertureUITests: XCTestCase {
  private func launch(
    emptyLibrary: Bool = false, seededLibrary: Bool = false,
    cameraPreview: Bool = false, accessibilityText: Bool = false
  ) -> XCUIApplication {
    let app = XCUIApplication()
    app.launchArguments = ["-ui-test-camera-denied"]
    if cameraPreview { app.launchArguments.append("-ui-test-camera-preview") }
    if accessibilityText {
      app.launchArguments += [
        "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"
      ]
    }
    if emptyLibrary {
      app.launchArguments.append("-ui-test-empty-library")
    }
    if seededLibrary {
      app.launchArguments.append("-ui-test-seeded-library")
    }
    app.launch()
    return app
  }

  private func attachScreen(_ name: String, app: XCUIApplication) {
    // A full-device screenshot avoids XCTest's rotated app-window crop.
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  func testCameraChromeFilmSelectionAndSettings() {
    let app = launch(cameraPreview: true)
    XCTAssertTrue(app.buttons["camera-film"].waitForExistence(timeout: 10))
    XCTAssertFalse(app.buttons["camera-shutter"].isEnabled,
      "The preview fixture must never pretend it can capture a photograph")
    attachScreen("Camera chrome — simulator placeholder, not live capture", app: app)

    app.buttons["camera-film"].tap()
    XCTAssertTrue(app.navigationBars["Film"].waitForExistence(timeout: 5))
    app.buttons["Night"].tap()
    XCTAssertTrue(app.buttons["camera-film"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.buttons["camera-film"].value as? String, "Night")

    app.buttons["camera-film"].tap()
    app.buttons["1998"].tap()
    app.buttons["camera-settings"].tap()
    XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    XCTAssertFalse(app.buttons["Date stamp"].exists,
      "1998 must not offer a date picker whose value the recipe ignores")
    XCTAssertTrue(app.staticTexts.containing(
      NSPredicate(format: "label CONTAINS %@", "1998 always prints a compact stamp")
    ).firstMatch.exists)
    attachScreen("1998 settings disclose the fixed date stamp", app: app)
    app.buttons["Done"].tap()

    app.buttons["camera-flash"].tap()
    XCTAssertTrue(app.buttons["Off"].waitForExistence(timeout: 5))
    app.buttons["Off"].tap()
    XCTAssertTrue(app.buttons["camera-film"].waitForExistence(timeout: 5))
  }

  func testCameraChromeRemainsReachableAtLargestTextSize() {
    let app = launch(cameraPreview: true, accessibilityText: true)
    XCTAssertTrue(app.buttons["camera-film"].waitForExistence(timeout: 10))
    for identifier in ["camera-film", "camera-settings", "camera-lab", "camera-flash", "camera-switch"] {
      let button = app.buttons[identifier]
      XCTAssertTrue(button.isHittable, "\(identifier) must remain reachable at accessibility text sizes")
      XCTAssertGreaterThanOrEqual(button.frame.height, 44, identifier)
      XCTAssertGreaterThanOrEqual(button.frame.width, 44, identifier)
    }
    attachScreen("Camera chrome — largest accessibility text", app: app)
    app.buttons["camera-film"].tap()
    XCTAssertTrue(app.navigationBars["Film"].waitForExistence(timeout: 5))
    let cinema = app.buttons["Cinema"]
    for _ in 0..<4 where !cinema.isHittable { app.swipeUp() }
    XCTAssertTrue(cinema.isHittable, "Every film must remain selectable")
    cinema.tap()
    XCTAssertTrue(app.buttons["camera-film"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.buttons["camera-film"].value as? String, "Cinema")
    // Restore the default so other tests don't depend on execution order.
    app.buttons["camera-film"].tap()
    app.buttons["1998"].tap()
  }

  func testCameraChromeRemainsReachableInLandscape() {
    let app = launch(cameraPreview: true)
    XCTAssertTrue(app.buttons["camera-film"].waitForExistence(timeout: 10))
    XCUIDevice.shared.orientation = .landscapeLeft
    defer { XCUIDevice.shared.orientation = .portrait }
    let landscapeLayout = NSPredicate { _, _ in
      app.frame.width > app.frame.height
        && app.buttons["camera-film"].frame.midX > app.frame.width / 2
    }
    XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
      predicate: landscapeLayout, object: nil)], timeout: 10), .completed)
    for identifier in ["camera-film", "camera-settings", "camera-lab", "camera-flash", "camera-switch"] {
      XCTAssertTrue(app.buttons[identifier].isHittable, identifier)
      XCTAssertTrue(app.frame.contains(app.buttons[identifier].frame), identifier)
    }
    attachScreen("Camera chrome — landscape", app: app)
    app.buttons["camera-settings"].tap()
    XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    app.buttons["Done"].tap()
  }

  func testLabDeletionRemovesOnlyTheSelectedItem() {
    let app = launch(seededLibrary: true)
    let firstID = "A7B4A9E8-3F04-4B3A-9DD4-6EAFB4F4A198"
    let secondID = "B8C5BAF9-4015-4C4B-AEE5-7FBC5C05B209"
    XCTAssertTrue(app.buttons["camera-lab"].waitForExistence(timeout: 10))
    app.buttons["camera-lab"].tap()
    XCTAssertTrue(app.buttons["lab-select"].waitForExistence(timeout: 10))
    app.buttons["lab-select"].tap()
    app.buttons["lab-item-\(firstID)"].tap()
    XCTAssertTrue(app.buttons["lab-delete"].waitForExistence(timeout: 5))
    app.buttons["lab-delete"].tap()
    XCTAssertTrue(app.buttons["lab-delete-confirm"].waitForExistence(timeout: 5))
    // iOS 26 exposes the same SwiftUI dialog action as nested buttons.
    app.sheets.buttons["lab-delete-confirm"].firstMatch.tap()
    let removed = app.buttons["lab-item-\(firstID)"]
    XCTAssertTrue(removed.waitForNonExistence(timeout: 5))
    XCTAssertTrue(app.buttons["lab-item-\(secondID)"].exists)
    attachScreen("Lab — one item deleted, other preserved", app: app)
  }

  func testDeniedCameraKeepsLabAndSettingsAvailable() {
    let app = launch()

    XCTAssertTrue(app.staticTexts["Camera access is off"].waitForExistence(timeout: 10))
    XCTAssertTrue(app.buttons["camera-lab"].exists)
    XCTAssertTrue(app.buttons["camera-settings"].exists)

    app.buttons["camera-lab"].tap()
    XCTAssertTrue(app.navigationBars["Lab"].waitForExistence(timeout: 5))
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
    XCTAssertTrue(app.navigationBars["Lab"].waitForExistence(timeout: 10))

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
    // The bottom bar only renders once the selection is non-empty, so the
    // first check has to wait for that render rather than sample immediately.
    XCTAssertTrue(app.buttons["lab-export"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["lab-share"].exists)
    XCTAssertTrue(app.buttons["lab-delete"].exists)

    app.buttons["lab-delete"].tap()
    XCTAssertTrue(app.buttons["lab-delete-confirm"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["Delete this media?"].exists)
  }

  /// Regression guard for the iOS 26 Lab layout: a full-width grid body was
  /// laid out under the navigation bar (first tile at y=2). The grid's edge
  /// inset keeps the first row below the bar; this measures that it stays so.
  func testLabGridStartsBelowNavigationBar() {
    let app = launch(seededLibrary: true)
    let firstID = "A7B4A9E8-3F04-4B3A-9DD4-6EAFB4F4A198"

    XCTAssertTrue(app.buttons["camera-lab"].waitForExistence(timeout: 10))
    app.buttons["camera-lab"].tap()
    let navigationBar = app.navigationBars["Lab"]
    XCTAssertTrue(navigationBar.waitForExistence(timeout: 10))
    let firstTile = app.buttons["lab-item-\(firstID)"]
    XCTAssertTrue(firstTile.waitForExistence(timeout: 10))

    let barFrame = navigationBar.frame
    let tileFrame = firstTile.frame
    XCTAssertGreaterThan(barFrame.height, 0)
    XCTAssertGreaterThanOrEqual(
      tileFrame.minY, barFrame.maxY,
      "First Lab tile \(tileFrame) is laid out under the navigation bar \(barFrame)"
    )
  }

  func testDetailPagesAcrossFiveItemsAndBack() {
    let app = launch(seededLibrary: true)
    XCTAssertTrue(app.buttons["camera-lab"].waitForExistence(timeout: 10))
    app.buttons["camera-lab"].tap()
    let first = app.buttons["lab-item-A7B4A9E8-3F04-4B3A-9DD4-6EAFB4F4A198"]
    XCTAssertTrue(first.waitForExistence(timeout: 10))
    first.tap()
    XCTAssertTrue(app.staticTexts["1 of 5"].waitForExistence(timeout: 5))
    XCTAssertEqual(app.pageIndicators.count, 0, "Page dots must not overlap the date caption")
    for page in 2...5 {
      app.swipeLeft(velocity: .fast)
      XCTAssertTrue(app.staticTexts["\(page) of 5"].waitForExistence(timeout: 5))
    }
    attachScreen("Detail — fifth page beyond initial preload window", app: app)
    for page in (1...4).reversed() {
      app.swipeRight(velocity: .fast)
      XCTAssertTrue(app.staticTexts["\(page) of 5"].waitForExistence(timeout: 5))
    }
    XCTAssertFalse(app.staticTexts["Photo unavailable"].exists)
    attachScreen("Detail — first page reloads after leaving active window", app: app)
  }

  func testPhotoDetailSwipesBetweenGalleryItems() {
    let app = launch(seededLibrary: true)
    let firstID = "A7B4A9E8-3F04-4B3A-9DD4-6EAFB4F4A198"
    let secondID = "B8C5BAF9-4015-4C4B-AEE5-7FBC5C05B209"

    XCTAssertTrue(app.buttons["camera-lab"].waitForExistence(timeout: 10))
    app.buttons["camera-lab"].tap()
    let firstTile = app.buttons["lab-item-\(firstID)"]
    XCTAssertTrue(firstTile.waitForExistence(timeout: 10))
    firstTile.tap()

    let firstPage = app.descendants(matching: .any)["detail-item-\(firstID)"]
    XCTAssertTrue(firstPage.waitForExistence(timeout: 10))
    firstPage.swipeLeft()
    XCTAssertTrue(
      app.descendants(matching: .any)["detail-item-\(secondID)"].waitForExistence(timeout: 5)
    )
  }
}
