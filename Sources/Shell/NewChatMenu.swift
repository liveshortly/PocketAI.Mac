import PocketKit
import PocketLiveShortly
import PocketUI
import SwiftUI

/// Starting something new, in one place: a local chat on a model you pick, or
/// an agent session on one of your machines. Both are conversations, so both
/// start from the same control.
///
/// ⌘N still makes a chat on the current default without asking — the menu is
/// for when the choice matters, not a toll on every new chat.
struct NewChatMenu: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Menu {
            let models = app.installedChatModels()
            if models.isEmpty {
                Button("Download a model…") { app.selection = .models }
            } else {
                Section("Chat on this Mac") {
                    ForEach(models, id: \.manifest.id) { entry in
                        Button {
                            app.newChat(modelId: entry.manifest.id)
                            NotificationCenter.default.post(
                                name: .pocketConversationsChanged, object: nil)
                        } label: {
                            if entry.manifest.id == app.currentModelId {
                                Label(menuLabel(entry), systemImage: "checkmark")
                            } else {
                                Text(menuLabel(entry))
                            }
                        }
                    }
                }
            }
            if app.liveShortly.isConnected {
                Section("LiveShortly") {
                    Button("New agent session…") { app.selection = .newSession }
                }
            }
            Divider()
            Button("Model library…") { app.selection = .models }
        } label: {
            Label("New chat", systemImage: "plus.circle.fill")
                .foregroundStyle(PocketColor.accent)
        } primaryAction: {
            // Clicking the row itself keeps the fast path.
            app.newChat()
            NotificationCenter.default.post(name: .pocketConversationsChanged, object: nil)
        }
        .menuStyle(.borderlessButton)
        .help("Click to start a chat, or open the menu to pick a model or an agent session")
    }

    /// Model name plus which engine runs it, so GGUF and MLX are
    /// distinguishable at the moment of choosing.
    private func menuLabel(_ entry: CatalogEntry) -> String {
        "\(entry.manifest.displayName) · \(entry.manifest.format.badge)"
    }
}
