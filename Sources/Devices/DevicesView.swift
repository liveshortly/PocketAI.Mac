import PocketKit
import PocketUI
import SwiftUI

/// Paired iPhones that may use this Mac's models, and the QR that pairs a new
/// one. Pairing raises Access to "paired devices" itself (MAC-18), so the
/// server is never a step the user has to take first.
struct DevicesView: View {
    @Environment(AppModel.self) private var app
    @State private var devices: [PairedDevice] = []
    @State private var peers: [Peer] = []
    @State private var qrString: String?
    @State private var qrError: String?
    @State private var confirmRevoke: PairedDevice?

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
                        Text(qrError)
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.statusBad)
                    }
                    section("Devices using this Mac", devices.isEmpty ? "None paired yet" : nil) {
                        ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                            if index > 0 { HUDRule() }
                            deviceRow(device)
                        }
                    }
                    section("Macs this app can borrow", peers.isEmpty ? "None" : nil) {
                        ForEach(Array(peers.enumerated()), id: \.element.id) { index, peer in
                            if index > 0 { HUDRule() }
                            peerRow(peer)
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
            forgetTitle,
            isPresented: Binding(
                get: { confirmRevoke != nil }, set: { if !$0 { confirmRevoke = nil } }),
            titleVisibility: .visible
        ) {
            Button("Forget", role: .destructive) {
                if let device = confirmRevoke {
                    try? app.core.revokeDevice(id: device.id)
                    reload()
                }
            }
        }
    }

    private var forgetTitle: String {
        let name = confirmRevoke?.name ?? "device"
        return "Forget \(name)? It's unpaired and must scan a new code to come back. To pause it instead, use Disconnect."
    }

    /// MAC-18: the last device was forgotten but Access stays where it is
    /// (never lock the user out of a setting) - offer to turn it off here.
    private var accessHint: some View {
        HStack(spacing: PocketSpacing.s8) {
            Text("No paired devices · Access: paired devices")
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
                        "Pairing QR code. Scan it with PocketAI on your iPhone, "
                        + "under Settings, Devices, Pair with a Mac.")
                VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                    Text("PocketAI on iPhone → Settings → Devices → Pair with a Mac.")
                        .font(.pocket(.footnote))
                        .foregroundStyle(PocketColor.textSecondary)
                    Text("This code expires in a few minutes and works once.")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textTertiary)
                    Button("Done") { qrString = nil }
                        .buttonStyle(.hud)
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
            Spacer(minLength: 0)
            linkButton(device)
            Button("Forget") { confirmRevoke = device }
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
            try? app.core.setDeviceDisconnected(id: device.id, disconnected: !off)
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
        if let synced = app.core.syncStatus(peerId: device.id).lastSyncedAt {
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
            Button("Forget") {
                try? app.core.revokePeer(id: peer.id)
                reload()
            }
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
        guard app.serverStatus.running else {
            qrError = """
                This Mac couldn't open itself to devices on the network, so there is nothing \
                to pair with. Devices on this network need PocketAI Pro.
                """
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
