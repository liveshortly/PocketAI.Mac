import XCTest
import SwiftUI
import PocketKit
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

/// UI-48: onboarding model pick ranking.
final class OnboardingPickTests: XCTestCase {
    private func c(_ id: String, _ v: FitVerdict, _ gb: UInt64, instruct: Bool = true) -> PickCandidate {
        PickCandidate(id: id, verdict: v, isInstruct: instruct, diskBytes: gb << 30)
    }

    func testRecommendedIsStrongestRunsWellAndAlternatesBracketIt() {
        let picks = onboardingPicks([
            c("tiny", .runsWell, 1), c("mid", .runsWell, 4), c("big", .runsSlow, 9),
            c("huge", .runsSlow, 20), c("nofit", .willNotFit, 40),
            c("base-large", .runsWell, 6, instruct: false),
        ])
        XCTAssertEqual(picks, OnboardingPicks(recommended: "mid", smaller: "tiny", larger: "base-large"))
    }

    func testNothingRunsWellMeansNoRecommendation() {
        XCTAssertEqual(onboardingPicks([c("a", .runsSlow, 4)]), OnboardingPicks())
    }

    func testNewestWinsASizeTie() {
        XCTAssertEqual(
            onboardingPicks([c("m-2506", .runsWell, 4), c("m-2507", .runsWell, 4)]).recommended,
            "m-2507")
    }
}

/// COM-10: pocketai://activate deep link parsing.
final class ActivateLinkTests: XCTestCase {
    func testValidKey() {
        XCTAssertEqual(ActivateLink.key(in: URL(string: "pocketai://activate?key=key/abc.def")!), "key/abc.def")
        XCTAssertEqual(ActivateLink.key(in: URL(string: "pocketai://activate?x=1&key=k1")!), "k1")
    }
    func testJunkMissingAndWrongScheme() {
        XCTAssertNil(ActivateLink.key(in: URL(string: "pocketai://activate")!))
        XCTAssertNil(ActivateLink.key(in: URL(string: "pocketai://activate?key=")!))
        XCTAssertNil(ActivateLink.key(in: URL(string: "pocketai://activate?key=%20")!))
        XCTAssertNil(ActivateLink.key(in: URL(string: "pocketai://session/abc?key=k")!))
        XCTAssertNil(ActivateLink.key(in: URL(string: "https://activate/?key=k")!))
        XCTAssertNil(ActivateLink.key(in: URL(string: "junk")!))
    }
    func testEmailPeek() {
        let payload = Data(#"{"user":{"email":"a@b.co"}}"#.utf8).base64EncodedString()
        XCTAssertEqual(ActivateLink.email(inKey: "key/\(payload).sig"), "a@b.co")
        XCTAssertNil(ActivateLink.email(inKey: "garbage"))
    }
}
