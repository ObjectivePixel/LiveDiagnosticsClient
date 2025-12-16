import Foundation
import SwiftUI

private struct TelemetryLoggerKey: EnvironmentKey {
    static let defaultValue: any TelemetryLogging = TelemetryLogger()
}

private struct TelemetryLifecycleKey: EnvironmentKey {
    @MainActor static var defaultValue: TelemetryLifecycleService {
        TelemetryLifecycleService()
    }
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
