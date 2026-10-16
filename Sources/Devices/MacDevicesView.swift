import SwiftUI
import CoreImage.CIFilterBuiltins
import PocketKit
import PocketUI

/// MAC-07: Devices + pairing (M-DEV, M-PAIR). "Pair iPhone" shows a QR
/// code with a countdown; an incoming request polls in as an Allow/Deny
/// sheet; paired peers list with revoke (confirm).
struct MacDevicesView: View {
    @Environment(AppModel.self) private var model

    @State private var peers: [Peer] = []
    @State private var showPairingSheet = false
    @State private var pendingRequest: PairingRequest?
    @State private var pendingRevokePeer: Peer?
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        List {
            Section("Paired iPhones") {
                if peers.isEmpty {
                    Text("No iPhones paired yet.").font(.pocket(.footnote)).foregroundStyle(PocketColor.textSecondary)
                } else {
                    ForEach(peers, id: \.id) { peer in
                        DeviceRow(
                            name: peer.name, isConnected: true, lastSeenText: "",
                            route: peer.addrs.first, icon: "iphone",
                            onRevoke: { pendingRevokePeer = peer }
                        )
                    }
                }
            }
            Section {
                Button("Pair iPhone…") { showPairingSheet = true }
            }
        }
        .task {
            reload()
            startPolling()
        }
        .onDisappear { pollTask?.cancel() }
        .sheet(isPresented: $showPairingSheet) {
            MacPairingQRSheet()
        }
        .sheet(item: $pendingRequest) { request in
            AllowDenySheet(
                request: request,
                onAllow: {
                    try? model.core.approvePairing(id: request.id)
                    pendingRequest = nil
                    reload()
                },
                onDeny: {
                    try? model.core.denyPairing(id: request.id)
                    pendingRequest = nil
                }
            )
        }
        .confirmationDialog(
            "Revoke “\(pendingRevokePeer?.name ?? "iPhone")”?",
            isPresented: Binding(get: { pendingRevokePeer != nil }, set: { if !$0 { pendingRevokePeer = nil } }),
            titleVisibility: .visible
        ) {
            Button("Revoke", role: .destructive) {
                if let peer = pendingRevokePeer {
                    revoke(peer)
                }
                pendingRevokePeer = nil
            }
            Button("Cancel", role: .cancel) {
                pendingRevokePeer = nil
            }
        } message: {
            Text("This will immediately disconnect the phone from using this Mac's models.")
        }
    }

    private func reload() {
        peers = model.core.peers()
    }

    private func revoke(_ peer: Peer) {
        try? model.core.revokePeer(id: peer.id)
        reload()
    }

    /// No push/event mechanism exists for "a device just asked to pair"
    /// (that's the same `CoreClient.events` gap flagged throughout this
    /// project), so this polls `pendingPairings()` every second - cheap,
    /// local, no network call.
    private func startPolling() {
        pollTask = Task {
            while !Task.isCancelled {
                if pendingRequest == nil, let request = model.core.pendingPairings().first {
                    pendingRequest = request
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}

extension PairingRequest: @retroactive Identifiable {}

private struct AllowDenySheet: View {
    let request: PairingRequest
    let onAllow: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(spacing: PocketSpacing.s24) {
            Image(systemName: "iphone")
                .font(.system(size: 40))
                .foregroundStyle(PocketColor.accent)
            Text("Allow “\(request.deviceName)” to use this Mac?")
                .font(.pocket(.title))
                .multilineTextAlignment(.center)
            HStack(spacing: PocketSpacing.s16) {
                Button("Deny", role: .destructive, action: onDeny)
                Button("Allow", action: onAllow)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(PocketSpacing.s32)
        .frame(width: 360)
    }
}

/// C14: QR + countdown ring, with "Enter code manually" fallback (the
/// same `pocketai://pair?...` string, just displayed as text instead of
/// a scanned code).
private struct MacPairingQRSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var qrString: String?
    @State private var errorText: String?
    @State private var secondsRemaining = 300
    @State private var countdownTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: PocketSpacing.s24) {
            Text("Scan with PocketAI on iPhone").font(.pocket(.title))

            if let qrString {
                ZStack {
                    qrImage(for: qrString)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 240, height: 240)
                    Circle()
                        .trim(from: 0, to: CGFloat(secondsRemaining) / 300)
                        .stroke(PocketColor.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 260, height: 260)
                    PocketMarkView(state: .idle, size: 40)
                }
                Text("Expires in \(secondsRemaining)s")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textTertiary)
                Text("Or enter manually: \(qrString)")
                    .font(.pocket(.mono))
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .frame(maxWidth: 400)
            } else if let errorText {
                Text(errorText).font(.pocket(.body)).foregroundStyle(PocketColor.statusBad)
            }

            Button("Close") { dismiss() }
        }
        .padding(PocketSpacing.s32)
        .frame(width: 440)
        .task {
            do {
                qrString = try model.core.pairingOfferQrString()
                startCountdown()
            } catch {
                errorText = "Couldn't generate a pairing code: \(error.localizedDescription)"
            }
        }
        .onDisappear { countdownTask?.cancel() }
    }

    private func startCountdown() {
        countdownTask = Task {
            while !Task.isCancelled && secondsRemaining > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                secondsRemaining -= 1
            }
        }
    }

    private func qrImage(for string: String) -> Image {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cgImage = context.createCGImage(output, from: output.extent)
        else {
            return Image(systemName: "qrcode")
        }
        return Image(decorative: cgImage, scale: 1, orientation: .up)
    }
}
