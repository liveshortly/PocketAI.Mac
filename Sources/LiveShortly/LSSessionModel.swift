import Foundation
import Observation
import PocketLiveShortly

/// Live state for one LiveShortly session: replayed history, then the SSE
/// stream. Mirrors `ChatModel` so the two kinds of conversation behave the
/// same in the UI — the only difference is where the tokens come from.
@Observable
@MainActor
final class LSSessionModel {
    let sessionID: String
    private let client: LSClient
    private let myHandle: String

    /// Settable so the share sheet can reflect a change it just made.
    var detail: LSSessionDetail?
    private(set) var events: [LSEvent] = []
    private(set) var items: [LSItem] = []
    private(set) var isLive = false
    private(set) var agentBusy = false
    private(set) var watchers = 0
    private(set) var errorText: String?
    private(set) var loaded = false
    /// Viewers currently typing: name → when their indicator expires.
    private(set) var typers: [String: Date] = [:]

    private var streamTask: Task<Void, Never>?
    private var runOpen = false
    private var lastFolded: LSEvent?
    private var echoes: [String: String] = [:]
    private var lastTypingSent = Date.distantPast

    init(sessionID: String, client: LSClient, myHandle: String) {
        self.sessionID = sessionID
        self.client = client
        self.myHandle = myHandle
    }

    var title: String {
        let stored = detail?.title ?? ""
        return stored.isEmpty ? "Untitled session" : stored
    }

    var canComment: Bool { detail?.canComment == true && isLive }

    var typingLine: String? {
        let now = Date()
        let names = typers.filter { $0.value > now }.keys.sorted()
        guard !names.isEmpty else { return nil }
        switch names.count {
        case 1:
            return "\(names[0]) is typing…"
        case 2:
            return "\(names[0]) and \(names[1]) are typing…"
        case 3:
            return "\(names[0]), \(names[1]) and \(names[2]) are typing…"
        default:
            return "\(names[0]), \(names[1]) and \(names.count - 2) others are typing…"
        }
    }

    /// The newest unanswered permission or input probe, if the session is live.
    var pendingProbe: LSEvent? {
        guard isLive else { return nil }
        for event in events.reversed() {
            switch event.eventType {
            case "viewer_decision", "prompt", "response": return nil
            case "input_requested": return event
            default: continue
            }
        }
        return nil
    }

    /// The tool call a permission probe is asking about: the last `tool_call`
    /// before it in the same turn. The capture hook emits the full tool input
    /// right before the agent's prompt, so this is the action awaiting a verdict.
    func toolCall(before probe: LSEvent) -> LSEvent? {
        guard probe.payload["kind"]?.stringValue == "permission" else { return nil }
        for event in events.reversed() where event.seq < probe.seq {
            switch event.eventType {
            case "tool_call": return event
            case "prompt", "response", "viewer_comment": return nil
            default: continue
            }
        }
        return nil
    }

    // MARK: - Loading and streaming

    func open() async {
        do {
            let loadedDetail = try await client.session(sessionID)
            detail = loadedDetail
            events = loadedDetail.events
            isLive = loadedDetail.isLive
            rebuild()
            errorText = nil
            loaded = true
            LSSeen.mark(sessionID, max(loadedDetail.eventCount, events.count))
            if loadedDetail.isLive { startStream() }
        } catch {
            errorText = error.localizedDescription
            loaded = true
        }
    }

    private func startStream() {
        streamTask?.cancel()
        streamTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await frame in await self.client.stream(self.sessionID) {
                    guard !Task.isCancelled else { return }
                    switch frame {
                    case .event(let event):
                        self.ingest(event)
                    case .watchers(let count):
                        self.watchers = count
                    case .typing(let who, let until):
                        if who != self.myHandle { self.typers[who] = until }
                    case .sessionEnded:
                        self.isLive = false
                    case .connected(let status):
                        self.isLive = status == "live"
                    case .other:
                        break
                    }
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled else { return }
                self.errorText = "Stream dropped — reopen the session to catch up."
            }
        }
    }

    /// Internal rather than private only so the transcript fold can be driven
    /// from tests the way the stream drives it — this is the real entry point
    /// for every streamed frame, not a test-only door.
    func ingest(_ event: LSEvent) {
        var removedEcho = false
        if event.eventType == "viewer_comment",
           let (localID, _) = echoes.first(where: { $0.value == lsBodyText(event) }) {
            events.removeAll { $0.id == localID }
            echoes[localID] = nil
            removedEcho = true
        }
        guard !events.contains(where: { $0.id == event.id }) else {
            if removedEcho { rebuild() }
            return
        }
        if let last = events.last, event.seq < last.seq {
            events.append(event)
            events.sort { $0.seq < $1.seq }
            rebuild()
        } else {
            events.append(event)
            if removedEcho { rebuild() } else { fold(event) }
        }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
    }

    // MARK: - Actions

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Optimistic echo, replaced when the server's own event arrives.
        let localID = "local-\(UUID().uuidString)"
        let echo = LSEvent(
            id: localID,
            seq: (events.last?.seq ?? 0) + 1,
            actor: "viewer",
            eventType: "viewer_comment",
            payload: .object(["message": .string(trimmed), "username": .string(myHandle)]),
            ts: Date())
        events.append(echo)
        fold(echo)
        echoes[localID] = trimmed

        Task {
            do {
                try await client.comment(sessionID, message: trimmed)
            } catch {
                events.removeAll { $0.id == localID }
                echoes[localID] = nil
                rebuild()
                errorText = error.localizedDescription
            }
        }
    }

    func noteTyping() {
        guard isLive, Date().timeIntervalSince(lastTypingSent) > 3 else { return }
        lastTypingSent = Date()
        Task { await client.typing(sessionID) }
    }

    /// Answers a permission probe. Returns false when the verdict did not
    /// reach the server, so the caller can re-enable its buttons instead of
    /// leaving the agent blocked behind a dead bar.
    @discardableResult
    func decide(_ decision: String) async -> Bool {
        do {
            try await client.decide(sessionID, decision: decision)
            return true
        } catch {
            errorText = "Couldn't send that answer: \(error.localizedDescription)"
            return false
        }
    }

    /// Switches the agent's model. The chip reads `detail.model`, so without
    /// writing it back the menu pick looked like it did nothing — and a
    /// refused change said nothing at all.
    func setModel(_ model: String) {
        Task {
            do {
                try await client.setModel(sessionID, model: model)
                detail?.model = model
            } catch {
                errorText = "Couldn't switch model: \(error.localizedDescription)"
            }
        }
    }

    func rename(_ title: String) {
        Task {
            do {
                try await client.rename(sessionID, title: title)
                detail?.title = title
            } catch {
                errorText = "Couldn't rename this session: \(error.localizedDescription)"
            }
        }
    }

    /// Ends the session. Only a verdict from the server flips `isLive` —
    /// marking it ended regardless hid a failure behind an "ENDED" chip while
    /// the agent carried on working.
    func endSession() {
        Task {
            do {
                try await client.stop(sessionID)
                isLive = false
            } catch {
                errorText = "Couldn't end this session: \(error.localizedDescription)"
            }
        }
    }

    func delete() async -> Bool {
        do {
            try await client.deleteSession(sessionID)
            return true
        } catch {
            errorText = error.localizedDescription
            return false
        }
    }

    func expireTypers(_ now: Date) {
        if !typers.isEmpty { typers = typers.filter { $0.value > now } }
    }

    // MARK: - Transcript fold
    //
    // Cached, appended per event — refolding the whole log on every frame is
    // O(n) per render and a long session streams hundreds of them.

    private static let breakers: Set<String> = [
        "prompt", "response", "viewer_comment", "input_requested", "viewer_decision",
    ]

    private func rebuild() {
        items = []
        runOpen = false
        agentBusy = false
        lastFolded = nil
        for event in events { fold(event) }
    }

    private func fold(_ event: LSEvent) {
        switch event.eventType {
        case "response", "session_ended", "stream_end", "input_requested":
            agentBusy = false
        case "prompt", "viewer_comment", "tool_call", "pre_tool", "file_write", "output":
            agentBusy = true
        default:
            break
        }

        if lastFolded == nil
            || !Calendar.current.isDate(lastFolded!.ts, inSameDayAs: event.ts) {
            runOpen = false
            items.append(LSItem(kind: .day(event.ts), id: "d\(event.seq)"))
        }

        if event.eventType == "stream_end" || event.eventType == "session_ended" {
            runOpen = false // turn marker: breaks the run, renders nothing
        } else if Self.breakers.contains(event.eventType) {
            runOpen = false
            var item = LSItem(kind: .single(event), id: "e\(event.seq)")
            if let previous = lastFolded, Self.breakers.contains(previous.eventType),
               previous.eventType == event.eventType,
               lsHandleText(previous) == lsHandleText(event),
               event.ts.timeIntervalSince(previous.ts) < 300 {
                item.grouped = true
            }
            items.append(item)
        } else if runOpen, case .work(let run) = items[items.count - 1].kind {
            items[items.count - 1].kind = .work(run + [event])
        } else {
            items.append(LSItem(kind: .work([event]), id: "w\(event.seq)"))
            runOpen = true
        }
        lastFolded = event
    }
}

/// One row of a session transcript.
struct LSItem: Identifiable {
    enum Kind {
        case single(LSEvent)
        case work([LSEvent])
        case day(Date)
    }
    var kind: Kind
    var id: String
    var grouped = false
}

/// Pulls the human text out of an event payload.
func lsBodyText(_ event: LSEvent) -> String {
    for key in ["message", "text", "content", "prompt"] {
        if let value = event.payload[key]?.stringValue,
           !value.trimmingCharacters(in: .whitespaces).isEmpty {
            return value
        }
    }
    return ""
}

/// Who an event came from, for author grouping and labels.
func lsHandleText(_ event: LSEvent) -> String {
    if let user = event.payload["username"]?.stringValue, !user.isEmpty { return "@\(user)" }
    if let actor = event.actor, actor != "agent" { return actor }
    return "agent"
}
