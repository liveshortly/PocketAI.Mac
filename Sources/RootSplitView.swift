import SwiftUI
import AppKit
import PocketKit
import PocketUI

/// Mac shell per 02-design-system.md: NavigationSplitView sidebar + content.
/// Sidebar items: Chats, Projects, Models, Devices, Server, Privacy.
/// Pinned PulseStrip at the bottom of the sidebar.
/// Window toolbar with new chat, model chip, Pulse mini, and sidebar toggle per MAC-02.
struct RootSplitView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.hasOnboarded {
            MacOnboardingFlow(
                core: model.core,
                deviceProfile: model.hooks.deviceProfile(),
                onFinished: { model.hasOnboarded = true },
                onOpenDevices: {
                    model.hasOnboarded = true
                    model.selectedTab = .devices
                }
            )
        } else {
            shell
        }
    }

    private var shell: some View {
        @Bindable var m = model
        return NavigationSplitView {
            List(AppModel.SidebarItem.allCases, selection: $m.selectedTab) { item in
                Label(item.rawValue, systemImage: item.icon).tag(item)
            }
            .navigationTitle("PocketAI")
            .safeAreaInset(edge: .bottom) {
                sidebarPulse
            }
        } detail: {
            switch model.selectedTab {
            case .chats:
                MacChatsView()
            case .projects:
                MacProjectsView()
            case .models:
                MacModelsView()
            case .server:
                MacServerView()
            case .devices:
                MacDevicesView()
            case .privacy:
                MacPrivacyView()
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
                } label: {
                    Image(systemName: "sidebar.leading")
                }
                .help("Toggle Sidebar")
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.selectedTab = .chats
                    model.pendingCommand = .newChat
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                }
                .help("New Chat (⌘N)")
            }

            ToolbarItem(placement: .status) {
                HStack(spacing: PocketSpacing.s8) {
                    Button {
                        model.selectedTab = .models
                    } label: {
                        HStack(spacing: PocketSpacing.s4) {
                            PocketMarkView(state: model.isGenerating ? .working(tokPerSec: 28) : .idle, size: 14)
                            Text("Qwen3 4B")
                                .font(.pocket(.caption))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(PocketColor.bgSurface)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Active Model")

                    if model.isGenerating {
                        Text("28 tok/s")
                            .font(.pocket(.metric))
                            .foregroundStyle(PocketColor.accent)
                    }
                }
            }
        }
        .onChange(of: model.pendingCommand) { _, command in
            switch command {
            case .openTab(let tab):
                model.selectedTab = tab
                model.pendingCommand = nil
            case .newChat, .focusComposer, .stopGeneration, .openConversation, .none:
                break
            }
        }
    }

    private var sidebarPulse: some View {
        VStack(spacing: 0) {
            Divider()
            PulseStrip(
                state: model.isGenerating
                    ? .generating(modelName: "This Mac", location: "On this Mac", tokPerSec: 28)
                    : (model.core.isOffline() ? .offlineMode : .idle),
                onTap: {}
            )
            .padding(PocketSpacing.s8)
        }
        .background(PocketColor.bgCanvas)
    }
}

/// MAC-08: menu bar popover. Pulse, model switcher, server toggle (+ LAN state),
/// connected devices, Open PocketAI, and Stop everything (with confirmation).
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var showStopConfirm = false
    @State private var installedModels: [CatalogEntry] = []
    @AppStorage("app.getpocketai.keepRunningInBackground") private var keepRunningInBackground = true

    private var status: ServerStatus { model.serverStatus }

    var body: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s12) {
            HStack(spacing: PocketSpacing.s8) {
                PocketMarkView(
                    state: model.isGenerating ? .working(tokPerSec: 28) : (status.running ? .working(tokPerSec: nil) : .idle),
                    size: 24
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text("PocketAI").font(.pocket(.headline))
                    if model.isGenerating {
                        Text("Generating · 28 tok/s")
                            .font(.pocket(.caption))
                            .foregroundStyle(PocketColor.accent)
                    } else if status.running {
                        Text("Server Active · :\(status.port)")
                            .font(.pocket(.caption))
                            .foregroundStyle(PocketColor.statusOk)
                    }
                }
            }

            // Model switcher per MAC-08
            if !installedModels.isEmpty {
                VStack(alignment: .leading, spacing: PocketSpacing.s4) {
                    Text("Model").font(.pocket(.footnote)).foregroundStyle(PocketColor.textSecondary)
                    Menu {
                        ForEach(installedModels, id: \.manifest.id) { entry in
                            Button(entry.manifest.displayName) {
                                // Select model
                            }
                        }
                    } label: {
                        Text(installedModels.first?.manifest.displayName ?? "Select Model")
                            .font(.pocket(.body))
                    }
                }
            }

            Toggle("Server running", isOn: Binding(
                get: { status.running },
                set: { on in on ? model.startServer(lan: status.lanEnabled) : model.stopServer() }
            ))
            Toggle("Serve on local network", isOn: Binding(
                get: { status.lanEnabled },
                set: { lan in if status.running { model.startServer(lan: lan) } }
            ))
            .disabled(!status.running)

            if status.running {
                Text("\(status.connectedDevices) connected device\(status.connectedDevices == 1 ? "" : "s")")
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textSecondary)
            }

            Toggle("Keep running in menu bar", isOn: $keepRunningInBackground)
                .font(.pocket(.footnote))

            Divider()

            Button("Open PocketAI") {
                NSApp.activate(ignoringOtherApps: true)
                for window in NSApp.windows where window.canBecomeKey {
                    window.makeKeyAndOrderFront(nil)
                    break
                }
            }
            Button("Stop Everything") { showStopConfirm = true }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .padding(PocketSpacing.s16)
        .frame(width: 260)
        .confirmationDialog(
            "Stop everything?",
            isPresented: $showStopConfirm,
            titleVisibility: .visible
        ) {
            Button("Stop Everything", role: .destructive) { model.stopEverything() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Stops any in-progress replies and turns off the server.")
        }
        .task {
            model.refreshServerStatus()
            installedModels = model.core.catalog(filter: CatalogFilter(modality: nil, curatedOnly: false, installedOnly: true))
            if installedModels.isEmpty {
                installedModels = model.core.catalog(filter: CatalogFilter(modality: nil, curatedOnly: true, installedOnly: false))
            }
        }
    }
}
