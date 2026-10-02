// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Miruun",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Miruun", targets: ["Miruun"]),
        .executable(name: "MiruunEngine", targets: ["MiruunEngine"])
    ],
    targets: [
        .target(name: "BridgeCore"),
        .systemLibrary(name: "CSQLite"),
        .target(name: "BridgeEngine", dependencies: ["BridgeCore", "CSQLite"]),
        .executableTarget(name: "MiruunEngine", dependencies: ["BridgeEngine"]),
        .executableTarget(name: "Miruun", dependencies: ["BridgeEngine"]),
        .testTarget(name: "BridgeCoreTests", dependencies: ["BridgeCore"]),
        .testTarget(name: "BridgeEngineTests", dependencies: ["BridgeEngine", "CSQLite"])
    ]
)
