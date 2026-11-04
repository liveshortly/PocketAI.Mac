import PocketKit
import PocketUI
import SwiftUI

/// Paired iPhones that may use this Mac's models, and the QR that pairs a new
/// one. Pairing raises Access to "paired devices" itself (MAC-18), so the
/// server is never a step the user has to take first.
struct DevicesView: View {
    @Environment(AppModel.self) private var app
    @State private var devices: [PairedDevice] = []
    /// Last chat sync per device, read on reload rather than on every render (UI-108).
    @State private var lastSynced: [String: Int64] = [:]
    @State private var peers: [Peer] = []
    @State private var qrString: String?
    /// When the shown code stops working: the core's offers live 300 s (C14).
    @State private var qrExpiresAt: Date?
    @State private var qrError: String?
    /// NET-23: the typed-code fallback beside the QR, made only when the
    /// user opens "Enter code manually".
    @State private var showManualCode = false
    @State private var manualCode: ManualPairingCode?
    @State private var confirmRevoke: PairedDevice?
    @State private var confirmForgetPeer: Peer?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Devices")
                    .font(.pocket(.headline))
                Spacer()
                Button("Pair a device…") { makeOffer() }
                    .buttonStyle(.hudProminent)
            }
            .padding(.horizontal, PocketSpacing.s16)
            .padding(.vertical, PocketSpacing.s8)
            .background(PocketColor.bgSurface)
            HUDRule()

            ScrollView {
                VStack(alignment: .leading, spacing: PocketSpacing.s16) {
                    if devices.isEmpty, qrString == nil, app.serverAccess == .pairedDevices {
                        accessHint
                    }
                    if let qrString { qrCard(qrString) }
                    if let qrError {
                        HStack(spacing: PocketSpacing.s8) {
                            Label(qrError, systemImage: "exclamationmark.triangle.fill")
                                .font(.pocket(.footnote))
                                .foregroundStyle(PocketColor.statusBad)
                            Spacer(minLength: 0)
                            if app.serverNeedsLicense { EnterLicenseButton() }
                        }
                        .padding(PocketSpacing.s12)
                        .hudPanel()
                    }
                    section(
                        "Devices using this Mac",
                        devices.isEmpty
                            ? "No iPhone paired yet. Choose Pair a device… and scan the code with PocketAI on your iPhone."
                            : nil
                    ) {
                        ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                            if index > 0 { HUDRule() }
                            deviceRow(device)
                        }
                    }
                    // Only shown once there is one: an empty "None" read as broken.
                    if !peers.isEmpty {
                        section("Macs this app can borrow", nil) {
                            ForEach(Array(peers.enumerated()), id: \.element.id) { index, peer in
                                if index > 0 { HUDRule() }
                                peerRow(peer)
                            }
                        }
                    }
                }
                .padding(PocketSpacing.s16)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .background(PocketColor.bgCanvas)
        .task { await keepFresh() }
        .onChange(of: app.commandSerial) { _, _ in handleCommand() }
        .confirmationDialog(
            "Forget \(confirmRevoke?.name ?? "this device")?",
            isPresented: Binding(
                get: { confirmRevoke != nil }, set: { if !$0 { confirmRevoke = nil } }),
            titleVisibility: .visible
        ) {
            // NET-22: keeping synced chats is the first, default choice.
            Button("Forget, Keep Chats on This Mac") { forget(removeChats: false) }
            Button("Forget and Delete Its Chats from This Mac", role: .destructive) {
                forget(removeChats: true)
            }
        } message: {
            Text("It's unpaired and must scan a new code to come back. The iPhone keeps its own chats. To pause it instead, use Disconnect.")
        }
        .confirmationDialog(
            "Forget \(confirmForgetPeer?.name ?? "this Mac")?",
            isPresented: Binding(
                get: { confirmForgetPeer != nil }, set: { if !$0 { confirmForgetPeer = nil } }),
            titleVisibility: .visible
        ) {
            Button("Forget", role: .destructive) {
                if let peer = confirmForgetPeer {
                    do { try app.core.revokePeer(id: peer.id) } catch {
                        app.toast("Couldn't forget \(peer.name): \(error.localizedDescription)")
                    }
                }
                reload()
            }
        } message: {
            Text("This app stops using its models. Pair again to get them back.")
        }
    }

    /// Removing chats is local only: the phone keeps every one of them.
    private func forget(removeChats: Bool) {
        guard let device = confirmRevoke else { return }
        if removeChats {
            do { _ = try app.core.removeSyncedChats(peerId: device.id) } catch {
                app.toast("Couldn't delete \(device.name)'s chats: \(error.localizedDescription)")
            }
            NotificationCenter.default.post(name: .pocketConversationsChanged, object: nil)
        }
        do { try app.core.revokeDevice(id: device.id) } catch {
            app.toast("Couldn't forget \(device.name): \(error.localizedDescription)")
        }
        reload()
    }

    /// MAC-18: the last device was forgotten but Access stays where it is
    /// (never lock the user out of a setting) - offer to turn it off here.
    private var accessHint: some View {
        HStack(spacing: PocketSpacing.s8) {
            Text("No paired devices, but Access still lets paired devices in.")
                .font(.pocket(.footnote))
                .foregroundStyle(PocketColor.textSecondary)
            Spacer(minLength: 0)
            Button("Turn off") { app.setServerAccess(.off) }
                .buttonStyle(.hud)
        }
        .padding(PocketSpacing.s12)
        .hudPanel()
    }

    /// C14's countdown: time left on the code, then a plain "expired" with the
    /// New code button right beside it. Works once either way.
    private func expiryLine(_ expiresAt: Date?) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, Int((expiresAt ?? context.date).timeIntervalSince(context.date)))
            VStack(alignment: .leading, spacing: PocketSpacing.s4) {
                Text(left > 0
                     ? "Expires in \(left / 60):\(String(format: "%02d", left % 60)) · works once"
                     : "This code expired. Make a new one.")
                    .font(.pocket(.caption))
                    .monospacedDigit()
                    .foregroundStyle(left > 0 ? PocketColor.textTertiary : PocketColor.statusBad)
                ProgressView(value: Double(left), total: 300)
                    .tint(left > 60 ? PocketColor.accent : PocketColor.statusBad)
                    .frame(maxWidth: 160)
                    .accessibilityHidden(true)
            }
        }
    }

    private func qrCard(_ qr: String) -> some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s8) {
            HUDLabel("Scan on the iPhone")
            HStack(alignment: .top, spacing: PocketSpacing.s16) {
                QRCodeImage(text: qr)
                    .frame(width: 180, height: 180)
                    .accessibilityLabel(
                        "Pairing QR code. Scan it with PocketAI on your iPhone: "
                        + "Mac tab, Scan pairing code.")
                VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                    Text("On your iPhone, open PocketAI › Mac tab › Scan pairing code.")
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.textSecondary)
                    expiryLine(qrExpiresAt)
                    HStack(spacing: PocketSpacing.s8) {
                        Button("New code") { makeOffer() }
                            .buttonStyle(.hud)
                            .help("Use this if the code expired or was already scanned.")
                        Button("Done") {
                            qrString = nil
                            showManualCode = false
                            manualCode = nil
                        }
                            .buttonStyle(.hud)
                            .keyboardShortcut(.cancelAction)
                    }
                }
            }
            DisclosureGroup("Enter code manually", isExpanded: $showManualCode) {
                manualCodePanel
            }
            .font(.pocket(.footnote))
            .onChange(of: showManualCode) { _, open in
                if open, manualCode == nil { makeManualCode() }
            }
        }
        .padding(PocketSpacing.s12)
        .hudPanel()
    }

    /// NET-23: for a phone that can't scan. The code can't carry this Mac's
    /// certificate the way the QR does, so the Allow sheet then asks the
    /// user to compare a 6-digit number on both screens.
    @ViewBuilder private var manualCodePanel: some View {
        if let manualCode {
            let address = manualCode.addrs.first.map { "\($0):\(manualCode.port)" } ?? "port \(manualCode.port)"
            let code = "\(manualCode.code.prefix(4))-\(manualCode.code.suffix(4))"
            VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                Text("On your iPhone, open PocketAI › Mac tab › Scan pairing code › Enter code manually, and type:")
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline, spacing: PocketSpacing.s24) {
                    VStack(alignment: .leading, spacing: PocketSpacing.s4) {
                        HUDLabel("Address")
                        Text(address)
                            .font(.pocket(.mono))
                            .textSelection(.enabled)
                    }
                    VStack(alignment: .leading, spacing: PocketSpacing.s4) {
                        HUDLabel("Code")
                        Text(code)
                            .font(.pocket(.title))
                            .monospaced()
                            .textSelection(.enabled)
                            .accessibilityLabel("Pairing code \(manualCode.code.map(String.init).joined(separator: " "))")
                    }
                }
                expiryLine(Date(timeIntervalSince1970: TimeInterval(manualCode.expiresAtMs) / 1000))
                Button("New code") { makeManualCode() }
                    .buttonStyle(.hud)
                    .help("Use this if the code expired, was used, or had too many wrong tries.")
            }
            .padding(.top, PocketSpacing.s8)
        }
    }

    private func makeManualCode() {
        do {
            manualCode = try app.core.pairingManualCode()
        } catch {
            manualCode = nil
            showManualCode = false
            qrError = "Couldn't create a pairing code: \(error.localizedDescription)"
        }
    }

    private func deviceRow(_ device: PairedDevice) -> some View {
        HStack(spacing: PocketSpacing.s12) {
            Image(systemName: "iphone")
                .foregroundStyle(PocketColor.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).font(.pocket(.body))
                Text(deviceSubtitle(device))
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            SyncChatsToggle(deviceId: device.id, deviceName: device.name, core: app.core,
                            onError: { app.toast(verbatim: $0) })
            RunCodeFromPhoneToggle(core: app.core, compact: true, onError: { app.toast(verbatim: $0) })
            linkButton(device)
            Button("Forget…") { confirmRevoke = device }
                .buttonStyle(.hud)
                .accessibilityLabel("Forget \(device.name)")
        }
        .padding(PocketSpacing.s8)
    }

    /// NET-17: drop this phone now, keep the pairing; "Allow" lifts it
    /// (the phone's own Connect does too).
    private func linkButton(_ device: PairedDevice) -> some View {
        let off = device.linkState == .disconnectedByHost
        return Button(off ? "Allow" : "Disconnect") {
            do { try app.core.setDeviceDisconnected(id: device.id, disconnected: !off) } catch {
                app.toast(off ? "Couldn't allow \(device.name): \(error.localizedDescription)" : "Couldn't disconnect \(device.name): \(error.localizedDescription)")
            }
            reload()
        }
        .buttonStyle(.hud)
        .accessibilityLabel(off ? "Allow \(device.name) to connect" : "Disconnect \(device.name)")
    }

    private func linkLabel(_ state: DeviceLinkState) -> String {
        switch state {
        case .connected: return "Connected"
        case .idle: return "Idle"
        case .disconnected: return "Disconnected"
        case .disconnectedByHost: return "Disconnected by this Mac"
        }
    }

    private func deviceSubtitle(_ device: PairedDevice) -> String {
        var bits = [linkLabel(device.linkState), "\(device.platform)"]
        if let seen = device.lastSeenAt { bits.append("seen \(hudRelative(seen))") }
        if let addr = device.lastAddr { bits.append(addr) }
        // NET-22: the phone drives sync; this Mac only reports when it last did.
        if let synced = lastSynced[device.id] {
            bits.append("chats synced \(hudRelative(synced / 1000))")
        }
        return bits.joined(separator: " · ")
    }

    private func peerRow(_ peer: Peer) -> some View {
        HStack(spacing: PocketSpacing.s12) {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(PocketColor.textTertiary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(peer.name).font(.pocket(.body))
                Text((peer.addrs.first ?? "—") + ":\(peer.port)")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
            }
            Spacer(minLength: 0)
            Button("Forget…") { confirmForgetPeer = peer }
            .buttonStyle(.hud)
            .accessibilityLabel("Forget \(peer.name)")
        }
        .padding(PocketSpacing.s8)
    }

    @ViewBuilder private func section<Content: View>(
        _ title: String, _ emptyText: String?, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s8) {
            HUDLabel(title)
            if let emptyText {
                Text(emptyText)
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textTertiary)
                    .padding(PocketSpacing.s12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .hudPanel()
            } else {
                VStack(spacing: 0) { content() }
                    .hudPanel()
            }
        }
    }

    private func reload() {
        // A revoked device is not a device any more; listing it only invites
        // confusion about whether it still has access.
        devices = app.core.devices().filter { $0.revokedAt == nil }
        lastSynced = Dictionary(uniqueKeysWithValues: devices.compactMap { d in
            app.core.syncStatus(peerId: d.id).lastSyncedAt.map { (d.id, $0) }
        })
        peers = app.core.peers()
        app.refreshServerStatus()
    }

    /// Link states age on their own (NET-18 lease), so keep the list fresh.
    private func keepFresh() async {
        handleCommand()
        while !Task.isCancelled {
            reload()
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }

    private func handleCommand() {
        switch app.pendingCommand {
        case .refresh: reload()
        case .pairDevice:
            app.clearCommand()
            makeOffer()
        default: break
        }
    }

    private func makeOffer() {
        qrError = nil
        // A phone reaches this Mac over the LAN: raise Access if it's lower
        // (starts or rebinds the server) - all in this one click.
        if app.serverAccess != .pairedDevices || !app.serverStatus.running {
            app.setServerAccess(.pairedDevices)
        }
        guard app.serverStatus.running, app.serverStatus.lanEnabled else {
            qrError = app.serverNeedsLicense
                ? "Pairing needs PocketAI Pro. Enter a license key, then try again."
                : "This Mac couldn't open itself to devices on the network, so there is nothing to pair with."
            return
        }
        do {
            qrString = try app.core.pairingOfferQrString()
            qrExpiresAt = Date().addingTimeInterval(300)
            if showManualCode { makeManualCode() }
        } catch {
            qrString = nil
            qrError = "Couldn't create a pairing code: \(error.localizedDescription)"
        }
    }
}

/// Renders a QR from a string with CoreImage — no bundled image assets.
struct QRCodeImage: View {
    let text: String

    var body: some View {
        if let image = render() {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .padding(PocketSpacing.s8)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: HUD.radius, style: .continuous))
        } else {
            Text("Couldn't render the code")
                .font(.pocket(.caption))
                .foregroundStyle(PocketColor.statusBad)
        }
    }

    private func render() -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: scaled.extent.width,
                                                 height: scaled.extent.height))
    }
}

extension PairedDevice: @retroactive Identifiable {}
extension Peer: @retroactive Identifiable {}

/// NET-22: Devices › phone "Sync chats". Off makes this Mac answer that
/// phone's sync with 403 `sync_disabled` ("Sync is off on <Mac>" there).
struct SyncChatsToggle: View {
    let deviceId: String
    let deviceName: String
    let core: CoreClient
    /// UI-108: a failed switch used to stay flipped with nothing saved.
    var onError: ((String) -> Void)? = nil
    @State private var isOn = true

    var body: some View {
        Toggle("Sync chats", isOn: $isOn)
            .toggleStyle(.switch)
            .controlSize(.small)
            .font(.pocket(.caption))
            .help("Sync chats between \(deviceName) and this Mac.")
            .accessibilityLabel("Sync chats with \(deviceName)")
            .onAppear { isOn = core.syncEnabledForDevice(deviceId: deviceId) }
            .onChange(of: isOn) { _, on in
                guard on != core.syncEnabledForDevice(deviceId: deviceId) else { return }
                do { try core.setSyncEnabledForDevice(deviceId: deviceId, enabled: on) } catch {
                    isOn = !on // show the setting that is actually in effect
                    onError?(String(localized: "Couldn't change chat sync: \(error.localizedDescription)"))
                }
            }
    }
}

/// AGT-13: "Let my paired iPhone run code on this Mac". One Mac-wide switch
/// (not per phone), off by default; while off the Mac refuses every run
/// request. Shown in Settings → Tools and, compactly, beside each phone.
struct RunCodeFromPhoneToggle: View {
    let core: CoreClient
    var compact = false
    var onError: ((String) -> Void)? = nil
    @State private var isOn = false

    var body: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s4) {
            Toggle(compact ? "Run code" : "Let my paired iPhone run code on this Mac", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(compact ? .small : .regular)
                .font(.pocket(compact ? .caption : .body))
                .help("Lets your paired iPhones run code they send, in a sandbox on this Mac. Applies to all paired iPhones.")
                .accessibilityLabel("Let my paired iPhone run code on this Mac")
            if !compact {
                Text("Off by default. When on, the model on your iPhone can ask to run Python, JavaScript or shell code here, after you approve each run on the iPhone. It runs in a sandbox: no network, no access to your files or folders, a time limit, and a scratch folder that is deleted afterwards. Every run is logged under Server. Turn it off and every run request is refused.")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
            }
        }
        .onAppear { isOn = core.runCodeEnabled() }
        .onChange(of: isOn) { _, on in
            guard on != core.runCodeEnabled() else { return }
            core.setRunCodeEnabled(on)
            if core.runCodeEnabled() != on {
                isOn = !on
                onError?(String(localized: "Couldn't change the run-code setting."))
            }
        }
    }
}

private struct SyncChatsTogglePreview: View {
    var body: some View {
        SyncChatsToggle(deviceId: "preview", deviceName: "Rohit's iPhone", core: PreviewCore())
            .padding(PocketSpacing.s16)
            .background(PocketColor.bgCanvas)
    }
}

#Preview("Light") { SyncChatsTogglePreview().preferredColorScheme(.light) }
#Preview("Dark") { SyncChatsTogglePreview().preferredColorScheme(.dark) }
#Preview("AX3") { SyncChatsTogglePreview().environment(\.dynamicTypeSize, .accessibility3) }
