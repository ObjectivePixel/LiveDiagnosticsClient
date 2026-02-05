import Foundation

public actor TelemetrySettingsSyncCoordinator {
    public enum RestoreState: Sendable, Equatable {
        case pending
        case restoring
        case restored(TelemetrySettings)
        case fresh
        case failed(String)

        public static func == (lhs: RestoreState, rhs: RestoreState) -> Bool {
            switch (lhs, rhs) {
            case (.pending, .pending), (.restoring, .restoring), (.fresh, .fresh):
                return true
            case (.restored(let lhsSettings), .restored(let rhsSettings)):
                return lhsSettings == rhsSettings
            case (.failed(let lhsError), .failed(let rhsError)):
                return lhsError == rhsError
            default:
                return false
            }
        }
    }

    public private(set) var state: RestoreState = .pending

    private let backupClient: CloudKitSettingsBackupClientProtocol

    public init(backupClient: CloudKitSettingsBackupClientProtocol) {
        self.backupClient = backupClient
    }

    public func restoreSettingsFromBackup() async -> RestoreState {
        state = .restoring

        do {
            if let restoredSettings = try await backupClient.loadSettings() {
                state = .restored(restoredSettings)
            } else {
                state = .fresh
            }
        } catch {
            state = .failed(error.localizedDescription)
        }

        return state
    }

    public func backupSettings(_ settings: TelemetrySettings) async throws {
        try await backupClient.saveSettings(settings)
    }

    public func clearBackup() async throws {
        try await backupClient.clearSettings()
    }
}
