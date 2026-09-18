// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Sundown",
    platforms: [.macOS(.v14)],
    products: [
        // Named SundownApp, not Sundown, and the reason is load-bearing:
        // macOS APFS is case-insensitive by default, so a product called
        // "Sundown" and one called "sundown" are the SAME FILE in .build.
        // Whichever linked last won, so `sundown --version` would sometimes
        // launch the GUI and hang in the AppKit event loop instead of printing
        // a version. Scripts/bundle.sh renames this to Sundown on the way into
        // the bundle, where CFBundleExecutable expects it.
        .executable(name: "SundownApp", targets: ["Sundown"]),

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

        // macOS shell. Knows nothing about how processes are found or killed.
        .executableTarget(
            name: "Sundown",
            dependencies: ["SessionKit"],
            // Info.plist belongs to the .app bundle, not to a SwiftPM resource
            // bundle. Scripts/bundle.sh puts it where macOS expects it.
            exclude: ["Resources"]
        ),

        .testTarget(name: "SessionKitTests", dependencies: ["SessionKit"]),

        // The parser decides whether a run may end processes. Untested
        // until 2026-09-18, on the one code path with no undo.
        .testTarget(name: "SundownCLITests", dependencies: ["SundownCLI"]),
    ]
)
