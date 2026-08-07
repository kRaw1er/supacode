#if DEBUG
  import AppKit
  import CoreGraphics

  /// In-process UI automation driver for autonomous / agent-driven testing.
  ///
  /// One generic file, NO per-screen wiring: it walks the app's own accessibility
  /// tree and performs primitive, feature-agnostic operations keyed off
  /// `accessibilityIdentifier`. Add a `.accessibilityIdentifier(_:)` to a view and
  /// it is instantly drivable; nothing here changes.
  ///
  /// How the tree is read: we start at `NSApp.windows` and recurse through the
  /// `NSAccessibility` object graph. The methods (`accessibilityChildren()`,
  /// `accessibilityIdentifier()`, …) are invoked via `AnyObject` `@objc` dynamic
  /// dispatch rather than a `NSAccessibilityProtocol` cast, because SwiftUI content
  /// is exposed as accessibility PROXIES that respond to the selectors but do NOT
  /// formally conform to the Swift protocol — a static cast drops the entire SwiftUI
  /// subtree and you see only native AppKit chrome. Dynamic dispatch sees anything
  /// that answers the selector.
  ///
  /// Why NOT the `AXUIElement` C API: an `AXUIElement` query against our OWN process
  /// is a mach round-trip serviced by our own main runloop — on the main thread it
  /// deadlocks, off the main thread it crashes the app (observed). The object-graph
  /// walk is a plain in-process method call: no IPC, no deadlock, safe on main —
  /// which is where we already are (the socket query hop lands on `@MainActor`).
  ///
  /// Why `tap` uses a synthetic click and not `accessibilityPerformPress()`: a
  /// SwiftUI `.plain` `Button` inside a `List` reports a press macOS "performs"
  /// successfully but whose closure never runs (the press lands on the List cell,
  /// not the Button). So `tap` reads the element's frame, then delivers a real
  /// `.leftMouseDown` / `.leftMouseUp` pair with `CGEvent.postToPid(getpid())` at the
  /// frame center. Posting to our own pid keeps the event in THIS process's queue,
  /// never moves the real cursor, and works while the window is in the background —
  /// the exact failure mode of coordinate-based external tools. `press` stays a
  /// distinct verb for controls where the accessibility press IS honored.
  @MainActor
  enum UIAutomationDriver {
    static func handle(params: [String: String]) -> [[String: String]] {
      switch params["action"] ?? "dump" {
      case "dump":
        return dump(filter: params["filter"])
      case "exists":
        guard let id = params["id"] else { return [error("Missing id")] }
        return [["exists": find(id: id) != nil ? "1" : "0"]]
      case "tap", "click":
        guard let id = params["id"] else { return [error("Missing id")] }
        return tap(id: id)
      case "press":
        guard let id = params["id"] else { return [error("Missing id")] }
        guard let element = find(id: id) else { return [error("Not found: \(id)")] }
        return [(element.accessibilityPerformPress?() ?? false) ? ["ok": "1"] : error("AXPress returned false")]
      case "setValue", "type":
        guard let id = params["id"] else { return [error("Missing id")] }
        guard let element = find(id: id) else { return [error("Not found: \(id)")] }
        element.setAccessibilityValue?(params["text"] ?? "")
        return [["ok": "1"]]
      case let other:
        return [error("Unknown action: \(other)")]
      }
    }

    // MARK: - Primitive operations

    /// Serialize the tree (optionally substring-filtered on id/role/title) so an
    /// agent can discover what is on screen and which ids exist.
    private static func dump(filter: String?) -> [[String: String]] {
      var out: [[String: String]] = []
      var visited = 0
      for window in NSApp.windows {
        walk(window) { node, depth in
          guard visited < 5000 else { return false }
          visited += 1
          let id = identifier(node)
          let role = (node.accessibilityRole?())?.rawValue ?? "?"
          let title = titleText(node)
          if let filter, !filter.isEmpty {
            guard "\(id) \(role) \(title)".lowercased().contains(filter.lowercased()) else { return true }
          }
          var entry: [String: String] = ["role": role, "depth": String(depth)]
          if !id.isEmpty { entry["id"] = id }
          if !title.isEmpty { entry["title"] = title }
          let frame = node.accessibilityFrame?() ?? .zero
          entry["frame"] = "\(Int(frame.minX)),\(Int(frame.minY)),\(Int(frame.width)),\(Int(frame.height))"
          out.append(entry)
          return true
        }
      }
      return out.isEmpty ? [["info": "no matching elements"]] : out
    }

    /// Real synthetic click at the element's frame center — the reliable primitive
    /// for `.plain` List buttons where the accessibility press is inert.
    private static func tap(id: String) -> [[String: String]] {
      guard let element = find(id: id) else { return [error("Not found: \(id)")] }
      let frame = element.accessibilityFrame?() ?? .zero
      guard frame.width > 0, frame.height > 0 else { return [error("Zero frame (off-screen?): \(id)")] }
      // AX frames are Cocoa screen coords (bottom-left origin); CGEvent wants
      // top-left global coords. Flip against the primary (zero-origin) screen.
      let primaryHeight = (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main)?.frame.height ?? 0
      let center = CGPoint(x: frame.midX, y: primaryHeight - frame.midY)
      let source = CGEventSource(stateID: .privateState)
      let pid = getpid()
      for type in [CGEventType.leftMouseDown, .leftMouseUp] {
        CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: center, mouseButton: .left)?
          .postToPid(pid)
      }
      return [["ok": "1", "x": String(Int(center.x)), "y": String(Int(center.y))]]
    }

    // MARK: - Tree traversal (in-process, main thread, dynamic dispatch)

    private static func find(id: String) -> AnyObject? {
      for window in NSApp.windows {
        var match: AnyObject?
        walk(window) { node, _ in
          if identifier(node) == id {
            match = node
            return false  // stop
          }
          return true
        }
        if let match { return match }
      }
      return nil
    }

    /// Depth-first walk over the `NSAccessibility` object graph. `visit` returns
    /// `false` to stop the entire traversal.
    @discardableResult
    private static func walk(_ node: AnyObject, depth: Int = 0, _ visit: (AnyObject, Int) -> Bool) -> Bool {
      guard depth < 400 else { return true }
      guard visit(node, depth) else { return false }
      for child in children(of: node) where !walk(child, depth: depth + 1, visit) {
        return false
      }
      return true
    }

    private static func children(of node: AnyObject) -> [AnyObject] {
      (node.accessibilityChildren?() as? [AnyObject]) ?? []
    }

    private static func identifier(_ node: AnyObject) -> String { node.accessibilityIdentifier?() ?? "" }

    /// Best-effort human title across the common label-bearing attributes.
    private static func titleText(_ node: AnyObject) -> String {
      node.accessibilityTitle?() ?? node.accessibilityLabel?() ?? ""
    }

    private static func error(_ message: String) -> [String: String] { ["ok": "0", "error": message] }
  }
#endif
