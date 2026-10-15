import SwiftUI
import PocketKit
import PocketUI

/// MAC-05: `02-design-system.md` §7.1's Mac onboarding - the same 5 steps
/// as the iPhone's `OnboardingFlow` (UI-07), plus the Mac-only 6th card
/// pointing at Devices/pairing. Kept as its own Mac-sized view (gutterMac,
/// no TabView dependency) rather than sharing code with the iPhone flow -
/// the layouts and navigation container differ enough that a shared type
/// would need its own abstraction for no real reuse.
struct MacOnboardingFlow: View {
    enum Step: Int { case welcome, deviceCheck, pickModel, downloading, ready, pairMac }

    let core: CoreClient
    let deviceProfile: DeviceProfile
    let onFinished: () -> Void

    @State private var step: Step = .welcome
    @State private var selectedModelId: String?
    @State private var catalog: [CatalogEntry] = []

    var body: some View {
        Group {
            switch step {
            case .welcome:
                MacOnboardingWelcomeView { step = .deviceCheck }
            case .deviceCheck:
                MacOnboardingDeviceCheckView(profile: deviceProfile) {
                    catalog = core.catalog(filter: CatalogFilter(modality: .text, curatedOnly: true, installedOnly: false))
                    step = .pickModel
                }
            case .pickModel:
                MacOnboardingPickModelView(catalog: catalog) { modelId in
                    selectedModelId = modelId
                    if let modelId, modelId != AppleFoundationModelsEngine.modelId {
                        try? core.startDownload(modelId: modelId)
                        step = .downloading
                    } else {
                        step = .pairMac
                    }
                }
            case .downloading:
                MacOnboardingDownloadingView(
                    core: core,
                    modelId: selectedModelId ?? "",
                    onSkipToApple: AppleFoundationModelsEngine.isAvailable ? { step = .pairMac } : nil,
                    onReady: { step = .pairMac }
                )
            case .pairMac:
                MacOnboardingPairCardView(onSkip: { step = .ready }, onOpenDevices: { step = .ready })
            case .ready:
                MacOnboardingReadyView(onStart: onFinished)
            }
        }
        .animation(.default, value: step)
        .frame(minWidth: 520, minHeight: 480)
        .background(PocketColor.bgCanvas)
    }
}

private struct MacOnboardingWelcomeView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: PocketSpacing.s32) {
            Spacer()
            PocketMarkView(state: .working(tokPerSec: nil), size: 96)
            Text("Private AI that lives on your devices.")
                .font(.pocket(.title))
                .multilineTextAlignment(.center)
                .foregroundStyle(PocketColor.textPrimary)

            VStack(alignment: .leading, spacing: PocketSpacing.s16) {
                MacOnboardingBulletRow(icon: "laptopcomputer", text: "Runs on this Mac, even offline")
                MacOnboardingBulletRow(icon: "eye", text: "Nothing leaves without you seeing it")
                MacOnboardingBulletRow(icon: "iphone", text: "Use it from your iPhone too")
            }
            .padding(.horizontal, PocketSpacing.gutterMac)

            Spacer()
            Button("Get started", action: onContinue)
                .buttonStyle(.borderedProminent)
                .tint(PocketColor.accent)
        }
        .padding(.horizontal, PocketSpacing.gutterMac)
        .padding(.vertical, PocketSpacing.s32)
    }
}

private struct MacOnboardingBulletRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: PocketSpacing.s12) {
            Image(systemName: icon)
                .foregroundStyle(PocketColor.accent)
            Text(text)
                .font(.pocket(.body))
                .foregroundStyle(PocketColor.textSecondary)
        }
    }
}

private struct MacOnboardingDeviceCheckView: View {
    let profile: DeviceProfile
    let onContinue: () -> Void

    @State private var revealedRows = 0

    private var rows: [String] {
        var r = [
            "\(profile.chip) · \(formatMacBytes(profile.totalRamBytes)) memory · up to \(formatMacBytes(profile.appMemoryLimitBytes)) for models",
            "\(formatMacBytes(profile.freeDiskBytes)) free storage",
        ]
        if AppleFoundationModelsEngine.isAvailable {
            r.append("Apple Intelligence available")
        }
        return r
    }

    var body: some View {
        VStack(spacing: PocketSpacing.s24) {
            Spacer()
            Text("Checking your Mac").font(.pocket(.title))
            VStack(alignment: .leading, spacing: PocketSpacing.s16) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index < revealedRows {
                        HStack(spacing: PocketSpacing.s12) {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(PocketColor.statusOk)
                            Text(row).font(.pocket(.body)).foregroundStyle(PocketColor.textPrimary)
                        }
                        .transition(.opacity)
                    }
                }
            }
            .padding(.horizontal, PocketSpacing.gutterMac)
            Spacer()
            Text("We read this on your device. It is never sent anywhere.")
                .font(.pocket(.footnote))
                .foregroundStyle(PocketColor.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, PocketSpacing.gutterMac)
        }
        .padding(.vertical, PocketSpacing.s32)
        .task {
            for _ in rows {
                try? await Task.sleep(nanoseconds: 280_000_000)
                withAnimation { revealedRows += 1 }
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            onContinue()
        }
    }
}

private func formatMacBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
}

private struct MacOnboardingPickModelView: View {
    let catalog: [CatalogEntry]
    let onPick: (String?) -> Void

    private var recommended: CatalogEntry? {
        catalog.first { $0.manifest.tags.contains("recommended") && $0.fit.verdict == .runsWell }
            ?? catalog.first { $0.fit.verdict == .runsWell }
    }

    private var alternates: [CatalogEntry] {
        catalog.filter { $0.manifest.id != recommended?.manifest.id }.prefix(2).map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: PocketSpacing.s24) {
                Text("Pick your first model").font(.pocket(.title))

                if AppleFoundationModelsEngine.isAvailable {
                    MacOnboardingAppleCard { onPick(AppleFoundationModelsEngine.modelId) }
                }

                if let recommended {
                    ModelRow(
                        data: ModelRowData(
                            name: recommended.manifest.displayName,
                            familyParamsQuant: "\(recommended.manifest.family) · \(recommended.manifest.quant)",
                            fitKind: fitKind(recommended.fit.verdict),
                            fitReason: recommended.fit.reason,
                            sizeOnDisk: formatMacBytes(recommended.manifest.estRuntimeBytes),
                            speedText: recommended.fit.estTokensPerSec.map { "\(Int($0)) tok/s" },
                            speedIsMeasured: false,
                            licenseLabel: recommended.manifest.license.spdx
                        ),
                        primaryActionLabel: "Download \(formatMacBytes(recommended.manifest.estRuntimeBytes))",
                        onPrimaryAction: { onPick(recommended.manifest.id) }
                    )
                    Text("Wi-Fi recommended")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textTertiary)
                }

                if !alternates.isEmpty {
                    Text("Other options").font(.pocket(.footnote)).foregroundStyle(PocketColor.textTertiary)
                    ForEach(alternates, id: \.manifest.id) { entry in
                        ModelRow(
                            data: ModelRowData(
                                name: entry.manifest.displayName,
                                familyParamsQuant: "\(entry.manifest.family) · \(entry.manifest.quant)",
                                fitKind: fitKind(entry.fit.verdict),
                                fitReason: entry.fit.reason,
                                sizeOnDisk: formatMacBytes(entry.manifest.estRuntimeBytes),
                                speedText: entry.fit.estTokensPerSec.map { "\(Int($0)) tok/s" },
                                speedIsMeasured: false,
                                licenseLabel: entry.manifest.license.spdx
                            ),
                            primaryActionLabel: "Choose",
                            onPrimaryAction: { onPick(entry.manifest.id) }
                        )
                    }
                }
            }
            .padding(.horizontal, PocketSpacing.gutterMac)
            .padding(.vertical, PocketSpacing.s32)
        }
    }

    private func fitKind(_ verdict: FitVerdict) -> FitBadgeKind {
        switch verdict {
        case .runsWell: return .runsWell
        case .runsSlow: return .runsSlow
        case .willNotFit: return .willNotFit
        case .notSupported: return .notSupported
        }
    }
}

private struct MacOnboardingAppleCard: View {
    let onPick: () -> Void

    var body: some View {
        Button(action: onPick) {
            VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                Text("Start instantly with Apple's on-device model")
                    .font(.pocket(.headline))
                Text("No download")
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(PocketSpacing.s16)
            .background(PocketColor.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

private struct MacOnboardingDownloadingView: View {
    let core: CoreClient
    let modelId: String
    let onSkipToApple: (() -> Void)?
    let onReady: () -> Void

    @State private var entry: CatalogEntry?

    private static let tips = [
        "Models stay on this device - nothing is uploaded.",
        "You can switch models anytime from the Models tab.",
        "Pair your iPhone to reach this Mac's bigger models.",
    ]

    var body: some View {
        VStack(spacing: PocketSpacing.s24) {
            Spacer()
            if let entry {
                DownloadProgress(
                    state: .downloading(
                        bytesDone: Int64(entry.bytesDone),
                        bytesTotal: Int64(entry.manifest.estRuntimeBytes),
                        bytesPerSecond: 18_000_000
                    ),
                    onPauseResume: {},
                    onCancel: {}
                )
                .padding(.horizontal, PocketSpacing.gutterMac)
            }
            Text("Downloading \(entry?.manifest.displayName ?? "model")…").font(.pocket(.headline))

            if let onSkipToApple {
                Button("Try Apple's model while you wait", action: onSkipToApple)
                    .font(.pocket(.footnote))
            }

            VStack(alignment: .leading, spacing: PocketSpacing.s12) {
                ForEach(Self.tips, id: \.self) { tip in
                    Text("• \(tip)").font(.pocket(.footnote)).foregroundStyle(PocketColor.textSecondary)
                }
            }
            .padding(.horizontal, PocketSpacing.gutterMac)
            Spacer()
        }
        .padding(.vertical, PocketSpacing.s32)
        .task {
            while true {
                let updated = core.catalog(filter: CatalogFilter(modality: nil, curatedOnly: false, installedOnly: false))
                    .first { $0.manifest.id == modelId }
                entry = updated
                if updated?.state == .installed {
                    onReady()
                    return
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }
}

/// §7.1's Mac-only 6th card: "Use PocketAI from your iPhone" → Devices.
private struct MacOnboardingPairCardView: View {
    let onSkip: () -> Void
    let onOpenDevices: () -> Void

    var body: some View {
        VStack(spacing: PocketSpacing.s24) {
            Spacer()
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 48))
                .foregroundStyle(PocketColor.accent)
            Text("Use PocketAI from your iPhone")
                .font(.pocket(.title))
            Text("Pair your iPhone to reach this Mac's models from anywhere on your network.")
                .font(.pocket(.body))
                .foregroundStyle(PocketColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, PocketSpacing.gutterMac)
            Button("Pair an iPhone…", action: onOpenDevices)
                .buttonStyle(.borderedProminent)
                .tint(PocketColor.accent)
            Button("Skip for now", action: onSkip)
                .font(.pocket(.footnote))
            Spacer()
        }
        .padding(.vertical, PocketSpacing.s32)
    }
}

private struct MacOnboardingReadyView: View {
    let onStart: () -> Void

    private static let suggestions = ["Summarize a long email", "Explain a concept simply", "Draft a quick reply"]

    var body: some View {
        VStack(spacing: PocketSpacing.s24) {
            Spacer()
            PocketMarkView(state: .idle, size: 64)
            Text("Ready").font(.pocket(.title))
            VStack(spacing: PocketSpacing.s8) {
                ForEach(Self.suggestions, id: \.self) { suggestion in
                    Button(suggestion, action: onStart)
                        .buttonStyle(.bordered)
                }
            }
            Button("Start chatting", action: onStart)
                .buttonStyle(.borderedProminent)
                .tint(PocketColor.accent)
            Spacer()
        }
        .padding(.horizontal, PocketSpacing.gutterMac)
        .padding(.vertical, PocketSpacing.s32)
    }
}
