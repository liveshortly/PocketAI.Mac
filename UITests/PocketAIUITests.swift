import XCTest

final class PocketAIUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Helper to launch PocketAI with standard test arguments
    private func launchApp(extraArgs: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        var args = ["-PocketPreviewCore", "-PocketSkipOnboarding"]
        args.append(contentsOf: extraArgs)
        app.launchArguments = args
        app.launch()
        return app
    }

    /// 1. testMainWindowAndSidebar (MAC-02):
    /// Launch; assert the main window exists and the sidebar shows the expected items
    /// (Chats, Projects, Models, Server, Devices, Privacy).
    func testMainWindowAndSidebar() throws {
        let app = launchApp()

        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10), "Main window should exist")

        let sidebarItems = ["Chats", "Projects", "Models", "Server", "Devices", "Privacy"]
        for item in sidebarItems {
            let element = app.staticTexts[item].firstMatch
            XCTAssertTrue(element.waitForExistence(timeout: 10), "Sidebar item '\(item)' should exist")
        }
    }

    /// 2. testSidebarNavigation (MAC-03/MAC-11, UI-11):
    /// Click each sidebar item and assert the detail pane switches (a distinctive static text / nav title per screen appears).
    func testSidebarNavigation() throws {
        let app = launchApp()

        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10), "Main window should exist")

        // 1. Chats (initial or clicked)
        let chatsItem = app.staticTexts["Chats"].firstMatch
        XCTAssertTrue(chatsItem.waitForExistence(timeout: 10))
        chatsItem.click()
        // Distinctive element in Chats view: "Chats" title, search field, or empty state
        let chatsSearch = app.textFields["Search chats…"].firstMatch
        XCTAssertTrue(chatsSearch.waitForExistence(timeout: 10), "Chats search field should appear in Chats pane")

        // 2. Projects
        let projectsItem = app.staticTexts["Projects"].firstMatch
        XCTAssertTrue(projectsItem.waitForExistence(timeout: 10))
        projectsItem.click()
        // Distinctive element in Projects view: "Select or create a project" or "No projects yet" or "Projects" title
        let projectsHeader = app.staticTexts["Projects"].firstMatch
        XCTAssertTrue(projectsHeader.waitForExistence(timeout: 10))
        let projectsEmptyOrDetail = app.staticTexts["Select or create a project"].firstMatch
        let projectsNoYet = app.staticTexts["No projects yet"].firstMatch
        XCTAssertTrue(projectsEmptyOrDetail.waitForExistence(timeout: 5) || projectsNoYet.waitForExistence(timeout: 5), "Projects content should appear")

        // 3. Models
        let modelsItem = app.staticTexts["Models"].firstMatch
        XCTAssertTrue(modelsItem.waitForExistence(timeout: 10))
        modelsItem.click()
        // Distinctive element in Models view: Memory budget gauge or browse segment
        let memoryBudget = app.staticTexts["Memory Budget for Models:"].firstMatch
        XCTAssertTrue(memoryBudget.waitForExistence(timeout: 10), "Memory budget section should appear in Models pane")

        // 4. Server
        let serverItem = app.staticTexts["Server"].firstMatch
        XCTAssertTrue(serverItem.waitForExistence(timeout: 10))
        serverItem.click()
        // Distinctive element in Server view: "NETWORK & SECURITY" or "LOCAL API KEY" or server status text
        let serverNetworkSecurity = app.staticTexts["NETWORK & SECURITY"].firstMatch
        XCTAssertTrue(serverNetworkSecurity.waitForExistence(timeout: 10), "Network & Security should appear in Server pane")

        // 5. Devices
        let devicesItem = app.staticTexts["Devices"].firstMatch
        XCTAssertTrue(devicesItem.waitForExistence(timeout: 10))
        devicesItem.click()
        // Distinctive element in Devices view: "Paired Devices" or "No iPhones Paired Yet"
        let pairedDevicesHeader = app.staticTexts["Paired Devices"].firstMatch
        XCTAssertTrue(pairedDevicesHeader.waitForExistence(timeout: 10), "Paired Devices should appear in Devices pane")

        // 6. Privacy
        let privacyItem = app.staticTexts["Privacy"].firstMatch
        XCTAssertTrue(privacyItem.waitForExistence(timeout: 10))
        privacyItem.click()
        // Distinctive element in Privacy view: "NETWORK PROOF" or "AUDIT LOG & CHAIN INTEGRITY"
        let networkProof = app.staticTexts["NETWORK PROOF"].firstMatch
        XCTAssertTrue(networkProof.waitForExistence(timeout: 10), "Network Proof should appear in Privacy pane")
        let auditLog = app.staticTexts["AUDIT LOG & CHAIN INTEGRITY"].firstMatch
        XCTAssertTrue(auditLog.waitForExistence(timeout: 10), "Audit Log section should appear in Privacy pane")
    }

    /// 3. testNewChatAndComposer (UI-09):
    /// On Chats, invoke New Chat (button or ⌘N) and assert a message composer text field is present and focusable.
    func testNewChatAndComposer() throws {
        let app = launchApp()

        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10), "Main window should exist")

        // Ensure we are on Chats
        let chatsItem = app.staticTexts["Chats"].firstMatch
        if chatsItem.waitForExistence(timeout: 5) {
            chatsItem.click()
        }

        // Invoke New Chat using ⌘N
        app.typeKey("n", modifierFlags: .command)

        // Find the composer text field/view
        // In MacChatDetailView: TextField("Ask PocketAI anything… (⌘L)", text: $composerText, axis: .vertical)
        var composer = app.textFields["Ask PocketAI anything… (⌘L)"].firstMatch
        if !composer.waitForExistence(timeout: 5) {
            composer = app.textViews["Ask PocketAI anything… (⌘L)"].firstMatch
        }
        if !composer.waitForExistence(timeout: 5) {
            // Check by identifier if added
            composer = app.textFields["chat-composer"].firstMatch
            if !composer.exists {
                composer = app.textViews["chat-composer"].firstMatch
            }
        }

        XCTAssertTrue(composer.waitForExistence(timeout: 10), "Message composer should be present after New Chat")

        // Assert focusable by clicking and typing into it
        composer.click()
        composer.typeText("Hello PocketAI")
        let value = composer.value as? String ?? ""
        XCTAssertTrue(value.contains("Hello PocketAI"), "Composer should accept focus and text input, got: \(value)")
    }

    /// 4. testOnboardingShows (MAC-05):
    /// Launch with -PocketResetOnboarding and assert the onboarding first screen appears;
    /// then verify advancing works.
    func testOnboardingShows() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-PocketPreviewCore", "-PocketResetOnboarding"]
        app.launch()

        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10), "Main window should exist")

        // Assert onboarding first screen headline appears
        let welcomeText = app.staticTexts["Private AI that lives on your devices."].firstMatch
        XCTAssertTrue(welcomeText.waitForExistence(timeout: 10), "Onboarding welcome headline should be visible")

        let getStartedButton = app.buttons["Get Started"].firstMatch
        XCTAssertTrue(getStartedButton.waitForExistence(timeout: 10), "Get Started button should be visible")

        // Advancing test: Click Get Started and assert transition to device check screen
        getStartedButton.click()

        let analyzingText = app.staticTexts["Analyzing your Mac hardware…"].firstMatch
        XCTAssertTrue(analyzingText.waitForExistence(timeout: 10), "Advancing should transition to hardware analysis screen")
    }

    /// 5. testMenuBarExtraOrCommands (MAC-08):
    /// Assert the app exposes its menu commands (e.g. the New Chat menu item under the app's menu) -
    /// if the menu-bar extra isn't reachable via XCUITest, assert the main menu's command instead and note it.
    func testMenuBarExtraOrCommands() throws {
        let app = launchApp()

        let mainWindow = app.windows.firstMatch
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 10), "Main window should exist")

        // Check main menu commands under File
        let fileMenu = app.menuBars.menuBarItems["File"]
        XCTAssertTrue(fileMenu.waitForExistence(timeout: 10), "File menu item should exist in main menu bar")
        fileMenu.click()

        let newChatItem = app.menuItems["New Chat"].firstMatch
        XCTAssertTrue(newChatItem.waitForExistence(timeout: 5), "New Chat menu item should exist under File menu")

        let newProjectItem = app.menuItems["New Project"].firstMatch
        XCTAssertTrue(newProjectItem.waitForExistence(timeout: 5), "New Project menu item should exist under File menu")

        // Close menu by pressing escape
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
    }
}
