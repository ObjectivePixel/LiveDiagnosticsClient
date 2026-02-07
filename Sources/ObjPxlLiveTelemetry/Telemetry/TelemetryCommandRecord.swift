import CloudKit
import Foundation

public struct TelemetryCommandRecord: Sendable, Equatable {
    public enum Error: Swift.Error, LocalizedError, Sendable {
        case missingRecordID
        case unexpectedRecordType(String)
        case missingField(String)
        case invalidAction(String)
        case invalidStatus(String)

        public var errorDescription: String? {
            switch self {
            case .missingRecordID:
                return "Record ID is required for update operations."
            case .unexpectedRecordType(let recordType):
                return "Expected \(TelemetrySchema.commandRecordType) but found \(recordType)."
            case .missingField(let field):
                return "Missing field '\(field)' on CloudKit record."
            case .invalidAction(let action):
                return "Invalid command action '\(action)'."
            case .invalidStatus(let status):
                return "Invalid command status '\(status)'."
            }
        }
    }

    public let recordID: CKRecord.ID?
    public let commandId: String
    public let clientId: String
    public let action: TelemetrySchema.CommandAction
    public let created: Date
    public var status: TelemetrySchema.CommandStatus
    public var executedAt: Date?
    public var errorMessage: String?

    public init(
        recordID: CKRecord.ID? = nil,
        commandId: String = UUID().uuidString,
        clientId: String,
        action: TelemetrySchema.CommandAction,
        created: Date = .now,
        status: TelemetrySchema.CommandStatus = .pending,
        executedAt: Date? = nil,
        errorMessage: String? = nil
    ) {
        self.recordID = recordID
        self.commandId = commandId
        self.clientId = clientId
        self.action = action
        self.created = created
        self.status = status
        self.executedAt = executedAt
        self.errorMessage = errorMessage
    }

    public init(record: CKRecord) throws {
        guard record.recordType == TelemetrySchema.commandRecordType else {
            throw Error.unexpectedRecordType(record.recordType)
        }

        guard let commandId = record[TelemetrySchema.CommandField.commandId.rawValue] as? String else {
            throw Error.missingField(TelemetrySchema.CommandField.commandId.rawValue)
        }

        guard let clientId = record[TelemetrySchema.CommandField.clientId.rawValue] as? String else {
            throw Error.missingField(TelemetrySchema.CommandField.clientId.rawValue)
        }

        guard let actionString = record[TelemetrySchema.CommandField.action.rawValue] as? String else {
            throw Error.missingField(TelemetrySchema.CommandField.action.rawValue)
        }

        guard let action = TelemetrySchema.CommandAction(rawValue: actionString) else {
            throw Error.invalidAction(actionString)
        }

        guard let created = record[TelemetrySchema.CommandField.created.rawValue] as? Date else {
            throw Error.missingField(TelemetrySchema.CommandField.created.rawValue)
        }

        guard let statusString = record[TelemetrySchema.CommandField.status.rawValue] as? String else {
            throw Error.missingField(TelemetrySchema.CommandField.status.rawValue)
        }

        guard let status = TelemetrySchema.CommandStatus(rawValue: statusString) else {
            throw Error.invalidStatus(statusString)
        }

        self.recordID = record.recordID
        self.commandId = commandId
        self.clientId = clientId
        self.action = action
        self.created = created
        self.status = status
        self.executedAt = record[TelemetrySchema.CommandField.executedAt.rawValue] as? Date
        self.errorMessage = record[TelemetrySchema.CommandField.errorMessage.rawValue] as? String
    }

    public func toCKRecord() -> CKRecord {
        let record: CKRecord
        if let recordID {
            record = CKRecord(recordType: TelemetrySchema.commandRecordType, recordID: recordID)
        } else {
            record = CKRecord(recordType: TelemetrySchema.commandRecordType)
        }

        record[TelemetrySchema.CommandField.commandId.rawValue] = commandId as CKRecordValue
        record[TelemetrySchema.CommandField.clientId.rawValue] = clientId as CKRecordValue
        record[TelemetrySchema.CommandField.action.rawValue] = action.rawValue as CKRecordValue
        record[TelemetrySchema.CommandField.created.rawValue] = created as CKRecordValue
        record[TelemetrySchema.CommandField.status.rawValue] = status.rawValue as CKRecordValue
        record[TelemetrySchema.CommandField.executedAt.rawValue] = executedAt as CKRecordValue?
        record[TelemetrySchema.CommandField.errorMessage.rawValue] = errorMessage as CKRecordValue?

        return record
    }

    public func applying(to record: CKRecord) throws -> CKRecord {
        guard record.recordType == TelemetrySchema.commandRecordType else {
            throw Error.unexpectedRecordType(record.recordType)
        }

        record[TelemetrySchema.CommandField.commandId.rawValue] = commandId as CKRecordValue
        record[TelemetrySchema.CommandField.clientId.rawValue] = clientId as CKRecordValue
        record[TelemetrySchema.CommandField.action.rawValue] = action.rawValue as CKRecordValue
        record[TelemetrySchema.CommandField.created.rawValue] = created as CKRecordValue
        record[TelemetrySchema.CommandField.status.rawValue] = status.rawValue as CKRecordValue
        record[TelemetrySchema.CommandField.executedAt.rawValue] = executedAt as CKRecordValue?
        record[TelemetrySchema.CommandField.errorMessage.rawValue] = errorMessage as CKRecordValue?

        return record
    }
}
