// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ObjPxlLiveTelemetry",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .visionOS(.v1),
        .watchOS(.v10)
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
