// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Sundown",
    platforms: [.macOS(.v14)],
    products: [

        // The headless path. Everything the app does, from a shell hook,
        // a launchd job, or CI — with no window and no dashboard.
        .executable(name: "sundown", targets: ["SundownCLI"]),

        .library(name: "SessionKit", targets: ["SessionKit"]),
    ],
    targets: [
        // Pure logic. No AppKit, no SwiftUI, no UI assumptions.
        // This is the module that gets ported to another platform.
        .target(name: "SessionKit"),

        // Deliberately dependency-free: this binary runs unattended with
        // permission to end processes, so it carries no supply chain.
        .executableTarget(name: "SundownCLI", dependencies: ["SessionKit"]),


        .testTarget(name: "SessionKitTests", dependencies: ["SessionKit"]),

        // The parser decides whether a run may end processes. Untested
        // until 2026-09-18, on the one code path with no undo.
        .testTarget(name: "SundownCLITests", dependencies: ["SundownCLI"]),
    ]
)
