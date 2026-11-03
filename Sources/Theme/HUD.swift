import PocketUI
import SwiftUI

/// The Mac app's visual idiom: the LiveShortly terminal HUD — warm paper,
/// hairline rules, uppercase monospaced labels, and the shared PocketUI green
/// accent (the same green as iPhone and Android, UI-38).
///
/// Everything here composes PocketUI tokens; no literal colors live in feature
/// code.
enum HUD {
    /// Corner radius for panels and cards. Small — the HUD reads as ruled
    /// surfaces, not floating pills.
    static let radius: CGFloat = 8
    static let hairline: CGFloat = 1
    /// Tracking applied to uppercase labels.
    static let labelTracking: CGFloat = 0.9
}

/// Small uppercase monospaced caption — the HUD's section and field label.
struct HUDLabel: View {
    private let text: String
    private let tint: Color

    init(_ text: String, tint: Color = PocketColor.textTertiary) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text.uppercased())
            .font(.pocket(.caption))
            .tracking(HUD.labelTracking)
            .foregroundStyle(tint)
            .accessibilityLabel(text)
    }
}

/// A hairline rule. The HUD separates with lines, not shadows.
struct HUDRule: View {
    var body: some View {
        Rectangle()
            .fill(PocketColor.lineHairline)
            .frame(height: HUD.hairline)
            .accessibilityHidden(true)
    }
}

/// Live/idle status dot with a soft halo, matching the LiveShortly badge.
///
/// The pulse is computed from the clock (`TimelineView`), not driven by an
/// implicit `.repeatForever` animation. That animation, started from
/// `onAppear` during the sidebar's first layout pass, also captured the dot's
/// position change, so the footer dot kept travelling between its first
/// layout spot and the footer and looked detached (MAC-20). A per-frame
/// opacity has no transaction to leak into layout.
struct HUDDot: View {
    var tint: Color = PocketColor.statusOk
    var pulsing: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if pulsing && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                    core.opacity(Self.pulse(at: context.date))
                }
            } else {
                core
            }
        }
        // The halo overflows the 7 pt layout box, as before.
        .background(Circle().fill(tint.opacity(0.18)).frame(width: 15, height: 15))
        .accessibilityHidden(true)
    }

    private var core: some View {
        Circle().fill(tint).frame(width: 7, height: 7)
    }

    /// 0.3...1 ease, 1.7 s period — the old 0.85 s autoreversing pulse.
    static func pulse(at date: Date) -> Double {
        let phase = date.timeIntervalSinceReferenceDate * 2 * .pi / 1.7
        return 0.65 + 0.35 * cos(phase)
    }
}

/// The LIVE capsule used in sidebar rows and session headers.
struct HUDLiveBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            HUDDot(pulsing: true)
            Text("LIVE")
                .font(.pocket(.caption))
                .tracking(HUD.labelTracking)
                .foregroundStyle(PocketColor.statusOk)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(PocketColor.statusOk.opacity(0.14)))
        .accessibilityLabel("Live")
    }
}

/// A neutral capsule for counts and short states (model name, event count).
struct HUDChip: View {
    let text: String
    var tint: Color = PocketColor.textSecondary
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(.pocket(.caption))
            .foregroundStyle(filled ? PocketColor.accentOnAccent : tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(filled ? PocketColor.accent : PocketColor.bgSunken)
            )
            .overlay(
                Capsule().stroke(
                    filled ? Color.clear : PocketColor.lineHairline,
                    lineWidth: HUD.hairline
                )
            )
    }
}

extension View {
    /// Panel surface with a hairline border — the HUD's one container style.
    func hudPanel(_ fill: Color = PocketColor.bgSurface) -> some View {
        background(
            RoundedRectangle(cornerRadius: HUD.radius, style: .continuous).fill(fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HUD.radius, style: .continuous)
                .stroke(PocketColor.lineHairline, lineWidth: HUD.hairline)
        )
    }

    /// Tints a panel with the accent — used for the one element that matters
    /// on a screen (a pending permission, the active selection).
    func hudAccentPanel() -> some View {
        background(
            RoundedRectangle(cornerRadius: HUD.radius, style: .continuous)
                .fill(PocketColor.accentSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: HUD.radius, style: .continuous)
                .stroke(PocketColor.accent.opacity(0.45), lineWidth: HUD.hairline)
        )
    }
}

/// Primary action button: filled accent, square-ish, monospaced label.
struct HUDButtonStyle: ButtonStyle {
    var prominent: Bool = false
    var destructive: Bool = false
    /// A disabled button must look disabled — otherwise it reads as broken
    /// when a click does nothing.
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let tint: Color = destructive ? PocketColor.statusBad : PocketColor.accent
        return configuration.label
            .font(.pocket(.headline))
            .foregroundStyle(prominent ? PocketColor.accentOnAccent : tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: HUD.radius, style: .continuous)
                    .fill(prominent ? tint : PocketColor.bgSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: HUD.radius, style: .continuous)
                    .stroke(
                        prominent ? Color.clear : PocketColor.lineStrong,
                        lineWidth: HUD.hairline
                    )
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == HUDButtonStyle {
    static var hud: HUDButtonStyle { HUDButtonStyle() }
    static var hudProminent: HUDButtonStyle { HUDButtonStyle(prominent: true) }
    static var hudDestructive: HUDButtonStyle { HUDButtonStyle(destructive: true) }
}

/// Formats a byte count the way the HUD does everywhere (2.4 GB, 812 MB).
func hudBytes(_ bytes: UInt64) -> String {
    let f = ByteCountFormatter()
    f.allowedUnits = [.useMB, .useGB]
    f.countStyle = .file
    return f.string(fromByteCount: Int64(bytes))
}

/// Relative timestamp for list rows ("2h ago", "just now").
func hudRelative(_ epochSeconds: Int64) -> String {
    let date = Date(timeIntervalSince1970: TimeInterval(epochSeconds))
    if Date().timeIntervalSince(date) < 60 { return "just now" }
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f.localizedString(for: date, relativeTo: Date())
}
