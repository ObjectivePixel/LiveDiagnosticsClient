import Foundation

public protocol TelemetryScenarioStoring: Sendable {
    func loadState(for scenarioName: String) async -> Bool?
    func loadAllStates() async -> [String: Bool]
    func saveState(for scenarioName: String, isEnabled: Bool) async
    func removeState(for scenarioName: String) async
    func removeAllStates() async
}

public actor UserDefaultsTelemetryScenarioStore: TelemetryScenarioStoring {
    static let keyPrefix = "telemetry.scenario."
    static let keySuffix = ".isEnabled"
    static let registryKey = "telemetry.scenario.registry"

    private let defaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
    }

    public func loadState(for scenarioName: String) async -> Bool? {
        let key = Self.key(for: scenarioName)
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.bool(forKey: key)
    }

    public func loadAllStates() async -> [String: Bool] {
        let names = defaults.stringArray(forKey: Self.registryKey) ?? []
        var states: [String: Bool] = [:]
        for name in names {
            let key = Self.key(for: name)
            if defaults.object(forKey: key) != nil {
                states[name] = defaults.bool(forKey: key)
            }
        }
        return states
    }

    public func saveState(for scenarioName: String, isEnabled: Bool) async {
        defaults.set(isEnabled, forKey: Self.key(for: scenarioName))
        addToRegistry(scenarioName)
    }

    public func removeState(for scenarioName: String) async {
        defaults.removeObject(forKey: Self.key(for: scenarioName))
        removeFromRegistry(scenarioName)
    }

    public func removeAllStates() async {
        let names = defaults.stringArray(forKey: Self.registryKey) ?? []
        for name in names {
            defaults.removeObject(forKey: Self.key(for: name))
        }
        defaults.removeObject(forKey: Self.registryKey)
    }

    private static func key(for scenarioName: String) -> String {
        "\(keyPrefix)\(scenarioName)\(keySuffix)"
    }

    private func addToRegistry(_ scenarioName: String) {
        var names = defaults.stringArray(forKey: Self.registryKey) ?? []
        if !names.contains(scenarioName) {
            names.append(scenarioName)
            defaults.set(names, forKey: Self.registryKey)
        }
    }

    private func removeFromRegistry(_ scenarioName: String) {
        var names = defaults.stringArray(forKey: Self.registryKey) ?? []
        names.removeAll { $0 == scenarioName }
        defaults.set(names, forKey: Self.registryKey)
    }
}
