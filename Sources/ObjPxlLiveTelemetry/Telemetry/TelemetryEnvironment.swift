import Foundation
import SwiftUI

private struct TelemetryLoggerKey: EnvironmentKey {
    static let defaultValue: any TelemetryLogging = TelemetryLogger()
}

private struct TelemetryLifecycleKey: @preconcurrency EnvironmentKey {
    // Must be `static let` (stored property), not `static var` (computed property).
    // On macOS, when the app goes to background and returns, SwiftUI may re-evaluate
    // environment values. A computed property would create a new service instance each
    // time with fresh default state (telemetryRequested = false), resetting the checkbox.
    // A stored property returns the same instance with its state intact.
    @MainActor static let defaultValue = TelemetryLifecycleService()
}

extension EnvironmentValues {
    public var telemetryLogger: any TelemetryLogging {
        get { self[TelemetryLoggerKey.self] }
        set { self[TelemetryLoggerKey.self] = newValue }
    }

    public var telemetryLifecycle: TelemetryLifecycleService {
        get { self[TelemetryLifecycleKey.self] }
        set { self[TelemetryLifecycleKey.self] = newValue }
    }
}
