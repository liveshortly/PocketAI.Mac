import PocketKit
import ServiceManagement
import PocketLiveShortly
import PocketUI
import SwiftUI

/// Settings window. One screen per tab — nothing nested deeper.
struct SettingsView: View {
    @Environment(AppModel.self) private var app
    /// Remembered so "Enter license key…" elsewhere can land on License.
    @AppStorage(SettingsView.tabKey) private var tab = "general"
    static let tabKey = "app.getpocketai.mac.settingsTab"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            ModelSettings()
                .tabItem { Label("Models", systemImage: "cpu") }
                .tag("models")
            VoiceSettings()
                .tabItem { Label("Voice", systemImage: "waveform") }
                .tag("voice")
            LiveShortlySettings()
                .tabItem { Label { Text("LiveShortly") } icon: { Image.lsLogo } }
                .tag("liveshortly")
            LicenseSettings()
                .tabItem { Label("License", systemImage: "key") }
                .tag("license")
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag("about")
        }
        .background(PocketColor.bgCanvas)
    }
}

/// Opens Settings on the License tab — the fix action wherever a missing
/// license blocks something (Server, Devices).
struct EnterLicenseButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Enter license key…") {
            UserDefaults.standard.set("license", forKey: SettingsView.tabKey)
            openSettings()
        }
        .buttonStyle(.hud)
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var app
    @AppStorage(GeneralSettings.appearanceKey) private var appearance = "auto"
    /// Read from the login-item service itself, so the switch shows what macOS
    /// actually does rather than what was last tapped.
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?
    @State private var confirmStop = false

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLoginItem(enabled) }
                if let loginItemError {
                    Text(loginItemError)
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.statusBad)
                }
                Picker("Appearance", selection: $appearance) {
                    Text("Auto").tag("auto")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
            } header: {
                HUDLabel("Window")
            }
            Section {
                Toggle("Offline mode", isOn: Binding(
                    get: { app.offlineMode.isOn },
                    set: { app.offlineMode.set($0) }))
                Text("Blocks every outbound request, including model downloads.")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
            } header: {
                HUDLabel("Privacy")
            }
            Section {
                Button("Stop everything…") { confirmStop = true }
                    .buttonStyle(.hudDestructive)
                Text("Cancels generation, stops the local server, unloads models.")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
            } header: {
                HUDLabel("Emergency stop")
            }
        }
        .confirmationDialog("Stop everything?", isPresented: $confirmStop) {
            Button("Stop everything", role: .destructive) { app.stopEverything() }
        } message: {
            Text("Replies stop mid-sentence, paired devices lose this Mac until you set Access again in Server, and models must reload.")
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(PocketColor.bgCanvas)
        .onChange(of: appearance) { _, value in Self.applyAppearance(value) }
    }

    static let appearanceKey = "app.getpocketai.mac.appearance"

    /// Also run at launch, or a saved Light/Dark only took effect after
    /// the picker was touched again.
    static func applyAppearance(
        _ value: String? = UserDefaults.standard.string(forKey: appearanceKey)
    ) {
        NSApp.appearance = switch value {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
        }
    }

    /// Registers or removes the app as a login item. An unsigned local build
    /// is refused by macOS, so the switch reports that instead of lying.
    private func setLoginItem(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginItemError = nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            loginItemError =
                "macOS refused to change this: \(error.localizedDescription). "
                + "A signed build is usually required."
        }
    }
}

struct ModelSettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Form {
            Section {
                if app.installedChatModels().isEmpty {
                    Text("No chat models installed yet. Get one from the model library.")
                        .font(.pocket(.callout))
                        .foregroundStyle(PocketColor.textSecondary)
                } else {
                    Picker("Default model", selection: Binding(
                        get: { app.currentModelId },
                        set: { app.currentModelId = $0 })
                    ) {
                        ForEach(app.installedChatModels(), id: \.manifest.id) { entry in
                            Text(ModelNaming.short(entry.manifest.displayName)).tag(entry.manifest.id)
                        }
                    }
                }
                // Settings is its own window: `reveal` brings the shell forward
                // so the library it just opened is what the keyboard reaches.
                Button("Open model library") { app.reveal(.models) }
                    .buttonStyle(.hud)
            } header: {
                HUDLabel("Chat")
            }
            Section {
                LabeledContent("Installed") {
                    Text("\(app.installedChatModels().count)")
                        .monospacedDigit()
                }
                Button("Unload current model from memory") {
                    do { try app.core.unloadModel(id: app.currentModelId) } catch {
                        app.toast("Couldn't unload the model: \(error.localizedDescription)")
                    }
                }
                .buttonStyle(.hud)
            } header: {
                HUDLabel("Memory")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(PocketColor.bgCanvas)
    }
}

/// Speech: which voice reads replies, and whether they are read automatically.
struct VoiceSettings: View {
    @State private var speech = ReadAloud.shared
    @AppStorage("app.getpocketai.mac.autoSpeak") private var autoSpeak = false
    private let voices = ReadAloud.availableVoices()

    var body: some View {
        Form {
            Section {
                Picker("Voice", selection: Binding(
                    get: { speech.voiceIdentifier ?? "" },
                    set: { speech.voiceIdentifier = $0.isEmpty ? nil : $0 })
                ) {
                    Text("System default").tag("")
                    ForEach(voices, id: \.identifier) { voice in
                        Text("\(voice.name) · \(voice.language)").tag(voice.identifier)
                    }
                }
                Button(speech.speakingId == "settings-preview" ? "Stop preview" : "Preview") {
                    speech.toggle(
                        "This is how replies will sound.", id: "settings-preview")
                }
                .buttonStyle(.hud)
            } header: {
                HUDLabel("Read aloud")
            }
            Section {
                Toggle("Speak replies automatically", isOn: $autoSpeak)
                Text("Every finished reply is read out. Stop it from the reply itself.")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(PocketColor.bgCanvas)
    }
}

struct LiveShortlySettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        LSConnectView(account: app.liveShortly)
            .background(PocketColor.bgCanvas)
    }
}

struct AboutSettings: View {
    @Environment(AppModel.self) private var app

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (\(b))"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Version") { Text(version).monospacedDigit() }
                LabeledContent("Plan") {
                    Text(app.core.entitlements().pro ? "Pro" : "Free")
                }
                .help("Manage it in the License tab.")
            } header: {
                HUDLabel("PocketAI for Mac")
            }
            Section {
                engineRow("MLX", "Apple silicon, .safetensors models")
                engineRow("llama.cpp", "GGUF models, built in")
                engineRow("Apple Intelligence", "System model, macOS 15.1+ on supported Macs")
                Text("A model's badge in the library says which engine runs it.")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
            } header: {
                HUDLabel("Engines")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(PocketColor.bgCanvas)
    }

    private func engineRow(_ name: String, _ detail: String) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.pocket(.body))
                Text(detail)
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Pro license (D133 testing phase: a Keygen key from the owner). Verifies
/// offline; the key is kept in the Keychain and re-activated on launch.
struct LicenseSettings: View {
    @Environment(AppModel.self) private var app
    @State private var licenseKey = ""
    @State private var result: (ok: Bool, text: String)?
    /// `core` isn't observable, so the plan row re-reads after activating.
    @State private var entitlements: Entitlements?

    var body: some View {
        Form {
            Section {
                LabeledContent("Plan") {
                    Text(planText).monospacedDigit()
                }
                if entitlements?.pro == true, let suffix = app.licenseKeySuffix {
                    LabeledContent("Key") {
                        Text("ending \(suffix)").monospaced()
                    }
                }
                if entitlements?.pro != true {
                    Text("Pro lets paired iPhones and other devices on your network use this Mac's models. Everything on this Mac stays free.")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textTertiary)
                }
            } header: {
                HUDLabel("PocketAI Pro")
            }
            Section {
                TextField("License key", text: $licenseKey, prompt: Text("Paste your key"))
                    .textFieldStyle(.roundedBorder)
                    .font(.pocket(.mono))
                    .autocorrectionDisabled()
                    .onSubmit { if !trimmedKey.isEmpty { activate() } }
                HStack {
                    if let result {
                        Label(result.text, systemImage: result.ok
                              ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.pocket(.caption))
                            .foregroundStyle(result.ok ? PocketColor.statusOk : PocketColor.statusBad)
                    }
                    Spacer(minLength: 0)
                    if result?.ok == true {
                        Button("Pair a device…") { app.pairDevice() }
                            .buttonStyle(.hud)
                    }
                    Button("Activate") { activate() }
                        .buttonStyle(.hudProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(trimmedKey.isEmpty)
                }
                Text("Checked on this Mac, no internet needed. The key is stored in your Keychain.")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
            } header: {
                HUDLabel(entitlements?.pro == true ? "Replace license key" : "Have a license key?")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(PocketColor.bgCanvas)
        .onAppear { entitlements = app.core.entitlements() }
    }

    /// Pasted keys often carry a trailing newline.
    private var trimmedKey: String {
        licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var planText: String {
        guard let entitlements, entitlements.pro else { return "Free" }
        guard let ms = entitlements.expiresAtMs else { return "Pro" }
        let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
        return "Pro · until \(date.formatted(date: .abbreviated, time: .omitted))"
    }

    private func activate() {
        let key = trimmedKey
        do {
            let ent = try app.core.activateLicense(key: key)
            app.saveLicenseKey(key)
            entitlements = app.core.entitlements()
            if ent.pro {
                licenseKey = ""
                result = (true, "Pro is on for this Mac.")
            } else {
                result = (false, "That key is valid but doesn't include Pro.")
            }
        } catch {
            result = (false, "That key didn't activate: \(error.localizedDescription)")
        }
    }
}
