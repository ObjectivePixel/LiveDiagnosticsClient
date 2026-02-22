import Foundation

public protocol TelemetryScenarioStoring: Sendable {
    func loadLevel(for scenarioName: String) async -> Int?
    func loadAllLevels() async -> [String: Int]
    func saveLevel(for scenarioName: String, diagnosticLevel: Int) async
    func removeState(for scenarioName: String) async
    func removeAllStates() async
}

public actor UserDefaultsTelemetryScenarioStore: TelemetryScenarioStoring {
    static let keyPrefix = "telemetry.scenario."
    static let keySuffix = ".diagnosticLevel"
    static let registryKey = "telemetry.scenario.registry"

    private let defaults: UserDefaults

    public init(userDefaults: UserDefaults = .standard) {
        self.defaults = userDefaults
    }

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
