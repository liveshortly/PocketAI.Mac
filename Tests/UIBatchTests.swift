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
