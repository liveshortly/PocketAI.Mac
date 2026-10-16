import SwiftUI
import AppKit
import PocketKit
import PocketUI

/// MAC-06: Server (M-SRV), `02` §7.6. Status row + on/off, LAN toggle,
/// local API key generate/rotate/copy, and code samples (curl/Python/JS) pre-filled with
/// the real base URL and key.
struct MacServerView: View {
    @Environment(AppModel.self) private var model

    private enum SampleLang: String, CaseIterable {
        case curl = "cURL"
        case python = "Python (OpenAI SDK)"
        case javascript = "JavaScript"
    }

    @State private var hasKey = false
    @State private var revealedKey: String?
    @State private var showRotateConfirm = false
    @State private var selectedLang = SampleLang.curl

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
                    Picker("Language", selection: $selectedLang) {
                        ForEach(SampleLang.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .padding(.bottom, PocketSpacing.s4)

                    VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                        Text(activeSampleCode)
                            .font(.pocket(.mono))
                            .textSelection(.enabled)
                            .padding(PocketSpacing.s8)
                            .background(PocketColor.bgCanvas)
                            .clipShape(RoundedRectangle(cornerRadius: 6))

                        HStack {
                            Spacer()
                            Button("Copy Code") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(activeSampleCode, forType: .string)
                            }
                        }
                    }
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

    private var activeSampleCode: String {
        switch selectedLang {
        case .curl:
            return curlSample
        case .python:
            return pythonSample
        case .javascript:
            return javascriptSample
        }
    }

    private var keyString: String {
        revealedKey ?? "<your-api-key>"
    }

    private var curlSample: String {
        """
        curl http://127.0.0.1:\(status.port)/v1/chat/completions \\
          -H "Authorization: Bearer \(keyString)" \\
          -H "Content-Type: application/json" \\
          -d '{"model": "default", "messages": [{"role": "user", "content": "Hello"}]}'
        """
    }

    private var pythonSample: String {
        """
        from openai import OpenAI

        client = OpenAI(
            base_url="http://127.0.0.1:\(status.port)/v1",
            api_key="\(keyString)"
        )

        response = client.chat.completions.create(
            model="default",
            messages=[{"role": "user", "content": "Hello"}]
        )

        print(response.choices[0].message.content)
        """
    }

    private var javascriptSample: String {
        """
        import OpenAI from "openai";

        const client = new OpenAI({
            baseURL: "http://127.0.0.1:\(status.port)/v1",
            apiKey: "\(keyString)"
        });

        const response = await client.chat.completions.create({
            model: "default",
            messages: [{ role: "user", content: "Hello" }]
        });

        console.log(response.choices[0].message.content);
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
