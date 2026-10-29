import AppKit
import PocketUI
import SwiftUI
import XCTest

@testable import PocketAI

/// Contrast for the pairs the Mac actually composes, measured against the
/// shipped asset catalog rather than a hand-copied hex list.
///
/// `PocketUITests/ContrastTests` in Core covers text-on-background through
/// `PocketContrastTokens`, but those literals have drifted from
/// `Colors.xcassets` (it asserts canvas `F7F6F3` where the app ships
/// `F3F1E9`, and primary `15161A` where the app ships `1A1916`), and it never
/// looks at the accent, the status colours or `bgRaised`. This reads the real
/// colours, so drift fails here.
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
    private func ratio(_ fg: Color, on bg: Color, _ appearance: NSAppearance.Name) -> Double {
        let f = components(fg, appearance)
        let b = components(bg, appearance)
        let flattened = PocketRawColor(
            String(format: "%02X%02X%02X",
                   Int((f.r * f.a + b.r * (1 - f.a)) * 255),
                   Int((f.g * f.a + b.g * (1 - f.a)) * 255),
                   Int((f.b * f.a + b.b * (1 - f.a)) * 255)))
        let background = PocketRawColor(
            String(format: "%02X%02X%02X",
                   Int(b.r * 255), Int(b.g * 255), Int(b.b * 255)))
        return PocketContrast.flattenedRatio(fg: flattened, bg: background)
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

    /// The green identity as text: `HUDLabel(tint: .accent)`, the "◆ assistant"
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
    func testTextTertiaryOnEverySurface() {
        XCTExpectFailure(
            """
            text.tertiary fails AA on every surface the Mac uses: measured \
            3.69:1 on bgRaised and 3.25:1 on bgCanvas in light mode, 3.46:1 on \
            bgRaised in dark, and 2.97:1 on bgSunken in light — below even the \
            3:1 non-text floor. The failures below carry each measured ratio. \
            Fix is a darker text.tertiary in PocketAI.Core's Colors.xcassets; \
            nothing in this repo can correct it.
            """)
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

    /// Accent on the sunken surface: `HUDChip` sits on `bgSunken`, and an
    /// accent-tinted chip there is just under the bar in light mode.
    func testAccentOnSunken() {
        XCTExpectFailure(
            """
            accent on bgSunken measures 4.35:1 in light mode; AA needs 4.5:1. \
            It passes on every other surface (5.05 on bgSurface, 5.32 on \
            bgRaised, 4.71 on bgCanvas) and in dark mode (7.4:1), so the cheap \
            fix is to stop tinting chips on bgSunken with the accent — but the \
            colours themselves are Core's.
            """)
        assertContrast(
            PocketColor.accent, "accent", on: PocketColor.bgSunken, "bgSunken",
            atLeast: Self.aa)
    }
}
