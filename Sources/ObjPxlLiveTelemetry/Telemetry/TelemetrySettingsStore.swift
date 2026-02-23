import Foundation

public struct TelemetrySettings: Equatable, Sendable {
    public var telemetryRequested: Bool
    public var telemetrySendingEnabled: Bool
    public var clientIdentifier: String?
    public var forceOnActive: Bool

    public init(
        telemetryRequested: Bool = false,
        telemetrySendingEnabled: Bool = false,
        clientIdentifier: String? = nil,
        forceOnActive: Bool = false
    ) {
        self.telemetryRequested = telemetryRequested
        self.telemetrySendingEnabled = telemetrySendingEnabled
        self.clientIdentifier = clientIdentifier
        self.forceOnActive = forceOnActive
    }

    public static let defaults = TelemetrySettings()
}

public protocol TelemetrySettingsStoring: Sendable {
    func load() async -> TelemetrySettings
    @discardableResult func save(_ settings: TelemetrySettings) async -> TelemetrySettings
    @discardableResult func update(_ transform: (inout TelemetrySettings) -> Void) async -> TelemetrySettings
    @discardableResult func reset() async -> TelemetrySettings
}

public actor UserDefaultsTelemetrySettingsStore: TelemetrySettingsStoring {
    private enum Key {
        static let telemetryRequested = "telemetryRequested"
        static let telemetrySendingEnabled = "telemetrySendingEnabled"
        static let clientIdentifier = "clientIdentifier"
        static let forceOnActive = "forceOnActive"
    }

    private let defaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
    }

    public func load() async -> TelemetrySettings {
        TelemetrySettings(
            telemetryRequested: defaults.bool(forKey: Key.telemetryRequested),
            telemetrySendingEnabled: defaults.bool(forKey: Key.telemetrySendingEnabled),
            clientIdentifier: defaults.string(forKey: Key.clientIdentifier),
            forceOnActive: defaults.bool(forKey: Key.forceOnActive)
        )
    }

    @discardableResult
    public func save(_ settings: TelemetrySettings) async -> TelemetrySettings {
        defaults.set(settings.telemetryRequested, forKey: Key.telemetryRequested)
        defaults.set(settings.telemetrySendingEnabled, forKey: Key.telemetrySendingEnabled)
        defaults.set(settings.clientIdentifier, forKey: Key.clientIdentifier)
        defaults.set(settings.forceOnActive, forKey: Key.forceOnActive)
        return settings
    }

    @discardableResult
    public func update(_ transform: (inout TelemetrySettings) -> Void) async -> TelemetrySettings {
        var settings = await load()
        transform(&settings)
        return await save(settings)
    }

    @discardableResult
    public func reset() async -> TelemetrySettings {
        defaults.removeObject(forKey: Key.telemetryRequested)
        defaults.removeObject(forKey: Key.telemetrySendingEnabled)
        defaults.removeObject(forKey: Key.clientIdentifier)
        defaults.removeObject(forKey: Key.forceOnActive)
        return await save(.defaults)
    }
}
