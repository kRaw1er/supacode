import AppKit
import SupacodeSettingsShared

/// True diff-body search — pierre ships NONE (`packages/trees/src/model/searchHelpers.ts`
/// exports only `normalizeSearchQuery`, wired to the file-tree sidebar, never the
/// diff body), so this is greenfield against our own model.
///
/// It searches each file's frozen UTF-16 blob buffers (Phase 9's `oldBlobUTF16` /
/// `newBlobUTF16`, projected into Phase-3 `UTF16LineStore`s), NOT the rendered views.
/// A `.line` chunk folded inside a collapsed gap (Phase 7) is not a materialized row
/// and not even a tree leaf — the ONLY place its text exists is the blob buffer, so
/// scanning the buffer is what makes "match content that isn't on screen" possible at
/// all. Each hit maps offset → `(side, line, col)` via the store's O(log n) line-start
/// table; nav expands the collapsed region containing the match (Phase 7) THEN reveals
/// it (Phase 10). Coverage is a first-class result, never a silent cut.
@MainActor
final class DiffSearchController {
  /// One match, resolved against `side`'s blob store. `lineNumber` is the **0-based
  /// store line index** (== `UTF16LineStore.line(atUTF16Offset:)`), NOT a 1-based git
  /// line number — every consumer closure (`rowForLine` / `expandToReveal`) and the
  /// `SearchableFile.deletedOldLines` set are in this same 0-based store space so the
  /// scan stays internally consistent. `utf16Range` is line-relative.
  struct Match: Equatable, Sendable {
    let fileID: FileChange.ID
    let side: DiffSide  // .new for context/additions, .old for deletions
    let lineNumber: Int  // 0-based line index within `side`'s blob store
    let utf16Range: Range<Int>  // line-relative UTF-16 range of the hit
  }

  /// What the search actually covered — the anti-silent-truncation contract. Any
  /// bound (match ceiling, not-yet-streamed blob, binary / large-file-capped file) is
  /// recorded here AND logged, never a truncated match set surfaced as "complete".
  struct Coverage: Equatable, Sendable {
    var scannedFiles = 0
    var skipped: [Skip] = []  // binary / capped / not-yet-streamed
    var matchCeilingReached = false  // hit `maxMatches`
    var isCapped: Bool { matchCeilingReached || !skipped.isEmpty }
  }

  /// One file dropped from the scan, with the reason (surfaced in the UI + logged).
  struct Skip: Equatable, Sendable {
    let fileID: FileChange.ID
    let reason: Reason
  }

  /// Why a file was not searched. `.blobNotMaterialized` is re-runnable — the file's
  /// batch simply has not streamed in yet (Phase 9), so re-searching once it arrives
  /// covers it.
  enum Reason: String, Sendable {
    case binary
    case largeFileCapped
    case blobNotMaterialized
  }

  /// Hard ceiling so a pathological corpus can't build an unbounded match list; the
  /// hit is REPORTED (Coverage + log), never silently dropped.
  private static let maxMatches = 20_000
  private nonisolated static let logger = SupaLogger("DiffSearch")

  /// The document's segment model — held so the controller documents that it searches
  /// THIS diff's model (the row/gap classification is delegated to `rowForLine` /
  /// `expandToReveal`, which keeps this file free of a build-order dependency on
  /// Phases 7 / 10).
  private unowned let tree: ChunkTree
  /// Phase 10 seam: anchored scroll-to for a materialized row.
  private let reveal: (_ row: Int) -> Void
  /// Phase 7 seam: expand the collapsed region so `(side, line)` becomes a real row;
  /// returns that row index (nil if it could not be materialized). Invoked ONLY when
  /// `rowForLine` reports the line is currently folded.
  private let expandToReveal: (_ side: DiffSide, _ line: Int) -> Int?
  /// Phase 1 seam: the materialized row for a diff line, or nil if it is folded inside
  /// a collapsed expander (offscreen).
  private let rowForLine: (_ side: DiffSide, _ line: Int) -> Int?

  private(set) var query = ""
  private(set) var matches: [Match] = []
  private(set) var current: Int?  // index into `matches`
  private(set) var coverage = Coverage()

  init(
    tree: ChunkTree,
    reveal: @escaping (Int) -> Void,
    expandToReveal: @escaping (DiffSide, Int) -> Int?,
    rowForLine: @escaping (DiffSide, Int) -> Int?
  ) {
    self.tree = tree
    self.reveal = reveal
    self.expandToReveal = expandToReveal
    self.rowForLine = rowForLine
  }

  // MARK: - Search (over the model, never the views)

  /// Run `raw` over every file's blob stores. Resets the prior result. A file that is
  /// binary / capped / not-yet-materialized is a reported skip (Coverage + log), never
  /// a silent omission.
  func search(_ raw: String, files: [SearchableFile]) {
    query = raw
    matches = []
    current = nil
    coverage = Coverage()
    let needle = raw as NSString
    guard needle.length > 0 else { return }

    for file in files {
      if file.isBinary {
        skip(file.id, .binary)
        continue
      }
      if file.isLargeFileCapped {
        skip(file.id, .largeFileCapped)
        continue
      }
      guard file.newStore != nil || file.oldStore != nil else {
        skip(file.id, .blobNotMaterialized)
        continue
      }
      coverage.scannedFiles += 1
      // New side: a FULL scan covers every context + addition line, INCLUDING lines
      // currently folded inside a collapsed gap (offscreen). This is the whole point —
      // we scan the buffer, not the rendered rows.
      if let store = file.newStore, !scan(store, side: .new, file: file, needle: needle) { return }
      // Old side: restrict to deletions. A context line is byte-identical in both
      // blobs, so scanning the whole old blob would double-report a context match
      // already found on the new side; only deletions are old-exclusive content.
      if let store = file.oldStore,
        !scan(store, side: .old, file: file, needle: needle, restrictTo: file.deletedOldLines)
      {
        return
      }
    }
  }

  /// Scan one store for `needle`, appending hits. Returns `false` when the match
  /// ceiling is reached (the caller stops the whole search; the cap is logged +
  /// recorded in Coverage). `restrictTo`, when non-nil, keeps only hits on those
  /// 0-based store line indices (the old-side deletions gate).
  private func scan(
    _ store: UTF16LineStore, side: DiffSide, file: SearchableFile,
    needle: NSString, restrictTo lines: Set<Int>? = nil
  ) -> Bool {
    let text = store.nsString  // UTF-16-native (Phase 3): O(1) indexed
    var from = 0
    while from < text.length {
      let found = text.range(
        of: needle as String,
        options: [.caseInsensitive, .literal],
        range: NSRange(location: from, length: text.length - from))
      guard found.location != NSNotFound else { break }
      let line = store.line(atUTF16Offset: found.location)  // Phase 3 line-start table, O(log n)
      if lines == nil || lines?.contains(line) == true {
        let lineStart = store.utf16Offset(ofLine: line)
        let relativeLow = found.location - lineStart
        let relativeRange = relativeLow..<(relativeLow + found.length)
        matches.append(Match(fileID: file.id, side: side, lineNumber: line, utf16Range: relativeRange))
        if matches.count >= Self.maxMatches {
          coverage.matchCeilingReached = true
          Self.logger.warning(
            "search coverage capped: \(matches.count) matches (ceiling \(Self.maxMatches)); "
              + "later files/lines NOT searched — refine the query")
          return false
        }
      }
      // Advance by at least one unit so a zero-width match still progresses (guards a
      // pathological zero-length needle; `needle.length > 0` already gates the caller).
      from = found.location + max(1, found.length)
    }
    return true
  }

  // MARK: - Navigation (expand-then-reveal)

  /// Move to the next match (wraps). No-op on an empty result set.
  func next() { advance(by: +1) }
  /// Move to the previous match (wraps). No-op on an empty result set.
  func previous() { advance(by: -1) }

  private func advance(by step: Int) {
    guard !matches.isEmpty else { return }
    let count = matches.count
    let index = ((current ?? (step > 0 ? -1 : 0)) + step + count) % count
    current = index
    focus(matches[index])
  }

  /// Expand the collapsed region containing the match BEFORE scrolling, so an
  /// offscreen / folded match is actually reachable, then reveal it (Phase 10).
  private func focus(_ match: Match) {
    let row =
      rowForLine(match.side, match.lineNumber)
      ?? expandToReveal(match.side, match.lineNumber)  // fold → materialize (Phase 7)
    guard let row else {
      Self.logger.warning("search match \(match.fileID)#\(match.lineNumber) not resolvable to a row")
      return
    }
    reveal(row)  // Phase 10 shared primitive: anchored scroll-to
  }

  private func skip(_ id: FileChange.ID, _ reason: Reason) {
    coverage.skipped.append(Skip(fileID: id, reason: reason))
    Self.logger.warning("search skipped \(id): \(reason.rawValue) — not covered")
  }
}

/// One frozen, searchable file: its UTF-16 blob stores (Phase 3, backed by Phase 9's
/// `[UInt16]` blobs) plus the cheap metadata that gates coverage. NOT `Sendable` — it
/// holds `@MainActor` `UTF16LineStore` references and only ever lives on the main
/// actor alongside `DiffSearchController`.
@MainActor
struct SearchableFile {
  let id: FileChange.ID
  let isBinary: Bool  // FileChange.isBinary
  let isLargeFileCapped: Bool  // FileChange.isLargeFileCapped
  let newStore: UTF16LineStore?  // nil until the batch streams in (Phase 9)
  let oldStore: UTF16LineStore?
  /// 0-based OLD-store line indices that are deletions — the only old-exclusive
  /// content (context lives in both blobs), so the old scan is restricted to these to
  /// avoid double-reporting a context match already found on the new side.
  let deletedOldLines: Set<Int>

  init(
    id: FileChange.ID,
    isBinary: Bool,
    isLargeFileCapped: Bool,
    newStore: UTF16LineStore?,
    oldStore: UTF16LineStore?,
    deletedOldLines: Set<Int>
  ) {
    self.id = id
    self.isBinary = isBinary
    self.isLargeFileCapped = isLargeFileCapped
    self.newStore = newStore
    self.oldStore = oldStore
    self.deletedOldLines = deletedOldLines
  }
}
