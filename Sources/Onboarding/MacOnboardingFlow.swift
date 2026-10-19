import SwiftUI
import PocketKit
import PocketUI

/// MAC-05: 02-design-system.md §7.1's Mac onboarding.
/// Award-winning first-run experience:
/// - Centered, paced layout with generous breathing room
/// - Large display typography, animated PocketMark
/// - Live hardware checklist animation
/// - Curated first model selection with FitBadge and memory budget
/// - Mac-only iPhone pairing offer card
struct MacOnboardingFlow: View {
    enum Step: Int { case welcome, deviceCheck, pickModel, downloading, pairMac, ready }

    let core: CoreClient
    let deviceProfile: DeviceProfile
    let onFinished: () -> Void
    var onOpenDevices: (() -> Void)? = nil

    @State private var step: Step = .welcome
    @State private var selectedModelId: String?
    @State private var catalog: [CatalogEntry] = []

    var body: some View {
        ZStack {
            PocketColor.bgCanvas
                .ignoresSafeArea()

            VStack {
                switch step {
                case .welcome:
                    MacOnboardingWelcomeView {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                            step = .deviceCheck
                        }
                    }
                case .deviceCheck:
                    MacOnboardingDeviceCheckView(profile: deviceProfile) {
                        catalog = core.catalog(filter: CatalogFilter(modality: .text, curatedOnly: true, installedOnly: false))
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                            step = .pickModel
                        }
                    }
                case .pickModel:
                    MacOnboardingPickModelView(catalog: catalog) { modelId in
                        selectedModelId = modelId
                        if let modelId, modelId != AppleFoundationModelsEngine.modelId {
                            try? core.startDownload(modelId: modelId)
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                                step = .downloading
                            }
                        } else {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                                step = .pairMac
                            }
                        }
                    }
                case .downloading:
                    MacOnboardingDownloadingView(
                        core: core,
                        modelId: selectedModelId ?? "",
                        onSkipToApple: AppleFoundationModelsEngine.isAvailable ? {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                                step = .pairMac
                            }
                        } : nil,
                        onReady: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                                step = .pairMac
                            }
                        }
                    )
                case .pairMac:
                    MacOnboardingPairCardView(
                        onSkip: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.86)) {
                                step = .ready
                            }
                        },
                        onOpenDevices: {
                            if let onOpenDevices {
                                onOpenDevices()
                            } else {
                                step = .ready
                            }
                        }
                    )
                case .ready:
                    MacOnboardingReadyView(onStart: onFinished)
                }
            }
            .frame(maxWidth: 580)
            .padding(PocketSpacing.gutterMac)
        }
        .frame(minWidth: 700, minHeight: 560)
    }
}

private struct MacOnboardingWelcomeView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: PocketSpacing.s24) {
            Spacer(minLength: 20)

            PocketMarkView(state: .working(tokPerSec: 28), size: 84)
                .padding(.bottom, PocketSpacing.s8)

            VStack(spacing: PocketSpacing.s8) {
                Text("Private AI that lives on your devices.")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(PocketColor.textPrimary)

                Text("Run modern open-weights models locally on your Mac's Apple Silicon GPU. Zero cloud, zero accounts, completely offline.")
                    .font(.pocket(.callout))
                    .foregroundStyle(PocketColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
            }

            VStack(alignment: .leading, spacing: PocketSpacing.s12) {
                bulletCard(icon: "laptopcomputer", title: "Runs on this Mac, even offline", subtitle: "All inference runs locally using Metal and MLX.")
                bulletCard(icon: "lock.shield.fill", title: "Nothing leaves without you seeing it", subtitle: "Inspect every outbound request live in Network Proof.")
                bulletCard(icon: "iphone.gen3", title: "Use your Mac's models from iPhone", subtitle: "Pair over local Wi-Fi to run larger models on your phone.")
            }
            .padding(.vertical, PocketSpacing.s8)

            Spacer(minLength: 20)

            Button("Get Started") {
                onContinue()
            }
            .buttonStyle(.pocketPrimary)
            .controlSize(.large)

            Spacer(minLength: 10)
        }
    }

    private func bulletCard(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: PocketSpacing.s12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(PocketColor.accent)
                .frame(width: 36, height: 36)
                .background(PocketColor.accentSoft)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.pocket(.headline))
                    .foregroundStyle(PocketColor.textPrimary)
                Text(subtitle)
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textSecondary)
            }

            Spacer()
        }
        .padding(PocketSpacing.s12)
        .background(PocketColor.bgSurface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(PocketColor.lineHairline, lineWidth: 0.8)
        )
    }
}

private struct MacOnboardingDeviceCheckView: View {
    let profile: DeviceProfile
    let onContinue: () -> Void

    @State private var revealedRows = 0

    private var rows: [(icon: String, title: String, subtitle: String)] {
        var r = [
            ("cpu", "\(profile.chip) with Apple Silicon Metal Acceleration", "Optimized unified memory architecture"),
            ("memorychip", "\(formatMacBytes(profile.totalRamBytes)) Unified Memory", "Allocated up to \(formatMacBytes(profile.appMemoryLimitBytes)) safely for models"),
            ("internaldrive", "\(formatMacBytes(profile.freeDiskBytes)) Free Storage Available", "Ample space to download weights"),
        ]
        if AppleFoundationModelsEngine.isAvailable {
            r.append(("apple.logo", "Apple Intelligence Ready", "System on-device model supported with zero download"))
        }
        return r
    }

    var body: some View {
        VStack(spacing: PocketSpacing.s24) {
            Spacer(minLength: 20)

            PocketMarkView(state: .working(tokPerSec: nil), size: 64)

            VStack(spacing: PocketSpacing.s8) {
                Text("Analyzing your Mac hardware…")
                    .font(.pocket(.title))
                    .fontWeight(.bold)
                    .foregroundStyle(PocketColor.textPrimary)

                Text("Checking chip generation and unified memory headroom.")
                    .font(.pocket(.callout))
                    .foregroundStyle(PocketColor.textSecondary)
            }

            VStack(alignment: .leading, spacing: PocketSpacing.s12) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index < revealedRows {
                        HStack(spacing: PocketSpacing.s12) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(PocketColor.statusOk)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title)
                                    .font(.pocket(.headline))
                                    .foregroundStyle(PocketColor.textPrimary)
                                Text(row.subtitle)
                                    .font(.pocket(.caption))
                                    .foregroundStyle(PocketColor.textSecondary)
                            }

                            Spacer()
                        }
                        .padding(PocketSpacing.s12)
                        .background(PocketColor.bgSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(PocketColor.lineHairline, lineWidth: 0.8)
                        )
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
            }
            .frame(maxWidth: 480)

            Spacer(minLength: 20)

            HStack(spacing: PocketSpacing.s8) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                Text("We read this strictly on your device. It is never sent anywhere.")
                    .font(.pocket(.caption))
            }
            .foregroundStyle(PocketColor.textTertiary)

            Spacer(minLength: 10)
        }
        .task {
            for _ in rows {
                try? await Task.sleep(nanoseconds: 280_000_000)
                withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                    revealedRows += 1
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
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
            VStack(spacing: PocketSpacing.s20) {
                VStack(spacing: PocketSpacing.s4) {
                    Text("Pick your first model")
                        .font(.pocket(.title))
                        .fontWeight(.bold)
                        .foregroundStyle(PocketColor.textPrimary)

                    Text("Curated for your Mac's memory profile with instant local inference.")
                        .font(.pocket(.callout))
                        .foregroundStyle(PocketColor.textSecondary)
                }

                if AppleFoundationModelsEngine.isAvailable {
                    MacOnboardingAppleCard { onPick(AppleFoundationModelsEngine.modelId) }
                }

                if let recommended {
                    VStack(alignment: .leading, spacing: PocketSpacing.s12) {
                        HStack {
                            Text("RECOMMENDED")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(PocketColor.accent)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(PocketColor.accentSoft)
                                .clipShape(Capsule())

                            Spacer()

                            FitBadge(kind: fitKind(recommended.fit.verdict), reason: recommended.fit.reason)
                        }

                        HStack(spacing: PocketSpacing.s16) {
                            PocketMarkView(state: .working(tokPerSec: 28), size: 36)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(recommended.manifest.displayName)
                                    .font(.pocket(.headline))
                                    .foregroundStyle(PocketColor.textPrimary)

                                Text("\(recommended.manifest.family) · \(recommended.manifest.quant) · Fast & smart")
                                    .font(.pocket(.caption))
                                    .foregroundStyle(PocketColor.textSecondary)
                            }

                            Spacer()

                            Button("Download \(formatMacBytes(recommended.manifest.estRuntimeBytes))") {
                                onPick(recommended.manifest.id)
                            }
                            .buttonStyle(.pocketPrimary)
                            .controlSize(.large)
                        }
                    }
                    .padding(PocketSpacing.s16)
                    .background(PocketColor.bgSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(PocketColor.accent.opacity(0.4), lineWidth: 1.5)
                    )
                }

                if !alternates.isEmpty {
                    VStack(alignment: .leading, spacing: PocketSpacing.s8) {
                        Text("OTHER OPTIONS")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(PocketColor.textTertiary)

                        ForEach(alternates, id: \.manifest.id) { entry in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.manifest.displayName)
                                        .font(.pocket(.body))
                                        .fontWeight(.medium)
                                    Text("\(entry.manifest.family) · \(formatMacBytes(entry.manifest.estRuntimeBytes))")
                                        .font(.pocket(.caption))
                                        .foregroundStyle(PocketColor.textSecondary)
                                }

                                Spacer()

                                Button("Choose") {
                                    onPick(entry.manifest.id)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(PocketSpacing.s12)
                            .background(PocketColor.bgSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(PocketColor.lineHairline, lineWidth: 0.8)
                            )
                        }
                    }
                    .frame(maxWidth: 480)
                }
            }
            .padding(.vertical, PocketSpacing.s16)
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
            HStack(spacing: PocketSpacing.s12) {
                Image(systemName: "apple.logo")
                    .font(.system(size: 20))
                    .foregroundStyle(PocketColor.textPrimary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Start instantly with Apple Intelligence")
                        .font(.pocket(.headline))
                        .foregroundStyle(PocketColor.textPrimary)
                    Text("Zero download needed · Built into macOS")
                        .font(.pocket(.caption))
                        .foregroundStyle(PocketColor.textSecondary)
                }

                Spacer()

                Image(systemName: "arrow.right")
                    .foregroundStyle(PocketColor.textTertiary)
            }
            .padding(PocketSpacing.s16)
            .background(PocketColor.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(PocketColor.lineHairline, lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: 480)
    }
}

private struct MacOnboardingDownloadingView: View {
    let core: CoreClient
    let modelId: String
    let onSkipToApple: (() -> Void)?
    let onReady: () -> Void

    @State private var entry: CatalogEntry?

    private static let tips = [
        "Models stay completely on this Mac — nothing is ever uploaded to a cloud server.",
        "You can switch between installed models anytime from the Models tab.",
        "Pair your iPhone from the Devices tab to query this Mac's models from your phone.",
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
            }

            VStack(spacing: PocketSpacing.s4) {
                Text("Downloading \(entry?.manifest.displayName ?? "Model")…")
                    .font(.pocket(.title))
                    .fontWeight(.bold)

                Text("Background download via Apple Silicon Metal engine")
                    .font(.pocket(.caption))
                    .foregroundStyle(PocketColor.textSecondary)
            }

            VStack(alignment: .leading, spacing: PocketSpacing.s12) {
                ForEach(Self.tips, id: \.self) { tip in
                    HStack(alignment: .top, spacing: PocketSpacing.s8) {
                        Image(systemName: "checkmark.seal")
                            .foregroundStyle(PocketColor.accent)
                        Text(tip)
                            .font(.pocket(.footnote))
                            .foregroundStyle(PocketColor.textSecondary)
                    }
                }
            }
            .padding(PocketSpacing.s16)
            .background(PocketColor.bgSurface)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(maxWidth: 480)

            if let onSkipToApple {
                Button("Try Apple's model while you wait", action: onSkipToApple)
                    .font(.pocket(.footnote))
            }

            Spacer()
        }
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

private struct MacOnboardingPairCardView: View {
    let onSkip: () -> Void
    let onOpenDevices: () -> Void

    var body: some View {
        VStack(spacing: PocketSpacing.s20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(PocketColor.accentSoft)
                    .frame(width: 80, height: 80)
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.system(size: 36))
                    .foregroundStyle(PocketColor.accent)
            }

            VStack(spacing: PocketSpacing.s4) {
                Text("Use PocketAI from your iPhone")
                    .font(.pocket(.title))
                    .fontWeight(.bold)

                Text("Pair your iPhone to query this Mac's models from anywhere on your Wi-Fi network.")
                    .font(.pocket(.callout))
                    .foregroundStyle(PocketColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }

            VStack(spacing: PocketSpacing.s8) {
                Button("Pair an iPhone…", action: onOpenDevices)
                    .buttonStyle(.pocketPrimary)
                    .controlSize(.large)

                Button("Skip for Now", action: onSkip)
                    .buttonStyle(.plain)
                    .font(.pocket(.footnote))
                    .foregroundStyle(PocketColor.textTertiary)
            }
            .padding(.top, PocketSpacing.s8)

            Spacer()
        }
    }
}

private struct MacOnboardingReadyView: View {
    let onStart: () -> Void

    private static let suggestions = [
        "Explain this Rust borrow checker error",
        "Summarize this quarterly financial report",
        "Draft a polite email reply",
    ]

    var body: some View {
        VStack(spacing: PocketSpacing.s24) {
            Spacer()

            PocketMarkView(state: .idle, size: 72)

            VStack(spacing: PocketSpacing.s8) {
                Text("Your Mac is Ready")
                    .font(.pocket(.title))
                    .fontWeight(.bold)
                    .foregroundStyle(PocketColor.textPrimary)

                Text("All systems nominal. Your model runs entirely on this Mac.")
                    .font(.pocket(.callout))
                    .foregroundStyle(PocketColor.textSecondary)
            }

            VStack(spacing: PocketSpacing.s8) {
                ForEach(Self.suggestions, id: \.self) { suggestion in
                    Button {
                        onStart()
                    } label: {
                        HStack {
                            Image(systemName: "sparkle")
                                .foregroundStyle(PocketColor.accent)
                            Text(suggestion)
                                .font(.pocket(.body))
                            Spacer()
                            Image(systemName: "arrow.right")
                                .foregroundStyle(PocketColor.textTertiary)
                        }
                        .padding(PocketSpacing.s12)
                        .background(PocketColor.bgSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(PocketColor.lineHairline, lineWidth: 0.8)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 460)

            Button("Start Chatting") {
                onStart()
            }
            .buttonStyle(.pocketPrimary)
            .controlSize(.large)

            Spacer()
        }
    }
}
