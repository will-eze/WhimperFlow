// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "WhimperFlow",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "WhimperFlowKit"),
        .target(name: "AudioSupport"),
        .executableTarget(
            name: "WhimperFlow",
            dependencies: ["WhimperFlowKit", "AudioSupport"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "WhimperRecorder",
            dependencies: ["AudioSupport"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "SpeechProbe",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "whimpereval",
            dependencies: ["WhimperFlowKit", "AudioSupport"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "WhimperFlowKitTests", dependencies: ["WhimperFlowKit", "AudioSupport"]),
    ]
)
