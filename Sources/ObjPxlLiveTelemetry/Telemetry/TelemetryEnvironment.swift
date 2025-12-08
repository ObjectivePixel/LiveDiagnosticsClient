import Foundation
import SwiftUI

private struct TelemetryLoggerKey: EnvironmentKey {
    static let defaultValue: any TelemetryLogging = NoopTelemetryLogger.shared
}

extension EnvironmentValues {
    public var telemetryLogger: any TelemetryLogging {
        get { self[TelemetryLoggerKey.self] }
        set { self[TelemetryLoggerKey.self] = newValue }
    }
}

public actor NoopTelemetryLogger: TelemetryLogging {
    public static let shared = NoopTelemetryLogger()

    private init() {}

    nonisolated public func logEvent(
        name: String,
        property1: String? = nil
    ) {}

    public func flush() async {}

    public func shutdown() async {}
}

public enum TelemetryBootstrap {
    public static func makeLogger(
        distribution: Distribution,
        containerIdentifier: String? = nil,
        configuration: TelemetryLogger.Configuration = .default
    ) -> any TelemetryLogging {
        guard distribution.isDebug else { return NoopTelemetryLogger.shared }
        let client = CloudKitClient(containerIdentifier: containerIdentifier)
        return TelemetryLogger(configuration: configuration, client: client)
    }
}

public enum Distribution: String, Sendable {
    case debug
    case release

    public var isDebug: Bool { self == .debug }
}
