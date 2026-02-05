import CloudKit
import Foundation

public protocol CloudKitSettingsBackupClientProtocol: Sendable {
    func saveSettings(_ settings: TelemetrySettings) async throws
    func loadSettings() async throws -> TelemetrySettings?
    func clearSettings() async throws
}

public struct CloudKitSettingsBackupClient: CloudKitSettingsBackupClientProtocol {
    private let container: CKContainer
    private let database: CKDatabase
    private static let recordType = TelemetrySchema.settingsBackupRecordType
    private static let fixedRecordName = "TelemetrySettingsBackup"

    public init(containerIdentifier: String) {
        let resolvedContainer = CKContainer(identifier: containerIdentifier)
        self.container = resolvedContainer
        self.database = resolvedContainer.privateCloudDatabase
    }

    public func saveSettings(_ settings: TelemetrySettings) async throws {
        let recordID = CKRecord.ID(recordName: Self.fixedRecordName)

        let record: CKRecord
        do {
            record = try await database.record(for: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            record = CKRecord(recordType: Self.recordType, recordID: recordID)
        }

        record[TelemetrySchema.SettingsBackupField.telemetryRequested.rawValue] = settings.telemetryRequested
        record[TelemetrySchema.SettingsBackupField.telemetrySendingEnabled.rawValue] = settings.telemetrySendingEnabled
        record[TelemetrySchema.SettingsBackupField.clientIdentifier.rawValue] = settings.clientIdentifier
        record[TelemetrySchema.SettingsBackupField.lastUpdated.rawValue] = Date()

        _ = try await database.save(record)
    }

    public func loadSettings() async throws -> TelemetrySettings? {
        let recordID = CKRecord.ID(recordName: Self.fixedRecordName)

        do {
            let record = try await database.record(for: recordID)

            let telemetryRequested = record[TelemetrySchema.SettingsBackupField.telemetryRequested.rawValue] as? Bool ?? false
            let telemetrySendingEnabled = record[TelemetrySchema.SettingsBackupField.telemetrySendingEnabled.rawValue] as? Bool ?? false
            let clientIdentifier = record[TelemetrySchema.SettingsBackupField.clientIdentifier.rawValue] as? String

            return TelemetrySettings(
                telemetryRequested: telemetryRequested,
                telemetrySendingEnabled: telemetrySendingEnabled,
                clientIdentifier: clientIdentifier
            )
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    public func clearSettings() async throws {
        let recordID = CKRecord.ID(recordName: Self.fixedRecordName)

        do {
            _ = try await database.deleteRecord(withID: recordID)
        } catch let error as CKError where error.code == .unknownItem {
            // Record doesn't exist, nothing to delete
        }
    }
}
