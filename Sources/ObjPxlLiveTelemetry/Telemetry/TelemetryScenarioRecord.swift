import CloudKit
import Foundation

public struct TelemetryScenarioRecord: Sendable, Equatable {
    public enum Error: Swift.Error, LocalizedError, Sendable {
        case missingRecordID
        case unexpectedRecordType(String)
        case missingField(String)

        public var errorDescription: String? {
            switch self {
            case .missingRecordID:
                return "Record ID is required for update operations."
            case .unexpectedRecordType(let recordType):
                return "Expected \(TelemetrySchema.scenarioRecordType) but found \(recordType)."
            case .missingField(let field):
                return "Missing field '\(field)' on CloudKit record."
            }
        }
    }

    public static let levelOff: Int = -1

    public let recordID: CKRecord.ID?
    public let clientId: String
    public let scenarioName: String
    public var diagnosticLevel: Int
    public let created: Date
    public let sessionId: String

    /// Convenience: is this scenario actively capturing?
    public var isActive: Bool { diagnosticLevel >= 0 }

    /// Convenience: the resolved TelemetryLogLevel, or nil if off.
    public var resolvedLevel: TelemetryLogLevel? {
        TelemetryLogLevel(rawValue: diagnosticLevel)
    }

    public init(
        recordID: CKRecord.ID? = nil,
        clientId: String,
        scenarioName: String,
        diagnosticLevel: Int = Self.levelOff,
        created: Date = .now,
        sessionId: String = ""
    ) {
        self.recordID = recordID
        self.clientId = clientId
        self.scenarioName = scenarioName
        self.diagnosticLevel = diagnosticLevel
        self.created = created
        self.sessionId = sessionId
    }

    public init(record: CKRecord) throws {
        guard record.recordType == TelemetrySchema.scenarioRecordType else {
            throw Error.unexpectedRecordType(record.recordType)
        }

        guard let clientId = record[TelemetrySchema.ScenarioField.clientId.rawValue] as? String else {
            throw Error.missingField(TelemetrySchema.ScenarioField.clientId.rawValue)
        }

        guard let scenarioName = record[TelemetrySchema.ScenarioField.scenarioName.rawValue] as? String else {
            throw Error.missingField(TelemetrySchema.ScenarioField.scenarioName.rawValue)
        }

        // Read diagnosticLevel, with backward-compatible fallback from isEnabled
        let diagnosticLevel: Int
        if let level = record[TelemetrySchema.ScenarioField.diagnosticLevel.rawValue] as? NSNumber {
            diagnosticLevel = level.intValue
        } else if let legacyEnabled = record["isEnabled"] as? NSNumber {
            // Migration: isEnabled true -> info (1), false -> off (-1)
            diagnosticLevel = legacyEnabled.boolValue ? TelemetryLogLevel.info.rawValue : Self.levelOff
        } else {
            throw Error.missingField(TelemetrySchema.ScenarioField.diagnosticLevel.rawValue)
        }

        guard let created = record[TelemetrySchema.ScenarioField.created.rawValue] as? Date else {
            throw Error.missingField(TelemetrySchema.ScenarioField.created.rawValue)
        }

        // sessionId is optional for backward compatibility with existing records
        let sessionId = record[TelemetrySchema.ScenarioField.sessionId.rawValue] as? String ?? ""

        self.recordID = record.recordID
        self.clientId = clientId
        self.scenarioName = scenarioName
        self.diagnosticLevel = diagnosticLevel
        self.created = created
        self.sessionId = sessionId
    }

    public func toCKRecord() -> CKRecord {
        let record: CKRecord
        if let recordID {
            record = CKRecord(recordType: TelemetrySchema.scenarioRecordType, recordID: recordID)
        } else {
            record = CKRecord(recordType: TelemetrySchema.scenarioRecordType)
        }

        record[TelemetrySchema.ScenarioField.clientId.rawValue] = clientId as CKRecordValue
        record[TelemetrySchema.ScenarioField.scenarioName.rawValue] = scenarioName as CKRecordValue
        record[TelemetrySchema.ScenarioField.diagnosticLevel.rawValue] = diagnosticLevel as CKRecordValue
        record[TelemetrySchema.ScenarioField.created.rawValue] = created as CKRecordValue
        record[TelemetrySchema.ScenarioField.sessionId.rawValue] = sessionId as CKRecordValue

        return record
    }

    public func applying(to record: CKRecord) throws -> CKRecord {
        guard record.recordType == TelemetrySchema.scenarioRecordType else {
            throw Error.unexpectedRecordType(record.recordType)
        }

        record[TelemetrySchema.ScenarioField.clientId.rawValue] = clientId as CKRecordValue
        record[TelemetrySchema.ScenarioField.scenarioName.rawValue] = scenarioName as CKRecordValue
        record[TelemetrySchema.ScenarioField.diagnosticLevel.rawValue] = diagnosticLevel as CKRecordValue
        record[TelemetrySchema.ScenarioField.created.rawValue] = created as CKRecordValue
        record[TelemetrySchema.ScenarioField.sessionId.rawValue] = sessionId as CKRecordValue

        return record
    }
}
