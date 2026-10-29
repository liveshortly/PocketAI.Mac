import PocketLiveShortly
import XCTest

@testable import PocketAI

/// Flow 4: open and drive a LiveShortly session.
///
/// `LSClient` is a concrete actor over HTTP with no injection point, so the
/// transcript fold is driven through `ingest` — the same entry point the SSE
/// stream uses — and the failure paths are driven against a closed port, which
/// fails immediately and deterministically. What depends on a live `isLive`
/// (`pendingProbe`, `canComment` while live) needs a real server and is not
/// covered here.
@MainActor
final class LiveShortlyPathTests: XCTestCase {

    /// Nothing listens here, so every call fails at connect — no DNS, no wait.
    private func deadClient() -> LSClient {
        LSClient(baseURL: URL(string: "http://127.0.0.1:1")!, accessToken: "t")
    }

    private func model() -> LSSessionModel {
        LSSessionModel(sessionID: "s-1", client: deadClient(), myHandle: "me")
    }

    private func event(
        _ seq: Int, _ type: String, _ payload: [String: LSJSON] = [:],
        actor: String? = "agent", at offset: TimeInterval = 0
    ) -> LSEvent {
        LSEvent(
            id: "e-\(seq)", seq: seq, actor: actor, eventType: type,
            payload: .object(payload), ts: Date(timeIntervalSince1970: 1_700_000_000 + offset))
    }

    // MARK: - Transcript fold

    /// Tool activity folds into one collapsible run; prompts and replies break
    /// it. Refolding wrongly is what turns a session into an unreadable wall.
    func testToolActivityFoldsIntoRunsThatPromptsAndRepliesBreak() {
        let session = model()
        session.ingest(event(1, "prompt", ["message": .string("do the thing")], actor: "user"))
        session.ingest(event(2, "tool_call", ["tool": .string("Bash")]))
        session.ingest(event(3, "file_write", ["file": .string("a.swift")]))
        session.ingest(event(4, "output", ["text": .string("done")]))
        session.ingest(event(5, "response", ["message": .string("finished")]))

        // One day marker, the prompt, one folded run of three, the reply.
        XCTAssertEqual(session.items.count, 4, "the three tool steps fold into one run")
        if case .day = session.items[0].kind {} else { XCTFail("first item should be the day") }
        if case .single(let prompt) = session.items[1].kind {
            XCTAssertEqual(prompt.eventType, "prompt")
        } else {
            XCTFail("the prompt stands on its own")
        }
        if case .work(let run) = session.items[2].kind {
            XCTAssertEqual(run.count, 3)
        } else {
            XCTFail("the tool steps fold")
        }
        if case .single(let reply) = session.items[3].kind {
            XCTAssertEqual(reply.eventType, "response")
        } else {
            XCTFail("the reply stands on its own")
        }
    }

    /// The working indicator: busy from the prompt until the reply lands, so
    /// there is no dead gap between sending and the agent's first step.
    func testAgentBusyTracksTheTurn() {
        let session = model()
        XCTAssertFalse(session.agentBusy)

        session.ingest(event(1, "prompt", ["message": .string("go")], actor: "user"))
        XCTAssertTrue(session.agentBusy, "busy as soon as the agent has something to do")

        session.ingest(event(2, "tool_call", ["tool": .string("Bash")]))
        XCTAssertTrue(session.agentBusy)

        session.ingest(event(3, "response", ["message": .string("done")]))
        XCTAssertFalse(session.agentBusy, "a reply ends the turn")
    }

    /// A permission probe also ends the busy state — the agent is waiting on
    /// the viewer, not working.
    func testAPermissionProbeStopsTheWorkingIndicator() {
        let session = model()
        session.ingest(event(1, "prompt", ["message": .string("go")], actor: "user"))
        session.ingest(event(2, "tool_call", ["tool": .string("Bash")]))
        session.ingest(event(3, "input_requested", ["kind": .string("permission")]))
        XCTAssertFalse(session.agentBusy)
    }

    func testTheSameEventTwiceIsRenderedOnce() {
        let session = model()
        let one = event(1, "response", ["message": .string("hi")])
        session.ingest(one)
        session.ingest(one)
        XCTAssertEqual(session.events.count, 1)
        XCTAssertEqual(session.items.count, 2, "day marker plus one reply")
    }

    func testAnOutOfOrderEventIsResortedAndRefolded() {
        let session = model()
        session.ingest(event(3, "response", ["message": .string("third")]))
        session.ingest(event(1, "prompt", ["message": .string("first")], actor: "user"))
        XCTAssertEqual(session.events.map(\.seq), [1, 3])
        // Re-folded from scratch, so the prompt precedes the reply.
        if case .single(let first) = session.items[1].kind {
            XCTAssertEqual(first.eventType, "prompt")
        } else {
            XCTFail("the earlier event has to sort back into place")
        }
    }

    /// Which action a verdict applies to. Getting this wrong means approving
    /// something other than what is on screen.
    func testThePermissionProbeResolvesToTheToolCallItIsAbout() throws {
        let session = model()
        session.ingest(event(1, "tool_call", ["tool": .string("Read")]))
        session.ingest(event(2, "response", ["message": .string("here you go")]))
        session.ingest(event(3, "tool_call",
                             ["tool": .string("Bash"), "command": .string("rm -rf build")]))
        let probe = event(4, "input_requested", ["kind": .string("permission")])
        session.ingest(probe)

        let resolved = try XCTUnwrap(session.toolCall(before: probe))
        XCTAssertEqual(resolved.payload["tool"]?.stringValue, "Bash",
                       "the newest tool call in this turn, not an earlier turn's")
        XCTAssertEqual(lsToolSummaryText(resolved), "Bash · rm -rf build")
    }

    /// A probe that is not a permission question has no tool call behind it —
    /// showing one would attribute an action to a plain input request.
    func testAnInputProbeHasNoToolCall() {
        let session = model()
        session.ingest(event(1, "tool_call", ["tool": .string("Bash")]))
        let probe = event(2, "input_requested", ["kind": .string("input")])
        session.ingest(probe)
        XCTAssertNil(session.toolCall(before: probe))
    }

    /// A tool call separated from the probe by a reply belongs to the previous
    /// turn.
    func testAToolCallFromAnEarlierTurnIsNotAttributed() {
        let session = model()
        session.ingest(event(1, "tool_call", ["tool": .string("Bash")]))
        session.ingest(event(2, "response", ["message": .string("done")]))
        let probe = event(3, "input_requested", ["kind": .string("permission")])
        session.ingest(probe)
        XCTAssertNil(session.toolCall(before: probe))
    }

    // MARK: - Failure paths

    /// A session that cannot be reached must land in a readable state, not a
    /// spinner: loaded, with the reason, and read-only.
    func testASessionThatCannotBeOpenedSaysSoAndGoesReadOnly() async {
        let session = model()
        await session.open()

        XCTAssertTrue(session.loaded, "the view must stop showing “Loading session…”")
        XCTAssertNotNil(session.errorText, "a failed open has to say why")
        XCTAssertFalse(session.isLive)
        XCTAssertFalse(
            session.canComment,
            "no composer on a session we never reached — sending would be a no-op")
        XCTAssertEqual(session.title, "Untitled session")
    }

    /// The permission bar disables its buttons while answering and re-enables
    /// them on failure. That depends entirely on `decide` returning false.
    func testADroppedVerdictReportsFailureSoTheBarComesBack() async {
        let session = model()
        let sent = await session.decide("allow")
        XCTAssertFalse(sent, "a verdict that never reached the server must not report success")
        XCTAssertNotNil(session.errorText)
    }

    /// Delete only clears the selection when the server agreed; otherwise the
    /// session is still there and closing the pane hides it from its owner.
    func testAFailedDeleteReportsFailure() async {
        let session = model()
        let deleted = await session.delete()
        XCTAssertFalse(deleted)
        XCTAssertNotNil(session.errorText)
    }

    /// Ending a session flips `isLive` only on the server's word — marking it
    /// ended regardless showed "ENDED" while the agent carried on working.
    func testAFailedEndLeavesTheSessionAsItWas() async throws {
        let session = model()
        session.endSession()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(session.isLive)
        XCTAssertNotNil(session.errorText, "the refusal has to surface")
    }

    // MARK: - Payload readers

    func testEventTextIsReadFromWhicheverKeyCarriesIt() {
        XCTAssertEqual(lsBodyText(event(1, "x", ["message": .string("m")])), "m")
        XCTAssertEqual(lsBodyText(event(1, "x", ["text": .string("t")])), "t")
        XCTAssertEqual(lsBodyText(event(1, "x", ["prompt": .string("p")])), "p")
        XCTAssertEqual(lsBodyText(event(1, "x", ["message": .string("  ")])), "")
        XCTAssertEqual(lsBodyText(event(1, "x")), "")
    }

    func testAuthorIsTheViewerHandleWhenThereIsOne() {
        XCTAssertEqual(lsHandleText(event(1, "x", ["username": .string("rohit")])), "@rohit")
        XCTAssertEqual(lsHandleText(event(1, "x", actor: "agent")), "agent")
        XCTAssertEqual(lsHandleText(event(1, "x", actor: "viewer")), "viewer")
    }

    func testToolSummaryNamesTheFileOrCommand() {
        let bash = event(1, "tool_call", [
            "tool": .string("Bash"),
            "input": .object(["command": .string("swift build\nmore")]),
        ])
        XCTAssertEqual(lsToolSummaryText(bash), "Bash · swift build")

        let edit = event(2, "tool_call", [
            "tool": .string("Edit"),
            "input": .object(["file_path": .string("/a/b/ChatView.swift")]),
        ])
        XCTAssertEqual(lsToolSummaryText(edit), "Edit · ChatView.swift")

        XCTAssertEqual(lsToolSummaryText(event(3, "tool_call", ["tool": .string("Grep")])), "Grep")
    }
}
