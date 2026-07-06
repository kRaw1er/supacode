import Foundation
import SwiftTreeSitter

@testable import supacode

/// I1 — the shared diff-fixture DSL. Promotes the `DiffRowBuilderTests:11-52`
/// helpers (`line` / `file` / `hunk`) into reusable, pure builders so every later
/// phase constructs `FileChange` / `DiffHunk` / `DiffLine` the same way.
///
/// `store` / `batch` / `namedRange` land with their consuming phases (the UTF-16
/// store is Phase 3, the streaming batch Phase 9, the `NamedRange` bucketer builder
/// is Phase 4) — this file owns the model DSL.
enum DiffFixture {
  /// A single diff line with defaulted numbers/content (the `DiffRowBuilderTests`
  /// `line(_:old:new:_:noNewline:)` helper).
  static func line(
    _ origin: DiffLineOrigin,
    old: Int? = nil,
    new: Int? = nil,
    _ content: String = "x",
    noNewline: Bool = false
  ) -> DiffLine {
    DiffLine(origin: origin, oldLineNumber: old, newLineNumber: new, content: content, noNewlineAtEof: noNewline)
  }

  /// A modified-file `FileChange` (overridable status / binary / capped).
  static func file(
    path: String = "a.swift",
    status: FileStatus = .modified,
    binary: Bool = false,
    capped: Bool = false
  ) -> FileChange {
    FileChange(
      oldPath: path,
      newPath: path,
      status: status,
      addedLines: 1,
      removedLines: 1,
      isBinary: binary,
      isLargeFileCapped: capped,
      hasLongLines: false,
      similarity: 0
    )
  }

  /// A hunk whose old/new counts are derived from the line origins (matching the
  /// `DiffRowBuilderTests.hunk` helper), so `verifyHunkLineValues` is satisfied by
  /// construction.
  static func hunk(
    _ lines: [DiffLine],
    oldStart: Int = 1,
    newStart: Int = 1,
    header: String = "@@ -1 +1 @@"
  ) -> DiffHunk {
    let oldCount = lines.filter { $0.origin == .context || $0.origin == .deletion }.count
    let newCount = lines.filter { $0.origin == .context || $0.origin == .addition }.count
    return DiffHunk(
      oldStart: oldStart,
      oldCount: oldCount,
      newStart: newStart,
      newCount: newCount,
      header: header,
      lines: lines
    )
  }

  /// A UTF-16 code-unit blob of a string (seed for the Phase-3 store DSL; kept
  /// here so I1 owns the primitive).
  static func blob(_ text: String) -> [UInt16] {
    Array(text.utf16)
  }

  /// A `NamedRange` for the Phase-4 highlight bucketer, from a capture name and a
  /// **UTF-16** `NSRange`. `NamedRange(name:range:)` stores `range.byteRange`
  /// (`×2`) and reads back `tsRange.bytes.range` (`÷2`), so `.range` round-trips to
  /// the SAME UTF-16 range — which the bucketer consumes directly (C10: NO second
  /// `/2`, unlike the shipping `SyntaxHighlighter.swift:109-110`).
  static func namedRange(_ name: String, _ range: NSRange) -> NamedRange {
    NamedRange(name: name, range: range)
  }
}
