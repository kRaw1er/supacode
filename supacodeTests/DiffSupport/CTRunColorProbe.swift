import AppKit
import CoreText

@testable import supacode

/// CT-HEADLESS render probe: reads the FOREGROUND color a `CTRun` actually carries
/// in a drawn `CTLine`, so a render test asserts the pixel-bound color WITHOUT
/// sampling pixels ("rects + tokens, never pixels"). Extracted from
/// `DiffSyntaxRenderTests` so the syntax-pipeline integration suite shares one
/// battle-tested extractor instead of re-deriving the `NSColor` / raw-`CGColor`
/// attribute-key duality every time.
@MainActor
enum CTRunColorProbe {
  /// Foreground of the `CTRun` covering `stringIndex` in one `CTLine`, or `nil`
  /// when no run carries that index / no color attribute is set.
  static func foreground(_ ctLine: CTLine, at stringIndex: Int) -> CGColor? {
    let runs = CTLineGetGlyphRuns(ctLine) as? [CTRun] ?? []
    for run in runs {
      let range = CTRunGetStringRange(run)
      if stringIndex >= range.location && stringIndex < range.location + range.length {
        let attrs = CTRunGetAttributes(run) as NSDictionary
        // `NSMutableAttributedString.foregroundColor` rides the "NSColor" key as an
        // NSColor; CoreText's own key is CTForegroundColor (a CGColor). Accept either.
        if let nsColor = attrs[NSAttributedString.Key.foregroundColor.rawValue] as? NSColor {
          return nsColor.cgColor
        }
        guard let value = attrs[kCTForegroundColorAttributeName as String],
          CFGetTypeID(value as CFTypeRef) == CGColor.typeID
        else { return nil }
        return unsafeDowncast(value as AnyObject, to: CGColor.self)
      }
    }
    return nil
  }

  /// sRGB-tolerant color equality (0.02 per component) — two colors resolved from
  /// different spaces (NSColor catalog vs CGColor) compare equal when they render
  /// the same.
  static func sameColor(_ lhs: CGColor?, _ rhs: CGColor?) -> Bool {
    guard let lhs, let rhs, let space = CGColorSpace(name: CGColorSpace.sRGB),
      let lhsSRGB = lhs.converted(to: space, intent: .defaultIntent, options: nil),
      let rhsSRGB = rhs.converted(to: space, intent: .defaultIntent, options: nil),
      let lhsParts = lhsSRGB.components, let rhsParts = rhsSRGB.components, lhsParts.count == rhsParts.count
    else { return false }
    return zip(lhsParts, rhsParts).allSatisfy { abs($0 - $1) < 0.02 }
  }
}
