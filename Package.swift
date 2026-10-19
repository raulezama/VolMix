// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "VolMix",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "VolMix",
            path: "Sources/VolMix",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
