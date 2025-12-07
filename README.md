# ObjPxlLiveTelemetry

Lightweight, multi-platform telemetry client for ObjectivePixel apps. The package targets iOS, macOS, visionOS, tvOS, and watchOS and is ready to drop into Xcode projects or Swift Package Manager builds.

## Installation

### Swift Package Manager

In Xcode: **File > Add Packages…** and use the repository URL once you push it to GitHub.

With a `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/objectivepixel/ObjPxlLiveTelemetry.git", from: "1.0.0")
]
```

Then add `ObjPxlLiveTelemetry` to your target dependencies.

## Usage

```swift
import ObjPxlLiveTelemetry

let configuration = TelemetryClient.Configuration(
    endpoint: URL(string: "https://telemetry.example.com/events")!,
    apiKey: "<your API key>",
    batchSize: 10,
    defaultAttributes: ["appVersion": "1.0.0"]
)

let client = TelemetryClient(configuration: configuration)

Task {
    try await client.track(.init(name: "app_launch"))
    try await client.track(.init(name: "screen_view", attributes: ["screen": "Home"]))
    try await client.flush() // Force a flush before shutdown if needed
}
```

The client batches events and posts JSON payloads. It merges `defaultAttributes` into every event and adds an `Authorization: Bearer <token>` header when `apiKey` is provided.

## Platforms

- iOS 15+
- macOS 12+
- tvOS 15+
- visionOS 1+
- watchOS 8+

## Contributing

Issues and pull requests are welcome. Please add tests for any new behavior.

## License

MIT. See [LICENSE](LICENSE).
