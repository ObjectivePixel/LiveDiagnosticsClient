# Task: Add Push Notification Support to Telemetry Package

## Context

Host apps using this telemetry package need to receive CloudKit push notifications so that admin commands (enable/disable/delete_events) can reach the device in real time. Currently, each host app must manually:
1. Create its own `UIApplicationDelegate` with `didReceiveRemoteNotification` forwarding
2. Call `UIApplication.shared.registerForRemoteNotifications()`
3. Wire everything up at app launch

This task adds convenience infrastructure to the package so host apps need minimal integration code.

## Repo

`/Users/jamesclarke/src/github.com/objectivepixel/ObjPxlLiveDiagnosticsClient`

## Changes Required

### 1. New File: `TelemetryAppDelegate.swift`

**Create at:** `Sources/ObjPxlLiveTelemetry/Telemetry/TelemetryAppDelegate.swift`

A convenience `open class` that host apps can use via `@UIApplicationDelegateAdaptor(TelemetryAppDelegate.self)` to handle push notification forwarding without writing their own delegate:

```swift
#if canImport(UIKit) && !os(watchOS)
import UIKit
import CloudKit

@MainActor
open class TelemetryAppDelegate: NSObject, UIApplicationDelegate {
    public var telemetryLifecycle: TelemetryLifecycleService?

    open func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard let lifecycle = telemetryLifecycle else {
            completionHandler(.noData)
            return
        }
        Task {
            let handled = await lifecycle.handleRemoteNotification(userInfo)
            completionHandler(handled ? .newData : .noData)
        }
    }
}
#endif
```

Key design decisions:
- `open` so host apps can subclass if they need additional delegate methods
- `#if canImport(UIKit) && !os(watchOS)` — only compiles on iOS/visionOS
- Does NOT call `registerForRemoteNotifications()` in `didFinishLaunchingWithOptions` — that's handled conditionally in the lifecycle service (see change 2)
- The `telemetryLifecycle` property is set by the host app after launch (in a `.task` block)

### 2. Modify: Auto-register for APNS in `setupCommandProcessing()`

**File:** `Sources/ObjPxlLiveTelemetry/Telemetry/TelemetryLifecycleService.swift`

**Why:** We want APNS registration to only happen when telemetry is active (not at every app launch). `setupCommandProcessing()` is the ideal place because it only runs when `telemetryRequested` is true and a client ID exists.

**Add conditional imports** at the top of the file (alongside existing imports):

```swift
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
```

**Add to the beginning of `setupCommandProcessing(for:)`** (currently at line 334, before the existing print statement):

```swift
// Register for remote notifications so CloudKit push can reach this device.
// Called here (not at app launch) so it only runs when telemetry is active.
#if canImport(UIKit) && !os(watchOS)
UIApplication.shared.registerForRemoteNotifications()
#elseif canImport(AppKit)
NSApplication.shared.registerForRemoteNotifications()
#endif
```

This ensures:
- **Telemetry OFF:** No APNS registration, no CloudKit subscription — zero system impact
- **Telemetry ON:** APNS registration + CloudKit subscription happen together automatically
- **Subsequent launches with telemetry ON:** Token is refreshed, subscription verified

### 3. Modify: Make `startup()` idempotent

**File:** `Sources/ObjPxlLiveTelemetry/Telemetry/TelemetryLifecycleService.swift`

**Why:** With host apps calling `startup()` at app launch AND `TelemetryToggleView.bootstrap()` also calling it when the view appears, we get double initialization. Adding a guard makes the second call a safe no-op.

**Add a private property** alongside the existing properties (around line 45):

```swift
private var hasStartedUp = false
```

**Add a guard at the top of `startup()`** (currently at line 85):

```swift
@discardableResult
public func startup() async -> TelemetrySettings {
    if hasStartedUp {
        return settings
    }
    hasStartedUp = true

    setStatus(.loading, message: "Loading telemetry preferences")
    // ... rest of existing code unchanged ...
}
```

## Files Summary

| File | Action |
|---|---|
| `Sources/ObjPxlLiveTelemetry/Telemetry/TelemetryAppDelegate.swift` | **New file** |
| `Sources/ObjPxlLiveTelemetry/Telemetry/TelemetryLifecycleService.swift` | **Modify** (add imports, APNS registration in `setupCommandProcessing`, idempotent `startup()`) |

## Verification

1. Build the package for iOS, macOS, and watchOS — all should compile
2. `TelemetryAppDelegate` should only be available on iOS/visionOS (not watchOS, not macOS)
3. Existing tests should still pass (`swift test` from the Packages directory)
4. Verify `startup()` idempotency: calling it twice should only execute the initialization once
5. After verification, tag a new version (bump minor or patch as appropriate)

## How Host Apps Use This

After consuming the new tag, a host app needs just 3 lines:

```swift
// In the App struct:
@UIApplicationDelegateAdaptor(TelemetryAppDelegate.self) private var appDelegate

// In the .task block:
appDelegate.telemetryLifecycle = telemetryLifecycle
await telemetryLifecycle.startup()
```

Everything else (APNS registration, subscription management, notification forwarding) is handled automatically by the package.
