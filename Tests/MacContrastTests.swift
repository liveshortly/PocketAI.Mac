import AppKit
import PocketUI
import SwiftUI
import XCTest

@testable import PocketAI

/// Contrast for the pairs the Mac actually composes, measured against the
/// shipped asset catalog rather than a hand-copied hex list.
///
/// `PocketUITests/ContrastTests` in Core now reads `Colors.xcassets` directly
/// too, so the drift this suite was written to catch (it asserted canvas
/// `F7F6F3` where the app ships `F3F1E9`) is gone. This one still earns its
/// place: it measures the pairs the *Mac* composes — the accent as text, the
/// status colours, and `bgRaised` — through `NSColor` in both appearances,
/// which is the only way to see a translucent foreground as it actually
/// renders.
///
/// Token definitions live in Core and cannot be changed from this repo; the
/// pairs that fail are recorded with `XCTExpectFailure` and their measured
/// ratio, so the suite stays honest and green, and reports "expected failure
/// did not occur" once Core fixes them.
final class MacContrastTests: XCTestCase {

    private static let aa = 4.5
    private static let aaa = 7.0

    // MARK: - Measuring

    private func components(_ color: Color, _ appearance: NSAppearance.Name)
        -> (r: Double, g: Double, b: Double, a: Double) {
        var out = (r: 0.0, g: 0.0, b: 0.0, a: 1.0)
        NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
            guard let resolved = NSColor(color).usingColorSpace(.sRGB) else { return }
            out = (
                Double(resolved.redComponent), Double(resolved.greenComponent),
                Double(resolved.blueComponent), Double(resolved.alphaComponent)
            )
        }
        return out
    }

    /// WCAG 2.x ratio with `fg` flattened over `bg` first, the way a
    /// translucent foreground actually renders.
    ///
    /// Goes straight to `PocketContrast.ratio` on the resolved components.
    /// The old version formatted both colours into hex strings and back, which
    /// no longer compiles (`PocketRawColor` and `flattenedRatio` were removed
    /// when Core's contrast suite was rewritten) and was lossy anyway —
    /// `Int(channel * 255)` truncates rather than rounds.
    private func ratio(_ fg: Color, on bg: Color, _ appearance: NSAppearance.Name) -> Double {
        let f = components(fg, appearance)
        let b = components(bg, appearance)
        let flattened = (
            r: f.r * f.a + b.r * (1 - f.a),
            g: f.g * f.a + b.g * (1 - f.a),
            b: f.b * f.a + b.b * (1 - f.a)
        )
        return PocketContrast.ratio(flattened, (r: b.r, g: b.g, b: b.b))
    }

    private func assertContrast(
        _ fg: Color, _ fgName: String, on bg: Color, _ bgName: String,
        atLeast minimum: Double, file: StaticString = #filePath, line: UInt = #line
    ) {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let measured = ratio(fg, on: bg, appearance)
            XCTAssertGreaterThanOrEqual(
                measured, minimum,
                String(
                    format: "%@ on %@ (%@) is %.2f:1, needs %.1f:1",
                    fgName, bgName, appearance == .aqua ? "light" : "dark", measured, minimum),
                file: file, line: line)
        }
    }

    // MARK: - What the Mac composes

    /// Body and label text on every surface the HUD puts it on.
    func testTextOnEverySurfaceMeetsAA() {
        let surfaces: [(Color, String)] = [
            (PocketColor.bgCanvas, "bgCanvas"),
            (PocketColor.bgSurface, "bgSurface"),
            (PocketColor.bgRaised, "bgRaised"),
            (PocketColor.bgSunken, "bgSunken"),
        ]
        for (surface, name) in surfaces {
            assertContrast(
                PocketColor.textPrimary, "textPrimary", on: surface, name, atLeast: Self.aaa)
            assertContrast(
                PocketColor.textSecondary, "textSecondary", on: surface, name, atLeast: Self.aa)
        }
    }

    /// The accent as text: `HUDLabel(tint: .accent)`, the "◆ assistant"
    /// marker, `Link("License")`, the "Re-run" benchmark action, the model
    /// chip, and `statusOk` wherever it labels something.
    func testAccentTextOnTheSurfacesItIsUsedOn() {
        assertContrast(
            PocketColor.accent, "accent", on: PocketColor.bgSurface, "bgSurface",
            atLeast: Self.aa)
        assertContrast(
            PocketColor.accent, "accent", on: PocketColor.bgCanvas, "bgCanvas",
            atLeast: Self.aa)
        assertContrast(
            PocketColor.accent, "accent", on: PocketColor.bgRaised, "bgRaised",
            atLeast: Self.aa)
        assertContrast(
            PocketColor.accentOnAccent, "accentOnAccent", on: PocketColor.accent, "accent",
            atLeast: Self.aa)
    }

    /// `HUDChip(tint:)` and the status text the HUD renders on its panels.
    func testStatusTextOnItsPanels() {
        assertContrast(
            PocketColor.statusOk, "statusOk", on: PocketColor.bgSurface, "bgSurface",
            atLeast: Self.aa)
        assertContrast(
            PocketColor.statusInfo, "statusInfo", on: PocketColor.bgSurface, "bgSurface",
            atLeast: Self.aa)
        assertContrast(
            PocketColor.statusBad, "statusBad", on: PocketColor.bgSurface, "bgSurface",
            atLeast: Self.aa)
        assertContrast(
            PocketColor.statusBad, "statusBad", on: PocketColor.bgCanvas, "bgCanvas",
            atLeast: Self.aa)
    }

    // MARK: - Known failures, pinned with their measured ratio

    /// `textTertiary` is the HUD's label colour — `HUDLabel`'s default tint,
    /// every row subtitle, every caption. On `bgRaised` (white in light mode,
    /// `#242320` in dark) it is the worst pair in the app.
    /// Now passes on every surface. It used to be the worst pair in the app
    /// (3.69:1 on bgRaised, 2.97:1 on bgSunken in light — under even the 3:1
    /// non-text floor) and was pinned with `XCTExpectFailure`; Core darkened
    /// `text.tertiary` (light 8A867A → 6A675E, dark 7A756B → 8E8A81) and this
    /// suite reported "expected failure ... but none recorded", which is the
    /// pinned-failure pattern doing its job. Asserted plainly now, so a
    /// regression fails here.
    func testTextTertiaryOnEverySurface() {
        for (surface, name) in [
            (PocketColor.bgCanvas, "bgCanvas"), (PocketColor.bgSurface, "bgSurface"),
            (PocketColor.bgRaised, "bgRaised"), (PocketColor.bgSunken, "bgSunken"),
        ] {
            assertContrast(
                PocketColor.textTertiary, "textTertiary", on: surface, name, atLeast: Self.aa)
        }
    }

    /// `statusWarn` labels the NON-COMMERCIAL chip and the warning panels. Its
    /// light value is too light for text at any size.
    func testStatusWarnAsText() {
        XCTExpectFailure(
            """
            status.warn's light value is too light for text: measured 3.48:1 on \
            bgSurface and 3.26:1 on bgCanvas. The dark value passes (7.8:1). \
            Fix is a darker light-mode status.warn in PocketAI.Core.
            """)
        for (surface, name) in [
            (PocketColor.bgSurface, "bgSurface"), (PocketColor.bgCanvas, "bgCanvas"),
        ] {
            assertContrast(
                PocketColor.statusWarn, "statusWarn", on: surface, name, atLeast: Self.aa)
        }
    }

    /// `statusBad` on a raised surface — the only accent/status pair that
    /// fails in dark mode rather than light.
    func testStatusBadOnRaised() {
        XCTExpectFailure(
            """
            status.bad on bgRaised measures 4.32:1 in dark mode; AA needs \
            4.5:1. The light value passes (5.4:1). The dark status.bad in \
            PocketAI.Core needs a touch more contrast.
            """)
        assertContrast(
            PocketColor.statusBad, "statusBad", on: PocketColor.bgRaised, "bgRaised",
            atLeast: Self.aa)
    }

    /// The Mac accent is the shared green (UI-38): `#1F7A4D` light, `#3DB27E`
    /// dark, the same pair as iPhone and Android. No `mac` idiom override.
    func testAccentIsGreen() {
        for (appearance, hex) in [
            (NSAppearance.Name.aqua, (0x1F, 0x7A, 0x4D)), (.darkAqua, (0x3D, 0xB2, 0x7E)),
        ] {
            let c = components(PocketColor.accent, appearance)
            let measured = (
                Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded())
            )
            XCTAssertTrue(
                measured == hex,
                "accent (\(appearance == .aqua ? "light" : "dark")) is \(measured), expected \(hex)")
        }
    }

    /// Accent on the sunken surface: `HUDChip` sits on `bgSunken`. Computed
    /// for the UI-38 green: light `#1F7A4D` on `#EAE7DC` is 4.30:1 (dark
    /// 7.37:1), so this fails AA in light mode until Core darkens the light
    /// accent (nearest passing hue-preserving green: `#1E764A`, 4.53:1).
    func testAccentOnSunken() {
        assertContrast(
            PocketColor.accent, "accent", on: PocketColor.bgSunken, "bgSunken",
            atLeast: Self.aa)
    }
}
