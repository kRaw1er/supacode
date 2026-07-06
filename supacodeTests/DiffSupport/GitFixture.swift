import Foundation

@testable import supacode

/// I4 — shared temp-git-repo fixture (extracted from `DiffClientTests` in Phase
/// 9). Builds real temporary git repositories by shelling `/usr/bin/git`, so the
/// libgit2 binding + the streaming walk are exercised against genuine on-disk
/// state (no mocks). Suites that use it run `@Suite(.serialized)`.
///
/// Reused by `DiffClientTests`, `DiffStreamTests`, `DiffStreamConsumerTests` (and
/// later `BlobSliceProviderTests` / P4's `correctBlobPerDiffSource` GF arm).
enum GitFixture {
  enum FixtureError: Error {
    case git(_ args: [String], _ output: String)
  }

  /// Creates a temp dir, `git init`, sets a deterministic identity.
  static func makeRepo() throws -> URL {
    let root = URL.temporaryDirectory.appending(path: "difftest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try run(["init", "-q", "-b", "main"], in: root)
    try run(["config", "user.email", "t@t.dev"], in: root)
    try run(["config", "user.name", "T"], in: root)
    try run(["config", "commit.gpgsign", "false"], in: root)
    return root
  }

  static func write(_ text: String, to rel: String, in root: URL) throws {
    let url = root.appending(path: rel)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data(text.utf8).write(to: url, options: .atomic)
  }

  static func writeBytes(_ bytes: [UInt8], to rel: String, in root: URL) throws {
    let url = root.appending(path: rel)
    try Data(bytes).write(to: url, options: .atomic)
  }

  static func setPermissions(_ perms: Int, to rel: String, in root: URL) throws {
    let url = root.appending(path: rel)
    try FileManager.default.setAttributes([.posixPermissions: perms], ofItemAtPath: url.path(percentEncoded: false))
  }

  static func stage(_ paths: String..., in root: URL) throws { try run(["add"] + paths, in: root) }
  static func commit(_ msg: String, in root: URL) throws { try run(["commit", "-q", "-m", msg], in: root) }
  static func checkout(_ branch: String, create: Bool = false, in root: URL) throws {
    try run(create ? ["checkout", "-q", "-b", branch] : ["checkout", "-q", branch], in: root)
  }
  static func updateRef(_ ref: String, to revision: String, in root: URL) throws {
    try run(["update-ref", ref, revision], in: root)
  }
  static func head(in root: URL) throws -> String {
    try run(["rev-parse", "HEAD"], in: root).trimmingCharacters(in: .whitespacesAndNewlines)
  }
  static func rename(_ from: String, _ destination: String, in root: URL) throws {
    try run(["mv", from, destination], in: root)
  }
  static func remove(_ path: String, in root: URL) throws {
    try FileManager.default.removeItem(at: root.appending(path: path))
  }

  static func cleanup(_ root: URL) {
    try? FileManager.default.removeItem(at: root)
  }

  @discardableResult
  static func run(_ args: [String], in root: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/git")
    process.arguments = ["-C", root.path(percentEncoded: false)] + args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    process.waitUntilExit()
    let output = String(bytes: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else { throw FixtureError.git(args, output) }
    return output
  }
}
