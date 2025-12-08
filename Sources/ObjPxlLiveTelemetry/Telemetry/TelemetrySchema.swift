import CloudKit
import Foundation

struct TelemetrySchema: Sendable {
    static let recordType = "TelemetryEvent"

    enum Field: String, CaseIterable {
        case eventId
        case eventName
        case eventTimestamp
        case deviceType
        case deviceName
        case deviceModel
        case osVersion
        case appVersion
        case threadId
        case property1

        var isIndexed: Bool {
            switch self {
            case .eventName, .eventTimestamp, .deviceType, .deviceName, .appVersion:
                return true
            default:
                return false
            }
        }
    }

    static func validateSchema(in database: CKDatabase) async throws {
        // Query with a true predicate to validate the record type exists; CloudKit rejects NSFalsePredicate
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        query.sortDescriptors = []

        do {
            _ = try await database.records(matching: query)
        } catch let error as CKError {
            if error.code == .unknownItem {
                throw SchemaError.recordTypeNotFound
            }
            throw SchemaError.validationFailed(error)
        }
    }

    enum SchemaError: Error, CustomStringConvertible {
        case recordTypeNotFound
        case validationFailed(Error)

        var description: String {
            switch self {
            case .recordTypeNotFound:
                return """
                CloudKit schema not found. Please create the '\(recordType)' record type in CloudKit Dashboard.

                Setup Instructions:
                1. Go to: https://icloud.developer.apple.com/
                2. Select your container
                3. Go to Schema → Record Types → Development
                4. Click "+" to create a new Record Type
                5. Name it: \(recordType)
                6. Add these fields:

                \(Field.allCases.map { "   - \($0.rawValue) (String)\($0.isIndexed ? " ✓ Queryable" : "")" }.joined(separator: "\n"))

                Note: eventTimestamp should be Date/Time type, rest are String

                7. Click "Save"
                8. Deploy to Production when ready
                """
            case .validationFailed(let error):
                return "Schema validation failed: \(error.localizedDescription)"
            }
        }
    }
}
