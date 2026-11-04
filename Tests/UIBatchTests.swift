import XCTest
import SwiftUI
@testable import PocketAI

@MainActor
final class UIBatchTests: XCTestCase {
    /// UI-47: before onboarding ends, ⌘N and App Intents must not create chats.
    func testNewChatIsGatedOnOnboarding() {
        let model = AppModel()
        model.hasOnboarded = false
        let before = model.selection
        XCTAssertNil(model.newChat())
        XCTAssertEqual(model.selection, before)
    }

    /// UI-87: approval shortcuts exist only for permission requests.
    func testApprovalShortcutMapping() {
        XCTAssertEqual(
            LSProbeDetailView.shortcut(for: "allow", kind: "permission"),
            KeyboardShortcut(.return, modifiers: .command))
        XCTAssertEqual(
            LSProbeDetailView.shortcut(for: "deny", kind: "permission"),
            KeyboardShortcut(.delete, modifiers: .command))
        XCTAssertNil(LSProbeDetailView.shortcut(for: "allow", kind: "input"))
        XCTAssertNil(LSProbeDetailView.shortcut(for: "deny", kind: nil))
    }
}
