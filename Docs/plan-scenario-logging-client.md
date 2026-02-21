# Plan: Scenario-Based Logging — Client Package (ObjPxlLiveTelemetry)

This plan covers all changes to the ObjPxlLiveTelemetry Swift package (LiveDiagnosticsClient repo). A separate plan covers the viewer app (RemindfulDiagnosticViewer repo).

---

## Context

The telemetry system uses CloudKit as the transport between client apps and the diagnostic viewer. Currently:

- Clients write `TelemetryClientRecord` on session start with `clientId`, `created`, `isEnabled`
- The viewer sends `TelemetryCommandRecord` with `CommandAction` (`.enable` / `.disable`) to control clients
- Clients write telemetry log records with fields defined in `TelemetrySchema.Field`
- `CloudKitClientProtocol` / `CloudKitClient` provides the CloudKit operations
- Clients persist their telemetry-enabled state locally (surviving app restarts)

This feature adds **scenario-based logging**: clients declare named logging categories, the viewer toggles them individually, and log records are annotated with their scenario. It also adds a **log level** concept so events can be classified as informational or diagnostic.

---

## Design Decisions (Resolved)

- **Ownership**: Per-client. Each client instance owns its scenarios. No cross-client grouping.
- **No bulk operations**: No "enable all / disable all" at the scenario level.
- **No history retention**: The viewer shows current state only.
- **Client persists scenario state**: The client must persist which scenarios are enabled/disabled locally (same pattern as the existing telemetry enabled/approved state), so scenario state survives app restarts and is restored when a session resumes.
- **Lifecycle service owns scenario state**: `TelemetryLifecycleService` is the source of truth for which scenarios exist and their enabled/disabled state. It pushes a synchronized copy to the logger for fast nonisolated access.
- **Local force override**: The host app can force individual scenarios on/off without going through the CloudKit command/approve flow. This is useful for development and debugging.
- **Log levels**: Events carry a `TelemetryLogLevel` (`.info` or `.diagnostic`) so the viewer can filter by severity.
- **Separate scenario store**: Scenario persistence uses its own protocol (`TelemetryScenarioStoring`) and `UserDefaults` implementation, decoupled from the core telemetry settings store.
- **Backward-compatible logging**: The existing `logEvent(name:property1:)` method remains unchanged. A new overload adds `scenario:` and `level:` parameters.

---

## Step 1: New Type — `TelemetryScenarioRecord`

Create a new file `TelemetryScenarioRecord.swift` in `Sources/ObjPxlLiveTelemetry/Telemetry/`. Follow the same pattern as `TelemetryClientRecord`:

```swift
public struct TelemetryScenarioRecord: Sendable, Equatable {
    public let recordID: CKRecord.ID?
    public let clientId: String
    public let scenarioName: String
    public var isEnabled: Bool
    public let created: Date

    public init(
        recordID: CKRecord.ID? = nil,
        clientId: String,
        scenarioName: String,
        isEnabled: Bool,
        created: Date = .now
    ) { ... }

    public init(record: CKRecord) throws { ... }
    public func toCKRecord() -> CKRecord { ... }
    public func applying(to record: CKRecord) throws -> CKRecord { ... }

    public enum Error: Swift.Error, LocalizedError, Sendable {
        case missingRecordID
        case unexpectedRecordType(String)
        case missingField(String)
    }
}
```

This mirrors `TelemetryClientRecord` — a value type wrapping a CloudKit record. One record per scenario per client in CloudKit.

---

## Step 2: New Type — `TelemetryLogLevel`

Create a new file `TelemetryLogLevel.swift` in `Sources/ObjPxlLiveTelemetry/Telemetry/`:

```swift
public enum TelemetryLogLevel: String, Sendable, CaseIterable, Comparable {
    case info
    case diagnostic

    public static func < (lhs: TelemetryLogLevel, rhs: TelemetryLogLevel) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }

    private var sortOrder: Int {
        switch self {
        case .info: return 0
        case .diagnostic: return 1
        }
    }
}
```

Log levels allow the viewer to filter events by severity. `.info` is for general events; `.diagnostic` is for detailed debugging data that is typically higher volume.

---

## Step 3: Extend `TelemetrySchema`

### 3a. New record type and fields for scenarios

```swift
extension TelemetrySchema {
    public static let scenarioRecordType = "TelemetryScenario"

    public enum ScenarioField: String, CaseIterable {
        case clientId = "clientid"
        case scenarioName
        case isEnabled
        case created

        public var fieldTypeDescription: String {
            switch self {
            case .clientId, .scenarioName: return "String"
            case .isEnabled: return "Int64 (0/1)"
            case .created: return "Date/Time"
            }
        }

        public var isIndexed: Bool {
            switch self {
            case .clientId, .scenarioName, .isEnabled: return true
            case .created: return false
            }
        }
    }
}
```

### 3b. Add `scenario` and `logLevel` to log record fields

Add two new cases to the existing `TelemetrySchema.Field` enum:

```swift
case scenario   // String, indexed — which scenario this log entry belongs to
case logLevel   // String, indexed — "info" or "diagnostic"
```

Both fields should be indexed so the viewer can query/filter by scenario and level. Update `isIndexed` and `fieldTypeDescription` accordingly.

### 3c. Add `scenarioName` to command fields

Add a new case to `TelemetrySchema.CommandField`:

```swift
case scenarioName  // String, optional — target scenario for scenario commands
```

---

## Step 4: Extend Command Actions

### 4a. New `CommandAction` cases

Add to the existing `TelemetrySchema.CommandAction` enum:

```swift
public enum CommandAction: String, Sendable, CaseIterable {
    case enable
    case disable
    case deleteEvents = "delete_events"
    case enableScenario
    case disableScenario
}
```

### 4b. Add `scenarioName` to `TelemetryCommandRecord`

Add an optional field to carry the target scenario for scenario-specific commands:

```swift
public struct TelemetryCommandRecord: Sendable, Equatable {
    public let recordID: CKRecord.ID?
    public let commandId: String
    public let clientId: String
    public let action: TelemetrySchema.CommandAction
    public let scenarioName: String?  // nil for whole-client commands (.enable/.disable/.deleteEvents)
    public let created: Date
    public var status: TelemetrySchema.CommandStatus
    public var executedAt: Date?
    public var errorMessage: String?
    // ...
}
```

Update the initializer to accept the optional `scenarioName` parameter (defaulting to `nil` for backward compatibility). Update both `init(record:)` and `toCKRecord()` / `applying(to:)` to read/write the `scenarioName` field via `TelemetrySchema.CommandField.scenarioName`.

---

## Step 5: Extend `CloudKitClientProtocol`

Add these methods to the protocol:

```swift
public protocol CloudKitClientProtocol {
    // ... existing methods ...

    // Scenario CRUD
    func createScenarios(_ scenarios: [TelemetryScenarioRecord]) async throws -> [TelemetryScenarioRecord]
    func fetchScenarios(forClient clientId: String?) async throws -> [TelemetryScenarioRecord]
    func updateScenario(_ scenario: TelemetryScenarioRecord) async throws -> TelemetryScenarioRecord
    func deleteScenarios(forClient clientId: String) async throws -> Int

    // Scenario subscriptions
    func createScenarioSubscription() async throws -> CKSubscription.ID
}
```

---

## Step 6: Implement `CloudKitClient` Scenario Methods

Implement the five new protocol methods in `CloudKitClient`. Follow the same patterns used for the existing client record methods:

### `createScenarios(_:)`
- Convert each `TelemetryScenarioRecord` to a `CKRecord` via `toCKRecord()`
- Batch save via the existing `save(records:)` method
- Return saved records (with record IDs assigned by CloudKit)

### `fetchScenarios(forClient:)`
- Query `TelemetryScenario` record type
- If `clientId` is non-nil, add a predicate filtering on `clientId`
- If `clientId` is nil, use `NSPredicate(value: true)` to fetch all
- Map `CKRecord` results to `TelemetryScenarioRecord` instances
- Follow the same pagination pattern as `fetchTelemetryClients`

### `updateScenario(_:)`
- Require non-nil `recordID` (throw `.missingRecordID` otherwise)
- Fetch the existing `CKRecord`, apply updates via `applying(to:)`, save
- Return the updated `TelemetryScenarioRecord`

### `deleteScenarios(forClient:)`
- Query all scenario records matching the `clientId`
- Batch delete via `CKModifyRecordsOperation`
- Return the count of deleted records
- Follow the same pattern as `deleteAllCommands(for:)`

### `createScenarioSubscription()`
- Create a `CKQuerySubscription` on `TelemetryScenario` record type
- Use subscription ID `"TelemetryScenario-All"`
- Configure notification info (set `shouldSendContentAvailable = true`)
- Follow the same pattern as `createClientRecordSubscription()`

---

## Step 7: Scenario State Persistence

Create a new file `TelemetryScenarioStore.swift` in `Sources/ObjPxlLiveTelemetry/Telemetry/`. This is separate from `TelemetrySettingsStore` to keep scenario persistence decoupled from core telemetry settings.

```swift
public protocol TelemetryScenarioStoring: Sendable {
    /// Load the persisted enabled state for a scenario. Returns nil if never persisted.
    func loadState(for scenarioName: String) async -> Bool?

    /// Load all persisted scenario states.
    func loadAllStates() async -> [String: Bool]

    /// Persist the enabled state for a scenario.
    func saveState(for scenarioName: String, isEnabled: Bool) async

    /// Remove persisted state for a scenario.
    func removeState(for scenarioName: String) async

    /// Remove all persisted scenario states.
    func removeAllStates() async
}

public actor UserDefaultsTelemetryScenarioStore: TelemetryScenarioStoring {
    // Key format: "telemetry.scenario.<scenarioName>.isEnabled"
    private static let keyPrefix = "telemetry.scenario."
    private static let keySuffix = ".isEnabled"
    private let defaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
    }

    // ... implementations ...
}
```

The store is protocol-based so tests can use an in-memory implementation. The separate protocol makes it easy to swap storage backends later without touching telemetry settings.

---

## Step 8: Client-Side Scenario Registration and Logging

### 8a. Scenario registration on `TelemetryLifecycleService`

Add a new public method and observable state:

```swift
@MainActor
@Observable
public final class TelemetryLifecycleService {
    // New observable property — maps scenario name to enabled state
    public private(set) var scenarioStates: [String: Bool] = [:]

    // Existing stored properties (add these):
    private let scenarioStore: TelemetryScenarioStoring
    private var scenarioRecords: [String: TelemetryScenarioRecord] = [:]

    /// Register scenarios for this client session. Writes one TelemetryScenario
    /// record per scenario to CloudKit. Restores previously persisted enabled state.
    public func registerScenarios(_ scenarioNames: [String]) async throws { ... }

    /// Force a scenario on or off locally, independent of the CloudKit command flow.
    /// Persists the state, updates CloudKit, and pushes to the logger.
    public func setScenarioEnabled(_ scenarioName: String, enabled: Bool) async throws { ... }
}
```

**`registerScenarios(_:)` implementation:**
1. For each scenario name, read locally persisted state from `scenarioStore`
2. Create a `TelemetryScenarioRecord` with `isEnabled` = restored value (or `false` if new)
3. Batch write all records to CloudKit via `createScenarios(_:)`
4. Store the returned records (with CloudKit record IDs) in `scenarioRecords`
5. Update `scenarioStates` (observable property)
6. Push state to logger via `logger.updateScenarioStates(scenarioStates)`

**`setScenarioEnabled(_:enabled:)` implementation:**
1. Update `scenarioStates[scenarioName]`
2. Persist via `scenarioStore.saveState(for:isEnabled:)`
3. If a CloudKit record exists in `scenarioRecords`, update it via `cloudKitClient.updateScenario(_:)`
4. Push state to logger via `logger.updateScenarioStates(scenarioStates)`

### 8b. Scenario-annotated logging

**`TelemetryLogging` protocol** — add a new overloaded method:

```swift
public protocol TelemetryLogging: Actor, Sendable {
    nonisolated var currentSessionId: String { get }

    // Existing — unchanged
    nonisolated func logEvent(name: String, property1: String?)

    // New — scenario-annotated logging with log level
    nonisolated func logEvent(name: String, scenario: String, level: TelemetryLogLevel, property1: String?)

    // New — lifecycle service pushes scenario state here
    func updateScenarioStates(_ states: [String: Bool])

    func activate(enabled: Bool) async
    func setEnabled(_ enabled: Bool) async
    func flush() async
    func shutdown() async
}
```

**`TelemetryLogger`** — implement the new methods:

```swift
public actor TelemetryLogger: TelemetryLogging {
    // New: lock-protected scenario state for fast nonisolated access
    private nonisolated let scenarioStatesLock = OSAllocatedUnfairLock<[String: Bool]>(initialState: [:])

    public func updateScenarioStates(_ states: [String: Bool]) {
        scenarioStatesLock.withLock { $0 = states }
    }

    public nonisolated func logEvent(
        name: String,
        scenario: String,
        level: TelemetryLogLevel,
        property1: String?
    ) {
        // Fast nonisolated check — if scenario is disabled, discard immediately
        let isEnabled = scenarioStatesLock.withLock { $0[scenario] ?? false }
        guard isEnabled else { return }

        // Same pattern as existing logEvent but with scenario + level attached
        // ... create TelemetryEvent with scenario and level, yield to stream ...
    }
}
```

The nonisolated scenario check uses `OSAllocatedUnfairLock`, the same pattern already used for `stateLock` and `shutdownLock` in the existing logger.

**`TelemetryEvent`** — add fields:

```swift
struct TelemetryEvent: Sendable {
    // ... existing fields ...
    let scenario: String?      // nil for unscoped events
    let level: TelemetryLogLevel  // defaults to .info for existing logEvent calls

    func toCKRecord() -> CKRecord {
        // ... existing fields ...
        record[TelemetrySchema.Field.scenario.rawValue] = scenario
        record[TelemetrySchema.Field.logLevel.rawValue] = level.rawValue
        return record
    }
}
```

**`NoopTelemetryLogger`** — add stub implementations:

```swift
public actor NoopTelemetryLogger: TelemetryLogging {
    public nonisolated func logEvent(name: String, scenario: String, level: TelemetryLogLevel, property1: String?) {}
    public func updateScenarioStates(_ states: [String: Bool]) {}
}
```

### 8c. Scenario command handling

Update `TelemetryCommandProcessor` to handle `enableScenario` / `disableScenario`:

```swift
public actor TelemetryCommandProcessor {
    // New handler types
    public typealias EnableScenarioHandler = @Sendable (String) async throws -> Void  // scenarioName
    public typealias DisableScenarioHandler = @Sendable (String) async throws -> Void // scenarioName

    // Add to init and store as properties
    private let onEnableScenario: EnableScenarioHandler
    private let onDisableScenario: DisableScenarioHandler

    private func processCommand(_ command: TelemetryCommandRecord) async {
        switch command.action {
        // ... existing cases ...
        case .enableScenario:
            guard let scenarioName = command.scenarioName else { /* mark failed */ return }
            try await onEnableScenario(scenarioName)
        case .disableScenario:
            guard let scenarioName = command.scenarioName else { /* mark failed */ return }
            try await onDisableScenario(scenarioName)
        }
    }
}
```

Update `TelemetryLifecycleService.setupCommandProcessing(for:)` to pass the new handlers:

```swift
let processor = TelemetryCommandProcessor(
    // ... existing handlers ...
    onEnableScenario: { [weak self] scenarioName in
        guard let self else { return }
        try await self.setScenarioEnabled(scenarioName, enabled: true)
    },
    onDisableScenario: { [weak self] scenarioName in
        guard let self else { return }
        try await self.setScenarioEnabled(scenarioName, enabled: false)
    }
)
```

---

## Step 9: Session-End Cleanup

When a client session ends:

1. Delete all `TelemetryScenarioRecord`s for this `clientId` from CloudKit
2. Delete all telemetry log records for this `clientId` from CloudKit
3. **Do NOT clear locally persisted scenario states** — these should survive session end so that the next session restores the same enabled/disabled configuration

Add a public `endSession()` method on `TelemetryLifecycleService`:

```swift
public func endSession() async throws {
    guard let clientId = settings.clientIdentifier else { return }
    _ = try await cloudKitClient.deleteScenarios(forClient: clientId)
    _ = try await cloudKitClient.deleteAllRecords()
    scenarioRecords.removeAll()
    scenarioStates.removeAll()
    // Local scenario persistence intentionally kept
}
```

Also update `disableTelemetry()` to delete scenario records alongside the existing cleanup.

---

## Step 10: Update Example App

The package includes an example app that demonstrates the telemetry client API. Update it to showcase scenario-based logging.

### 10a. Define example scenarios

Add a sample scenario enum to the example app:

```swift
enum ExampleScenario: String, CaseIterable {
    case networkRequests = "NetworkRequests"
    case dataSync = "DataSync"
    case userInteraction = "UserInteraction"
}
```

### 10b. Register scenarios on session start

Update the example app's session start flow to call `registerScenarios()` with the example enum values. This should happen right after the existing telemetry client initialization.

### 10c. Use scenario-annotated logging

Update existing example log call sites to include the `scenario:` and `level:` parameters. Each log call in the example app should be annotated with the appropriate scenario from the enum above.

### 10d. Show scenario state in example UI

Add a simple UI section to the example app that displays the current scenario list and their enabled/disabled states. Include a toggle per scenario to demonstrate local force override via `setScenarioEnabled(_:enabled:)`. This helps verify the round-trip: viewer enables a scenario -> client receives command -> client updates state -> example UI reflects change.

### 10e. Session-end cleanup

Update the example app's session teardown to call `endSession()`, demonstrating the full lifecycle including scenario record deletion.

---

## Step 11: Unit Tests

Tests should follow the existing test patterns in the package. Create new test files alongside existing ones.

### New type tests — `TelemetryScenarioRecordTests.swift`

- `TelemetryScenarioRecord` init with all fields, including default values
- `TelemetryScenarioRecord` init with defaults only (recordID nil, created auto-set)
- `TelemetryScenarioRecord` round-trip to/from `CKRecord` (serialize then deserialize, verify all fields preserved)
- `TelemetryScenarioRecord` round-trip with isEnabled = true and isEnabled = false
- `TelemetryScenarioRecord.Error.missingRecordID` thrown when expected
- `TelemetryScenarioRecord.Error.unexpectedRecordType` thrown for wrong record type
- `TelemetryScenarioRecord.Error.missingField` thrown for each required field
- `Equatable` conformance tests
- `applying(to:)` updates existing CKRecord correctly
- `applying(to:)` throws for wrong record type

### Log level tests — `TelemetryLogLevelTests.swift`

- `TelemetryLogLevel.info.rawValue` == `"info"`
- `TelemetryLogLevel.diagnostic.rawValue` == `"diagnostic"`
- `TelemetryLogLevel.allCases` contains both cases
- `Comparable`: `.info < .diagnostic`

### Schema tests (extend existing or new file)

- `TelemetrySchema.scenarioRecordType` == `"TelemetryScenario"`
- `TelemetrySchema.ScenarioField.allCases` contains all expected fields
- Each `ScenarioField` returns correct `fieldTypeDescription` and `isIndexed` values
- `TelemetrySchema.Field.scenario` exists, is indexed, type is String
- `TelemetrySchema.Field.logLevel` exists, is indexed, type is String
- `TelemetrySchema.CommandField.scenarioName` exists

### Command tests (extend `TelemetryCommandRecordTests.swift`)

- `CommandAction.enableScenario` and `.disableScenario` have correct raw values
- `TelemetryCommandRecord` init with `scenarioName` — verify field is set
- `TelemetryCommandRecord` init without `scenarioName` — verify field is nil (backward compatible)
- `TelemetryCommandRecord` round-trip to/from `CKRecord` with `scenarioName` set
- `TelemetryCommandRecord` round-trip to/from `CKRecord` without `scenarioName`

### Scenario store tests — `TelemetryScenarioStoreTests.swift`

- Persist a scenario state -> restore it -> verify value matches
- Restore a scenario that was never persisted -> verify returns nil
- Persist enabled -> persist disabled -> restore -> verify latest value (disabled)
- Persist states for multiple scenarios -> restore each -> verify independence
- `loadAllStates()` returns all persisted states
- `removeState(for:)` removes only the specified scenario
- `removeAllStates()` clears everything

### Logging behavior tests (extend `TelemetryLoggerTests.swift`)

- Log with an enabled scenario -> verify record is written with scenario and level fields set
- Log with a disabled scenario -> verify record is **not** written (skipped)
- Log without a scenario (original method) -> verify backward compatibility (record written, scenario field nil, level defaults to .info)
- `updateScenarioStates` -> subsequent log calls respect the new state
- Log with `.diagnostic` level -> verify level field set correctly

### Command handling tests (extend `TelemetryLifecycleServiceTests.swift`)

- Receive `.enableScenario` command with scenarioName -> verify local scenario state updated to enabled
- Receive `.disableScenario` command with scenarioName -> verify local scenario state updated to disabled
- Receive scenario command -> verify local persistence is updated
- Receive scenario command for unknown scenario name -> verify graceful handling (no crash)
- Receive scenario command without scenarioName -> verify graceful handling (marked failed)

### Session lifecycle tests (extend `TelemetryLifecycleServiceTests.swift`)

- `registerScenarios()` with fresh state -> all scenarios written to CloudKit as disabled
- `registerScenarios()` with previously persisted states -> scenarios written with restored enabled/disabled values
- `setScenarioEnabled()` -> updates local state, persists, updates CloudKit record, pushes to logger
- `endSession()` -> scenario records deleted from CloudKit
- `endSession()` -> local persisted scenario states are **preserved** (not cleared)
- Full lifecycle: register -> enable via command -> end session -> re-register -> verify enabled state restored

### MockCloudKitClient updates

Add scenario methods to the existing `MockCloudKitClient` in the test file:
- `createScenarios(_:)` — store in local array with generated record IDs
- `fetchScenarios(forClient:)` — filter and return
- `updateScenario(_:)` — update in-place
- `deleteScenarios(forClient:)` — remove matching, return count
- `createScenarioSubscription()` — return fixed subscription ID

---

## Implementation Order

1. **`TelemetryLogLevel`** — New enum (Step 2)
2. **`TelemetryScenarioRecord`** — New type (Step 1)
3. **`TelemetrySchema` extensions** — Record type, fields, scenario + logLevel on logs, scenarioName on commands (Step 3)
4. **`CommandAction` + `TelemetryCommandRecord`** — New actions and scenarioName field (Step 4)
5. **`CloudKitClientProtocol` methods** — Protocol additions (Step 5)
6. **`CloudKitClient` implementation** — Create, fetch, update, delete, subscribe for scenarios (Step 6)
7. **`TelemetryScenarioStore`** — Persistence protocol + UserDefaults implementation (Step 7)
8. **`TelemetryLogging` + `TelemetryLogger`** — New overload, updateScenarioStates, TelemetryEvent changes (Step 8b)
9. **`TelemetryCommandProcessor`** — Scenario command handlers (Step 8c)
10. **`TelemetryLifecycleService`** — registerScenarios, setScenarioEnabled, endSession, command wiring (Steps 8a, 9)
11. **Example app** — Update to demonstrate scenario registration, annotated logging, and lifecycle (Step 10)
12. **Unit tests** — Cover all new types, methods, and behaviors (Step 11)

---

## Files to Create / Modify

| File | Action | Description |
|------|--------|-------------|
| `Sources/.../Telemetry/TelemetryLogLevel.swift` | **Create** | New log level enum |
| `Sources/.../Telemetry/TelemetryScenarioRecord.swift` | **Create** | New scenario record type |
| `Sources/.../Telemetry/TelemetryScenarioStore.swift` | **Create** | Scenario persistence protocol + UserDefaults impl |
| `Sources/.../Telemetry/TelemetrySchema.swift` | **Modify** | Add `scenarioRecordType`, `ScenarioField` enum, `scenario` + `logLevel` to `Field`, `scenarioName` to `CommandField` |
| `Sources/.../Telemetry/TelemetryCommandRecord.swift` | **Modify** | Add optional `scenarioName` field, update init and CKRecord mapping |
| `Sources/.../Telemetry/CloudKitClient.swift` | **Modify** | Add 5 scenario methods to protocol, implement in struct |
| `Sources/.../Telemetry/TelemetryLogger.swift` | **Modify** | Add scenario overload, `updateScenarioStates`, scenarioStatesLock |
| `Sources/.../Telemetry/TelemetryEvent.swift` | **Modify** | Add `scenario` and `level` fields, update `toCKRecord()` |
| `Sources/.../Telemetry/TelemetryCommandProcessor.swift` | **Modify** | Add `enableScenario`/`disableScenario` handlers |
| `Sources/.../Telemetry/TelemetryLifecycleService.swift` | **Modify** | Add `scenarioStates`, `registerScenarios()`, `setScenarioEnabled()`, `endSession()`, command wiring |
| `Examples/.../ContentView.swift` | **Modify** | Scenario UI, annotated logging |
| `Examples/.../Live_Diagnostics_Example_ClientApp.swift` | **Modify** | Register scenarios on startup |
| `Tests/.../TelemetryScenarioRecordTests.swift` | **Create** | Scenario record tests |
| `Tests/.../TelemetryLogLevelTests.swift` | **Create** | Log level tests |
| `Tests/.../TelemetryScenarioStoreTests.swift` | **Create** | Scenario persistence tests |
| `Tests/.../TelemetryCommandRecordTests.swift` | **Modify** | Add scenario command tests |
| `Tests/.../TelemetryLifecycleServiceTests.swift` | **Modify** | Add scenario lifecycle + command tests |
| `Tests/.../TelemetryLoggerTests.swift` | **Modify** | Add scenario logging tests |

---

## Public API Reference (Post-Implementation)

This section documents the complete public API surface of the `ObjPxlLiveTelemetry` package after all changes are applied. **New** items are marked. Existing items are included for completeness.

### Package Info

```swift
public enum ObjPxlLiveTelemetryVersion {
    public static let version: String          // "0.0.4"
    public static let major: Int
    public static let minor: Int
    public static let patch: Int
}
```

---

### TelemetryLogLevel *(New)*

```swift
public enum TelemetryLogLevel: String, Sendable, CaseIterable, Comparable {
    case info
    case diagnostic
}
```

---

### TelemetrySchema

```swift
public struct TelemetrySchema: Sendable {
    // Record type names
    public static let recordType: String                    // "TelemetryEvent"
    public static let clientRecordType: String              // "TelemetryClient"
    public static let settingsBackupRecordType: String      // "TelemetrySettingsBackup"
    public static let commandRecordType: String             // "TelemetryCommand"
    public static let scenarioRecordType: String            // "TelemetryScenario"  ← New

    // Log event fields
    public enum Field: String, CaseIterable {
        case eventId, eventName, eventTimestamp, sessionId
        case deviceType, deviceName, deviceModel, osVersion, appVersion
        case threadId, property1
        case scenario                                       // ← New
        case logLevel                                       // ← New

        public var isIndexed: Bool { ... }
        var fieldTypeDescription: String { ... }
    }

    // Client record fields
    public enum ClientField: String, CaseIterable {
        case clientId, created, isEnabled
        public var isIndexed: Bool { ... }
        public var fieldTypeDescription: String { ... }
    }

    // Settings backup fields
    public enum SettingsBackupField: String, CaseIterable {
        case telemetryRequested, telemetrySendingEnabled
        case clientIdentifier, lastUpdated
        public var fieldTypeDescription: String { ... }
    }

    // Command record fields
    public enum CommandField: String, CaseIterable {
        case commandId, clientId, action, created
        case status, executedAt, errorMessage
        case scenarioName                                   // ← New
        public var isIndexed: Bool { ... }
        public var fieldTypeDescription: String { ... }
    }

    // Scenario record fields  ← New
    public enum ScenarioField: String, CaseIterable {
        case clientId, scenarioName, isEnabled, created
        public var isIndexed: Bool { ... }
        public var fieldTypeDescription: String { ... }
    }

    public enum CommandAction: String, Sendable, CaseIterable {
        case enable
        case disable
        case deleteEvents
        case enableScenario                                 // ← New
        case disableScenario                                // ← New
    }

    public enum CommandStatus: String, Sendable, CaseIterable {
        case pending, executed, failed
    }

    // Schema validation
    public static func validateSchema(in database: CKDatabase) async throws
    public enum SchemaError: Error, CustomStringConvertible { ... }
}
```

---

### TelemetryClientRecord

```swift
public struct TelemetryClientRecord: Sendable {
    public let recordID: CKRecord.ID?
    public var clientId: String
    public var created: Date
    public var isEnabled: Bool

    public init(recordID: CKRecord.ID?, clientId: String, created: Date, isEnabled: Bool)
    public init(record: CKRecord) throws
    public func toCKRecord() -> CKRecord
    public func applying(to record: CKRecord) throws -> CKRecord

    public enum Error: Swift.Error, LocalizedError, Sendable {
        case missingRecordID
        case unexpectedRecordType(String)
        case missingField(String)
    }
}
```

---

### TelemetryScenarioRecord *(New)*

```swift
public struct TelemetryScenarioRecord: Sendable, Equatable {
    public let recordID: CKRecord.ID?
    public let clientId: String
    public let scenarioName: String
    public var isEnabled: Bool
    public let created: Date

    public init(recordID: CKRecord.ID?, clientId: String, scenarioName: String, isEnabled: Bool, created: Date)
    public init(record: CKRecord) throws
    public func toCKRecord() -> CKRecord
    public func applying(to record: CKRecord) throws -> CKRecord

    public enum Error: Swift.Error, LocalizedError, Sendable {
        case missingRecordID
        case unexpectedRecordType(String)
        case missingField(String)
    }
}
```

---

### TelemetryCommandRecord

```swift
public struct TelemetryCommandRecord: Sendable, Equatable {
    public let recordID: CKRecord.ID?
    public let commandId: String
    public let clientId: String
    public let action: TelemetrySchema.CommandAction
    public let scenarioName: String?                        // ← New (nil for whole-client commands)
    public let created: Date
    public var status: TelemetrySchema.CommandStatus
    public var executedAt: Date?
    public var errorMessage: String?

    public init(
        recordID: CKRecord.ID?, commandId: String, clientId: String,
        action: TelemetrySchema.CommandAction,
        scenarioName: String?,                              // ← New parameter (default nil)
        created: Date, status: TelemetrySchema.CommandStatus,
        executedAt: Date?, errorMessage: String?
    )
    public init(record: CKRecord) throws
    public func toCKRecord() -> CKRecord
    public func applying(to record: CKRecord) throws -> CKRecord

    public enum Error: Swift.Error, LocalizedError, Sendable {
        case missingRecordID
        case unexpectedRecordType(String)
        case missingField(String)
        case invalidAction(String)
        case invalidStatus(String)
    }
}
```

---

### CloudKitClientProtocol

```swift
public protocol CloudKitClientProtocol: Sendable {
    // Schema
    func validateSchema() async -> Bool

    // Telemetry events (log records)
    func save(records: [CKRecord]) async throws
    func fetchAllRecords() async throws -> [CKRecord]
    func fetchRecords(limit: Int, cursor: CKQueryOperation.Cursor?) async throws -> ([CKRecord], CKQueryOperation.Cursor?)
    func countRecords() async throws -> Int
    func deleteAllRecords() async throws -> Int

    // Client records
    func createTelemetryClient(clientId: String, created: Date, isEnabled: Bool) async throws -> TelemetryClientRecord
    func createTelemetryClient(_ telemetryClient: TelemetryClientRecord) async throws -> TelemetryClientRecord
    func updateTelemetryClient(recordID: CKRecord.ID, clientId: String?, created: Date?, isEnabled: Bool?) async throws -> TelemetryClientRecord
    func updateTelemetryClient(_ telemetryClient: TelemetryClientRecord) async throws -> TelemetryClientRecord
    func deleteTelemetryClient(recordID: CKRecord.ID) async throws
    func fetchTelemetryClients(clientId: String?, isEnabled: Bool?) async throws -> [TelemetryClientRecord]

    // Commands
    func createCommand(_ command: TelemetryCommandRecord) async throws -> TelemetryCommandRecord
    func fetchCommand(recordID: CKRecord.ID) async throws -> TelemetryCommandRecord?
    func fetchPendingCommands(for clientId: String) async throws -> [TelemetryCommandRecord]
    func updateCommandStatus(recordID: CKRecord.ID, status: TelemetrySchema.CommandStatus, executedAt: Date?, errorMessage: String?) async throws -> TelemetryCommandRecord
    func deleteCommand(recordID: CKRecord.ID) async throws
    func deleteAllCommands(for clientId: String) async throws -> Int

    // Scenarios ← New
    func createScenarios(_ scenarios: [TelemetryScenarioRecord]) async throws -> [TelemetryScenarioRecord]
    func fetchScenarios(forClient clientId: String?) async throws -> [TelemetryScenarioRecord]
    func updateScenario(_ scenario: TelemetryScenarioRecord) async throws -> TelemetryScenarioRecord
    func deleteScenarios(forClient clientId: String) async throws -> Int
    func createScenarioSubscription() async throws -> CKSubscription.ID

    // Subscriptions
    func createCommandSubscription(for clientId: String) async throws -> CKSubscription.ID
    func removeCommandSubscription(_ subscriptionID: CKSubscription.ID) async throws
    func fetchCommandSubscription(for clientId: String) async throws -> CKSubscription.ID?
    func createClientRecordSubscription() async throws -> CKSubscription.ID
    func removeSubscription(_ subscriptionID: CKSubscription.ID) async throws
    func fetchSubscription(id: CKSubscription.ID) async throws -> CKSubscription.ID?

    // Debug
    func debugDatabaseInfo() async
    func detectEnvironment() async -> String
    func getDebugInfo() async -> DebugInfo
}

// Convenience extension
public extension CloudKitClientProtocol {
    func deleteAllTelemetryEvents() async throws -> Int
}
```

---

### CloudKitClient

```swift
public struct CloudKitClient: CloudKitClientProtocol {
    public let container: CKContainer
    public let database: CKDatabase
    public let identifier: String

    public init(containerIdentifier: String)

    // Implements all CloudKitClientProtocol methods
}
```

---

### TelemetryLogging Protocol

```swift
public protocol TelemetryLogging: Actor, Sendable {
    nonisolated var currentSessionId: String { get }

    // Unscoped logging (existing)
    nonisolated func logEvent(name: String, property1: String?)

    // Scenario-annotated logging with log level ← New
    nonisolated func logEvent(name: String, scenario: String, level: TelemetryLogLevel, property1: String?)

    // Scenario state management ← New
    func updateScenarioStates(_ states: [String: Bool])

    func activate(enabled: Bool) async
    func setEnabled(_ enabled: Bool) async
    func flush() async
    func shutdown() async
}

// Default parameter extension (existing)
public extension TelemetryLogging {
    nonisolated func logEvent(name: String, property1: String? = nil)
}

// Default parameter extension ← New
public extension TelemetryLogging {
    nonisolated func logEvent(name: String, scenario: String, level: TelemetryLogLevel = .info, property1: String? = nil)
}
```

---

### TelemetryLogger

```swift
public actor TelemetryLogger: TelemetryLogging {
    public struct Configuration: Sendable {
        public let batchSize: Int
        public let flushInterval: TimeInterval
        public let maxRetries: Int

        public init(batchSize: Int, flushInterval: TimeInterval, maxRetries: Int)
        public static let `default`: Configuration
    }

    public nonisolated let currentSessionId: String

    public init(configuration: Configuration, client: CloudKitClientProtocol)

    // Unscoped logging (existing)
    public nonisolated func logEvent(name: String, property1: String?)

    // Scenario-annotated logging ← New
    public nonisolated func logEvent(name: String, scenario: String, level: TelemetryLogLevel, property1: String?)

    // Scenario state management ← New
    public func updateScenarioStates(_ states: [String: Bool])

    public func activate(enabled: Bool) async
    public func setEnabled(_ enabled: Bool) async
    public func flush() async
    public func shutdown() async

    public nonisolated static func currentThreadId() -> String
}
```

---

### NoopTelemetryLogger

```swift
public actor NoopTelemetryLogger: TelemetryLogging {
    public nonisolated let currentSessionId: String
    public init()
    // Stub implementations of all TelemetryLogging methods (no-ops)
}
```

---

### TelemetryScenarioStoring *(New)*

```swift
public protocol TelemetryScenarioStoring: Sendable {
    func loadState(for scenarioName: String) async -> Bool?
    func loadAllStates() async -> [String: Bool]
    func saveState(for scenarioName: String, isEnabled: Bool) async
    func removeState(for scenarioName: String) async
    func removeAllStates() async
}

public actor UserDefaultsTelemetryScenarioStore: TelemetryScenarioStoring {
    public init(userDefaults: UserDefaults = .standard)
    // Implements all TelemetryScenarioStoring methods
    // Key format: "telemetry.scenario.<scenarioName>.isEnabled"
}
```

---

### TelemetrySettingsStoring / TelemetrySettings

```swift
public struct TelemetrySettings: Equatable, Sendable {
    public var telemetryRequested: Bool
    public var telemetrySendingEnabled: Bool
    public var clientIdentifier: String?

    public init(telemetryRequested: Bool, telemetrySendingEnabled: Bool, clientIdentifier: String?)
    public static let defaults: TelemetrySettings
}

public protocol TelemetrySettingsStoring: Sendable {
    func load() async -> TelemetrySettings
    @discardableResult func save(_ settings: TelemetrySettings) async -> TelemetrySettings
    @discardableResult func update(_ transform: (inout TelemetrySettings) -> Void) async -> TelemetrySettings
    @discardableResult func reset() async -> TelemetrySettings
}

public actor UserDefaultsTelemetrySettingsStore: TelemetrySettingsStoring {
    public init(userDefaults: UserDefaults = .standard)
    // Implements all TelemetrySettingsStoring methods
}
```

---

### TelemetryLifecycleService

```swift
@MainActor
@Observable
public final class TelemetryLifecycleService {
    // Status types
    public enum Status: Equatable {
        case idle, loading, syncing, enabled, disabled, pendingApproval, error(String)
    }
    public enum ReconciliationResult: Equatable {
        case localAndServerEnabled, serverEnabledLocalDisabled
        case serverDisabledLocalEnabled, allDisabled, missingClient, pendingApproval
    }

    // Configuration
    public struct Configuration: Sendable {
        public var containerIdentifier: String
        public var loggerConfiguration: TelemetryLogger.Configuration
        public init(containerIdentifier: String, loggerConfiguration: TelemetryLogger.Configuration)
    }

    // Observable state
    public private(set) var status: Status
    public private(set) var reconciliation: ReconciliationResult?
    public private(set) var settings: TelemetrySettings
    public private(set) var clientRecord: TelemetryClientRecord?
    public private(set) var statusMessage: String?
    public private(set) var isRestorationInProgress: Bool
    public private(set) var scenarioStates: [String: Bool]  // ← New

    // Logger access
    public var telemetryLogger: any TelemetryLogging

    // Initializer
    public init(
        settingsStore: any TelemetrySettingsStoring = UserDefaultsTelemetrySettingsStore(),
        cloudKitClient: CloudKitClientProtocol? = nil,
        identifierGenerator: any TelemetryIdentifierGenerating = TelemetryIdentifierGenerator(),
        configuration: Configuration,
        logger: (any TelemetryLogging)? = nil,
        syncCoordinator: TelemetrySettingsSyncCoordinator? = nil,
        subscriptionManager: (any TelemetrySubscriptionManaging)? = nil,
        scenarioStore: (any TelemetryScenarioStoring)? = nil  // ← New
    )

    // Lifecycle
    @discardableResult public func startup() async -> TelemetrySettings
    @discardableResult public func enableTelemetry() async -> TelemetrySettings
    @discardableResult public func disableTelemetry(reason: ReconciliationResult?) async -> TelemetrySettings
    @discardableResult public func reconcile() async -> ReconciliationResult?
    public func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) async -> Bool

    // Scenarios ← New
    public func registerScenarios(_ scenarioNames: [String]) async throws
    public func setScenarioEnabled(_ scenarioName: String, enabled: Bool) async throws
    public func endSession() async throws
}
```

---

### TelemetryCommandProcessor

```swift
public actor TelemetryCommandProcessor {
    public typealias EnableHandler = @Sendable () async throws -> Void
    public typealias DisableHandler = @Sendable () async throws -> Void
    public typealias DeleteEventsHandler = @Sendable () async throws -> Void
    public typealias EnableScenarioHandler = @Sendable (String) async throws -> Void   // ← New
    public typealias DisableScenarioHandler = @Sendable (String) async throws -> Void  // ← New

    public init(
        cloudKitClient: CloudKitClientProtocol,
        clientId: String,
        onEnable: @escaping EnableHandler,
        onDisable: @escaping DisableHandler,
        onDeleteEvents: @escaping DeleteEventsHandler,
        onEnableScenario: @escaping EnableScenarioHandler,     // ← New
        onDisableScenario: @escaping DisableScenarioHandler    // ← New
    )

    public func processCommands() async
    public func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) async -> Bool
}
```

---

### TelemetrySubscriptionManaging

```swift
public protocol TelemetrySubscriptionManaging: Sendable {
    var currentSubscriptionID: CKSubscription.ID? { get async }
    func registerSubscription(for clientId: String) async throws
    func unregisterSubscription() async throws
}

public actor TelemetrySubscriptionManager: TelemetrySubscriptionManaging {
    public init(cloudKitClient: CloudKitClientProtocol)
    // Implements all TelemetrySubscriptionManaging methods
}
```

---

### TelemetryIdentifierGenerating

```swift
public protocol TelemetryIdentifierGenerating: Sendable {
    func generateIdentifier() -> String
}

public struct TelemetryIdentifierGenerator: TelemetryIdentifierGenerating {
    public init(length: Int = 10)
    public func generateIdentifier() -> String
}
```

---

### TelemetryAppDelegate

```swift
// Available on iOS (non-watchOS) and macOS
@MainActor
open class TelemetryAppDelegate: NSObject, UIApplicationDelegate {  // or NSApplicationDelegate on macOS
    public var telemetryLifecycle: TelemetryLifecycleService?
    // Handles remote notifications and forwards to lifecycle service
}
```

---

### TelemetryToggleView

```swift
public struct TelemetryToggleView: View {
    public init(lifecycle: TelemetryLifecycleService)
    public var body: some View { ... }
}
```

---

### DebugInfo

```swift
public struct DebugInfo: Sendable {
    public let containerID: String
    public let buildType: String
    public let environment: String
    public let testQueryResults: Int
    public let firstRecordID: String?
    public let firstRecordFields: [String]
    public let recordCount: Int?
    public let errorMessage: String?
}
```

---

### CloudKitSettingsBackupClient

```swift
public protocol CloudKitSettingsBackupClientProtocol: Sendable {
    func saveSettings(_ settings: TelemetrySettings) async throws
    func loadSettings() async throws -> TelemetrySettings?
    func clearSettings() async throws
}

public struct CloudKitSettingsBackupClient: CloudKitSettingsBackupClientProtocol {
    public init(containerIdentifier: String)
}
```

---

### TelemetrySettingsSyncCoordinator

```swift
public actor TelemetrySettingsSyncCoordinator {
    public enum RestoreResult { ... }
    public init(backupClient: CloudKitSettingsBackupClientProtocol)
    public func backupSettings(_ settings: TelemetrySettings) async throws
    public func restoreSettingsFromBackup() async -> RestoreResult
    public func clearBackup() async throws
}
```
