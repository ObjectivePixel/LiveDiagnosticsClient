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

This feature adds **scenario-based logging**: clients declare named logging categories, the viewer toggles them individually, and log records are annotated with their scenario.

---

## Design Decisions (Resolved)

- **Ownership**: Per-client. Each client instance owns its scenarios. No cross-client grouping.
- **No bulk operations**: No "enable all / disable all" at the scenario level.
- **No history retention**: The viewer shows current state only.
- **Client persists scenario state**: The client must persist which scenarios are enabled/disabled locally (same pattern as the existing telemetry enabled/approved state), so scenario state survives app restarts and is restored when a session resumes.

---

## Step 1: New Type — `TelemetryScenarioRecord`

Create a new file `TelemetryScenarioRecord.swift`. Follow the same pattern as `TelemetryClientRecord`:

```swift
public struct TelemetryScenarioRecord: Sendable {
    public let recordID: CKRecord.ID?
    public let clientId: String
    public let scenarioName: String
    public let isEnabled: Bool
    public let created: Date

    public init(
        recordID: CKRecord.ID? = nil,
        clientId: String,
        scenarioName: String,
        isEnabled: Bool,
        created: Date = Date()
    ) { ... }

    public enum Error: Swift.Error {
        case missingRecordID
    }
}
```

This mirrors `TelemetryClientRecord` — a value type wrapping a CloudKit record. One record per scenario per client in CloudKit.

---

## Step 2: Extend `TelemetrySchema`

### 2a. New record type and fields for scenarios

```swift
extension TelemetrySchema {
    public static let scenarioRecordType = "TelemetryScenario"

    public enum ScenarioField: String, CaseIterable {
        case clientId
        case scenarioName
        case isEnabled
        case created

        public var fieldType: String {
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

### 2b. Add `scenario` to log record fields

Add a new case to the existing `TelemetrySchema.Field` enum:

```swift
case scenario  // String, indexed — which scenario this log entry belongs to
```

This lets log records carry their scenario annotation. The field should be indexed so the viewer can query/filter by scenario.

---

## Step 3: Extend Command Actions

### 3a. New `CommandAction` cases

Add to the existing `TelemetrySchema.CommandAction` enum:

```swift
public enum CommandAction: String, Sendable {
    case enable
    case disable
    case enableScenario
    case disableScenario
}
```

### 3b. Add `scenarioName` to `TelemetryCommandRecord`

Add an optional field to carry the target scenario for scenario-specific commands:

```swift
public struct TelemetryCommandRecord: Sendable {
    public let commandId: String
    public let clientId: String
    public let action: TelemetrySchema.CommandAction
    public let scenarioName: String?  // nil for whole-client commands (.enable/.disable)
    // ... existing fields
}
```

Update the initializer to accept the optional `scenarioName` parameter (defaulting to `nil` for backward compatibility). Update the CloudKit record serialization/deserialization to read/write the `scenarioName` field.

---

## Step 4: Extend `CloudKitClientProtocol`

Add these methods to the protocol:

```swift
public protocol CloudKitClientProtocol {
    // ... existing methods ...

    /// Fetch scenarios, optionally filtered by client ID. Pass nil to fetch all.
    func fetchScenarios(forClient clientId: String?) async throws -> [TelemetryScenarioRecord]

    /// Update a scenario record (typically to toggle isEnabled).
    func updateScenario(_ scenario: TelemetryScenarioRecord) async throws -> TelemetryScenarioRecord

    /// Delete all scenario records for a specific client. Returns count deleted.
    func deleteScenarios(forClient clientId: String) async throws -> Int

    /// Create a CloudKit subscription for TelemetryScenario record changes.
    func createScenarioSubscription() async throws -> String
}
```

---

## Step 5: Implement `CloudKitClient` Scenario Methods

Implement the four new protocol methods in `CloudKitClient`. Follow the same patterns used for the existing client record methods:

### `fetchScenarios(forClient:)`
- Query `TelemetryScenario` record type
- If `clientId` is non-nil, add a predicate filtering on `clientId`
- If `clientId` is nil, use `NSPredicate(value: true)` to fetch all
- Map `CKRecord` results to `TelemetryScenarioRecord` instances

### `updateScenario(_:)`
- Require non-nil `recordID` (throw `.missingRecordID` otherwise)
- Fetch the existing `CKRecord`, update fields, save via `CKModifyRecordsOperation`
- Return the updated `TelemetryScenarioRecord`

### `deleteScenarios(forClient:)`
- Query all scenario records matching the `clientId`
- Batch delete via `CKModifyRecordsOperation`
- Return the count of deleted records

### `createScenarioSubscription()`
- Create a `CKQuerySubscription` on `TelemetryScenario` record type
- Use subscription ID `"TelemetryScenario-All"`
- Configure notification info (set `shouldSendContentAvailable = true`)
- Follow the same pattern as `createClientRecordSubscription()`

---

## Step 6: Client-Side Scenario Registration

### 6a. Scenario registration on session start

Add a method for clients to declare their scenarios when starting a session:

```swift
/// Register scenarios for this client session. Writes one TelemetryScenario
/// record per scenario to CloudKit. Restores previously persisted enabled state.
public func registerScenarios(_ scenarioNames: [String]) async throws
```

Implementation:
1. Read locally persisted scenario states (see Step 7)
2. For each scenario name, create a `TelemetryScenarioRecord` with:
   - `clientId` = this client's ID
   - `scenarioName` = the name
   - `isEnabled` = restored from local persistence, or `false` if new
   - `created` = now
3. Write all records to CloudKit (batch save)

### 6b. Scenario annotation on log calls

Extend the logging API to accept an optional scenario parameter:

```swift
/// Log a telemetry event annotated with a scenario.
public func log(_ eventName: String, scenario: String, properties: ...) async throws
```

When writing the telemetry `CKRecord`, set the `scenario` field (from `TelemetrySchema.Field.scenario`).

If logging is called with a scenario that is currently disabled, the client should **skip writing** the record (this is the whole point of per-scenario control).

### 6c. Scenario command handling

When the client receives a push notification for a command record:
1. Fetch the command
2. If action is `.enableScenario` or `.disableScenario`:
   - Read the `scenarioName` field from the command
   - Update the local scenario enabled state
   - Persist the new state locally (Step 7)
   - Update the `TelemetryScenarioRecord` in CloudKit (`isEnabled` field) so the viewer sees the change
3. Existing `.enable` / `.disable` commands continue to work at the whole-client level

---

## Step 7: Local Persistence of Scenario State

The client must persist which scenarios are currently enabled/disabled so the state survives app restarts. Follow the same pattern used for the existing telemetry enabled/approved state (likely `UserDefaults` or a plist).

```swift
/// Persist scenario enabled states to local storage.
/// Key format: "telemetry.scenario.<scenarioName>.isEnabled"
private func persistScenarioState(_ scenarioName: String, isEnabled: Bool)

/// Restore scenario enabled state from local storage. Returns nil if never persisted.
private func restoredScenarioState(_ scenarioName: String) -> Bool?
```

On session start (`registerScenarios`), the client checks local persistence for each scenario and uses the stored state rather than defaulting to `false`.

---

## Step 8: Session-End Cleanup

When a client session ends:

1. Delete all `TelemetryScenarioRecord`s for this `clientId` from CloudKit
2. Delete all telemetry log records for this `clientId` from CloudKit
3. **Do NOT clear locally persisted scenario states** — these should survive session end so that the next session restores the same enabled/disabled configuration

```swift
public func endSession() async throws {
    try await deleteScenarios(forClient: clientId)
    try await deleteAllRecords()  // existing method for log records
    // Local scenario persistence intentionally kept
}
```

---

## Step 9: Update Example App

The package includes an example app that demonstrates the telemetry client API. Update it to showcase scenario-based logging:

### 9a. Define example scenarios

Add a sample scenario enum to the example app:

```swift
enum ExampleScenario: String, CaseIterable {
    case networkRequests = "NetworkRequests"
    case dataSync = "DataSync"
    case userInteraction = "UserInteraction"
}
```

### 9b. Register scenarios on session start

Update the example app's session start flow to call `registerScenarios()` with the example enum values. This should happen right after the existing telemetry client initialization.

### 9c. Use scenario-annotated logging

Update existing example log call sites to include the `scenario:` parameter. Each log call in the example app should be annotated with the appropriate scenario from the enum above.

### 9d. Show scenario state in example UI

Add a simple UI section to the example app that displays the current scenario list and their enabled/disabled states. This helps verify the round-trip: viewer enables a scenario → client receives command → client updates state → example UI reflects change.

### 9e. Session-end cleanup

Update the example app's session teardown to call `endSession()`, demonstrating the full lifecycle including scenario record deletion.

---

## Implementation Order

1. **`TelemetryScenarioRecord`** — New type (Step 1)
2. **`TelemetrySchema` extensions** — Record type, fields, scenario field on logs (Step 2)
3. **`CommandAction` + `TelemetryCommandRecord`** — New actions and scenarioName field (Step 3)
4. **`CloudKitClientProtocol` methods** — Protocol additions (Step 4)
5. **`CloudKitClient` implementation** — Fetch, update, delete, subscribe for scenarios (Step 5)
6. **Client registration + logging API** — registerScenarios, annotated logging, command handling (Step 6)
7. **Local persistence** — Persist/restore scenario enabled states (Step 7)
8. **Session cleanup** — Delete CloudKit records on session end, preserve local state (Step 8)
9. **Example app** — Update to demonstrate scenario registration, annotated logging, and lifecycle (Step 9)
10. **Unit tests** — Cover all new types, methods, and behaviors (Step 10)

---

## Files to Create / Modify

| File | Action | Description |
|------|--------|-------------|
| `TelemetryScenarioRecord.swift` | Create | New scenario record type |
| `TelemetrySchema.swift` | Modify | Add `scenarioRecordType`, `ScenarioField` enum, `scenario` to `Field` |
| `TelemetrySchema+CommandAction.swift` (or wherever `CommandAction` lives) | Modify | Add `.enableScenario`, `.disableScenario` |
| `TelemetryCommandRecord.swift` | Modify | Add optional `scenarioName` field, update init and CKRecord mapping |
| `CloudKitClientProtocol.swift` | Modify | Add 4 scenario methods |
| `CloudKitClient.swift` | Modify | Implement 4 scenario methods |
| Client session manager (wherever session start/end lives) | Modify | Add `registerScenarios()`, `endSession()` cleanup, command handling |
| Client logging call (wherever `log()` is defined) | Modify | Add `scenario` parameter, check enabled state before writing |
| Client persistence (UserDefaults or equivalent) | Modify | Add scenario state persistence/restoration |
| Example app scenario enum | Create | `ExampleScenario` enum for sample scenarios |
| Example app session/UI code | Modify | Register scenarios, annotate logs, show scenario state, demonstrate cleanup |

---

## Step 10: Unit Tests

Tests should follow the existing test patterns in the package. Create new test files alongside existing ones.

### New type tests

- `TelemetryScenarioRecord` init with all fields, including default values
- `TelemetryScenarioRecord` round-trip to/from `CKRecord` (serialize then deserialize, verify all fields preserved)
- `TelemetryScenarioRecord.Error.missingRecordID` thrown when expected

### Schema tests

- `TelemetrySchema.scenarioRecordType` has expected string value
- `TelemetrySchema.ScenarioField.allCases` contains all expected fields
- Each `ScenarioField` returns correct `fieldType` and `isIndexed` values
- `TelemetrySchema.Field.scenario` exists with correct type and is indexed

### Command tests

- `CommandAction.enableScenario` and `.disableScenario` have correct raw values
- `TelemetryCommandRecord` init with `scenarioName` — verify field is set
- `TelemetryCommandRecord` init without `scenarioName` — verify field is nil
- `TelemetryCommandRecord` round-trip to/from `CKRecord` with and without `scenarioName`

### CloudKit client tests

- `fetchScenarios(forClient: nil)` returns all scenarios (mock/stub CloudKit)
- `fetchScenarios(forClient: "specific-id")` returns only matching scenarios
- `updateScenario(_:)` updates `isEnabled` field and returns updated record
- `updateScenario(_:)` throws `missingRecordID` when recordID is nil
- `deleteScenarios(forClient:)` deletes correct records and returns count
- `createScenarioSubscription()` creates subscription with expected ID and configuration

### Scenario state persistence tests

- Persist a scenario state → restore it → verify value matches
- Restore a scenario that was never persisted → verify returns nil
- Persist enabled → persist disabled → restore → verify latest value (disabled)
- Persist states for multiple scenarios → restore each → verify independence

### Logging behavior tests

- Log with an enabled scenario → verify record is written with scenario field set
- Log with a disabled scenario → verify record is **not** written (skipped)
- Log without a scenario → verify backward compatibility (record written, scenario field empty/nil)

### Command handling tests

- Receive `.enableScenario` command → verify local scenario state updated to enabled
- Receive `.disableScenario` command → verify local scenario state updated to disabled
- Receive scenario command → verify local persistence is updated
- Receive scenario command for unknown scenario name → verify graceful handling

### Session lifecycle tests

- `registerScenarios()` with fresh state → all scenarios written to CloudKit as disabled
- `registerScenarios()` with previously persisted states → scenarios written with restored enabled/disabled values
- `endSession()` → scenario records deleted from CloudKit
- `endSession()` → local persisted scenario states are **preserved** (not cleared)
- Full lifecycle: register → enable via command → end session → re-register → verify enabled state restored
