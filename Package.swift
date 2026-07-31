// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIUsageBar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UsageCore", targets: ["UsageCore"]),
        .executable(name: "usagectl", targets: ["usagectl"]),
        .executable(name: "AIUsageBar", targets: ["AIUsageBar"]),
    ],
    targets: [
        .target(
            name: "UsageCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "usagectl",
            dependencies: ["UsageCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AIUsageBar",
            dependencies: ["UsageCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "UsageCoreTests",
            dependencies: ["UsageCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
