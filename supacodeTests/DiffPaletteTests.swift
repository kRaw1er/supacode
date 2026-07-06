import AppKit
import Testing

@testable import supacode

/// Phase 3 — the semantic diff palette DERIVED from system colors (the single
/// scoped exemption). Colors resolve differently in light vs dark, the style
/// generation bumps on demand, and the semantic identities are locked as a
/// structural golden (3.14 + `paletteThemeGolden` + the OKLab number fill).
@MainActor
struct DiffPaletteTests {
  private let aqua = NSAppearance(named: .aqua)!
  private let darkAqua = NSAppearance(named: .darkAqua)!

  /// Resolve a dynamic `NSColor` to concrete sRGB components under `appearance`.
  private func components(_ color: NSColor, _ appearance: NSAppearance) -> [CGFloat] {
    var out: [CGFloat] = []
    appearance.performAsCurrentDrawingAppearance {
      let srgb = color.usingColorSpace(.sRGB) ?? .black
      out = [srgb.redComponent, srgb.greenComponent, srgb.blueComponent, srgb.alphaComponent]
    }
    return out
  }

  // MARK: - 3.14 palette resolves differently in light vs dark; generation bumps

  @Test func paletteResolvesDifferentLightVsDark() {
    let palette = DiffPalette.shared
    // The deletion base (systemRed) resolves to different components across the
    // two appearances — the whole point of deriving from a system color. (macOS
    // resolves systemRed differently light↔dark; systemGreen happens to match, so
    // the appearance-tracking assertion rides the deletion palette.)
    #expect(components(palette.delBase, aqua) != components(palette.delBase, darkAqua))
    #expect(
      components(palette.changeBar(for: .deletion)!, aqua) != components(palette.changeBar(for: .deletion)!, darkAqua))
    #expect(
      components(palette.rowTint(for: .deletion)!, aqua) != components(palette.rowTint(for: .deletion)!, darkAqua))

    // styleDidChange bumps the generation used to key the CTLine cache.
    let before = palette.styleGeneration
    palette.styleDidChange()
    #expect(palette.styleGeneration == before + 1)
  }

  // MARK: - paletteThemeGolden — semantic identity lock (colors fill in at P4)

  @Test func paletteThemeGolden() {
    let palette = DiffPalette.shared
    // Row tint / change bar exist only for changed rows.
    #expect(palette.rowTint(for: .context) == nil)
    #expect(palette.changeBar(for: .context) == nil)
    #expect(palette.rowTint(for: .addition) != nil)
    #expect(palette.rowTint(for: .deletion) != nil)

    // Reference pierre hexes (style.css:23-28): added ~#0dbe4e, deleted #ff2e3f,
    // modified #009fff. We derive from system colors instead, so the golden locks
    // the SEMANTIC identity (green-ish add, red-ish del, distinct modified) that
    // tracks light/dark, not a hard-pinned hex.
    for appearance in [aqua, darkAqua] {
      let add = components(palette.addBase, appearance)
      let del = components(palette.delBase, appearance)
      let modified = components(palette.modifiedBase, appearance)
      #expect(add[1] > add[0] && add[1] > add[2], "addition base not green-dominant in \(appearance.name)")
      #expect(del[0] > del[1] && del[0] > del[2], "deletion base not red-dominant in \(appearance.name)")
      #expect(add != del)
      #expect(modified != add && modified != del)
    }
  }

  // MARK: - OKLab number-column fill (opaque, perceptual, per origin)

  @Test func numberColumnFillIsPerceptualAndOriginScoped() {
    let palette = DiffPalette.shared
    #expect(palette.numberColumnFill(for: .context) == nil)
    let add = palette.numberColumnFill(for: .addition)
    let del = palette.numberColumnFill(for: .deletion)
    #expect(add != nil)
    #expect(del != nil)
    // The blend resolves to a concrete, opaque color under each appearance.
    for appearance in [aqua, darkAqua] {
      let addComponents = components(add!, appearance)
      #expect(addComponents[3] == 1)  // opaque (blended over the editor bg, not an alpha tint)
      #expect(components(add!, appearance) != components(del!, appearance))
    }
  }
}
