// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexSwapChecks",
    platforms: [.macOS(.v14)],
    products: [.library(name: "CodexSwapTelemetry", targets: ["CodexSwapTelemetry"])],
    targets: [
        .target(name: "CodexSwapTelemetry", path: "app/Telemetry"),
        .testTarget(name: "CodexSwapTelemetryTests", dependencies: ["CodexSwapTelemetry"], path: "tests/telemetry")
    ]
)
