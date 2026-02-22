# DiagnosticClient Implementation Spec

## Overview

This change reworks the client's telemetry activation flow and introduces per-scenario diagnostic levels. Instead of the client self-enabling via a toggle, the viewer now initiates activation by sending a command. The client displays a stable code, polls for activation commands on user request, and creates records only after receiving an activation command from the viewer.

**No record ownership changes.** The client continues to own `TelemetryClient`, `TelemetryScenario`, and `TelemetryEvent` records.

---

## 1. TelemetryLogLevel (rewrite)

**File:** `Sources/ObjPxlLiveTelemetry/Telemetry/TelemetryLogLevel.swift`

Replace the current String-backed, 2-level enum with an Int-backed, 4-level enum.

### Current

```swift
public enum TelemetryLogLevel: String, Sendable, CaseIterable, Comparable {
    case info
    case diagnostic
    // manual Comparable via sortOrder
}
```

### New

```swift
public enum TelemetryLogLevel: Int, Sendable, CaseIterable, Comparable, CustomStringConvertible {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    public var description: String {
        switch self {
        case .debug: "Debug"
        case .info: "Info"
        case .warning: "Warning"
        case .error: "Error"
        }
    }
}
```

`Comparable` conformance is now automatic via `Int` raw value (no manual `sortOrder` needed).

**Impact:** Every call site that uses `.info` continues to work. Call sites using `.diagnostic` must be migrated (search the codebase for `.diagnostic` references and replace with the appropriate new level, likely `.debug`).

---

## 2. TelemetrySchema changes

**File:** `Sources/ObjPxlLiveTelemetry/Telemetry/TelemetrySchema.swift`

### 2a. ScenarioField: `isEnabled` -> `diagnosticLevel`

```swift
public enum ScenarioField: String, CaseIterable {
    case clientId = "clientid"
    case scenarioName
    case diagnosticLevel   // was: isEnabled
    case created

    public var isIndexed: Bool {
        switch self {
        case .clientId, .scenarioName, .diagnosticLevel, .created:
            return true
        }
    }

    public var fieldTypeDescription: String {
        switch self {
        case .clientId, .scenarioName:
            return "String"
        case .diagnosticLevel:
            return "Int64"   // was: "Int64 (0/1)"
        case .created:
            return "Date/Time"
        }
    }
}
```

### 2b. CommandField: add `diagnosticLevel`

Add a new case to `CommandField`:

```swift
public enum CommandField: String, CaseIterable {
    // ... existing cases ...
    case diagnosticLevel   // NEW

    public var isIndexed: Bool {
        switch self {
        // ... existing ...
        case .diagnosticLevel:
            return false
        }
    }

    public var fieldTypeDescription: String {
        switch self {
        // ... existing ...
        case .diagnosticLevel:
            return "Int64"
        }
    }
}
```

### 2c. CommandAction: add `.activate`, replace scenario commands

```swift
public enum CommandAction: String, Sendable, CaseIterable {
    case activate               // NEW: create client + enable from scratch
    case enable
    case disable
    case deleteEvents = "delete_events"
    case setScenarioLevel       // NEW: replaces enableScenario + disableScenario
}
```

Remove `enableScenario` and `disableScenario`. The `.setScenarioLevel` command carries `scenarioName` + `diagnosticLevel` (where level 0 maps to an "off" sentinel — see section 3).

### 2d. Update `fields(for:)` and schema instructions

Update the `fields(for:)` helper to reflect the new field names and types. The CloudKit Dashboard instructions should reference `diagnosticLevel` instead of `isEnabled` for the scenario record type, and include `diagnosticLevel` for the command record type.

---

## 3. TelemetryScenarioRecord

**File:** `Sources/ObjPxlLiveTelemetry/Telemetry/TelemetryScenarioRecord.swift`

### Replace `isEnabled: Bool` with `diagnosticLevel: Int`

Use `Int` (not `TelemetryLogLevel`) for the model field since CloudKit stores Int64 and we need a sentinel value for "off" (disabled). Convention: `-1` means off/disabled, `0..3` maps to `TelemetryLogLevel` raw values.

```swift
public struct TelemetryScenarioRecord: Sendable, Equatable {
    // ... Error enum unchanged ...

    public static let levelOff: Int = -1

    public let recordID: CKRecord.ID?
    public let clientId: String
    public let scenarioName: String
    public var diagnosticLevel: Int    // was: isEnabled: Bool
    public let created: Date

    /// Convenience: is this scenario actively capturing?
    public var isActive: Bool { diagnosticLevel >= 0 }

    /// Convenience: the resolved TelemetryLogLevel, or nil if off.
    public var resolvedLevel: TelemetryLogLevel? {
        TelemetryLogLevel(rawValue: diagnosticLevel)
    }

    public init(
        recordID: CKRecord.ID? = nil,
        clientId: String,
        scenarioName: String,
        diagnosticLevel: Int = Self.levelOff,   // default: off
        created: Date = .now
    ) {
        self.recordID = recordID
        self.clientId = clientId
        self.scenarioName = scenarioName
        self.diagnosticLevel = diagnosticLevel
        self.created = created
    }
}
```

### Update `init(record:)` — read `diagnosticLevel` as Int64

```swift
// Replace the isEnabled reading block with:
guard let level = record[TelemetrySchema.ScenarioField.diagnosticLevel.rawValue] as? NSNumber else {
    throw Error.missingField(TelemetrySchema.ScenarioField.diagnosticLevel.rawValue)
}
self.diagnosticLevel = level.intValue
```

### Update `toCKRecord()` and `applying(to:)`

Replace:
```swift
record[TelemetrySchema.ScenarioField.isEnabled.rawValue] = isEnabled as CKRecordValue
```
With:
```swift
record[TelemetrySchema.ScenarioField.diagnosticLevel.rawValue] = diagnosticLevel as CKRecordValue
```

---

## 4. TelemetryCommandRecord

**File:** `Sources/ObjPxlLiveTelemetry/Telemetry/TelemetryCommandRecord.swift`

### Add `diagnosticLevel` field

```swift
public struct TelemetryCommandRecord: Sendable, Equatable {
    // ... existing fields ...
    public let diagnosticLevel: Int?   // NEW: for setScenarioLevel commands

    public init(
        // ... existing params ...
        diagnosticLevel: Int? = nil    // NEW
    ) {
        // ... existing assignments ...
        self.diagnosticLevel = diagnosticLevel
    }
}
```

### Update `init(record:)` — read optional diagnosticLevel

After the existing field reads, add:

```swift
self.diagnosticLevel = (record[TelemetrySchema.CommandField.diagnosticLevel.rawValue] as? NSNumber)?.intValue
```

### Update `toCKRecord()` and `applying(to:)`

Add:
```swift
record[TelemetrySchema.CommandField.diagnosticLevel.rawValue] = diagnosticLevel as CKRecordValue?
```

---

## 5. TelemetryEvent

**File:** `Sources/ObjPxlLiveTelemetry/Telemetry/TelemetryEvent.swift`

### Store logLevel as Int in CloudKit

In `toCKRecord()`, change:
```swift
record[TelemetrySchema.Field.logLevel.rawValue] = level.rawValue
```
To:
```swift
record[TelemetrySchema.Field.logLevel.rawValue] = level.rawValue as CKRecordValue  // Int
```

Also update the `Field.logLevel` `fieldTypeDescription` in `TelemetrySchema.Field` from `"String"` to `"Int64"`.

**Note:** This is a schema-level change. Existing event records in CloudKit store logLevel as String. New records will store as Int64. The viewer should handle both formats during the transition. Consider whether a data migration is needed, or whether old events can simply be deleted.

---

## 6. TelemetryToggleView (redesign)

**File:** `Sources/ObjPxlLiveTelemetry/Telemetry/TelemetryToggleView.swift`

### New UI structure

Replace the toggle-based UI with:

```
Section("Telemetry") {
    // 1. Client Code — always shown
    LabeledContent("Client Code") {
        HStack {
            Text(clientCode)           // 12-digit base32, monospaced
            Button("Copy", systemImage: "doc.on.doc") { copy to pasteboard }
        }
    }

    // 2. Status row — always shown
    TelemetryStatusRow(...)

    // 3. Session ID — shown when active
    if isActive {
        LabeledContent("Session ID") { Text(sessionId) }
    }

    // 4. Request Diagnostics button — shown when NOT active
    if !isActive {
        Button("Request Diagnostics", systemImage: "antenna.radiowaves.left.and.right") {
            Task { await requestDiagnostics() }
        }
    }

    // 5. End Session button — shown when active
    if isActive {
        Button("End Session", role: .destructive, systemImage: "stop.fill") {
            showEndSessionConfirmation = true
        }
        .confirmationDialog("End Diagnostic Session?", ...) { ... }
    }
} header: {
    Text("Telemetry")
} footer: {
    Text("Share your client code with the diagnostics administrator to enable telemetry.")
}
```

### Remove

- The `Toggle(isOn: $isTelemetryRequested)` and its `onChange` handler
- The `isTelemetryRequested` state variable
- The "Sync Status" button
- The "Clear Telemetry Data" button (replaced by "End Session")
- The `handleToggleChange` method
- The `reconcile` method call from the view (reconciliation still exists in the lifecycle service but is not exposed as a UI action)

### New state

```swift
@State private var viewState: ViewState = .idle
@State private var didBootstrap = false
@State private var showEndSessionConfirmation = false
```

### Client code display

The client code is the `clientIdentifier` from settings. It must be generated once on first view appearance and persisted. Update `bootstrap()`:

```swift
func bootstrap() async {
    viewState = .loading
    _ = await lifecycle.startup()

    // Ensure a stable client identifier exists
    if lifecycle.settings.clientIdentifier == nil {
        await lifecycle.generateAndPersistClientIdentifier()
    }

    didBootstrap = true
    settleViewState()
}
```

The `clientCode` computed property reads from `lifecycle.settings.clientIdentifier ?? ""`.

### `requestDiagnostics()` method

```swift
func requestDiagnostics() async {
    viewState = .syncing
    await lifecycle.requestDiagnostics()
    settleViewState()
}
```

### `endSession()` method

```swift
func endSession() async {
    viewState = .syncing
    _ = await lifecycle.disableTelemetry()
    settleViewState()
}
```

### Status mapping

The `TelemetryStatusRow` continues to work with the existing `Status` enum. Add handling for a new `.noRegistration` status case (see section 7).

Add a new status display:
- `.noRegistration` → "No Registration Found" (grey, info icon)

### Copy to pasteboard

```swift
#if canImport(UIKit)
UIPasteboard.general.string = clientCode
#elseif canImport(AppKit)
NSPasteboard.general.clearContents()
NSPasteboard.general.setString(clientCode, forType: .string)
#endif
```

---

## 7. TelemetryLifecycleService

**File:** `Sources/ObjPxlLiveTelemetry/Telemetry/TelemetryLifecycleService.swift`

### 7a. New Status case

```swift
public enum Status: Equatable {
    case idle
    case loading
    case syncing
    case enabled
    case disabled
    case pendingApproval
    case noRegistration       // NEW: no activate command found
    case error(String)
}
```

### 7b. New public method: `generateAndPersistClientIdentifier()`

Called once from the view to ensure a stable identifier exists without triggering any CloudKit interaction.

```swift
public func generateAndPersistClientIdentifier() async {
    guard settings.clientIdentifier == nil else { return }
    let identifier = identifierGenerator.generateIdentifier()
    var currentSettings = await settingsStore.load()
    currentSettings.clientIdentifier = identifier
    settings = await settingsStore.save(currentSettings)
}
```

Note: This intentionally does NOT back up to CloudKit or set `telemetryRequested = true`. It only persists the identifier locally.

### 7c. New public method: `requestDiagnostics()`

This is the "poll for activation" flow triggered by the "Request Diagnostics" button.

```swift
public func requestDiagnostics() async {
    guard let clientId = settings.clientIdentifier else {
        setStatus(.error("No client identifier"), message: "Client code not generated.")
        return
    }

    setStatus(.syncing, message: "Checking for activation...")

    do {
        let pendingCommands = try await cloudKitClient.fetchPendingCommands(for: clientId)

        // Look for an activate command
        if let activateCommand = pendingCommands.first(where: { $0.action == .activate }) {
            // Process the activate command — this creates TelemetryClient, scenarios, etc.
            await handleActivateCommand(activateCommand)
        } else if let enableCommand = pendingCommands.first(where: { $0.action == .enable }) {
            // Also handle enable commands (for re-activation after deactivate)
            await handleActivateCommand(enableCommand)
        } else {
            // No activation command found
            setStatus(.noRegistration, message: "No registration found. Share your client code with the diagnostics administrator.")
        }
    } catch {
        setStatus(.error("Check failed: \(error.localizedDescription)"),
                  message: "Failed to check for activation: \(error.localizedDescription)")
    }
}
```

### 7d. New private method: `handleActivateCommand(_ command:)`

This runs the existing `enableTelemetry()` logic but in response to a command rather than a toggle. The key difference: the TelemetryClient record is created with `isEnabled = true` directly (no pending approval state).

```swift
private func handleActivateCommand(_ command: TelemetryCommandRecord) async {
    guard let clientId = settings.clientIdentifier else { return }

    setStatus(.syncing, message: "Activating telemetry...")

    var currentSettings = await settingsStore.load()
    currentSettings.telemetryRequested = true
    currentSettings.telemetrySendingEnabled = true
    currentSettings.clientIdentifier = clientId
    settings = await saveAndBackupSettings(currentSettings)

    do {
        // Create or fetch the TelemetryClient record (isEnabled = true)
        let existingClients = try await cloudKitClient.fetchTelemetryClients(clientId: clientId, isEnabled: nil)
        if let existing = existingClients.first {
            // Update to enabled if needed
            if !existing.isEnabled, let recordID = existing.recordID {
                clientRecord = try await cloudKitClient.updateTelemetryClient(
                    recordID: recordID, clientId: nil, created: nil, isEnabled: true
                )
            } else {
                clientRecord = existing
            }
        } else {
            clientRecord = try await cloudKitClient.createTelemetryClient(
                clientId: clientId, created: .now, isEnabled: true
            )
        }

        // Mark the command as executed
        if let recordID = command.recordID {
            _ = try await cloudKitClient.updateCommandStatus(
                recordID: recordID, status: .executed, executedAt: .now, errorMessage: nil
            )
        }

        // Set up command subscription (push-based commands from here on)
        await setupCommandProcessing(for: clientId)

        // Activate logger
        await logger.activate(enabled: true)

        // Register deferred scenarios
        if let pending = pendingScenarioNames {
            await performScenarioRegistration(pending, clientId: clientId)
        }

        reconciliation = .localAndServerEnabled
        setStatus(.enabled, message: "Telemetry active. Client ID: \(clientId)")
    } catch {
        setStatus(.error("Activation failed: \(error.localizedDescription)"),
                  message: "Activation failed: \(error.localizedDescription)")
    }
}
```

### 7e. Modify `enableTelemetry()` — remove toggle-driven creation

The existing `enableTelemetry()` method is no longer called from the UI toggle (which is removed). However, it is still called from the `handleEnableCommand()` handler when the client receives a push-based `.enable` command. Simplify it or delegate to `handleActivateCommand`.

Consider making `enableTelemetry()` a thin wrapper around the activate logic, or keep it for the `.enable` command handler. The key point: it should no longer be called from the view.

### 7f. Modify `startup()` / `performBackgroundRestore()`

In `performBackgroundRestore()`, if the client has a saved `clientIdentifier` and `telemetryRequested = true`, it should reconcile as before (checking if TelemetryClient exists on server, setting up command subscription). This handles app relaunch while a session is active.

No changes needed to the core restore logic — it already handles this correctly.

### 7g. New handler for `.setScenarioLevel`

Replace the `onEnableScenario` / `onDisableScenario` callbacks in `setupCommandProcessing()`:

```swift
let processor = TelemetryCommandProcessor(
    cloudKitClient: cloudKitClient,
    clientId: clientId,
    onEnable: { ... },
    onDisable: { ... },
    onDeleteEvents: { ... },
    onActivate: { [weak self] in           // NEW
        guard let self else { return }
        await self.handleEnableCommand()   // reuse enable logic for push-based activate
    },
    onSetScenarioLevel: { [weak self] scenarioName, level in    // NEW (replaces onEnable/DisableScenario)
        guard let self else { return }
        try await self.setScenarioDiagnosticLevel(scenarioName, level: level)
    }
)
```

### 7h. Modify scenario state management

Replace `scenarioStates: [String: Bool]` with `scenarioStates: [String: Int]` (where the Int is the diagnostic level, `-1` = off).

```swift
public private(set) var scenarioStates: [String: Int] = [:]   // was [String: Bool]
```

Update `setScenarioDiagnosticLevel`:

```swift
public func setScenarioDiagnosticLevel(_ scenarioName: String, level: Int) async throws {
    scenarioStates[scenarioName] = level
    await scenarioStore.saveLevel(for: scenarioName, diagnosticLevel: level)

    if var record = scenarioRecords[scenarioName] {
        record.diagnosticLevel = level
        let updated = try await cloudKitClient.updateScenario(record)
        scenarioRecords[scenarioName] = updated
    }

    await pushScenarioStatesToLogger()
}
```

### 7i. Modify `performScenarioRegistration`

Scenarios are created with `diagnosticLevel = TelemetryScenarioRecord.levelOff` (inactive by default):

```swift
newRecords.append(TelemetryScenarioRecord(
    clientId: clientId,
    scenarioName: name,
    diagnosticLevel: TelemetryScenarioRecord.levelOff   // was: isEnabled: states[name] ?? false
))
```

Load persisted levels instead of bools:

```swift
for name in scenarioNames {
    let persisted = await scenarioStore.loadLevel(for: name)
    states[name] = persisted ?? TelemetryScenarioRecord.levelOff
}
```

### 7j. Remove `pendingApproval` status usage from activation flow

In the new flow, the client doesn't enter a "pending approval" state. It either finds an activation command (and activates) or doesn't (noRegistration). The `.pendingApproval` status can remain in the enum for backward compatibility but won't be set during the normal activation flow.

---

## 8. TelemetryCommandProcessor

**File:** `Sources/ObjPxlLiveTelemetry/Telemetry/TelemetryCommandProcessor.swift`

### Replace handler types

```swift
public actor TelemetryCommandProcessor {
    public typealias EnableHandler = @Sendable () async throws -> Void
    public typealias DisableHandler = @Sendable () async throws -> Void
    public typealias DeleteEventsHandler = @Sendable () async throws -> Void
    public typealias ActivateHandler = @Sendable () async throws -> Void                      // NEW
    public typealias SetScenarioLevelHandler = @Sendable (String, Int) async throws -> Void    // NEW (replaces Enable/DisableScenarioHandler)

    private let onActivate: ActivateHandler                      // NEW
    private let onSetScenarioLevel: SetScenarioLevelHandler      // NEW

    // Remove: onEnableScenario, onDisableScenario
```

### Update `processCommand(_:)` switch

```swift
case .activate:
    try await onActivate()

case .setScenarioLevel:
    guard let scenarioName = command.scenarioName else {
        // ... fail with missing scenarioName ...
        return
    }
    guard let level = command.diagnosticLevel else {
        // ... fail with missing diagnosticLevel ...
        return
    }
    try await onSetScenarioLevel(scenarioName, level)
```

Remove the `.enableScenario` and `.disableScenario` cases.

---

## 9. TelemetryLogger

**File:** `Sources/ObjPxlLiveTelemetry/Telemetry/TelemetryLogger.swift`

### 9a. Change scenario states type

```swift
private nonisolated let scenarioStatesLock = OSAllocatedUnfairLock<[String: Int]>(initialState: [:])
// was: OSAllocatedUnfairLock<[String: Bool]>
```

### 9b. Update `TelemetryLogging` protocol

```swift
func updateScenarioStates(_ states: [String: Int])
// was: func updateScenarioStates(_ states: [String: Bool])
```

### 9c. Update scenario check in `logEvent(name:scenario:level:property1:)`

Replace:
```swift
let isEnabled = scenarioStatesLock.withLock { $0[scenario] ?? false }
guard isEnabled else { return }
```

With level-based filtering:
```swift
let scenarioLevel = scenarioStatesLock.withLock { $0[scenario] ?? TelemetryScenarioRecord.levelOff }
guard scenarioLevel >= 0, level.rawValue >= scenarioLevel else { return }
```

This means: if the scenario's diagnostic level is `.debug` (0), all events at debug and above are captured. If `.warning` (2), only warning and error events are captured. If `-1` (off), nothing is captured.

### 9d. Update NoopTelemetryLogger

```swift
public func updateScenarioStates(_ states: [String: Int]) {}
```

---

## 10. TelemetryScenarioStore

**File:** `Sources/ObjPxlLiveTelemetry/Telemetry/TelemetryScenarioStore.swift`

### Update protocol

```swift
public protocol TelemetryScenarioStoring: Sendable {
    func loadLevel(for scenarioName: String) async -> Int?             // was loadState -> Bool?
    func loadAllLevels() async -> [String: Int]                        // was loadAllStates -> [String: Bool]
    func saveLevel(for scenarioName: String, diagnosticLevel: Int) async  // was saveState(..., isEnabled: Bool)
    func removeState(for scenarioName: String) async                   // unchanged
    func removeAllStates() async                                       // unchanged
}
```

### Update UserDefaultsTelemetryScenarioStore

Change the key suffix and stored type:

```swift
static let keySuffix = ".diagnosticLevel"    // was: ".isEnabled"

public func loadLevel(for scenarioName: String) async -> Int? {
    let key = Self.key(for: scenarioName)
    guard defaults.object(forKey: key) != nil else { return nil }
    return defaults.integer(forKey: key)
}

public func loadAllLevels() async -> [String: Int] {
    let names = defaults.stringArray(forKey: Self.registryKey) ?? []
    var levels: [String: Int] = [:]
    for name in names {
        let key = Self.key(for: name)
        if defaults.object(forKey: key) != nil {
            levels[name] = defaults.integer(forKey: key)
        }
    }
    return levels
}

public func saveLevel(for scenarioName: String, diagnosticLevel: Int) async {
    defaults.set(diagnosticLevel, forKey: Self.key(for: scenarioName))
    addToRegistry(scenarioName)
}
```

---

## 11. CloudKitClient

**File:** `Sources/ObjPxlLiveTelemetry/Telemetry/CloudKitClient.swift`

### Scenario methods

Any method that reads/writes `isEnabled` on scenario records needs to use `diagnosticLevel` instead. This includes:
- `createScenarios(_:)` — no change needed (uses `toCKRecord()` which is updated)
- `fetchScenarios(forClient:)` — no change needed (uses `init(record:)` which is updated)
- `updateScenario(_:)` — no change needed (uses `applying(to:)` which is updated)

### Query predicates

If any queries filter by `isEnabled`, update the field name to `diagnosticLevel`. For example, if there's a query like:
```swift
NSPredicate(format: "isEnabled == %@", NSNumber(value: true))
```
This would need to change to:
```swift
NSPredicate(format: "diagnosticLevel >= %d", 0)
```
(where >= 0 means "any active level")

### Protocol

If `CloudKitClientProtocol` has signatures referencing `isEnabled` for scenario queries, update them.

---

## 12. Summary of removed functionality

| Removed | Replacement |
|---|---|
| Toggle switch in TelemetryToggleView | "Request Diagnostics" button |
| "Sync Status" button | Removed (reconciliation happens on startup) |
| "Clear Telemetry Data" button | "End Session" button |
| `.pendingApproval` in activation flow | `.noRegistration` status |
| `enableScenario` / `disableScenario` commands | `setScenarioLevel` command |
| `scenarioStates: [String: Bool]` | `scenarioStates: [String: Int]` |
| `TelemetryLogLevel.diagnostic` | `TelemetryLogLevel.debug` (or `.warning`/`.error` as appropriate) |

---

## 13. CloudKit Schema Changes

These changes require corresponding updates in the CloudKit Dashboard:

### TelemetryScenario record type
- **Remove field:** `isEnabled` (Int64)
- **Add field:** `diagnosticLevel` (Int64, Queryable)

### TelemetryCommand record type
- **Add field:** `diagnosticLevel` (Int64)

### TelemetryEvent record type
- **Change field:** `logLevel` from String to Int64 (or add new Int64 field alongside)

**Migration:** Existing scenario records with `isEnabled = true` should be treated as `diagnosticLevel = 1` (info). Records with `isEnabled = false` should be treated as `diagnosticLevel = -1` (off). Consider adding backward-compatible reading in `TelemetryScenarioRecord.init(record:)` that checks for both field names during the transition.

---

## 14. Files changed (summary)

| File | Change type |
|---|---|
| `TelemetryLogLevel.swift` | Rewrite |
| `TelemetrySchema.swift` | Modify (ScenarioField, CommandField, CommandAction) |
| `TelemetryScenarioRecord.swift` | Modify (isEnabled -> diagnosticLevel) |
| `TelemetryCommandRecord.swift` | Modify (add diagnosticLevel) |
| `TelemetryEvent.swift` | Modify (logLevel as Int) |
| `TelemetryToggleView.swift` | Rewrite |
| `TelemetryLifecycleService.swift` | Modify (new methods, status, scenario states) |
| `TelemetryCommandProcessor.swift` | Modify (new handlers, new command cases) |
| `TelemetryLogger.swift` | Modify (scenario level filtering) |
| `TelemetryScenarioStore.swift` | Modify (Bool -> Int) |
| `CloudKitClient.swift` | Minor (field name in predicates if applicable) |
| `Scripts/cktool-telemetry-schema.sh` | Modify (schema field changes) |
| `Examples/.../ContentView.swift` | Modify (scenario UI, log level references) |
| `Examples/.../CommandDebugView.swift` | Modify (new status case, request diagnostics) |
| `Examples/.../Live_Diagnostics_Example_ClientApp.swift` | Minor (startup flow unchanged, scenario registration still works) |

---

## 15. cktool Schema Script

**File:** `Scripts/cktool-telemetry-schema.sh`

Update the embedded CloudKit schema DSL to reflect the new field names and types.

### TelemetryScenario: `isEnabled` -> `diagnosticLevel`

Change:
```
    RECORD TYPE TelemetryScenario (
        ...
        isEnabled       INT64 QUERYABLE SORTABLE,
        ...
    );
```

To:
```
    RECORD TYPE TelemetryScenario (
        ...
        diagnosticLevel INT64 QUERYABLE SORTABLE,
        ...
    );
```

### TelemetryCommand: add `diagnosticLevel`

Add the `diagnosticLevel` field:

```
    RECORD TYPE TelemetryCommand (
        ...
        diagnosticLevel INT64,
        scenarioName    STRING,
        status          STRING QUERYABLE SEARCHABLE SORTABLE,
        ...
    );
```

### TelemetryEvent: `logLevel` String -> INT64

Change:
```
        logLevel        STRING QUERYABLE SEARCHABLE SORTABLE,
```

To:
```
        logLevel        INT64 QUERYABLE SORTABLE,
```

Note: `SEARCHABLE` is removed since Int64 fields don't support text search. `QUERYABLE` and `SORTABLE` are retained.

---

## 16. Example App Changes

### 16a. ContentView.swift

**File:** `Examples/Live Diagnostics Example Client/Live Diagnostics Example Client/ContentView.swift`

#### `TestEventSection` — Log level picker

The `Picker("Log Level", ...)` currently iterates `TelemetryLogLevel.allCases` using `.rawValue` (String).

After the `TelemetryLogLevel` rewrite to `Int`-backed, the picker `ForEach` uses `\.rawValue` which is now `Int`. Update the display text:

```swift
Picker("Log Level", selection: $selectedLogLevel) {
    ForEach(TelemetryLogLevel.allCases, id: \.rawValue) { level in
        Text(level.description).tag(level)   // was: Text(level.rawValue).tag(level)
    }
}
```

#### `ScenarioSection` — Replace toggles with read-only level display

Scenarios are now controlled by the viewer, not the client. The example app should display the current diagnostic level as read-only (or at least reflect the new `[String: Int]` type).

Replace:
```swift
let isEnabled = lifecycle.scenarioStates[scenario.rawValue] ?? false
// ...
Text(isEnabled ? "Enabled" : "Disabled")
    .foregroundStyle(isEnabled ? .green : .secondary)
// ...
Toggle("", isOn: Binding(
    get: { isEnabled },
    set: { newValue in
        Task {
            try? await lifecycle.setScenarioEnabled(scenario.rawValue, enabled: newValue)
        }
    }
))
```

With:
```swift
let level = lifecycle.scenarioStates[scenario.rawValue] ?? TelemetryScenarioRecord.levelOff
let levelName = TelemetryLogLevel(rawValue: level)?.description ?? "Off"
// ...
Text(level >= 0 ? levelName : "Off")
    .foregroundStyle(level >= 0 ? .green : .secondary)
```

Remove the `Toggle` — scenario levels are set by the viewer. Optionally keep the "Log" button to test event filtering at the current level.

#### `ScenarioSection` — Fix `.diagnostic` reference

The "Log" button uses `.diagnostic` level:
```swift
telemetryLogger.logEvent(
    name: "scenario_test_\(scenario.rawValue)",
    scenario: scenario.rawValue,
    level: .diagnostic,      // ← this case is removed
    property1: "manual_test"
)
```

Change `.diagnostic` to `.debug` (or `.info`, depending on intended test behaviour).

#### `ScenarioSection` — "End Session" button

The "End Session" button already exists in the example app's `ScenarioSection`. It should be moved into the `TelemetryToggleView` as specified in section 6. Remove it from `ScenarioSection` to avoid duplication.

### 16b. CommandDebugView.swift

**File:** `Examples/Live Diagnostics Example Client/Live Diagnostics Example Client/CommandDebugView.swift`

#### Add `.noRegistration` status

Update `statusDescription`:
```swift
private var statusDescription: String {
    switch lifecycle.status {
    // ... existing cases ...
    case .noRegistration:
        return "No Registration"
    }
}
```

#### "Poll Commands Now" — consider using `requestDiagnostics()`

The current implementation triggers `lifecycle.reconcile()`. For the new flow, this is still valid (reconcile checks server state). Optionally add a "Request Diagnostics" button that calls `lifecycle.requestDiagnostics()` for testing the initial activation flow.

### 16c. Live_Diagnostics_Example_ClientApp.swift

**File:** `Examples/Live Diagnostics Example Client/Live Diagnostics Example Client/Live_Diagnostics_Example_ClientApp.swift`

Minimal changes. The startup flow remains:

```swift
.task {
    appDelegate.telemetryLifecycle = telemetryLifecycle
    await telemetryLifecycle.startup()
    try? await telemetryLifecycle.registerScenarios(
        ExampleScenario.allCases.map(\.rawValue)
    )
}
```

`registerScenarios` still works — it stores scenario names as pending until activation creates the CloudKit records. No changes needed here unless the method signature changes (it doesn't).
