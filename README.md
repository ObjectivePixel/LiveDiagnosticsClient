# ObjPxlLiveTelemetry

Lightweight, multi-platform telemetry client for ObjectivePixel apps. The package targets iOS, macOS, visionOS, tvOS, and watchOS and is ready to drop into Xcode projects or Swift Package Manager builds.

## Installation

### Swift Package Manager

In Xcode: **File > Add Packages…** and use the repository URL once you push it to GitHub.

With a `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/ObjectivePixel/LiveDiagnosticsClient.git", from: "0.0.1")
]
```

Then add `ObjPxlLiveTelemetry` to your target dependencies.

## SwiftUI Telemetry Toggle

Expose the lifecycle service and toggle view to let users opt into diagnostics and keep CloudKit in sync:

```swift
import ObjPxlLiveTelemetry
import SwiftUI

@main
struct MyApp: App {
    private let telemetryLifecycle = TelemetryLifecycleService(
        configuration: .init(
            distribution: .debug,
            containerIdentifier: TelemetrySchema.cloudKitContainerIdentifierTelemetry
        )
    )

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                TelemetryToggleView()
            }
            .environment(\.telemetryLifecycle, telemetryLifecycle)
            .environment(\.telemetryLogger, telemetryLifecycle.telemetryLogger)
        }
    }
}
```

- The toggle view loads stored preferences, reconciles with CloudKit, and shows the generated client ID once telemetry is enabled.
- Logging is performed through `telemetryLifecycle.telemetryLogger`. When telemetry is disabled, a `NoopTelemetryLogger` is injected to prevent emission.

### Settings keys and identifiers

- `telemetryRequested`: persisted `Bool` indicating whether a user turned telemetry on.
- `telemetrySendingEnabled`: persisted `Bool` indicating that local sending is active.
- `clientIdentifier`: persisted `String` ID (10–12 characters, base32-like alphabet without ambiguous characters).

Identifiers are stable once generated and are written to CloudKit alongside the client record. Collision risk is negligible for interactive use.

### CloudKit schema expectations

- `TelemetryClient` records include `clientid` (String, indexed), `created` (Date, indexed), and `isEnabled` (Bool, indexed).
- `TelemetryEvent` records use the fields listed in `TelemetrySchema.Field`.
- Disabling telemetry deletes event records, removes client records for the current identifier, and clears local settings/ID.
- Reconciliation outcomes:
  - Local off / server on → local sending is enabled.
  - Local on / server off or missing client → telemetry is disabled and cleared.
  - Both on → no change.
  - Both off → settings are cleared locally.

## HTTP Telemetry Client

If you need an HTTP client instead of CloudKit, use `TelemetryClient` directly:

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

- iOS 17+
- macOS 14+
- tvOS 17+
- visionOS 1+
- watchOS 10+

## Contributing

Issues and pull requests are welcome. Please add tests for any new behavior.

## License

MIT. See [LICENSE](LICENSE).
