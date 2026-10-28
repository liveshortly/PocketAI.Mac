import SwiftUI
import AppKit
import PocketKit
import PocketUI

/// Non-crashing surface for a core-open failure (replaces the old fatalError).
private struct MacCoreErrorBanner: View {
    let message: String
    @State private var dismissed = false
    var body: some View {
        if !dismissed {
            HStack(alignment: .top, spacing: PocketSpacing.s8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(PocketColor.statusBad)
                Text(message)
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: PocketSpacing.s8)
                Button { dismissed = true } label: {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(PocketColor.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(PocketSpacing.s12)
            .frame(maxWidth: 520)
            .background(PocketColor.bgRaised, in: RoundedRectangle(cornerRadius: PocketRadius.card))
            .overlay(RoundedRectangle(cornerRadius: PocketRadius.card).strokeBorder(PocketColor.statusBad.opacity(0.4)))
            .padding(.top, PocketSpacing.s12)
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
    }
}

/// Real process memory footprint (phys_footprint) — honest instruments, not a
/// fabricated constant. Shared by the Pulse detail sheet.
func appUsedMemoryBytes() -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
}

/// Mac shell per 02-design-system.md §6.2: NavigationSplitView sidebar + content.
/// Sidebar items: Chats, Projects, Models, Server, Devices, Privacy.
/// Grouped sidebar sections, native translucent chrome, pinned Pulse status footer,
/// and a unified toolbar with model switcher popover.
struct RootSplitView: View {
    @Environment(AppModel.self) private var model
    @State private var isModelPopoverPresented = false
    @State private var isPulseSheetPresented = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        if !model.hasOnboarded {
            MacOnboardingFlow(
                core: model.core,
                deviceProfile: model.hooks.deviceProfile(),
                onFinished: { model.hasOnboarded = true },
                onOpenDevices: {
                    model.hasOnboarded = true
                    model.selectedTab = .devices
                },
                onModelPicked: { model.currentModelId = $0 }
            )
        } else {
            shell
                .overlay(alignment: .top) {
                    if let err = model.coreOpenError {
                        MacCoreErrorBanner(message: err)
                    }
                }
        }
    }

    private var shell: some View {
        @Bindable var m = model
        return NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $m.selectedTab) {
                Section("WORKSPACE") {
                    Label {
                        Text("Chats")
                            .font(.pocket(.body))
                    } icon: {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .tag(AppModel.SidebarItem.chats)

                    Label {
                        Text("Projects")
                            .font(.pocket(.body))
                    } icon: {
                        Image(systemName: "folder")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .tag(AppModel.SidebarItem.projects)
                }

                Section("SYSTEM") {
                    Label {
                        Text("Models")
                            .font(.pocket(.body))
                    } icon: {
                        Image(systemName: "cpu")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .tag(AppModel.SidebarItem.models)

                    Label {
                        HStack {
                            Text("Server")
                                .font(.pocket(.body))
                            Spacer()
                            if model.serverStatus.running {
                                Circle()
                                    .fill(PocketColor.statusOk)
                                    .frame(width: 7, height: 7)
                            }
                        }
                    } icon: {
                        Image(systemName: "server.rack")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .tag(AppModel.SidebarItem.server)

                    Label {
                        Text("Devices")
                            .font(.pocket(.body))
                    } icon: {
                        Image(systemName: "iphone")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .tag(AppModel.SidebarItem.devices)

                    Label {
                        HStack {
                            Text("Privacy")
                                .font(.pocket(.body))
                            Spacer()
                            if model.core.isOffline() {
                                Image(systemName: "airplane")
                                    .font(.system(size: 11))
                                    .foregroundStyle(PocketColor.statusWarn)
                            }
                        }
                    } icon: {
                        Image(systemName: "hand.raised")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .tag(AppModel.SidebarItem.privacy)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("PocketAI")
            .safeAreaInset(edge: .bottom) {
                sidebarStatusFooter
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
        .frame(minWidth: 960, minHeight: 640)
        .toolbar {
            ToolbarItem(placement: .principal) {
                modelSwitcherButton
            }

            ToolbarItemGroup(placement: .primaryAction) {
                if model.selectedTab == .chats {
                    Button {
                        model.selectedTab = .chats
                        model.pendingCommand = .newChat
                    } label: {
                        Label("New Chat", systemImage: "square.and.pencil")
                    }
                    .help("New Chat (⌘N)")

                    Button {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            model.showChatInspector.toggle()
                        }
                    } label: {
                        Label("Conversation Details", systemImage: "sidebar.trailing")
                    }
                    .help("Conversation Inspector (⌥⌘I)")
                }
            }
        }
        .onChange(of: model.pendingCommand) { _, command in
            switch command {
            case .openTab(let tab):
                model.selectedTab = tab
                model.pendingCommand = nil
            case .toggleInspector:
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    model.showChatInspector.toggle()
                }
                model.pendingCommand = nil
            case .newChat, .focusComposer, .stopGeneration, .openConversation, .none:
                break
            }
        }
        // Incoming pairing approval, presented from the root so it appears on
        // any tab (AppModel polls for requests app-wide).
        .sheet(item: $m.pendingPairingRequest) { request in
            PairingApprovalSheet(request: request)
        }
        .sheet(isPresented: $isPulseSheetPresented) {
            VStack(spacing: 0) {
                HStack {
                    Text("Pulse System Status")
                        .font(.pocket(.headline))
                        .foregroundStyle(PocketColor.textPrimary)
                    Spacer()
                    Button("Done") {
                        isPulseSheetPresented = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .padding(.horizontal, PocketSpacing.s16)
                .padding(.vertical, PocketSpacing.s12)
                .background(PocketColor.bgSurface)

                Divider()

                PulseDetailSheet(
                    ramUsedBytes: appUsedMemoryBytes(),
                    ramBudgetBytes: Int64(model.hooks.deviceProfile().appMemoryLimitBytes),
                    ramTotalBytes: Int64(model.hooks.deviceProfile().totalRamBytes),
                    thermalLabel: "Nominal",
                    loadedModels: [
                        LoadedModelSummary(
                            id: model.currentModelId,
                            name: model.currentModelDisplayName,
                            residentBytes: appUsedMemoryBytes(),
                            onEject: { try? model.core.unloadModel(id: model.currentModelId) }
                        )
                    ],
                    // Honest instruments: no fabricated "measured" stat. Shows
                    // the real last-reply number only when one exists.
                    lastReply: nil,
                    egressCountToday: model.core.egressLog(limit: 0).count
                )
            }
            .frame(width: 440, height: 480)
        }
    }

    private var modelSwitcherButton: some View {
        Button {
            isModelPopoverPresented.toggle()
        } label: {
            HStack(spacing: PocketSpacing.s8) {
                PocketMarkView(state: model.isGenerating ? .working(tokPerSec: model.activeTokPerSec > 0 ? Double(model.activeTokPerSec) : nil) : .idle, size: 14)

                Text(model.currentModelDisplayName)
                    .font(.pocket(.caption))
                    .fontWeight(.medium)
                    .foregroundStyle(PocketColor.textPrimary)

                if model.isGenerating {
                    Text("\(model.activeTokPerSec) tok/s")
                        .font(.pocket(.metric))
                        .foregroundStyle(PocketColor.accent)
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(PocketColor.textTertiary)
            }
            .padding(.horizontal, PocketSpacing.s8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(PocketColor.bgRaised.opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(PocketColor.lineHairline, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help("Active Model Switcher")
        .popover(isPresented: $isModelPopoverPresented, arrowEdge: .bottom) {
            ModelSwitcherPopoverView()
                .environment(model)
        }
    }

    private var sidebarStatusFooter: some View {
        Button {
            isPulseSheetPresented = true
        } label: {
            HStack(spacing: PocketSpacing.s8) {
                PocketMarkView(
                    state: model.isGenerating ? .working(tokPerSec: model.activeTokPerSec > 0 ? Double(model.activeTokPerSec) : nil) : .idle,
                    size: 16
                )

                VStack(alignment: .leading, spacing: 1) {
                    if model.isGenerating {
                        HStack(spacing: PocketSpacing.s4) {
                            Text("Generating")
                                .font(.pocket(.caption))
                                .fontWeight(.medium)
                                .foregroundStyle(PocketColor.accent)
                            Text("· \(model.activeTokPerSec) tok/s")
                                .font(.pocket(.metric))
                                .foregroundStyle(PocketColor.accent)
                        }
                    } else if model.core.isOffline() {
                        Text("Offline Mode Active")
                            .font(.pocket(.caption))
                            .fontWeight(.medium)
                            .foregroundStyle(PocketColor.statusWarn)
                    } else if model.serverStatus.running {
                        HStack(spacing: PocketSpacing.s4) {
                            Text("Server Active")
                                .font(.pocket(.caption))
                                .fontWeight(.medium)
                                .foregroundStyle(PocketColor.statusOk)
                            Text(":\(model.serverStatus.port)")
                                .font(.pocket(.metric))
                                .foregroundStyle(PocketColor.textSecondary)
                        }
                    } else {
                        Text("Ready · On this Mac")
                            .font(.pocket(.caption))
                            .foregroundStyle(PocketColor.textSecondary)
                    }
                }

                Spacer()

                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(PocketColor.textTertiary)
            }
            .padding(.horizontal, PocketSpacing.s12)
            .padding(.vertical, PocketSpacing.s8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(PocketColor.bgRaised.opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(PocketColor.lineHairline, lineWidth: 0.5)
            )
            .padding(PocketSpacing.s8)
        }
        .buttonStyle(.plain)
        .help("System Status & Hardware Pulse")
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
                    state: model.isGenerating ? .working(tokPerSec: model.activeTokPerSec > 0 ? Double(model.activeTokPerSec) : nil) : (status.running ? .working(tokPerSec: nil) : .idle),
                    size: 24
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text("PocketAI").font(.pocket(.headline))
                    if model.isGenerating {
                        Text(model.activeTokPerSec > 0 ? "Generating · \(model.activeTokPerSec) tok/s" : "Generating")
                            .font(.pocket(.caption))
                            .foregroundStyle(PocketColor.accent)
                    } else if status.running {
                        Text("Server Active · :\(status.port)")
                            .font(.pocket(.caption))
                            .foregroundStyle(PocketColor.statusOk)
                    } else {
                        Text("Ready · On-Device")
                            .font(.pocket(.caption))
                            .foregroundStyle(PocketColor.textSecondary)
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
                                model.currentModelId = entry.manifest.id
                            }
                        }
                    } label: {
                        Text(model.currentModelDisplayName)
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
                set: { lan in
                    // The core returns current status while running, so a live
                    // server must be restarted for a LAN change to take effect.
                    if status.running {
                        model.stopServer()
                        model.startServer(lan: lan)
                    }
                }
            ))
            .disabled(!status.running)

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
