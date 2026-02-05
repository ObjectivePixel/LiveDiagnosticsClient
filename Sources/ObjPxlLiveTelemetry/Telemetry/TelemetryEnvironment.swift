import Foundation
import SwiftUI

private struct TelemetryLoggerKey: EnvironmentKey {
    static let defaultValue: any TelemetryLogging = NoopTelemetryLogger()
}

private struct TelemetryLifecycleKey: EnvironmentKey {
    static var defaultValue: TelemetryLifecycleService {
        preconditionFailure("TelemetryLifecycleService must be injected via .environment(\\.telemetryLifecycle, service)")
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
