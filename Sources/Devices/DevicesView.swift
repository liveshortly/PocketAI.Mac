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
    @State private var qrError: String?
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
                    Text("This code expires in a few minutes and works once.")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textTertiary)
                    HStack(spacing: PocketSpacing.s8) {
                        Button("New code") { makeOffer() }
                            .buttonStyle(.hud)
                            .help("Use this if the code expired or was already scanned.")
                        Button("Done") { qrString = nil }
                            .buttonStyle(.hud)
                            .keyboardShortcut(.cancelAction)
                    }
                }
            }
        }
        .padding(PocketSpacing.s12)
        .hudPanel()
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
                            onError: { app.toast($0) })
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
                app.toast("Couldn't \(off ? "allow" : "disconnect") \(device.name): \(error.localizedDescription)")
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
                    onError?("Couldn't change chat sync: \(error.localizedDescription)")
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
