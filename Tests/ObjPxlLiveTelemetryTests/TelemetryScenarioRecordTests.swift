import CloudKit
import XCTest
@testable import ObjPxlLiveTelemetry

final class TelemetryScenarioRecordTests: XCTestCase {

    func testInitWithAllFields() {
        let recordID = CKRecord.ID(recordName: "test-record")
        let created = Date(timeIntervalSince1970: 1000)
        let record = TelemetryScenarioRecord(
            recordID: recordID,
            clientId: "client-1",
            scenarioName: "NetworkRequests",
            diagnosticLevel: TelemetryLogLevel.info.rawValue,
            created: created
        )

        XCTAssertEqual(record.recordID, recordID)
        XCTAssertEqual(record.clientId, "client-1")
        XCTAssertEqual(record.scenarioName, "NetworkRequests")
        XCTAssertEqual(record.diagnosticLevel, TelemetryLogLevel.info.rawValue)
        XCTAssertTrue(record.isActive)
        XCTAssertEqual(record.resolvedLevel, .info)
        XCTAssertEqual(record.created, created)
    }

    func testInitWithDefaults() {
        let record = TelemetryScenarioRecord(
            clientId: "client-2",
            scenarioName: "DataSync"
        )

        XCTAssertNil(record.recordID)
        XCTAssertEqual(record.clientId, "client-2")
        XCTAssertEqual(record.scenarioName, "DataSync")
        XCTAssertEqual(record.diagnosticLevel, TelemetryScenarioRecord.levelOff)
        XCTAssertFalse(record.isActive)
        XCTAssertNil(record.resolvedLevel)
        // created should be auto-set to now
        XCTAssertTrue(record.created.timeIntervalSinceNow < 1)
    }

    func testRoundTripToCKRecord() throws {
        let original = TelemetryScenarioRecord(
            clientId: "client-3",
            scenarioName: "UserInteraction",
            diagnosticLevel: TelemetryLogLevel.debug.rawValue,
            created: Date(timeIntervalSince1970: 2000)
        )

        let ckRecord = original.toCKRecord()
        XCTAssertEqual(ckRecord.recordType, TelemetrySchema.scenarioRecordType)

        let restored = try TelemetryScenarioRecord(record: ckRecord)
        XCTAssertEqual(restored.clientId, original.clientId)
        XCTAssertEqual(restored.scenarioName, original.scenarioName)
        XCTAssertEqual(restored.diagnosticLevel, original.diagnosticLevel)
        XCTAssertEqual(restored.created.timeIntervalSince1970, original.created.timeIntervalSince1970, accuracy: 1)
    }

    func testRoundTripDisabled() throws {
        let original = TelemetryScenarioRecord(
            clientId: "client-4",
            scenarioName: "Logging",
            diagnosticLevel: TelemetryScenarioRecord.levelOff,
            created: Date(timeIntervalSince1970: 3000)
        )

        let ckRecord = original.toCKRecord()
        let restored = try TelemetryScenarioRecord(record: ckRecord)
        XCTAssertEqual(restored.diagnosticLevel, TelemetryScenarioRecord.levelOff)
        XCTAssertFalse(restored.isActive)
    }

    func testBackwardCompatibleReadingFromIsEnabled() throws {
        // Simulate a legacy record with isEnabled (Bool) instead of diagnosticLevel
        let ckRecord = CKRecord(recordType: TelemetrySchema.scenarioRecordType)
        ckRecord["clientid"] = "client-legacy"
        ckRecord["scenarioName"] = "Legacy"
        ckRecord["isEnabled"] = NSNumber(value: true)
        ckRecord["created"] = Date(timeIntervalSince1970: 1000)

        let record = try TelemetryScenarioRecord(record: ckRecord)
        XCTAssertEqual(record.diagnosticLevel, TelemetryLogLevel.info.rawValue)
        XCTAssertTrue(record.isActive)
    }

    func testBackwardCompatibleReadingFromIsEnabledFalse() throws {
        let ckRecord = CKRecord(recordType: TelemetrySchema.scenarioRecordType)
        ckRecord["clientid"] = "client-legacy"
        ckRecord["scenarioName"] = "Legacy"
        ckRecord["isEnabled"] = NSNumber(value: false)
        ckRecord["created"] = Date(timeIntervalSince1970: 1000)

        let record = try TelemetryScenarioRecord(record: ckRecord)
        XCTAssertEqual(record.diagnosticLevel, TelemetryScenarioRecord.levelOff)
        XCTAssertFalse(record.isActive)
    }

    func testUnexpectedRecordTypeThrows() {
        let wrongRecord = CKRecord(recordType: "WrongType")
        wrongRecord["clientid"] = "client-1"
        wrongRecord["scenarioName"] = "Test"
        wrongRecord["diagnosticLevel"] = NSNumber(value: 1)
        wrongRecord["created"] = Date()

        XCTAssertThrowsError(try TelemetryScenarioRecord(record: wrongRecord)) { error in
            guard case TelemetryScenarioRecord.Error.unexpectedRecordType = error else {
                XCTFail("Expected unexpectedRecordType error")
                return
            }
        }
    }

    func testMissingClientIdThrows() {
        let record = CKRecord(recordType: TelemetrySchema.scenarioRecordType)
        record["scenarioName"] = "Test"
        record["diagnosticLevel"] = NSNumber(value: 1)
        record["created"] = Date()

        XCTAssertThrowsError(try TelemetryScenarioRecord(record: record)) { error in
            guard case TelemetryScenarioRecord.Error.missingField = error else {
                XCTFail("Expected missingField error")
                return
            }
        }
    }

    func testMissingScenarioNameThrows() {
        let record = CKRecord(recordType: TelemetrySchema.scenarioRecordType)
        record["clientid"] = "client-1"
        record["diagnosticLevel"] = NSNumber(value: 1)
        record["created"] = Date()

        XCTAssertThrowsError(try TelemetryScenarioRecord(record: record)) { error in
            guard case TelemetryScenarioRecord.Error.missingField = error else {
                XCTFail("Expected missingField error")
                return
            }
        }
    }

    func testMissingDiagnosticLevelThrows() {
        let record = CKRecord(recordType: TelemetrySchema.scenarioRecordType)
        record["clientid"] = "client-1"
        record["scenarioName"] = "Test"
        record["created"] = Date()

        XCTAssertThrowsError(try TelemetryScenarioRecord(record: record)) { error in
            guard case TelemetryScenarioRecord.Error.missingField = error else {
                XCTFail("Expected missingField error")
                return
            }
        }
    }

    func testMissingCreatedThrows() {
        let record = CKRecord(recordType: TelemetrySchema.scenarioRecordType)
        record["clientid"] = "client-1"
        record["scenarioName"] = "Test"
        record["diagnosticLevel"] = NSNumber(value: 1)

        XCTAssertThrowsError(try TelemetryScenarioRecord(record: record)) { error in
            guard case TelemetryScenarioRecord.Error.missingField = error else {
                XCTFail("Expected missingField error")
                return
            }
        }
    }

    func testEquatable() {
        let id = CKRecord.ID(recordName: "eq-test")
        let date = Date(timeIntervalSince1970: 5000)
        let a = TelemetryScenarioRecord(recordID: id, clientId: "c", scenarioName: "S", diagnosticLevel: 1, created: date)
        let b = TelemetryScenarioRecord(recordID: id, clientId: "c", scenarioName: "S", diagnosticLevel: 1, created: date)
        XCTAssertEqual(a, b)
    }

    func testApplyingToRecord() throws {
        let existingCK = CKRecord(recordType: TelemetrySchema.scenarioRecordType)
        existingCK["clientid"] = "old-client"
        existingCK["scenarioName"] = "OldScenario"
        existingCK["diagnosticLevel"] = NSNumber(value: TelemetryScenarioRecord.levelOff)
        existingCK["created"] = Date(timeIntervalSince1970: 1000)

        let updated = TelemetryScenarioRecord(
            recordID: existingCK.recordID,
            clientId: "new-client",
            scenarioName: "NewScenario",
            diagnosticLevel: TelemetryLogLevel.warning.rawValue,
            created: Date(timeIntervalSince1970: 2000)
        )

        let applied = try updated.applying(to: existingCK)
        XCTAssertEqual(applied["clientid"] as? String, "new-client")
        XCTAssertEqual(applied["scenarioName"] as? String, "NewScenario")
    }

    func testApplyingToWrongRecordTypeThrows() {
        let wrongRecord = CKRecord(recordType: "WrongType")
        let scenario = TelemetryScenarioRecord(clientId: "c", scenarioName: "S")

        XCTAssertThrowsError(try scenario.applying(to: wrongRecord)) { error in
            guard case TelemetryScenarioRecord.Error.unexpectedRecordType = error else {
                XCTFail("Expected unexpectedRecordType error")
                return
            }
        }
    }

    func testErrorDescriptions() {
        let errors: [TelemetryScenarioRecord.Error] = [
            .missingRecordID,
            .unexpectedRecordType("Wrong"),
            .missingField("test"),
        ]

        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error \(error) should have a description")
        }
    }

    func testResolvedLevelForValidValues() {
        let record = TelemetryScenarioRecord(clientId: "c", scenarioName: "S", diagnosticLevel: 2)
        XCTAssertEqual(record.resolvedLevel, .warning)
    }

    func testResolvedLevelForInvalidValue() {
        let record = TelemetryScenarioRecord(clientId: "c", scenarioName: "S", diagnosticLevel: 99)
        XCTAssertNil(record.resolvedLevel)
    }
}
