import CloudKit
import Foundation

public struct TelemetrySchema: Sendable {
    public static let recordType = "TelemetryEvent"
    public static let clientRecordType = "TelemetryClient"
    public static let settingsBackupRecordType = "TelemetrySettingsBackup"
    public static let commandRecordType = "TelemetryCommand"
    public static let scenarioRecordType = "TelemetryScenario"

    public enum Field: String, CaseIterable {
        case eventId
        case eventName
        case eventTimestamp
        case sessionId
        case deviceType
        case deviceName
        case deviceModel
        case osVersion
        case appVersion
        case threadId
        case property1
        case scenario
        case logLevel

        public var isIndexed: Bool {
            switch self {
            case .eventName, .eventTimestamp, .sessionId, .deviceType, .deviceName, .appVersion, .scenario, .logLevel:
                return true
            default:
                return false
            }
        }

        var fieldTypeDescription: String {
            switch self {
            case .eventTimestamp:
                return "Date/Time"
            default:
                return "String"
            }
        }
    }

    public enum ClientField: String, CaseIterable {
        case clientId = "clientid"
        case created
        case isEnabled

        public var isIndexed: Bool {
            switch self {
            case .clientId, .created, .isEnabled:
                return true
            }
        }

        public var fieldTypeDescription: String {
            switch self {
            case .clientId:
                return "String"
            case .created:
                return "Date/Time"
            case .isEnabled:
                return "Boolean"
            }
        }
    }

    public enum SettingsBackupField: String, CaseIterable {
        case telemetryRequested
        case telemetrySendingEnabled
        case clientIdentifier
        case lastUpdated

        public var fieldTypeDescription: String {
            switch self {
            case .telemetryRequested, .telemetrySendingEnabled:
                return "Boolean"
            case .clientIdentifier:
                return "String"
            case .lastUpdated:
                return "Date/Time"
            }
        }
    }

    public enum CommandField: String, CaseIterable {
        case commandId
        case clientId = "clientid"
        case action
        case created
        case status
        case executedAt
        case errorMessage
        case scenarioName

        public var isIndexed: Bool {
            switch self {
            case .commandId, .clientId, .created, .status:
                return true
            case .action, .executedAt, .errorMessage, .scenarioName:
                return false
            }
        }

        public var fieldTypeDescription: String {
            switch self {
            case .commandId, .clientId, .action, .status, .errorMessage, .scenarioName:
                return "String"
            case .created, .executedAt:
                return "Date/Time"
            }
        }
    }

    public enum ScenarioField: String, CaseIterable {
        case clientId = "clientid"
        case scenarioName
        case isEnabled
        case created

        public var isIndexed: Bool {
            switch self {
            case .clientId, .scenarioName, .isEnabled, .created:
                return true
            }
        }

        public var fieldTypeDescription: String {
            switch self {
            case .clientId, .scenarioName:
                return "String"
            case .isEnabled:
                return "Int64 (0/1)"
            case .created:
                return "Date/Time"
            }
        }
    }

    public enum CommandAction: String, Sendable, CaseIterable {
        case enable
        case disable
        case deleteEvents = "delete_events"
        case enableScenario
        case disableScenario
    }

    public enum CommandStatus: String, Sendable, CaseIterable {
        case pending
        case executed
        case failed
    }

    public static func validateSchema(in database: CKDatabase) async throws {
        print("📋 [Schema] Validating schema in database: \(database.databaseScope.rawValue == 1 ? "public" : database.databaseScope.rawValue == 2 ? "private" : "shared")")
        try await validate(recordTypeName: recordType, in: database)
        try await validate(recordTypeName: clientRecordType, in: database)
        try await validate(recordTypeName: commandRecordType, in: database)
        try await validate(recordTypeName: scenarioRecordType, in: database)
        print("📋 [Schema] All record types validated successfully")
    }

    private static func validate(recordTypeName: String, in database: CKDatabase) async throws {
        print("📋 [Schema] Checking record type: \(recordTypeName)")
        let query = CKQuery(recordType: recordTypeName, predicate: NSPredicate(value: true))
        query.sortDescriptors = []

        do {
            let (results, _) = try await database.records(matching: query, resultsLimit: 1)
            print("📋 [Schema] ✅ \(recordTypeName) exists (found \(results.count) record(s))")
        } catch let error as CKError {
            print("📋 [Schema] ❌ \(recordTypeName) check failed - CKError code: \(error.code.rawValue) (\(error.code))")
            if error.code == .unknownItem {
                throw SchemaError.recordTypeNotFound(recordTypeName)
            }
            throw SchemaError.validationFailed(error, recordType: recordTypeName)
        } catch {
            print("📋 [Schema] ❌ \(recordTypeName) check failed with non-CK error: \(error)")
            throw error
        }
    }

    public enum SchemaError: Error, CustomStringConvertible {
        case recordTypeNotFound(String)
        case validationFailed(Error, recordType: String)

        public var description: String {
            switch self {
            case .recordTypeNotFound(let recordType):
                return TelemetrySchema.schemaInstruction(for: recordType, reason: "CloudKit schema not found.")
            case .validationFailed(let error, let recordType):
                return TelemetrySchema.schemaInstruction(for: recordType, reason: "Schema validation failed: \(error.localizedDescription)")
            }
        }
    }

    private static func schemaInstruction(for recordType: String, reason: String) -> String {
        """
        \(reason) Please create the '\(recordType)' record type in CloudKit Dashboard.

        Setup Instructions:
        1. Go to: https://icloud.developer.apple.com/
        2. Select your container
        3. Go to Schema → Record Types → Development
        4. Click "+" to create a new Record Type
        5. Name it: \(recordType)
        6. Add these fields:

        \(fields(for: recordType))

        7. Click "Save"
        8. Deploy to Production when ready
        """
    }

    private static func fields(for recordType: String) -> String {
        if recordType == Self.recordType {
            return Field.allCases
                .map { "   - \($0.rawValue) (\($0.fieldTypeDescription))\($0.isIndexed ? " ✓ Queryable" : "")" }
                .joined(separator: "\n")
        }

        if recordType == Self.clientRecordType {
            return ClientField.allCases
                .map { "   - \($0.rawValue) (\($0.fieldTypeDescription))\($0.isIndexed ? " ✓ Queryable" : "")" }
                .joined(separator: "\n")
        }

        if recordType == Self.commandRecordType {
            return CommandField.allCases
                .map { "   - \($0.rawValue) (\($0.fieldTypeDescription))\($0.isIndexed ? " ✓ Queryable" : "")" }
                .joined(separator: "\n")
        }

        if recordType == Self.scenarioRecordType {
            return ScenarioField.allCases
                .map { "   - \($0.rawValue) (\($0.fieldTypeDescription))\($0.isIndexed ? " ✓ Queryable" : "")" }
                .joined(separator: "\n")
        }

        return "   - No field metadata available for \(recordType)"
    }
}
