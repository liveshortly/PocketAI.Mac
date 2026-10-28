import PocketKit
import PocketUI
import SwiftUI

/// Paired iPhones that may use this Mac's models, and the QR that pairs a new
/// one. Pairing needs the local server running — said here, not discovered by
/// a failure.
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
                // Never a dead button: pairing needs the LAN server, so this
                // starts it rather than sitting disabled with the reason
                // somewhere else on screen.
                Button(app.serverStatus.running ? "Pair a device…" : "Start server & pair…") {
                    makeOffer()
                }
                .buttonStyle(.hudProminent)
            }
            .padding(.horizontal, PocketSpacing.s16)
            .padding(.vertical, PocketSpacing.s8)
            .background(PocketColor.bgSurface)
            HUDRule()

            ScrollView {
                VStack(alignment: .leading, spacing: PocketSpacing.s16) {
                    if !app.serverStatus.running {
                        serverHint
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
        .task { reload() }
        .confirmationDialog(
            "Revoke \(confirmRevoke?.name ?? "device")? It loses access to this Mac's models.",
            isPresented: Binding(
                get: { confirmRevoke != nil }, set: { if !$0 { confirmRevoke = nil } }),
            titleVisibility: .visible
        ) {
            Button("Revoke access", role: .destructive) {
                if let device = confirmRevoke {
                    try? app.core.revokeDevice(id: device.id)
                    reload()
                }
            }
        }
    }

    private var serverHint: some View {
        HStack(spacing: PocketSpacing.s8) {
            Image(systemName: "info.circle")
                .foregroundStyle(PocketColor.statusWarn)
            Text("Start the local server before pairing — a device connects to it directly.")
                .font(.pocket(.footnote))
            Spacer(minLength: 0)
            Button("Local server") { app.selection = .server }
                .buttonStyle(.hud)
        }
        .padding(PocketSpacing.s12)
        .hudPanel(PocketColor.statusWarn.opacity(0.10))
    }

    private func qrCard(_ qr: String) -> some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s8) {
            HUDLabel("Scan on the iPhone")
            HStack(alignment: .top, spacing: PocketSpacing.s16) {
                QRCodeImage(text: qr)
                    .frame(width: 180, height: 180)
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
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).font(.pocket(.body))
                Text(deviceSubtitle(device))
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
            }
            Spacer(minLength: 0)
            if device.revokedAt != nil {
                HUDChip(text: "REVOKED", tint: PocketColor.statusBad)
            } else {
                Button("Revoke") { confirmRevoke = device }
                    .buttonStyle(.hud)
            }
        }
        .padding(PocketSpacing.s8)
    }

    private func deviceSubtitle(_ device: PairedDevice) -> String {
        var bits = ["\(device.platform)", device.role]
        if let seen = device.lastSeenAt { bits.append("seen \(hudRelative(seen))") }
        if let addr = device.lastAddr { bits.append(addr) }
        return bits.joined(separator: " · ")
    }

    private func peerRow(_ peer: Peer) -> some View {
        HStack(spacing: PocketSpacing.s12) {
            Image(systemName: "desktopcomputer")
                .foregroundStyle(PocketColor.textTertiary)
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
        devices = app.core.devices()
        peers = app.core.peers()
        app.refreshServerStatus()
    }

    private func makeOffer() {
        qrError = nil
        // A phone reaches this Mac over the LAN, so loopback-only serving
        // cannot complete a pairing.
        if !app.serverStatus.running {
            app.startServer(lan: true)
        } else if !app.serverStatus.lanEnabled {
            // Already serving, but only on loopback — a phone on the LAN can
            // never reach that, so rebind before handing out a code.
            app.stopServer()
            app.startServer(lan: true)
        }
        guard app.serverStatus.running else {
            qrError = """
                The local server didn't start, so there is nothing for a device to pair with. \
                Open Local server and start it there to see why.
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
