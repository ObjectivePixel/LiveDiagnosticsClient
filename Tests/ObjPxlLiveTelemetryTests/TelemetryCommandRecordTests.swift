import CloudKit
import XCTest
@testable import ObjPxlLiveTelemetry

final class TelemetryCommandRecordTests: XCTestCase {

    func testInitializationWithDefaults() {
        let command = TelemetryCommandRecord(
            clientId: "test-client",
            action: .enable
        )

        XCTAssertNil(command.recordID)
        XCTAssertFalse(command.commandId.isEmpty)
        XCTAssertEqual(command.clientId, "test-client")
        XCTAssertEqual(command.action, .enable)
        XCTAssertEqual(command.status, .pending)
        XCTAssertNil(command.executedAt)
        XCTAssertNil(command.errorMessage)
    }

    func testInitializationWithAllValues() {
        let recordID = CKRecord.ID(recordName: "test-record")
        let commandId = "custom-command-id"
        let created = Date(timeIntervalSince1970: 1000)
        let executedAt = Date(timeIntervalSince1970: 2000)

        let command = TelemetryCommandRecord(
            recordID: recordID,
            commandId: commandId,
            clientId: "test-client",
            action: .disable,
            created: created,
            status: .executed,
            executedAt: executedAt,
            errorMessage: nil
        )

        XCTAssertEqual(command.recordID, recordID)
        XCTAssertEqual(command.commandId, commandId)
        XCTAssertEqual(command.clientId, "test-client")
        XCTAssertEqual(command.action, .disable)
        XCTAssertEqual(command.created, created)
        XCTAssertEqual(command.status, .executed)
        XCTAssertEqual(command.executedAt, executedAt)
        XCTAssertNil(command.errorMessage)
    }

    func testRoundTripToCKRecord() throws {
        let original = TelemetryCommandRecord(
            commandId: "round-trip-test",
            clientId: "test-client",
            action: .deleteEvents,
            created: Date(timeIntervalSince1970: 1000),
            status: .pending
        )

        let ckRecord = original.toCKRecord()
        let restored = try TelemetryCommandRecord(record: ckRecord)

        XCTAssertEqual(restored.commandId, original.commandId)
        XCTAssertEqual(restored.clientId, original.clientId)
        XCTAssertEqual(restored.action, original.action)
        XCTAssertEqual(restored.created, original.created)
        XCTAssertEqual(restored.status, original.status)
        XCTAssertEqual(restored.executedAt, original.executedAt)
        XCTAssertEqual(restored.errorMessage, original.errorMessage)
    }

    func testRoundTripWithExecutedStatus() throws {
        let executedAt = Date(timeIntervalSince1970: 2000)
        var original = TelemetryCommandRecord(
            commandId: "executed-test",
            clientId: "test-client",
            action: .enable,
            created: Date(timeIntervalSince1970: 1000),
            status: .executed
        )
        original.executedAt = executedAt

        let ckRecord = original.toCKRecord()
        let restored = try TelemetryCommandRecord(record: ckRecord)

        XCTAssertEqual(restored.status, .executed)
        XCTAssertEqual(restored.executedAt, executedAt)
    }

    func testRoundTripWithFailedStatus() throws {
        let executedAt = Date(timeIntervalSince1970: 2000)
        var original = TelemetryCommandRecord(
            commandId: "failed-test",
            clientId: "test-client",
            action: .disable,
            created: Date(timeIntervalSince1970: 1000),
            status: .failed
        )
        original.executedAt = executedAt
        original.errorMessage = "Something went wrong"

        let ckRecord = original.toCKRecord()
        let restored = try TelemetryCommandRecord(record: ckRecord)

        XCTAssertEqual(restored.status, .failed)
        XCTAssertEqual(restored.executedAt, executedAt)
        XCTAssertEqual(restored.errorMessage, "Something went wrong")
    }

    func testInvalidActionThrows() {
        let record = CKRecord(recordType: TelemetrySchema.commandRecordType)
        record[TelemetrySchema.CommandField.commandId.rawValue] = "test-id"
        record[TelemetrySchema.CommandField.clientId.rawValue] = "test-client"
        record[TelemetrySchema.CommandField.action.rawValue] = "invalid_action"
        record[TelemetrySchema.CommandField.created.rawValue] = Date()
        record[TelemetrySchema.CommandField.status.rawValue] = "pending"

        XCTAssertThrowsError(try TelemetryCommandRecord(record: record)) { error in
            guard case TelemetryCommandRecord.Error.invalidAction(let action) = error else {
                XCTFail("Expected invalidAction error, got \(error)")
                return
            }
            XCTAssertEqual(action, "invalid_action")
        }
    }

    func testInvalidStatusThrows() {
        let record = CKRecord(recordType: TelemetrySchema.commandRecordType)
        record[TelemetrySchema.CommandField.commandId.rawValue] = "test-id"
        record[TelemetrySchema.CommandField.clientId.rawValue] = "test-client"
        record[TelemetrySchema.CommandField.action.rawValue] = "enable"
        record[TelemetrySchema.CommandField.created.rawValue] = Date()
        record[TelemetrySchema.CommandField.status.rawValue] = "invalid_status"

        XCTAssertThrowsError(try TelemetryCommandRecord(record: record)) { error in
            guard case TelemetryCommandRecord.Error.invalidStatus(let status) = error else {
                XCTFail("Expected invalidStatus error, got \(error)")
                return
            }
            XCTAssertEqual(status, "invalid_status")
        }
    }

    func testMissingCommandIdThrows() {
        let record = CKRecord(recordType: TelemetrySchema.commandRecordType)
        record[TelemetrySchema.CommandField.clientId.rawValue] = "test-client"
        record[TelemetrySchema.CommandField.action.rawValue] = "enable"
        record[TelemetrySchema.CommandField.created.rawValue] = Date()
        record[TelemetrySchema.CommandField.status.rawValue] = "pending"

        XCTAssertThrowsError(try TelemetryCommandRecord(record: record)) { error in
            guard case TelemetryCommandRecord.Error.missingField(let field) = error else {
                XCTFail("Expected missingField error, got \(error)")
                return
            }
            XCTAssertEqual(field, TelemetrySchema.CommandField.commandId.rawValue)
        }
    }

    func testMissingClientIdThrows() {
        let record = CKRecord(recordType: TelemetrySchema.commandRecordType)
        record[TelemetrySchema.CommandField.commandId.rawValue] = "test-id"
        record[TelemetrySchema.CommandField.action.rawValue] = "enable"
        record[TelemetrySchema.CommandField.created.rawValue] = Date()
        record[TelemetrySchema.CommandField.status.rawValue] = "pending"

        XCTAssertThrowsError(try TelemetryCommandRecord(record: record)) { error in
            guard case TelemetryCommandRecord.Error.missingField(let field) = error else {
                XCTFail("Expected missingField error, got \(error)")
                return
            }
            XCTAssertEqual(field, TelemetrySchema.CommandField.clientId.rawValue)
        }
    }

    func testMissingActionThrows() {
        let record = CKRecord(recordType: TelemetrySchema.commandRecordType)
        record[TelemetrySchema.CommandField.commandId.rawValue] = "test-id"
        record[TelemetrySchema.CommandField.clientId.rawValue] = "test-client"
        record[TelemetrySchema.CommandField.created.rawValue] = Date()
        record[TelemetrySchema.CommandField.status.rawValue] = "pending"

        XCTAssertThrowsError(try TelemetryCommandRecord(record: record)) { error in
            guard case TelemetryCommandRecord.Error.missingField(let field) = error else {
                XCTFail("Expected missingField error, got \(error)")
                return
            }
            XCTAssertEqual(field, TelemetrySchema.CommandField.action.rawValue)
        }
    }

    func testMissingCreatedThrows() {
        let record = CKRecord(recordType: TelemetrySchema.commandRecordType)
        record[TelemetrySchema.CommandField.commandId.rawValue] = "test-id"
        record[TelemetrySchema.CommandField.clientId.rawValue] = "test-client"
        record[TelemetrySchema.CommandField.action.rawValue] = "enable"
        record[TelemetrySchema.CommandField.status.rawValue] = "pending"

        XCTAssertThrowsError(try TelemetryCommandRecord(record: record)) { error in
            guard case TelemetryCommandRecord.Error.missingField(let field) = error else {
                XCTFail("Expected missingField error, got \(error)")
                return
            }
            XCTAssertEqual(field, TelemetrySchema.CommandField.created.rawValue)
        }
    }

    func testMissingStatusThrows() {
        let record = CKRecord(recordType: TelemetrySchema.commandRecordType)
        record[TelemetrySchema.CommandField.commandId.rawValue] = "test-id"
        record[TelemetrySchema.CommandField.clientId.rawValue] = "test-client"
        record[TelemetrySchema.CommandField.action.rawValue] = "enable"
        record[TelemetrySchema.CommandField.created.rawValue] = Date()

        XCTAssertThrowsError(try TelemetryCommandRecord(record: record)) { error in
            guard case TelemetryCommandRecord.Error.missingField(let field) = error else {
                XCTFail("Expected missingField error, got \(error)")
                return
            }
            XCTAssertEqual(field, TelemetrySchema.CommandField.status.rawValue)
        }
    }

    func testUnexpectedRecordTypeThrows() {
        let record = CKRecord(recordType: "WrongRecordType")

        XCTAssertThrowsError(try TelemetryCommandRecord(record: record)) { error in
            guard case TelemetryCommandRecord.Error.unexpectedRecordType(let recordType) = error else {
                XCTFail("Expected unexpectedRecordType error, got \(error)")
                return
            }
            XCTAssertEqual(recordType, "WrongRecordType")
        }
    }

    func testApplyingToRecordWithWrongTypeThrows() throws {
        let command = TelemetryCommandRecord(
            clientId: "test-client",
            action: .enable
        )
        let wrongRecord = CKRecord(recordType: "WrongRecordType")

        XCTAssertThrowsError(try command.applying(to: wrongRecord)) { error in
            guard case TelemetryCommandRecord.Error.unexpectedRecordType(let recordType) = error else {
                XCTFail("Expected unexpectedRecordType error, got \(error)")
                return
            }
            XCTAssertEqual(recordType, "WrongRecordType")
        }
    }

    func testApplyingToRecord() throws {
        let command = TelemetryCommandRecord(
            commandId: "apply-test",
            clientId: "test-client",
            action: .deleteEvents,
            status: .executed
        )
        let existingRecord = CKRecord(recordType: TelemetrySchema.commandRecordType)

        let updatedRecord = try command.applying(to: existingRecord)

        XCTAssertEqual(updatedRecord[TelemetrySchema.CommandField.commandId.rawValue] as? String, "apply-test")
        XCTAssertEqual(updatedRecord[TelemetrySchema.CommandField.clientId.rawValue] as? String, "test-client")
        XCTAssertEqual(updatedRecord[TelemetrySchema.CommandField.action.rawValue] as? String, "delete_events")
        XCTAssertEqual(updatedRecord[TelemetrySchema.CommandField.status.rawValue] as? String, "executed")
    }

    func testEquatable() {
        let recordID = CKRecord.ID(recordName: "test-record")
        let created = Date(timeIntervalSince1970: 1000)

        let command1 = TelemetryCommandRecord(
            recordID: recordID,
            commandId: "test-id",
            clientId: "test-client",
            action: .enable,
            created: created,
            status: .pending
        )

        let command2 = TelemetryCommandRecord(
            recordID: recordID,
            commandId: "test-id",
            clientId: "test-client",
            action: .enable,
            created: created,
            status: .pending
        )

        let command3 = TelemetryCommandRecord(
            recordID: recordID,
            commandId: "different-id",
            clientId: "test-client",
            action: .enable,
            created: created,
            status: .pending
        )

        XCTAssertEqual(command1, command2)
        XCTAssertNotEqual(command1, command3)
    }

    // MARK: - Scenario Command Tests

    func testEnableScenarioActionRawValue() {
        XCTAssertEqual(TelemetrySchema.CommandAction.enableScenario.rawValue, "enableScenario")
        XCTAssertEqual(TelemetrySchema.CommandAction.disableScenario.rawValue, "disableScenario")
    }

    func testInitWithScenarioName() {
        let command = TelemetryCommandRecord(
            clientId: "test-client",
            action: .enableScenario,
            scenarioName: "NetworkRequests"
        )

        XCTAssertEqual(command.action, .enableScenario)
        XCTAssertEqual(command.scenarioName, "NetworkRequests")
    }

    func testInitWithoutScenarioName() {
        let command = TelemetryCommandRecord(
            clientId: "test-client",
            action: .enable
        )

        XCTAssertNil(command.scenarioName, "scenarioName should be nil for non-scenario commands")
    }

    func testRoundTripWithScenarioName() throws {
        let original = TelemetryCommandRecord(
            commandId: "scenario-roundtrip",
            clientId: "test-client",
            action: .enableScenario,
            scenarioName: "DataSync",
            created: Date(timeIntervalSince1970: 1000),
            status: .pending
        )

        let ckRecord = original.toCKRecord()
        let restored = try TelemetryCommandRecord(record: ckRecord)

        XCTAssertEqual(restored.action, .enableScenario)
        XCTAssertEqual(restored.scenarioName, "DataSync")
    }

    func testRoundTripWithoutScenarioName() throws {
        let original = TelemetryCommandRecord(
            commandId: "no-scenario",
            clientId: "test-client",
            action: .enable,
            created: Date(timeIntervalSince1970: 1000),
            status: .pending
        )

        let ckRecord = original.toCKRecord()
        let restored = try TelemetryCommandRecord(record: ckRecord)

        XCTAssertNil(restored.scenarioName)
    }

    func testAllCommandActions() {
        for action in TelemetrySchema.CommandAction.allCases {
            let command = TelemetryCommandRecord(
                clientId: "test-client",
                action: action
            )
            XCTAssertEqual(command.action, action)

            let ckRecord = command.toCKRecord()
            XCTAssertEqual(ckRecord[TelemetrySchema.CommandField.action.rawValue] as? String, action.rawValue)
        }
    }

    func testAllCommandStatuses() throws {
        for status in TelemetrySchema.CommandStatus.allCases {
            let command = TelemetryCommandRecord(
                clientId: "test-client",
                action: .enable,
                status: status
            )
            XCTAssertEqual(command.status, status)

            let ckRecord = command.toCKRecord()
            let restored = try TelemetryCommandRecord(record: ckRecord)
            XCTAssertEqual(restored.status, status)
        }
    }
}
