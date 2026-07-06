import AppKit

// ⚠️ SCOPED CONVENTION EXEMPTION — DiffPalette.swift
// ---------------------------------------------------------------------------
// This file is THE single sanctioned deviation from the CLAUDE.md "Never use
// custom colors, always use system provided ones" convention. Every semantic
// diff color below is DERIVED from a system color (no hand-picked hex) so it
// still tracks light/dark + the user's accent. The exemption is kept SCOPED to
// this one file (the brainstorm's "ONE scoped exemption for the diff palette").
//
// There is NO swiftlint rule to disable: `.swiftlint.yml` defines only
// `store_state_mutation_in_views`, none for colors (⚠️ Deepening note 1). A
// literal lint disable directive would be a no-op (and could trip the
// superfluous-disable-command rule). This header comment IS the exemption +
// reviewer sign-off surface. If the team ever adds a `custom_rules:` regex that
// forbids `NSColor` synthesis, THEN scope a real per-line lint disable to this
// file — not before.
//
// Reference bases (pierre `style.css:23-28`, recorded, NOT hardcoded here):
// added #0dbe4e/#5ecc71, modified #009fff/#69b1ff, deleted #ff2e3f/#ff6762. We
// deliberately derive from `.systemGreen` / `.systemRed` / `.controlAccentColor`
// instead so the palette follows the OS + accent rather than pinning pierre hex.
// ---------------------------------------------------------------------------

/// Semantic diff colors derived from system colors. Row tint / change bar /
/// word-diff emphasis / opaque number-column fill all resolve per the current
/// `NSAppearance`, so light ↔ dark is free. `styleGeneration` bumps on
/// appearance / Dynamic Type / zoom and is folded into the `CTLineCache` key +
/// measured-height validity (it invalidates CTLine + heights, NEVER parse trees).
@MainActor
final class DiffPalette {
  static let shared = DiffPalette()

  private(set) var styleGeneration = 0

  /// Bump on appearance / Dynamic Type / zoom. Invalidates CTLine + heights (not
  /// parse trees — those are keyed on `(blobOID, lang)`, theme-independent).
  func styleDidChange() { styleGeneration &+= 1 }

  // MARK: - System-sourced bases

  // Resolve per current `NSAppearance` ⇒ light/dark for free. No literal hex.
  var addBase: NSColor { .systemGreen }
  var delBase: NSColor { .systemRed }
  var modifiedBase: NSColor { .controlAccentColor }
  var codeForeground: NSColor { .labelColor }

  // MARK: - Row substrate

  /// Full-row add/del tint. 0.12 alpha = pierre `--diffs-bg-addition` 12%
  /// (style.css:192) AND the current `DiffCellView.swift:458-464` viewer tint, so
  /// the render swap is pixel-neutral. (Pierre bumps to 20% in dark — ⚠️ note 3;
  /// we keep a flat 0.12 both, low-risk since the system base already tracks
  /// appearance.)
  func rowTint(for origin: DiffLineOrigin) -> NSColor? {
    switch origin {
    case .addition: return Self.alphaTint(addBase, alpha: 0.12)
    case .deletion: return Self.alphaTint(delBase, alpha: 0.12)
    case .context, .noNewlineMarker: return nil
    }
  }

  /// Intra-line word-diff emphasis (drawn ON TOP of the row tint, hand-filled
  /// behind the glyphs in Phase 5). pierre `--diffs-bg-*-emphasis` = 0.15 (light)
  /// / 0.20 (dark) (style.css:184-205); the current viewer uses 0.35. We adopt a
  /// calmer middle 0.18 (⚠️ Deepening note 2 — confirm with design in Phase 5).
  func wordEmphasis(isOld: Bool) -> NSColor {
    Self.alphaTint(isOld ? delBase : addBase, alpha: 0.18)
  }

  /// A **dynamic** alpha-tinted color that re-resolves `base` under each
  /// appearance before applying `alpha`. Plain `NSColor.withAlphaComponent(_:)`
  /// snapshots a dynamic system color to whatever appearance is current at the
  /// call site (losing light/dark tracking), so a tint built once and drawn later
  /// under a different appearance would be wrong — this wrapper avoids that.
  static func alphaTint(_ base: NSColor, alpha: CGFloat) -> NSColor {
    NSColor(name: nil) { appearance in
      var tinted = base
      appearance.performAsCurrentDrawingAppearance {
        tinted = (base.usingColorSpace(.sRGB) ?? base).withAlphaComponent(alpha)
      }
      return tinted
    }
  }

  /// The change-bar color for a row's origin (4pt rail: solid add / dashed del).
  func changeBar(for origin: DiffLineOrigin) -> NSColor? {
    switch origin {
    case .addition: return addBase
    case .deletion: return delBase
    case .context, .noNewlineMarker: return nil
    }
  }

  /// Opaque number-column fill = the change-bar base blended over the editor
  /// background in a **perceptual** space (pierre `color-mix(in lab, …)` analog —
  /// NOT sRGB `blended(withFraction:)`, which muddies at low fractions). Returns
  /// a dynamic color so it re-blends per appearance.
  func numberColumnFill(for origin: DiffLineOrigin) -> NSColor? {
    guard let base = changeBar(for: origin) else { return nil }
    return Self.blendOKLab(base, over: .textBackgroundColor, baseFraction: 0.14)
  }

  // MARK: - Perceptual (OKLab) blend

  /// `base` mixed over `background` at `baseFraction` in OKLab (the perceptual
  /// space `color-mix(in lab, …)` uses). Returns a **dynamic** `NSColor` so the
  /// blend re-resolves for each appearance the drawing code hands it. Static (no
  /// top-level free function, per CLAUDE.md).
  static func blendOKLab(_ base: NSColor, over background: NSColor, baseFraction: CGFloat) -> NSColor {
    NSColor(name: nil) { appearance in
      var mixed = background
      appearance.performAsCurrentDrawingAppearance {
        let baseLab = oklab(of: base)
        let backgroundLab = oklab(of: background)
        let fraction = min(max(baseFraction, 0), 1)
        let blended = OKLab(
          lightness: backgroundLab.lightness + (baseLab.lightness - backgroundLab.lightness) * fraction,
          chromaA: backgroundLab.chromaA + (baseLab.chromaA - backgroundLab.chromaA) * fraction,
          chromaB: backgroundLab.chromaB + (baseLab.chromaB - backgroundLab.chromaB) * fraction
        )
        mixed = color(fromOKLab: blended)
      }
      return mixed
    }
  }

  /// The three OKLab channels (perceptual lightness + the two chroma axes). Named
  /// so the identifier-name lint is satisfied and the math stays readable.
  private struct OKLab {
    var lightness: CGFloat
    var chromaA: CGFloat
    var chromaB: CGFloat
  }

  /// Resolve an `NSColor` to OKLab. Falls back to the sRGB conversion of the
  /// resolved color; `.textBackgroundColor` / `.systemGreen` etc. always convert.
  private static func oklab(of color: NSColor) -> OKLab {
    let srgb = color.usingColorSpace(.sRGB) ?? color.usingColorSpace(.deviceRGB) ?? .black
    let red = linearize(srgb.redComponent)
    let green = linearize(srgb.greenComponent)
    let blue = linearize(srgb.blueComponent)
    // linear sRGB → LMS (Björn Ottosson OKLab matrices).
    let long = 0.4122214708 * red + 0.5363325363 * green + 0.0514459929 * blue
    let medium = 0.2119034982 * red + 0.6806995451 * green + 0.1073969566 * blue
    let short = 0.0883024619 * red + 0.2817188376 * green + 0.6299787005 * blue
    let longRoot = cbrt(long)
    let mediumRoot = cbrt(medium)
    let shortRoot = cbrt(short)
    return OKLab(
      lightness: 0.2104542553 * longRoot + 0.7936177850 * mediumRoot - 0.0040720468 * shortRoot,
      chromaA: 1.9779984951 * longRoot - 2.4285922050 * mediumRoot + 0.4505937099 * shortRoot,
      chromaB: 0.0259040371 * longRoot + 0.7827717662 * mediumRoot - 0.8086757660 * shortRoot
    )
  }

  private static func color(fromOKLab lab: OKLab) -> NSColor {
    let longRoot = lab.lightness + 0.3963377774 * lab.chromaA + 0.2158037573 * lab.chromaB
    let mediumRoot = lab.lightness - 0.1055613458 * lab.chromaA - 0.0638541728 * lab.chromaB
    let shortRoot = lab.lightness - 0.0894841775 * lab.chromaA - 1.2914855480 * lab.chromaB
    let long = longRoot * longRoot * longRoot
    let medium = mediumRoot * mediumRoot * mediumRoot
    let short = shortRoot * shortRoot * shortRoot
    let red = 4.0767416621 * long - 3.3077115913 * medium + 0.2309699292 * short
    let green = -1.2684380046 * long + 2.6097574011 * medium - 0.3413193965 * short
    let blue = -0.0041960863 * long - 0.7034186147 * medium + 1.7076147010 * short
    return NSColor(
      srgbRed: min(max(delinearize(red), 0), 1),
      green: min(max(delinearize(green), 0), 1),
      blue: min(max(delinearize(blue), 0), 1),
      alpha: 1
    )
  }

  private static func linearize(_ channel: CGFloat) -> CGFloat {
    channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
  }

  private static func delinearize(_ channel: CGFloat) -> CGFloat {
    channel <= 0.0031308 ? channel * 12.92 : 1.055 * pow(channel, 1 / 2.4) - 0.055
  }
}
