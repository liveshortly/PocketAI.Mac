import PocketKit
import PocketLiveShortly
import PocketUI
import SwiftUI

/// The window: sidebar · detail · inspector. Onboarding takes the whole
/// window until it is done, so the shell is never shown half-configured.
struct RootView: View {
    @Environment(AppModel.self) private var app
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        @Bindable var app = app
        Group {
            if !app.hasOnboarded {
                OnboardingView()
            } else {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    SidebarView()
                        .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 340)
                } detail: {
                    detail
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .background(PocketColor.bgCanvas)
            }
        }
        .sheet(isPresented: $app.showCommandPalette) {
            CommandPaletteView()
                .environment(app)
        }
        .sheet(
            item: Binding(
                get: { app.pendingPairingRequest },
                set: { app.pendingPairingRequest = $0 })
        ) { request in
            PairingApprovalSheet(request: request)
                .environment(app)
        }
        .overlay(alignment: .top) {
            if let error = app.coreOpenError {
                CoreErrorBanner(message: error)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        switch app.selection {
        case .chat(let id):
            ChatView(conversationId: id)
                .id(id)
        case .project(let id):
            ProjectDetailView(projectId: id)
                .id(id)
        case .session(let id):
            LSChatView(sessionID: id)
                .id(id)
        case .newSession:
            LSNewSessionView()
        case .allChats:
            AllChatsView()
        case .allSessions:
            AllSessionsView()
        case .models:
            ModelsView()
        case .devices:
            DevicesView()
        case .server:
            ServerView()
        case .images:
            ImageGenView()
        case .privacy:
            PrivacyView()
        case .none:
            EmptyDetail()
        }
    }
}

/// Shown when nothing is selected — teaches the two ways to start rather than
/// leaving an empty pane.
struct EmptyDetail: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: PocketSpacing.s12) {
            PocketMarkView(state: .idle, size: 44)
            Text("Nothing open")
                .font(.pocket(.title))
            Text(
                "Press ⌘N to start a chat, or ⌘K to jump to anything — a chat, a project, a live session."
            )
            .font(.pocket(.footnote))
            .foregroundStyle(PocketColor.textSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
            Button("New chat") { app.newChat() }
                .buttonStyle(.hudProminent)
                .padding(.top, PocketSpacing.s4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PocketColor.bgCanvas)
    }
}

/// Degraded-core banner. The app stays usable; this says what is broken.
struct CoreErrorBanner: View {
    let message: String
    @State private var dismissed = false

    var body: some View {
        if !dismissed {
            HStack(alignment: .top, spacing: PocketSpacing.s8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(PocketColor.statusWarn)
                Text(message)
                    .font(.pocket(.footnote))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button {
                    dismissed = true
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(PocketColor.textTertiary)
            }
            .padding(PocketSpacing.s12)
            .hudPanel(PocketColor.statusWarn.opacity(0.10))
            .padding(PocketSpacing.s12)
            .frame(maxWidth: 640)
        }
    }
}

extension PairingRequest: @retroactive Identifiable {}
