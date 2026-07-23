// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Tidewatch",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Tidewatch",
            path: "Sources/Tidewatch"
        ),
        .testTarget(
            name: "TidewatchTests",
            dependencies: ["Tidewatch"],
            path: "Tests/TidewatchTests"
        )
    ]
)
