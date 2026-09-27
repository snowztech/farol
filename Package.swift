// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Farol",
    platforms: [.macOS(.v14)],
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
        .executableTarget(name: "Farol", dependencies: ["GhosttyTerminal"]),
    ],
    swiftLanguageModes: [.v5]
)
