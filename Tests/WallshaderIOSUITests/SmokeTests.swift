import XCTest

/// Minimal launch smoke (C10): the app comes up, the library is visible,
/// tapping a wallpaper opens the editor. Photos-add is granted via simctl
/// in `make test` so the save path can't hang automation.
final class SmokeTests: XCTestCase {
    @MainActor
    func testLaunchLibraryAndOpenEditor() {
        // iPad: landscape keeps the split view's sidebar (the library)
        // visible; portrait collapses it and the smoke can't see rows.
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .landscapeLeft
        }
        let app = XCUIApplication()
        app.launchArguments = ["--suppress-onboarding"]
        app.launch()

        // Seeded starters exist on first launch. The Photos-style grid has
        // no text labels — the tile itself carries the accessibility label;
        // the iPad sidebar still shows it as a row.
        let tile = app.buttons["Mesh Gradient"].firstMatch
        let row = app.staticTexts["Mesh Gradient"].firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 15) || row.exists,
                      "seeded library visible")
        (tile.exists ? tile : row).tap()
        // Detail: the variant selector is up (current device preselected).
        XCTAssertTrue(app.buttons["iPhone"].waitForExistence(timeout: 15),
                      "detail opened with the variant selector")
    }
}
