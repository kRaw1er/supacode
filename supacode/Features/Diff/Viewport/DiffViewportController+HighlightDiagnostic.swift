#if DEBUG
  import AppKit
  import CoreText
  import SupacodeSettingsShared

  /// OPT-IN runtime diagnostic for the "deep-scroll highlight on wrong characters" report
  /// (`docs/reviews/2026-07-11-diff-highlight-wrong-ranges-FINDINGS.md`). Enabled only when
  /// the app runs with `SUPACODE_DIFF_HL_DIAG=1` in the environment; otherwise every call is
  /// an immediate no-op. Fires at most ~once per 0.7 s from `layoutVisibleChunks` (so it
  /// captures the settled frame, not every scroll tick).
  ///
  /// For each drawn row of every materialized `LineRowView` it cross-checks the ACTUAL baked
  /// glyph colors against (a) the runs the engine has cached for that row's blob line under
  /// the controller's CURRENT blob OID and (b) the blob's own line text. It logs ONLY the
  /// rows that disagree — so a clean scroll prints one summary line, and a miscolored line
  /// prints exactly what it drew vs what it should have. This catches runtime-only conditions
  /// the headless repros cannot model: a stale render-context blob OID, a content↔blob-line
  /// index desync, or corrupted cached runs.
  ///
  /// SupaLogger prints to STDOUT in DEBUG, so run `make run-app` (foreground) or a detached
  /// launch of the DerivedData binary with the env var set, scroll to the bad region, and
  /// grep the output for `[hldiag]`.
  extension DiffViewportController {
    private static let diagLogger = SupaLogger("DiffHLDiag")

    /// Env-gated + throttled entry point called from `layoutVisibleChunks`.
    func runHighlightDiagnosticThrottled() {
      guard ProcessInfo.processInfo.environment["SUPACODE_DIFF_HL_DIAG"] != nil else { return }
      let now = CFAbsoluteTimeGetCurrent()
      guard now - hlDiagLastDump > 0.7 else { return }
      hlDiagLastDump = now
      runHighlightDiagnostic()
    }

    private func runHighlightDiagnostic() {
      let base = DiffPalette.shared.codeForeground.cgColor
      let views = documentView.subviews.compactMap { $0 as? LineRowView }
      guard !views.isEmpty else { return }

      var suspects = 0
      var visNewLo = Int.max
      var visNewHi = Int.min
      var checkedColored = 0

      for view in views {
        // Resolve THIS leaf's expected blobs by its own fileID — the same per-file lookup
        // the render path uses, so the diagnostic catches a wrong-file resolution too.
        let entry = view.configuredFileID.flatMap { highlightBlobsByFile[$0] }
        for render in view.typesetRowRenders {
          guard let content = render.content, !render.ctLines.isEmpty, !content.isEmpty else { continue }
          // In unified mode a deletion row shows the OLD side; everything else the NEW side.
          let isOld = render.unifiedOrigin == .deletion
          guard let number = isOld ? render.oldNumber : render.newNumber else { continue }
          guard let blob = isOld ? entry?.old : entry?.new,
            let query = DiffHighlightEngine.grammarQueryName(forPath: blob.path)
          else { continue }
          if !isOld {
            visNewLo = min(visNewLo, number)
            visNewHi = max(visNewHi, number)
          }

          let blobLine = number - 1
          let cached = highlightEngine.cachedRuns(blobOID: blob.blobOID, queryName: query, blobLine: blobLine)

          // (1) content the row DISPLAYS vs the blob line the runs describe (index/content desync).
          let lines = decodedBlobLines(blob)
          let blobText = blobLine >= 0 && blobLine < lines.count ? lines[blobLine] : nil
          let contentMismatch = blobText != nil && content != blobText

          // (2) each baked glyph color vs the runs cached for THIS blob line (stale OID / wrong runs).
          var offenders: [Int] = []
          let length = (content as NSString).length
          for index in 0..<length {
            guard let drawn = Self.foreground(render.ctLines, at: index) else { continue }
            if Self.sameColor(drawn, base) { continue }  // base color needs no run
            checkedColored += 1
            let justified = cached.contains { run in
              run.range.contains(index) && Self.sameColor(HighlightTheme.color(for: run.capture).cgColor, drawn)
            }
            if !justified {
              offenders.append(index)
              if offenders.count >= 12 { break }
            }
          }

          guard contentMismatch || !offenders.isEmpty else { continue }
          suspects += 1
          let runsDesc = cached.map { "\($0.range.lowerBound)..<\($0.range.upperBound)=\($0.capture)" }
            .joined(separator: ",")
          Self.diagLogger.error(
            "[hldiag] SUSPECT side=\(isOld ? "old" : "new") line=\(number) oid=\(blob.blobOID.prefix(8)) "
              + "q=\(query) contentMismatch=\(contentMismatch) offenderCols=\(offenders)\n"
              + "    content =\(content.debugDescription)\n"
              + "    blobLine=\((blobText ?? "<out-of-range>").debugDescription)\n"
              + "    runs    =[\(runsDesc)]")
          if suspects >= 30 { break }
        }
        if suspects >= 30 { break }
      }

      let visRange = visNewLo <= visNewHi ? "\(visNewLo)..\(visNewHi)" : "-"
      let files = highlightBlobsByFile.map { id, blobs in
        "\(id):\(blobs.new?.blobOID.prefix(8) ?? "-")\(blobs.disabled ? "(off)" : "")"
      }.sorted().joined(separator: ",")
      Self.diagLogger.info(
        "[hldiag] settle mode=\(mode == .unified ? "unified" : "split") files=[\(files)] "
          + "visibleNew=\(visRange) coloredGlyphsChecked=\(checkedColored) suspects=\(suspects)")
    }

    /// The blob's line text (0x0A split, matching `DiffHighlightEngine.lineStarts` and
    /// `DiffLine.content`), decoded once per OID.
    private func decodedBlobLines(_ blob: HighlightBlobInput) -> [String] {
      if let cached = hlDiagBlobLines[blob.blobOID] { return cached }
      let text = String(decoding: blob.utf16, as: UTF16.self)
      let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
      hlDiagBlobLines[blob.blobOID] = lines
      return lines
    }

    /// Foreground color of whichever wrapped sub-line covers `stringIndex` (sub-line runs
    /// carry LINE-relative UTF-16 indices, so a wrapped line is probed across all of them).
    private static func foreground(_ subLines: [CTLine], at stringIndex: Int) -> CGColor? {
      for sub in subLines {
        if let color = foreground(sub, at: stringIndex) { return color }
      }
      return nil
    }

    /// Foreground color of the `CTRun` covering `stringIndex` in one `ctLine`.
    private static func foreground(_ ctLine: CTLine, at stringIndex: Int) -> CGColor? {
      let runs = CTLineGetGlyphRuns(ctLine) as? [CTRun] ?? []
      for run in runs {
        let range = CTRunGetStringRange(run)
        guard stringIndex >= range.location, stringIndex < range.location + range.length else { continue }
        let attrs = CTRunGetAttributes(run) as NSDictionary
        if let nsColor = attrs[NSAttributedString.Key.foregroundColor.rawValue] as? NSColor {
          return nsColor.cgColor
        }
        guard let value = attrs[kCTForegroundColorAttributeName as String],
          CFGetTypeID(value as CFTypeRef) == CGColor.typeID
        else { return nil }
        return unsafeDowncast(value as AnyObject, to: CGColor.self)
      }
      return nil
    }

    /// sRGB-tolerant color equality (catalog NSColor vs raw CGColor render the same).
    private static func sameColor(_ lhs: CGColor?, _ rhs: CGColor?) -> Bool {
      guard let lhs, let rhs, let space = CGColorSpace(name: CGColorSpace.sRGB),
        let lhsSRGB = lhs.converted(to: space, intent: .defaultIntent, options: nil),
        let rhsSRGB = rhs.converted(to: space, intent: .defaultIntent, options: nil),
        let lhsParts = lhsSRGB.components, let rhsParts = rhsSRGB.components, lhsParts.count == rhsParts.count
      else { return false }
      return zip(lhsParts, rhsParts).allSatisfy { abs($0 - $1) < 0.02 }
    }
  }
#endif
