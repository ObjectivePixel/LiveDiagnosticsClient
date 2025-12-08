// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ObjPxlLiveTelemetry",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
        .tvOS(.v16),
        .visionOS(.v1),
        .watchOS(.v9)
    ],
    products: [
        .library(
            name: "ObjPxlLiveTelemetry",
            targets: ["ObjPxlLiveTelemetry"]
        )
    ],
    targets: [
        .target(
            name: "ObjPxlLiveTelemetry",
            path: "Sources/ObjPxlLiveTelemetry"
        ),
        .testTarget(
            name: "ObjPxlLiveTelemetryTests",
            dependencies: ["ObjPxlLiveTelemetry"],
            path: "Tests/ObjPxlLiveTelemetryTests"
        )
    ]
)
