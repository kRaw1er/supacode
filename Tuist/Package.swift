// swift-tools-version: 6.0
import PackageDescription

#if TUIST
import ProjectDescription

let packageSettings = PackageSettings(
  productTypes: [
    "Sparkle": .framework,
  ]
)
#endif

let package = Package(
  name: "supacode",
  dependencies: [
    .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.7.1"),
    .package(url: "https://github.com/ibrahimcetin/libgit2", exact: "1.9.2"),
    .package(url: "https://github.com/apple/swift-collections", exact: "1.3.0"),
    .package(url: "https://github.com/onevcat/Kingfisher.git", exact: "8.8.0"),
    .package(url: "https://github.com/PostHog/posthog-ios.git", exact: "3.38.0"),
    .package(url: "https://github.com/getsentry/sentry-cocoa/", exact: "9.3.0"),
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.0-beta.2"),
    // Syntax highlighting for the diff viewer (Phase 4), via ChimeHQ neon (Phase 0
    // adoption spike + GATE). neon pins SwiftTreeSitter `branch: main`, which pulls
    // the transitive `tree-sitter` runtime `.upToNextMinor(from: "0.25.0")` → 0.25.10
    // (multi-file `sources: ["src"]` layout). The Phase-0 spike built this exact graph
    // green under BOTH the pinned Xcode 26.3 / Swift 6.2 AND Xcode 26.4.1 / Swift 6.3.1
    // through the xcodebuild explicit-modules pipeline (`-explicit-module-build`), so
    // the tree-sitter#5523 "TSLanguage not in scope" regression (Xcode 26.4.0 / Swift
    // 6.3.0 only, fixed in the 26.4.1 / 6.3.1 point release) does NOT bite — neon is
    // adopted VANILLA, with no vendored tree-sitter amalgamation override. The project
    // also always compiles under 26.3 (ghostty/zig#31658 forces it via
    // scripts/select-developer-dir.sh), so tree-sitter is never compiled under 26.4+
    // on the build path that ships. See the Phase-0 decision matrix (RECORD line).
    //
    // Commit-pins: neon has no live semver tag → pin the revision; SPM rejects a
    // root `.revision()` over neon's transitive `branch: "main"` requirement on
    // SwiftTreeSitter ("required using two different revision-based requirements"),
    // so SwiftTreeSitter stays `branch: "main"` and the exact sha is committed into
    // Tuist/Package.resolved (that IS the commit-pin). Rearrange is plain semver.
    // Grammars ship as a prebuilt static xcframework (see `TreeSitterGrammars` in
    // Project.swift), rebuilt against the 0.25 ABI.
    .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", branch: "main"),
    .package(url: "https://github.com/ChimeHQ/Neon", revision: "484d6fb9e0c4fb679a1d5f5ddaf2cac2ecf21165"),
    .package(url: "https://github.com/ChimeHQ/Rearrange", from: "2.0.0"),
    .package(url: "https://github.com/pointfreeco/swift-case-paths", exact: "1.7.2"),
    .package(url: "https://github.com/pointfreeco/swift-clocks", exact: "1.0.6"),
    .package(url: "https://github.com/pointfreeco/swift-composable-architecture", exact: "1.23.1"),
    .package(url: "https://github.com/pointfreeco/swift-concurrency-extras", exact: "1.3.2"),
    .package(url: "https://github.com/pointfreeco/swift-custom-dump", exact: "1.3.4"),
    .package(url: "https://github.com/pointfreeco/swift-dependencies", exact: "1.10.1"),
    .package(url: "https://github.com/pointfreeco/swift-identified-collections", exact: "1.1.1"),
    .package(url: "https://github.com/pointfreeco/swift-navigation", exact: "2.7.0"),
    .package(url: "https://github.com/pointfreeco/swift-perception", exact: "2.0.9"),
    .package(url: "https://github.com/pointfreeco/swift-sharing", exact: "2.7.4"),
    .package(url: "https://github.com/pointfreeco/xctest-dynamic-overlay", exact: "1.8.1"),
  ]
)
