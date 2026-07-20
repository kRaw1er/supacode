import AppKit
import Testing

@testable import supacode

/// Phase 13 (C 15.8) — the image-compare widget's decode + layout model (the only
/// genuinely new edge-diff renderer). Valid PNG / JPEG decode on both sides;
/// added-only (nil before) / deleted-only (nil after); an undecodable pair falls
/// back to the binary summary row (never a crash); the fitted height is non-zero.
@MainActor
struct ImageCompareWidgetTests {

  private func imageData(width: Int, height: Int, type: NSBitmapImageRep.FileType) -> Data {
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    NSColor.systemBlue.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    image.unlockFocus()
    let tiff = image.tiffRepresentation!
    let rep = NSBitmapImageRep(data: tiff)!
    return rep.representation(using: type, properties: [:])!
  }

  @Test func decodesValidPNGBothSides() {
    let before = imageData(width: 10, height: 6, type: .png)
    let after = imageData(width: 8, height: 12, type: .png)
    let model = ImageCompareModel.make(beforeData: before, afterData: after)
    #expect(model.before != nil)
    #expect(model.after != nil)
    #expect(model.canCompare)
    #expect(model.fittedHeight(forWidth: 400) > 0)
  }

  @Test func decodesJPEG() {
    let data = imageData(width: 20, height: 20, type: .jpeg)
    #expect(ImageCompareModel.decode(data) != nil)
  }

  @Test func addedOnlyHasNilBefore() {
    let after = imageData(width: 12, height: 12, type: .png)
    let model = ImageCompareModel.make(beforeData: nil, afterData: after)
    #expect(model.before == nil)
    #expect(model.after != nil)
    #expect(model.canCompare)
    #expect(model.fittedHeight(forWidth: 400) > 0)
  }

  @Test func deletedOnlyHasNilAfter() {
    let before = imageData(width: 12, height: 12, type: .png)
    let model = ImageCompareModel.make(beforeData: before, afterData: nil)
    #expect(model.before != nil)
    #expect(model.after == nil)
    #expect(model.canCompare)
  }

  @Test func undecodableFallsBackToSummary() {
    let garbage = Data([0x00, 0x01, 0x02, 0x03, 0x04])
    let model = ImageCompareModel.make(beforeData: garbage, afterData: garbage)
    #expect(model.before == nil)
    #expect(model.after == nil)
    #expect(!model.canCompare)  // ⇒ binary summary row, no crash
    #expect(model.fittedHeight(forWidth: 400) == ImageCompareModel.summaryHeight)
  }

  @Test func emptyDataDecodesNil() {
    #expect(ImageCompareModel.decode(nil) == nil)
    #expect(ImageCompareModel.decode(Data()) == nil)
  }
}
