import Foundation
import Testing

/// I5 — golden-of-model. Snapshots the deterministic, appearance-independent
/// MODEL as plain text (pierre snapshots the DOM; we snapshot the projected row
/// model), **never pixels**. `UPDATE_GOLDEN=1` regenerates the `.txt` under a
/// `__Goldens__/` folder next to the calling test file.
enum GoldenText {
  /// Assert `actual` matches the committed golden named `name`. With
  /// `UPDATE_GOLDEN=1` set, (re)writes the golden instead of comparing.
  static func assert(
    _ actual: String,
    _ name: String,
    filePath: StaticString = #filePath,
    sourceLocation: SourceLocation = #_sourceLocation
  ) {
    let url = goldenURL(name: name, filePath: filePath)
    if ProcessInfo.processInfo.environment["UPDATE_GOLDEN"] == "1" {
      try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try? actual.write(to: url, atomically: true, encoding: .utf8)
      return
    }
    guard let expected = try? String(contentsOf: url, encoding: .utf8) else {
      Issue.record(
        "Missing golden '\(name)'. Run the suite with UPDATE_GOLDEN=1 to create it.\n--- actual ---\n\(actual)",
        sourceLocation: sourceLocation
      )
      return
    }
    if expected != actual {
      let message = "Golden '\(name)' mismatch. Run UPDATE_GOLDEN=1 to update."
      Issue.record(
        "\(message)\n--- expected ---\n\(expected)\n--- actual ---\n\(actual)",
        sourceLocation: sourceLocation
      )
    }
  }

  private static func goldenURL(name: String, filePath: StaticString) -> URL {
    URL(fileURLWithPath: "\(filePath)")
      .deletingLastPathComponent()
      .appendingPathComponent("__Goldens__", isDirectory: true)
      .appendingPathComponent("\(name).txt", isDirectory: false)
  }
}
