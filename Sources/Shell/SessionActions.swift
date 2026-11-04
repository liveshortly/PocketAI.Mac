import AppKit
import PocketLiveShortly
import PocketUI
import SwiftUI

/// UI-86: the session context menu and its End / Delete confirmations, shared
/// by the sidebar and the All sessions list so both rows behave the same.
@Observable
final class SessionActionState {
    var pendingEnd: LSSession?
    var pendingDelete: LSSession?
    /// Why the last action didn't take; the server may refuse either.
    var error: String?
}

extension View {
    /// Open / Copy link, plus End and Delete for sessions this account owns
    /// (a shared session carries `sharedLine`; those are the owner's to end).
    func sessionContextMenu(_ session: LSSession, state: SessionActionState) -> some View {
        modifier(SessionContextMenu(session: session, state: state))
    }

    /// Hosts the End / Delete confirmation dialogs. `onChange` runs after a
    /// successful end or delete so a list that loads its own copy can refresh.
    func sessionActionDialogs(
        _ state: SessionActionState, onChange: @escaping () -> Void = {}
    ) -> some View {
        modifier(SessionActionDialogs(state: state, onChange: onChange))
    }
}

private struct SessionContextMenu: ViewModifier {
    @Environment(AppModel.self) private var app
    let session: LSSession
    let state: SessionActionState

    func body(content: Content) -> some View {
        content.contextMenu {
            Button("Open") { app.selection = .session(session.id) }
            if let link = app.liveShortly.client?.sessionLink(session.id) {
                Button("Copy link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link.absoluteString, forType: .string)
                }
            }
            if session.sharedLine == nil {
                Divider()
                if session.isLive {
                    Button("End session", role: .destructive) { state.pendingEnd = session }
                }
                Button("Delete session", role: .destructive) { state.pendingDelete = session }
            }
        }
    }
}

private struct SessionActionDialogs: ViewModifier {
    @Environment(AppModel.self) private var app
    @Bindable var state: SessionActionState
    let onChange: () -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "End “\(state.pendingEnd?.title ?? "session")”? The agent stops where it is.",
                isPresented: Binding(
                    get: { state.pendingEnd != nil },
                    set: { if !$0 { state.pendingEnd = nil } }),
                titleVisibility: .visible
            ) {
                Button("End session", role: .destructive) {
                    guard let target = state.pendingEnd, let client = app.liveShortly.client
                    else { return }
                    Task {
                        do {
                            try await client.stop(target.id)
                            state.error = nil
                        } catch {
                            state.error = "Couldn't end that session: \(error.localizedDescription)"
                        }
                        await app.liveShortly.feed.reload()
                        onChange()
                    }
                }
            }
            .confirmationDialog(
                "Delete “\(state.pendingDelete?.title ?? "session")”? This cannot be undone.",
                isPresented: Binding(
                    get: { state.pendingDelete != nil },
                    set: { if !$0 { state.pendingDelete = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete session", role: .destructive) {
                    guard let target = state.pendingDelete, let client = app.liveShortly.client
                    else { return }
                    Task {
                        do {
                            try await client.deleteSession(target.id)
                            state.error = nil
                            if app.selection == .session(target.id) { app.selection = nil }
                            app.liveShortly.feed.remove(target.id)
                            onChange()
                        } catch {
                            state.error = "Couldn't delete that session: \(error.localizedDescription)"
                        }
                    }
                }
            }
    }
}
