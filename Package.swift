// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DropForge",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "DropForge", targets: ["DropForge"]),
    ],
    dependencies: [
        // The standalone package keeps tests runnable with Apple's Command Line Tools,
        // whose Swift 6.3 installation does not ship the Testing or XCTest modules.
        .package(url: "https://github.com/swiftlang/swift-testing.git", from: "0.12.0"),

    ],
    targets: [
        .target(name: "DropForgeCore"),
        .target(name: "DropForgeEngines", dependencies: ["DropForgeCore"]),
        .target(name: "DropForgeUI", dependencies: ["DropForgeCore", "DropForgeEngines"]),
        .executableTarget(name: "DropForge", dependencies: ["DropForgeCore", "DropForgeEngines", "DropForgeUI", "Sparkle"]),
        .testTarget(name: "DropForgeCoreTests", dependencies: ["DropForgeCore", .product(name: "Testing", package: "swift-testing")]),
        .testTarget(name: "DropForgeEngineTests", dependencies: ["DropForgeCore", "DropForgeEngines", .product(name: "Testing", package: "swift-testing")],
                    resources: [.copy("Fixtures")]),
        .testTarget(name: "DropForgeUITests", dependencies: ["DropForgeCore", "DropForgeEngines", "DropForgeUI", .product(name: "Testing", package: "swift-testing")]),
        .binaryTarget(name: "Sparkle", path: "Vendor/Sparkle/Sparkle.xcframework"),
    ]
)
