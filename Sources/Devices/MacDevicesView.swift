import SwiftUI
import CoreImage.CIFilterBuiltins
import PocketKit
import PocketUI

/// MAC-07: Devices + pairing (M-DEV, M-PAIR).
/// Award-winning device management:
/// - Glanceable paired device cards with latency, connection dot, and route
/// - Delightful empty state with step-by-step guidance
/// - High-resolution C14 Pairing QR sheet with centered PocketMark & circular countdown ring
/// - Polished Allow/Deny modal sheet for incoming pairing requests
struct MacDevicesView: View {
    @Environment(AppModel.self) private var model

    /// iPhones paired TO this Mac (`devices()`), not hosts this Mac is paired
    /// to (`peers()`).
    @State private var devices: [PairedDevice] = []
    @State private var showPairingSheet = false
    @State private var pendingRevokeDevice: PairedDevice?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PocketSpacing.s20) {
                // Header Bar
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Paired Devices")
                            .font(.pocket(.title))
                            .fontWeight(.bold)
                            .foregroundStyle(PocketColor.textPrimary)

                        Text("Allow your iPhone to run inference on this Mac's models over local Wi-Fi.")
                            .font(.pocket(.callout))
                            .foregroundStyle(PocketColor.textSecondary)
                    }

                    Spacer()

                    Button {
                        showPairingSheet = true
                    } label: {
                        Label("Pair iPhone…", systemImage: "plus")
                    }
                    .buttonStyle(.pocketPrimary)
                    .controlSize(.large)
                }

                Divider()

                // Paired Devices List or Empty State
                if devices.isEmpty {
                    emptyDevicesView
                } else {
                    pairedDevicesList
                }
            }
            .padding(PocketSpacing.gutterMac)
            .frame(maxWidth: 800)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(PocketColor.bgCanvas)
        .task { reload() }
        .sheet(isPresented: $showPairingSheet) {
            MacPairingQRSheet()
        }
        // Pending-request polling + the approval sheet live in AppModel /
        // RootSplitView now, so a request surfaces on any tab. Refresh the
        // list once a request has been decided.
        .onChange(of: model.pendingPairingRequest) { _, request in
            if request == nil { reload() }
        }
        .confirmationDialog(
            "Revoke “\(pendingRevokeDevice?.name ?? "iPhone")”?",
            isPresented: Binding(get: { pendingRevokeDevice != nil }, set: { if !$0 { pendingRevokeDevice = nil } }),
            titleVisibility: .visible
        ) {
            Button("Revoke Access", role: .destructive) {
                if let device = pendingRevokeDevice {
                    revoke(device)
                }
                pendingRevokeDevice = nil
            }
            Button("Cancel", role: .cancel) {
                pendingRevokeDevice = nil
            }
        } message: {
            Text("This will immediately disconnect the iPhone from using this Mac's models.")
        }
    }

    private var emptyDevicesView: some View {
        VStack(spacing: PocketSpacing.s20) {
            Spacer(minLength: 40)

            ZStack {
                Circle()
                    .fill(PocketColor.accentSoft)
                    .frame(width: 80, height: 80)
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 36))
                    .foregroundStyle(PocketColor.accent)
            }

            VStack(spacing: PocketSpacing.s8) {
                Text("No iPhones Paired Yet")
                    .font(.pocket(.title))
                    .fontWeight(.bold)
                    .foregroundStyle(PocketColor.textPrimary)

                Text("Pair your iPhone to access this Mac's larger models wherever you are on your local network.")
                    .font(.pocket(.body))
                    .foregroundStyle(PocketColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            // Benefits cards
            VStack(alignment: .leading, spacing: PocketSpacing.s12) {
                featureBullet(icon: "wifi", text: "Zero configuration over local Wi-Fi or Tailscale")
                featureBullet(icon: "lock.shield", text: "End-to-end encrypted; nothing touches a cloud server")
                featureBullet(icon: "battery.100.bolt", text: "Saves iPhone battery by running heavy compute on this Mac")
            }
            .padding(PocketSpacing.s16)
            .background(PocketColor.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(PocketColor.lineHairline, lineWidth: 0.8)
            )
            .frame(maxWidth: 480)

            Button("Pair iPhone Now…") {
                showPairingSheet = true
            }
            .buttonStyle(.borderedProminent)
            .tint(PocketColor.accent)
            .controlSize(.large)
            .padding(.top, PocketSpacing.s8)

            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity)
    }

    private func featureBullet(icon: String, text: String) -> some View {
        HStack(spacing: PocketSpacing.s12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PocketColor.accent)
                .frame(width: 24)

            Text(text)
                .font(.pocket(.callout))
                .foregroundStyle(PocketColor.textSecondary)
        }
    }

    private var pairedDevicesList: some View {
        VStack(alignment: .leading, spacing: PocketSpacing.s12) {
            Text("PAIRED DEVICES (\(devices.count))")
                .font(.pocket(.caption))
                .foregroundStyle(PocketColor.textTertiary)

            ForEach(devices, id: \.id) { peer in
                HStack(spacing: PocketSpacing.s16) {
                    Image(systemName: "iphone.gen3")
                        .font(.system(size: 28))
                        .foregroundStyle(PocketColor.accent)
                        .frame(width: 44, height: 44)
                        .background(PocketColor.accentSoft)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(peer.name)
                                .font(.pocket(.headline))
                                .foregroundStyle(PocketColor.textPrimary)

                            Circle()
                                .fill(PocketColor.textTertiary)
                                .frame(width: 8, height: 8)

                            // Honest instruments: we know the device is paired,
                            // not whether it is reachable right now.
                            Text("Paired")
                                .font(.pocket(.caption))
                                .foregroundStyle(PocketColor.textSecondary)
                        }

                        Text(peer.lastAddr ?? "Local Network")
                            .font(.pocket(.caption))
                            .foregroundStyle(PocketColor.textSecondary)
                    }

                    Spacer()

                    Button("Revoke", role: .destructive) {
                        pendingRevokeDevice = peer
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
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
    }

    private func reload() {
        devices = model.core.devices().filter { $0.revokedAt == nil }
    }

    private func revoke(_ device: PairedDevice) {
        try? model.core.revokeDevice(id: device.id)
        reload()
    }
}

extension PairingRequest: @retroactive Identifiable {}

/// Presents the Allow/Deny decision for `AppModel.pendingPairingRequest`.
/// Shared by RootSplitView (any tab) and the QR sheet (which would otherwise
/// block a sibling sheet from presenting).
struct PairingApprovalSheet: View {
    let request: PairingRequest
    @Environment(AppModel.self) private var model

    var body: some View {
        AllowDenySheet(
            request: request,
            onAllow: {
                try? model.core.approvePairing(id: request.id)
                model.pendingPairingRequest = nil
            },
            onDeny: {
                try? model.core.denyPairing(id: request.id)
                model.pendingPairingRequest = nil
            }
        )
    }
}

private struct AllowDenySheet: View {
    let request: PairingRequest
    let onAllow: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(spacing: PocketSpacing.s20) {
            ZStack {
                Circle()
                    .fill(PocketColor.accentSoft)
                    .frame(width: 64, height: 64)
                Image(systemName: "iphone")
                    .font(.system(size: 32))
                    .foregroundStyle(PocketColor.accent)
            }

            VStack(spacing: PocketSpacing.s8) {
                Text("Allow “\(request.deviceName)” to Pair?")
                    .font(.pocket(.title))
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)

                Text("This will grant this iPhone permission to use your Mac's models over your local network.")
                    .font(.pocket(.callout))
                    .foregroundStyle(PocketColor.textSecondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: PocketSpacing.s12) {
                Button("Deny", role: .cancel, action: onDeny)
                    .buttonStyle(.pocketSecondary)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)

                Button("Allow Connection", action: onAllow)
                    .buttonStyle(.pocketPrimary)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
            }
            .padding(.top, PocketSpacing.s8)
        }
        .padding(PocketSpacing.s32)
        .frame(width: 400)
        .background(PocketColor.bgCanvas)
    }
}

/// C14: QR + countdown ring, with "Enter code manually" fallback.
private struct MacPairingQRSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var qrString: String?
    @State private var errorText: String?
    @State private var secondsRemaining = 300
    @State private var countdownTask: Task<Void, Never>?
    @State private var copiedFeedback = false

    var body: some View {
        VStack(spacing: PocketSpacing.s20) {
            // Header
            VStack(spacing: PocketSpacing.s4) {
                Text("Scan with PocketAI on iPhone")
                    .font(.pocket(.title))
                    .fontWeight(.bold)

                Text("Open PocketAI → Devices → Tap Scan Code")
                    .font(.pocket(.callout))
                    .foregroundStyle(PocketColor.textSecondary)
            }

            // QR Code Area with Circular Countdown Ring
            if let qrString {
                ZStack {
                    // Outer countdown ring
                    Circle()
                        .stroke(PocketColor.bgSunken, lineWidth: 4)
                        .frame(width: 270, height: 270)

                    Circle()
                        .trim(from: 0, to: CGFloat(secondsRemaining) / 300.0)
                        .stroke(PocketColor.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 270, height: 270)
                        .animation(.linear(duration: 1.0), value: secondsRemaining)

                    // Sharp QR Code
                    qrImage(for: qrString)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 230, height: 230)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    // Centered PocketMark badge
                    ZStack {
                        Circle()
                            .fill(PocketColor.bgSurface)
                            .frame(width: 48, height: 48)
                            .shadow(color: Color.black.opacity(0.12), radius: 4, y: 2)

                        PocketMarkView(state: .idle, size: 28)
                    }
                }
                .padding(.vertical, PocketSpacing.s8)

                HStack(spacing: PocketSpacing.s4) {
                    Image(systemName: "timer")
                        .foregroundStyle(PocketColor.textTertiary)
                    Text("Code expires in \(secondsRemaining)s")
                        .font(.pocket(.metric))
                        .foregroundStyle(PocketColor.textSecondary)
                }

                // Manual entry fallback
                VStack(spacing: PocketSpacing.s8) {
                    Text("Or enter manual pairing link:")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textTertiary)

                    HStack {
                        Text(qrString)
                            .font(.pocket(.mono))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(PocketColor.textSecondary)

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(qrString, forType: .string)
                            copiedFeedback = true
                            Task {
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                copiedFeedback = false
                            }
                        } label: {
                            Label(copiedFeedback ? "Copied" : "Copy", systemImage: copiedFeedback ? "checkmark" : "doc.on.doc")
                                .font(.pocket(.caption))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(PocketSpacing.s8)
                    .background(PocketColor.bgSunken)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .frame(maxWidth: 400)
            } else if let errorText {
                Text(errorText)
                    .font(.pocket(.body))
                    .foregroundStyle(PocketColor.statusBad)
            }

            Button("Done") {
                dismiss()
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .padding(.top, PocketSpacing.s8)
        }
        .padding(PocketSpacing.s32)
        .frame(width: 460)
        .background(PocketColor.bgCanvas)
        // An incoming approval must be able to present while this sheet is
        // open — a sibling sheet on the parent view can't.
        .sheet(item: Binding(
            get: { model.pendingPairingRequest },
            set: { model.pendingPairingRequest = $0 }
        )) { request in
            PairingApprovalSheet(request: request)
        }
        .task {
            // Orchestration fix (root cause of "sync not working"): the pairing
            // QR encodes `server_status().port`. If the server is stopped, that
            // port is 0, so the iPhone probes https://<ip>:0 and fails with a
            // generic "Mac not reachable". Pairing also needs the LAN listener,
            // not loopback-only — a running loopback server must be restarted
            // with LAN on (the core returns current status while running).
            if model.serverStatus.running && !model.serverStatus.lanEnabled {
                model.stopServer()
            }
            if !model.serverStatus.running || model.serverStatus.port == 0 {
                model.startServer(lan: true)
            }
            guard model.serverStatus.running, model.serverStatus.port != 0, model.serverStatus.lanEnabled else {
                errorText = "Couldn't start the LAN server needed for pairing. Open the Server tab, turn it on with \"Serve on Local Network\", then try again. (Pairing and LAN serving require PocketAI Pro.)"
                return
            }
            refreshOffer()
            startCountdown()
        }
        .onDisappear { countdownTask?.cancel() }
    }

    private func refreshOffer() {
        do {
            qrString = try model.core.pairingOfferQrString()
            errorText = nil
            secondsRemaining = 300
        } catch {
            qrString = nil
            errorText = "Couldn't generate a pairing code: \(error.localizedDescription)"
        }
    }

    private func startCountdown() {
        countdownTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                secondsRemaining -= 1
                // Expired: mint a fresh code instead of showing a dead QR.
                if secondsRemaining <= 0 {
                    refreshOffer()
                    if qrString == nil { return }
                }
            }
        }
    }

    private func qrImage(for string: String) -> Image {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "H"
        guard let output = filter.outputImage,
              let cgImage = context.createCGImage(output, from: output.extent)
        else {
            return Image(systemName: "qrcode")
        }
        return Image(decorative: cgImage, scale: 1, orientation: .up)
    }
}
