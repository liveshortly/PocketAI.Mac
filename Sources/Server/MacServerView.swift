import SwiftUI
import PocketKit
import PocketUI

/// MAC-06: Server (M-SRV), `02` §7.6. Status row + on/off, LAN toggle,
/// local API key generate/rotate/copy, and code samples pre-filled with
/// the real base URL and key. Not implemented: the request log table
/// (no per-request event feed wired into CoreClient yet) and "Export
/// certificate" (pocket-trust generates a TLS identity but there's no
/// FFI path to export its PEM) - both left as plain notes rather than
/// built as non-functional UI.
struct MacServerView: View {
    @Environment(AppModel.self) private var model

    @State private var hasKey = false
    @State private var revealedKey: String?
    @State private var showRotateConfirm = false

    private var status: ServerStatus { model.serverStatus }

    var body: some View {
        Form {
            Section {
                Toggle("Server running", isOn: Binding(
                    get: { status.running },
                    set: { toggleServer($0) }
                ))
                if status.running {
                    LabeledContent("Serving on", value: "127.0.0.1:\(status.port)" + (status.lanEnabled ? " and on your LAN" : ""))
                    StatTile(label: "Connected devices", value: "\(status.connectedDevices)")
                }
                Toggle("Serve on local network", isOn: Binding(
                    get: { status.lanEnabled },
                    set: { lan in if status.running { toggleServer(true, lan: lan) } }
                ))
                .disabled(!status.running)
            }

            Section("Local API key") {
                if let revealedKey {
                    LabeledContent("Key") {
                        Text(revealedKey).font(.pocket(.mono)).textSelection(.enabled)
                    }
                    Text("Shown once - copy it now. You won't be able to see it again.")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textTertiary)
                } else if hasKey {
                    LabeledContent("Key", value: "••••••••••••••••")
                } else {
                    Text("No local API key yet.").font(.pocket(.footnote)).foregroundStyle(PocketColor.textSecondary)
                }
                Button(hasKey ? "Rotate Key" : "Generate Key") {
                    if hasKey {
                        showRotateConfirm = true
                    } else {
                        generateKey()
                    }
                }
            }

            if status.running {
                Section("Code samples") {
                    Text(curlSample).font(.pocket(.mono)).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .task { reload() }
        .confirmationDialog(
            "Rotate the local API key?",
            isPresented: $showRotateConfirm,
            titleVisibility: .visible
        ) {
            Button("Rotate", role: .destructive) { generateKey() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Anything using the old key (curl, scripts, Cursor) will stop working until you update it.")
        }
    }

    private var curlSample: String {
        """
        curl http://127.0.0.1:\(status.port)/v1/chat/completions \\
          -H "Authorization: Bearer \(revealedKey ?? "<your key>")" \\
          -H "Content-Type: application/json" \\
          -d '{"model": "default", "messages": [{"role": "user", "content": "Hello"}]}'
        """
    }

    private func reload() {
        model.refreshServerStatus()
        hasKey = model.core.hasLocalApiKey()
    }

    private func toggleServer(_ on: Bool, lan: Bool? = nil) {
        if on {
            model.startServer(lan: lan ?? status.lanEnabled)
        } else {
            model.stopServer()
        }
    }

    private func generateKey() {
        revealedKey = model.core.generateLocalApiKey()
        hasKey = true
    }
}
