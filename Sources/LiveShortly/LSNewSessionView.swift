import PocketLiveShortly
import PocketUI
import SwiftUI

/// Starting a LiveShortly session is a destination, not a modal: it opens in
/// the detail pane like a chat does, so starting an agent and starting a chat
/// are the same gesture in the same place.
struct LSNewSessionView: View {
    @Environment(AppModel.self) private var app
    /// When set, the session that gets created is filed under this project.
    var projectId: String?

    @State private var hosts: [LSHost] = []
    @State private var hostID: String?
    @State private var agent: String?
    @State private var cwd: String?
    @State private var model: String?
    @State private var bypass = false
    @State private var loading = true
    @State private var starting = false
    @State private var errorText: String?

    private var host: LSHost? { hosts.first { $0.id == hostID } }

    private func hostLabel(_ host: LSHost) -> String {
        let base = "\(host.name) · \(host.os) \(host.arch)"
        return host.isOnline ? base : base + " · offline"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            HUDRule()
            ScrollView {
                VStack(alignment: .leading, spacing: PocketSpacing.s16) {
                    if loading {
                        ProgressView("Looking for your machines…")
                            .font(.pocket(.footnote))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 60)
                    } else if hosts.isEmpty {
                        noMachines
                    } else {
                        form
                    }
                    if let errorText {
                        Text(errorText)
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.statusBad)
                            .padding(PocketSpacing.s12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .hudPanel(PocketColor.statusBad.opacity(0.08))
                    }
                }
                .padding(PocketSpacing.s16)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .background(PocketColor.bgCanvas)
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: PocketSpacing.s12) {
            Image(systemName: "bolt")
                .foregroundStyle(LSColor.accent)
                .accessibilityHidden(true)
            Text(projectId == nil ? "New agent session" : "New agent session in this project")
                .font(.pocket(.headline))
            Spacer(minLength: 0)
            // Creating a session is a round trip to the machine: say that it is
            // happening rather than greying the button out in silence.
            Button(starting ? "Starting…" : "Start session") { start() }
                .buttonStyle(.hudProminent)
                .disabled(!canStart || starting)
        }
        .padding(.horizontal, PocketSpacing.s16)
        .padding(.vertical, PocketSpacing.s8)
        .background(PocketColor.bgSurface)
    }

    private var noMachines: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s8) {
            Text("No machines are online")
                .font(.pocket(.title))
            Text(
                "A machine appears here once `live daemon` is running on it and registered to your account. Start the daemon from the directory you want agents to work in."
            )
            .font(.pocket(.footnote))
            .foregroundStyle(PocketColor.textSecondary)
            Text("live daemon --dir ~/code")
                .font(.pocket(.mono))
                .textSelection(.enabled)
                .padding(PocketSpacing.s8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .hudPanel(PocketColor.bgSunken)
            Button("Check again") { Task { await load() } }
                .buttonStyle(.hud)
        }
        .padding(PocketSpacing.s12)
        .hudPanel()
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s12) {
            field("Machine") {
                Picker("Machine", selection: Binding(
                    get: { hostID ?? "" },
                    set: { newValue in
                        hostID = newValue
                        syncHostDefaults()
                    })
                ) {
                    ForEach(hosts, id: \.id) { host in
                        Text(hostLabel(host)).tag(host.id)
                    }
                }
                .labelsHidden()
            }
            if let host {
                field("Agent") {
                    Picker("Agent", selection: Binding(
                        get: { agent ?? host.agents.first ?? "" },
                        set: { newAgent in
                            agent = newAgent
                            // A model from the previous agent means nothing here.
                            model = nil
                        })
                    ) {
                        ForEach(host.agents, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
                field("Directory") {
                    Picker("Directory", selection: Binding(
                        get: { cwd ?? host.dirs.first ?? "" },
                        set: { cwd = $0 })
                    ) {
                        ForEach(host.dirs, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
                let choices = host.models(forAgent: agent ?? host.agents.first ?? "")
                if !choices.isEmpty {
                    field("Model") {
                        Picker("Model", selection: Binding(
                            get: { model ?? "" },
                            set: { model = $0.isEmpty ? nil : $0 })
                        ) {
                            Text("Default").tag("")
                            ForEach(choices, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                    }
                }
                if !host.isOnline {
                    HStack(spacing: PocketSpacing.s8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(PocketColor.statusWarn)
                            .accessibilityHidden(true)
                        Text(
                            "This machine hasn't checked in recently. Starting a session "
                            + "may produce one with no agent attached."
                        )
                        .font(.pocket(.caption))
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(PocketSpacing.s8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hudPanel(PocketColor.statusWarn.opacity(0.10))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Skip permission prompts", isOn: $bypass)
                        .toggleStyle(.switch)
                        .tint(LSColor.accent)
                        .font(.pocket(.body))
                    Text(
                        "The agent runs without asking before each tool call. Only for a directory you trust it in."
                    )
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
                }
                .padding(PocketSpacing.s12)
                .hudPanel()
            }
            Text("Directories come from the daemon's own registration — this app can never name a path the machine has not allowed.")
                .font(.pocket(.caption))
                .foregroundStyle(PocketColor.textTertiary)
        }
    }

    @ViewBuilder private func field<Content: View>(
        _ label: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s4) {
            HUDLabel(label)
            content()
                .padding(PocketSpacing.s8)
                .hudPanel()
        }
    }

    private var canStart: Bool {
        host != nil && !(agent ?? host?.agents.first ?? "").isEmpty
            && !(cwd ?? host?.dirs.first ?? "").isEmpty
    }

    private func syncHostDefaults() {
        agent = host?.agents.first
        cwd = host?.dirs.first
        model = nil
    }

    private func load() async {
        guard let client = app.liveShortly.client else {
            loading = false
            return
        }
        loading = true
        do {
            hosts = try await client.hosts()
            if hostID == nil || hosts.allSatisfy({ $0.id != hostID }) {
                hostID = hosts.first?.id
                syncHostDefaults()
            }
            errorText = nil
        } catch {
            errorText = "Couldn't load your machines: \(error.localizedDescription)"
        }
        loading = false
    }

    private func start() {
        guard let client = app.liveShortly.client, let host else { return }
        let chosenAgent = agent ?? host.agents.first ?? ""
        let chosenCwd = cwd ?? host.dirs.first ?? ""
        starting = true
        errorText = nil
        Task {
            do {
                let created = try await client.createSession(
                    hostID: host.id, agent: chosenAgent, cwd: chosenCwd,
                    model: model, bypassPermissions: bypass)
                if let spawn = created.spawn, spawn.status == "failed" {
                    // Stay on this screen so the reason is readable: navigating
                    // would destroy the view showing it and drop the user into
                    // an empty session with no agent behind it.
                    errorText = "The session was created, but the machine refused to start "
                        + "the agent: \(spawn.error ?? "unknown error"). "
                        + "It is in the sidebar if you still want to open it."
                } else {
                    if let projectId {
                        ProjectSessions.link(created.id, to: projectId)
                    }
                    // Straight into the session, as a new chat opens its thread.
                    app.selection = .session(created.id)
                }
            } catch {
                errorText = "Couldn't start the session: \(error.localizedDescription)"
            }
            starting = false
        }
    }
}
