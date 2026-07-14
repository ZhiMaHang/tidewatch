// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "QuotaBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "QuotaBar",
            path: "Sources/QuotaBar"
        )
    ]
)
