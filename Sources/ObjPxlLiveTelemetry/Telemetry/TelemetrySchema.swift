import CloudKit
import Foundation

public struct TelemetrySchema: Sendable {
    public static let recordType = "TelemetryEvent"
    public static let clientRecordType = "TelemetryClient"
    public static let settingsBackupRecordType = "TelemetrySettingsBackup"

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

        public var isIndexed: Bool {
            switch self {
            case .eventName, .eventTimestamp, .sessionId, .deviceType, .deviceName, .appVersion:
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

    public static func validateSchema(in database: CKDatabase) async throws {
        try await validate(recordTypeName: recordType, in: database)
        try await validate(recordTypeName: clientRecordType, in: database)
    }

    private static func validate(recordTypeName: String, in database: CKDatabase) async throws {
        let query = CKQuery(recordType: recordTypeName, predicate: NSPredicate(value: true))
        query.sortDescriptors = []

        do {
            _ = try await database.records(matching: query, resultsLimit: 1)
        } catch let error as CKError {
            if error.code == .unknownItem {
                throw SchemaError.recordTypeNotFound(recordTypeName)
            }
            throw SchemaError.validationFailed(error, recordType: recordTypeName)
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

        return "   - No field metadata available for \(recordType)"
    }
}
