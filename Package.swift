// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Farol",
    platforms: [.macOS(.v14)],
    dependencies: [
        // What a paired phone and the Mac say to each other, shared with the iOS app.
        .package(url: "https://github.com/snowztech/farol-remote", from: "0.12.0"),
    ],
    targets: [
        .binaryTarget(name: "GhosttyKit", path: "vendor/GhosttyKit.xcframework"),
        // The only target allowed to import GhosttyKit. Keeps the unstable C API in one place.
        .target(
            name: "GhosttyTerminal",
            dependencies: ["GhosttyKit"],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("Carbon"),
            ]
        ),
        // Logic that can lose work if it's wrong (git, worktrees). No UI, and tested.
        .target(name: "FarolCore"),
        .testTarget(name: "FarolCoreTests", dependencies: ["FarolCore"]),
        // The `farol` command that agent hooks call. Bundled inside the app.
        .executableTarget(name: "FarolCLI", dependencies: ["FarolCore"]),
        .executableTarget(
            name: "Farol",
            dependencies: ["GhosttyTerminal", "FarolCore", .product(name: "FarolRemote", package: "farol-remote")]),
    ],
    swiftLanguageModes: [.v5]
)
