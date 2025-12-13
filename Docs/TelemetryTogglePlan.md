# Telemetry Toggle & Sync Plan

## Architecture & Audit
- Review `Sources/ObjPxlLiveTelemetry/Telemetry` to map current entry points: `CloudKitClient` CRUD for `TelemetryClientRecord`, `TelemetryLogger` + `NoopTelemetryLogger` + `TelemetryBootstrap`, `TelemetryEnvironment`, and schema constants.
- Confirm platform-conditional paths for iOS, macOS, tvOS, watchOS, and visionOS; choose a location for SwiftUI code (new file under `Sources/ObjPxlLiveTelemetry/Telemetry`).
- Decide public surface: a reusable SwiftUI `TelemetryToggleView` plus a lifecycle/coordinator service exposed through `@Environment`.

## Settings & Identifier
- Settings keys (UserDefaults per platform): `telemetryRequested`, `telemetrySendingEnabled`, `clientIdentifier`.
- Implement a platform-shared settings store (protocol + UserDefaults-backed type) with async-safe read/write, default values, and clear/reset support.
- Add a short, human-copyable ID generator (e.g., 10–12 character base32/ULID-style, lowercase, avoiding confusing characters); document collision expectations and persist deterministically.

## CloudKit Sync (via `CloudKitClient` / `TelemetryClientRecord`)
- Add helper APIs if needed: create/update/delete a telemetry client record; fetch current client(s) by ID; delete all telemetry event records.
- Enable flow: write a `TelemetryClientRecord` with `isEnabled` reflecting sending state and include an `embedded == false` field; persist ID/settings.
- Disable flow: delete telemetry event records, delete the active client record, and clear settings/ID.
- Reconciliation: given local settings, query server state (isEnabled) for the current client ID; return resolution outcomes (local off/server on, local on/server off, both on, both off) and apply changes.

## Logger Lifecycle
- Extend bootstrap to swap `NoopTelemetryLogger` for `TelemetryLogger` when telemetry is active/requested; revert on disable.
- Ensure startup consults stored settings before emitting events; avoid logging when `telemetrySendingEnabled` is false.

## SwiftUI View
- Build cross-platform `TelemetryToggleView` (Toggle, status text, and client ID display when enabled) using `@Environment` for lifecycle service/logger and `@State` for view state (idle/loading/syncing/error).
- Platform-appropriate affordances: default Toggle styling adapts per OS; compatible with iOS, macOS, tvOS, watchOS, visionOS; avoid UIKit.
- Status messaging reflects reconciliation results and current sending state in human-friendly wording; show generated ID when telemetry is requested/enabled.
- Follow guidelines: `NavigationStack`/`Tab`, avoid single-parameter `onChange`, avoid `onTapGesture`, prefer Buttons for actions.

## Startup & Flows
- Provide an async startup entry to load settings and run reconciliation; update settings and logger accordingly.
- Enable path: generate ID; set `telemetryRequested = true`, `telemetrySendingEnabled = false`; create CloudKit client record (`embedded = false`); activate logger; surface status.
- Post-reconciliation outcomes: local false/server true → enable sending; local true/server false → disable; both true → no-op; ensure UI reflects final `telemetrySendingEnabled`.
- Disable path: if sending was enabled, delete telemetry records and client; clear settings/ID; revert to Noop logger; update status.
- Integrate the toggle view into the example app/demo target to allow an end-to-end flow (enable, reconcile, disable) against CloudKit with visible status and ID.

## Testing & Docs
- Unit tests with mocked `CloudKitClientProtocol` for settings store, ID generator, enable/disable flows, reconciliation outcomes, and logger switching.
- SwiftUI previews/snapshot sanity for `TelemetryToggleView` across platforms (non-blocking).
- Documentation: README/package docs describing the toggle view, settings keys, ID format, CloudKit `TelemetryClientRecord` usage/fields, and lifecycle behavior.

## Example app
- Implement the toggle view in the example app to demonstrate the end-to-end flow.
