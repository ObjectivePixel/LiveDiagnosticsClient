// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ObjPxlLiveTelemetry",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .visionOS(.v1),
        .watchOS(.v8)
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
            path: "Sources"
        ),
        .testTarget(
            name: "ObjPxlLiveTelemetryTests",
            dependencies: ["ObjPxlLiveTelemetry"],
            path: "Tests"
        )
    ]
)
