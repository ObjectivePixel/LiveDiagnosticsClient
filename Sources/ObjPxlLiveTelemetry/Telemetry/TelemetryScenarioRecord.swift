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

    public let recordID: CKRecord.ID?
    public let clientId: String
    public let scenarioName: String
    public var isEnabled: Bool
    public let created: Date

    public init(
        recordID: CKRecord.ID? = nil,
        clientId: String,
        scenarioName: String,
        isEnabled: Bool,
        created: Date = .now
    ) {
        self.recordID = recordID
        self.clientId = clientId
        self.scenarioName = scenarioName
        self.isEnabled = isEnabled
        self.created = created
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

        let isEnabled: Bool
        if let storedBool = record[TelemetrySchema.ScenarioField.isEnabled.rawValue] as? NSNumber {
            isEnabled = storedBool.boolValue
        } else if let stored = record[TelemetrySchema.ScenarioField.isEnabled.rawValue] as? Bool {
            isEnabled = stored
        } else {
            throw Error.missingField(TelemetrySchema.ScenarioField.isEnabled.rawValue)
        }

        guard let created = record[TelemetrySchema.ScenarioField.created.rawValue] as? Date else {
            throw Error.missingField(TelemetrySchema.ScenarioField.created.rawValue)
        }

        self.recordID = record.recordID
        self.clientId = clientId
        self.scenarioName = scenarioName
        self.isEnabled = isEnabled
        self.created = created
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
        record[TelemetrySchema.ScenarioField.isEnabled.rawValue] = isEnabled as CKRecordValue
        record[TelemetrySchema.ScenarioField.created.rawValue] = created as CKRecordValue

        return record
    }

    public func applying(to record: CKRecord) throws -> CKRecord {
        guard record.recordType == TelemetrySchema.scenarioRecordType else {
            throw Error.unexpectedRecordType(record.recordType)
        }

        record[TelemetrySchema.ScenarioField.clientId.rawValue] = clientId as CKRecordValue
        record[TelemetrySchema.ScenarioField.scenarioName.rawValue] = scenarioName as CKRecordValue
        record[TelemetrySchema.ScenarioField.isEnabled.rawValue] = isEnabled as CKRecordValue
        record[TelemetrySchema.ScenarioField.created.rawValue] = created as CKRecordValue

        return record
    }
}
