import PocketKit
import ServiceManagement
import PocketLiveShortly
import PocketUI
import SwiftUI

/// Settings window. Four tabs, each one screen — nothing nested deeper.
struct SettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            ModelSettings()
                .tabItem { Label("Models", systemImage: "cpu") }
            LiveShortlySettings()
                .tabItem { Label("LiveShortly", systemImage: "dot.radiowaves.left.and.right") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .background(PocketColor.bgCanvas)
    }
}

struct GeneralSettings: View {
    @Environment(AppModel.self) private var app
    @AppStorage("app.getpocketai.mac.appearance") private var appearance = "auto"
    /// Read from the login-item service itself, so the switch shows what macOS
    /// actually does rather than what was last tapped.
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginItemError: String?

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
                Toggle(
                    "Offline mode",
                    isOn: Binding(
                        get: { app.core.isOffline() },
                        set: { app.core.setOfflineMode(on: $0) })
                )
                Text("Blocks every outbound request, including model downloads.")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
            } header: {
                HUDLabel("Privacy")
            }
            Section {
                Button("Stop everything") { app.stopEverything() }
                    .buttonStyle(.hudDestructive)
                Text("Cancels generation, stops the local server, unloads models.")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
            } header: {
                HUDLabel("Panic")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(PocketColor.bgCanvas)
        .onChange(of: appearance) { _, value in
            NSApp.appearance = switch value {
            case "light": NSAppearance(named: .aqua)
            case "dark": NSAppearance(named: .darkAqua)
            default: nil
            }
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
                Picker("Default model", selection: Binding(
                    get: { app.currentModelId },
                    set: { app.currentModelId = $0 })
                ) {
                    ForEach(app.installedChatModels(), id: \.manifest.id) { entry in
                        Text(entry.manifest.displayName).tag(entry.manifest.id)
                    }
                }
                Button("Open model library") { app.selection = .models }
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
                    try? app.core.unloadModel(id: app.currentModelId)
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

struct LiveShortlySettings: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        LSConnectView(account: app.liveShortly)
            .background(PocketColor.bgCanvas)
    }
}

struct AboutSettings: View {
    @Environment(AppModel.self) private var app
    @State private var licenseKey = ""
    @State private var activationMessage: String?

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
            } header: {
                HUDLabel("PocketAI for Mac")
            }
            Section {
                TextField("License key", text: $licenseKey)
                    .textFieldStyle(.roundedBorder)
                Button("Activate") { activate() }
                    .buttonStyle(.hudProminent)
                    .disabled(licenseKey.trimmingCharacters(in: .whitespaces).isEmpty)
                if let activationMessage {
                    Text(activationMessage)
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textSecondary)
                }
            } header: {
                HUDLabel("License")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(PocketColor.bgCanvas)
    }

    private func activate() {
        let key = licenseKey.trimmingCharacters(in: .whitespaces)
        do {
            let entitlements = try app.core.activateLicense(key: key)
            app.saveLicenseKey(key)
            activationMessage = entitlements.pro
                ? "Pro activated on this Mac." : "That key did not unlock Pro."
        } catch {
            activationMessage = "Activation failed: \(error.localizedDescription)"
        }
    }
}
