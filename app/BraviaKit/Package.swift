// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BraviaKit",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "BraviaKit", targets: ["BraviaKit"]),
        .library(name: "PultIR", targets: ["PultIR"]),
        .library(name: "PultProfiles", targets: ["PultProfiles"]),
    ],
    targets: [
        // IR protocols and the bridge's signal format. Foundation only, so it also builds on Linux.
        .target(name: "PultIR"),
        // Builds TV profiles from Flipper-IRDB .ir files (a port of tools/profiles/import_flipper_irdb.py).
        .target(name: "PultProfiles", dependencies: ["PultIR"], resources: [.process("Resources")]),
        .target(name: "BraviaKit", dependencies: ["PultIR", "PultProfiles"], resources: [.process("Resources")]),
        .testTarget(name: "BraviaKitTests", dependencies: ["BraviaKit"]),
        .testTarget(name: "PultIRTests", dependencies: ["PultIR"]),
        .testTarget(name: "PultProfilesTests", dependencies: ["PultProfiles"]),
    ]
)
