import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PocketKit
import PocketUI

/// MAC-06: Server (M-SRV), 02-design-system.md §7.6.
/// Award-winning glanceable status hero, live stat tiles, grouped network controls,
/// secure API key management, and interactive code samples with instant copy.
struct MacServerView: View {
    @Environment(AppModel.self) private var model

    private enum SampleLang: String, CaseIterable {
        case curl = "cURL"
        case python = "Python (OpenAI)"
        case javascript = "JavaScript (Node)"
    }

    @State private var hasKey = false
    @State private var revealedKey: String?
    @State private var showRotateConfirm = false
    @State private var selectedLang = SampleLang.curl
    @State private var copiedKeyFeedback = false
    @State private var copiedCodeFeedback = false

    private var status: ServerStatus { model.serverStatus }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PocketSpacing.s20) {
                // Glanceable Status Hero Card
                statusHeroCard

                // Stat Tiles Row (when running)
                if status.running {
                    statTilesRow
                }

                // Configuration Form
                VStack(alignment: .leading, spacing: PocketSpacing.s16) {
                    Text("NETWORK & SECURITY")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(PocketColor.textTertiary)

                    VStack(spacing: PocketSpacing.s12) {
                        Toggle("Serve on Local Network (LAN)", isOn: Binding(
                            get: { status.lanEnabled },
                            set: { lan in if status.running { toggleServer(true, lan: lan) } }
                        ))
                        .font(.pocket(.body))
                        .disabled(!status.running)

                        if status.lanEnabled && status.running {
                            HStack(spacing: PocketSpacing.s8) {
                                Image(systemName: "wifi")
                                    .foregroundStyle(PocketColor.statusOk)
                                Text("Available to paired iPhones and other devices on your local Wi-Fi.")
                                    .font(.pocket(.caption))
                                    .foregroundStyle(PocketColor.textSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        Divider()

                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("TLS Certificate")
                                    .font(.pocket(.body))
                                    .foregroundStyle(PocketColor.textPrimary)
                                Text("Self-signed certificate for secure LAN connections and custom clients.")
                                    .font(.pocket(.caption))
                                    .foregroundStyle(PocketColor.textSecondary)
                            }

                            Spacer()

                            Button("Export Certificate…") {
                                exportCertificate()
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(PocketSpacing.s16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(PocketColor.bgSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(PocketColor.lineHairline, lineWidth: 0.8)
                    )
                }

                // Local API Key Card
                apiKeySection

                // Interactive Code Samples
                if status.running {
                    codeSamplesSection
                }
            }
            .padding(PocketSpacing.gutterMac)
            .frame(maxWidth: 800)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(PocketColor.bgCanvas)
        .task { reload() }
        .confirmationDialog(
            "Rotate the local API key?",
            isPresented: $showRotateConfirm,
            titleVisibility: .visible
        ) {
            Button("Rotate Key", role: .destructive) { generateKey() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Any apps or scripts currently using the old API key will stop working until you update them with the new key.")
        }
    }

    private var statusHeroCard: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s12) {
            HStack(spacing: PocketSpacing.s16) {
                // Status pulse dot
                ZStack {
                    Circle()
                        .fill(status.running ? PocketColor.statusOk.opacity(0.2) : PocketColor.textTertiary.opacity(0.15))
                        .frame(width: 24, height: 24)
                    Circle()
                        .fill(status.running ? PocketColor.statusOk : PocketColor.textTertiary)
                        .frame(width: 10, height: 10)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(status.running ? "Local API Server Running" : "Local API Server Stopped")
                        .font(.pocket(.title))
                        .fontWeight(.bold)
                        .foregroundStyle(PocketColor.textPrimary)

                    Text(status.running
                        ? "OpenAI-compatible endpoints active at http://127.0.0.1:\(status.port)/v1"
                        : "Expose on-device models to Cursor, Continue, or custom developer scripts."
                    )
                    .font(.pocket(.callout))
                    .foregroundStyle(PocketColor.textSecondary)
                }

                Spacer(minLength: PocketSpacing.s16)

                if status.running {
                    Button {
                        toggleServer(false)
                    } label: {
                        Label("Stop Server", systemImage: "stop.fill")
                    }
                    .buttonStyle(.pocketSecondary)
                    .controlSize(.large)
                } else {
                    Button {
                        toggleServer(true)
                    } label: {
                        Label("Start Server", systemImage: "play.fill")
                    }
                    .buttonStyle(.pocketPrimary)
                    .controlSize(.large)
                }
            }
            .frame(maxWidth: .infinity)

            if status.running {
                Divider()

                HStack(spacing: PocketSpacing.s16) {
                    HStack(spacing: 6) {
                        Text("Base URL:")
                            .font(.pocket(.caption))
                            .foregroundStyle(PocketColor.textSecondary)
                        Text("http://127.0.0.1:\(status.port)/v1")
                            .font(.pocket(.mono))
                            .foregroundStyle(PocketColor.textPrimary)
                    }

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("http://127.0.0.1:\(status.port)/v1", forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help("Copy Base URL")

                    Spacer()

                    Text("Protocol: OpenAI API v1")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textTertiary)
                }
            }
        }
        .padding(PocketSpacing.s20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PocketColor.bgRaised)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(status.running ? PocketColor.statusOk.opacity(0.3) : PocketColor.lineHairline, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.04), radius: 8, y: 3)
    }

    private var statTilesRow: some View {
        HStack(spacing: PocketSpacing.s12) {
            statCard(label: "Connected Devices", value: "\(status.connectedDevices)", icon: "iphone")
            statCard(label: "Serving Port", value: ":\(status.port)", icon: "network")
            statCard(label: "Local Interface", value: "127.0.0.1", icon: "laptopcomputer")
        }
    }

    private func statCard(label: String, value: String, icon: String) -> some View {
        HStack(spacing: PocketSpacing.s12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(PocketColor.accent)
                .frame(width: 36, height: 36)
                .background(PocketColor.accentSoft)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textSecondary)
                Text(value)
                    .font(.pocket(.headline))
                    .foregroundStyle(PocketColor.textPrimary)
            }
            Spacer()
        }
        .padding(PocketSpacing.s12)
        .background(PocketColor.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(PocketColor.lineHairline, lineWidth: 0.8)
        )
    }

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s8) {
            Text("LOCAL API KEY")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(PocketColor.textTertiary)

            VStack(alignment: .leading, spacing: PocketSpacing.s12) {
                if let revealedKey {
                    VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                        HStack {
                            Text(revealedKey)
                                .font(.pocket(.mono))
                                .textSelection(.enabled)
                                .foregroundStyle(PocketColor.textPrimary)
                            Spacer()
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(revealedKey, forType: .string)
                                copiedKeyFeedback = true
                                Task {
                                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                                    copiedKeyFeedback = false
                                }
                            } label: {
                                Label(copiedKeyFeedback ? "Copied" : "Copy", systemImage: copiedKeyFeedback ? "checkmark" : "doc.on.doc")
                                    .font(.pocket(.caption))
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(PocketSpacing.s12)
                        .background(PocketColor.bgSunken)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        Text("Shown once — copy it now. You won't be able to view this secret again.")
                            .font(.pocket(.caption))
                            .foregroundStyle(PocketColor.statusWarn)
                    }
                } else if hasKey {
                    HStack {
                        Text("••••••••••••••••••••••••••••••••")
                            .font(.pocket(.mono))
                            .foregroundStyle(PocketColor.textSecondary)
                        Spacer()
                        Text("Active")
                            .font(.pocket(.caption))
                            .foregroundStyle(PocketColor.statusOk)
                    }
                    .padding(PocketSpacing.s12)
                    .background(PocketColor.bgSunken)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Text("No local API key generated yet. Generate a key to authenticate external requests.")
                        .font(.pocket(.callout))
                        .foregroundStyle(PocketColor.textSecondary)
                }

                HStack {
                    Button(hasKey ? "Rotate Key…" : "Generate API Key") {
                        if hasKey {
                            showRotateConfirm = true
                        } else {
                            generateKey()
                        }
                    }
                    .buttonStyle(.bordered)

                    Spacer()
                }
            }
            .padding(PocketSpacing.s16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PocketColor.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(PocketColor.lineHairline, lineWidth: 0.8)
            )
        }
    }

    private var codeSamplesSection: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s8) {
            HStack {
                Text("INTEGRATION CODE SAMPLES")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PocketColor.textTertiary)

                Spacer()

                Picker("", selection: $selectedLang) {
                    ForEach(SampleLang.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)
            }

            VStack(alignment: .leading, spacing: PocketSpacing.s12) {
                // Code box
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(activeSampleCode)
                        .font(.pocket(.mono))
                        .textSelection(.enabled)
                        .padding(PocketSpacing.s12)
                }
                .background(PocketColor.bgSunken)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                HStack {
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(activeSampleCode, forType: .string)
                        copiedCodeFeedback = true
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            copiedCodeFeedback = false
                        }
                    } label: {
                        Label(copiedCodeFeedback ? "Copied" : "Copy Code", systemImage: copiedCodeFeedback ? "checkmark" : "doc.on.doc")
                            .font(.pocket(.callout))
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(PocketSpacing.s16)
            .background(PocketColor.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(PocketColor.lineHairline, lineWidth: 0.8)
            )
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
          -d '{
            "model": "default",
            "messages": [{"role": "user", "content": "Hello PocketAI"}]
          }'
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
            messages=[{"role": "user", "content": "Hello PocketAI"}]
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
            messages: [{ role: "user", content: "Hello PocketAI" }]
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

    private func exportCertificate() {
        let panel = NSSavePanel()
        panel.title = "Export Certificate"
        panel.nameFieldStringValue = "pocketai-host.pem"
        if let pemType = UTType(filenameExtension: "pem") {
            panel.allowedContentTypes = [pemType, .plainText]
        } else {
            panel.allowedContentTypes = [.plainText]
        }

        if panel.runModal() == .OK, let url = panel.url {
            let pem = model.core.hostCertPem()
            try? pem.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
