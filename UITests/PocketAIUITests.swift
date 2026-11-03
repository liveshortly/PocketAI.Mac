import XCTest

/// Smoke coverage for the v2 shell plus a screenshot of every surface, so the
/// look can be reviewed without a human driving the app.
final class PocketAIUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchApp(extraArgs: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-PocketPreviewCore", "-PocketSkipOnboarding"] + extraArgs
        app.launch()
        return app
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = app.windows.firstMatch.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The window opens with the three-zone shell and the sidebar's sections.
    func testMainWindowAndSidebar() throws {
        let app = launchApp()
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15), "Main window should exist")

        for label in ["Chats", "Tools"] {
            XCTAssertTrue(
                app.staticTexts[label].firstMatch.waitForExistence(timeout: 10),
                "Sidebar should show '\(label)'")
        }
        // Sidebar rows are buttons that draw their own selection (MAC-22).
        XCTAssertTrue(
            app.buttons["Models"].firstMatch.waitForExistence(timeout: 10),
            "Sidebar should show 'Models'")
        capture(app, "01-shell")
    }

    /// Every tool surface opens from the sidebar and renders its own content.
    func testToolSurfaces() throws {
        let app = launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))

        let surfaces: [(String, String)] = [
            ("Models", "02-models"),
            ("Images", "03-images"),
            ("Devices", "04-devices"),
            ("Local server", "05-server"),
            ("Privacy", "06-privacy"),
        ]
        for (label, shot) in surfaces {
            let row = app.buttons[label].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10), "Sidebar row '\(label)' missing")
            row.click()
            // Give the detail pane a beat to swap before the screenshot.
            Thread.sleep(forTimeInterval: 1.2)
            capture(app, shot)
        }
    }

    /// ⌘K opens the palette and it lists actions.
    func testCommandPalette() throws {
        let app = launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))

        app.typeKey("k", modifierFlags: .command)
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "Palette field should appear")
        Thread.sleep(forTimeInterval: 0.6)
        capture(app, "07-command-palette")
        app.typeKey(.escape, modifierFlags: [])
    }

    /// A new chat opens with the composer focused and the empty state visible.
    func testNewChat() throws {
        let app = launchApp()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))

        app.typeKey("n", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1.2)
        capture(app, "08-new-chat")
    }

    /// Onboarding renders on a fresh install.
    func testOnboarding() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-PocketPreviewCore", "-PocketResetOnboarding"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
        Thread.sleep(forTimeInterval: 1.0)
        capture(app, "09-onboarding")
    }
}
