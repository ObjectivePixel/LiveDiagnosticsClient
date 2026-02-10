import CloudKit
import XCTest
@testable import ObjPxlLiveTelemetry

final class TelemetryLoggerTests: XCTestCase {

    // MARK: - Events dropped when activated with enabled: false

    func testEventsDroppedAfterActivateDisabled() async throws {
        let spy = SpyCloudKitClient()
        let logger = TelemetryLogger(
            configuration: .init(batchSize: 1, flushInterval: 60, maxRetries: 1),
            client: spy
        )

        // Activate with telemetry disabled — no bootstrap, no CloudKit work
        await logger.activate(enabled: false)

        // Log several events; state is .ready(enabled: false) so they should be discarded
        logger.logEvent(name: "should_be_dropped_1")
        logger.logEvent(name: "should_be_dropped_2")

        // Explicit flush should be a no-op (pending is empty)
        await logger.flush()

        let savedCount = await spy.savedRecordCount
        XCTAssertEqual(savedCount, 0, "No records should be saved when telemetry is disabled")

        let validated = await spy.didValidateSchema
        XCTAssertFalse(validated, "Schema should not be validated when activated with enabled: false")

        await logger.shutdown()
    }

    // MARK: - Events queued during init are discarded when activated disabled

    func testQueuedEventsDuringInitDiscardedOnActivateDisabled() async throws {
        let spy = SpyCloudKitClient()
        let logger = TelemetryLogger(
            configuration: .init(batchSize: 1, flushInterval: 60, maxRetries: 1),
            client: spy
        )

        // State is .initializing — events are queued
        logger.logEvent(name: "queued_event_1")
        logger.logEvent(name: "queued_event_2")

        // Allow the queued Task { await self.queueEvent(event) } calls to run
        try await Task.sleep(for: .milliseconds(50))

        // Activate disabled — queued events should be discarded, no bootstrap
        await logger.activate(enabled: false)

        // Flush should be a no-op
        await logger.flush()

        let savedCount = await spy.savedRecordCount
        XCTAssertEqual(savedCount, 0, "Queued events should be discarded when activated with enabled: false")

        let validated = await spy.didValidateSchema
        XCTAssertFalse(validated, "Schema should not be validated when activated with enabled: false")

        await logger.shutdown()
    }

    // MARK: - Events dropped after setEnabled(false)

    func testEventsDroppedAfterSetEnabledFalse() async throws {
        let spy = SpyCloudKitClient()
        let logger = TelemetryLogger(
            configuration: .init(batchSize: 10, flushInterval: 60, maxRetries: 1),
            client: spy
        )

        // Activate enabled so bootstrap runs
        await logger.activate(enabled: true)

        // Now disable via setEnabled
        await logger.setEnabled(false)

        // Log events — state is .ready(enabled: false) so they should be discarded
        logger.logEvent(name: "after_disable_1")
        logger.logEvent(name: "after_disable_2")

        // Give any async work a chance to run
        try await Task.sleep(for: .milliseconds(50))

        // Flush — pending should be empty since logEvent discarded the events
        await logger.flush()

        let savedCount = await spy.savedRecordCount
        XCTAssertEqual(savedCount, 0, "No records should be saved after setEnabled(false)")

        await logger.shutdown()
    }

    // MARK: - No CloudKit activity before activate

    func testNoCloudKitActivityBeforeActivate() async throws {
        let spy = SpyCloudKitClient()
        let _ = TelemetryLogger(
            configuration: .init(batchSize: 1, flushInterval: 60, maxRetries: 1),
            client: spy
        )

        // Allow any potential stray Tasks to execute
        try await Task.sleep(for: .milliseconds(100))

        let validated = await spy.didValidateSchema
        XCTAssertFalse(validated, "Schema validation should not run until activate is called")

        let savedCount = await spy.savedRecordCount
        XCTAssertEqual(savedCount, 0, "No CloudKit saves should happen before activate")
    }
}

// MARK: - Spy CloudKit Client

/// Minimal CloudKitClientProtocol implementation that tracks calls without hitting CloudKit.
private actor SpyCloudKitClient: CloudKitClientProtocol {
    private(set) var didValidateSchema = false
    private(set) var savedRecordCount = 0

    func validateSchema() async -> Bool {
        didValidateSchema = true
        return true
    }

    func save(records: [CKRecord]) async throws {
        savedRecordCount += records.count
    }

    // MARK: - Unused stubs

    func fetchAllRecords() async throws -> [CKRecord] { [] }
    func fetchRecords(limit: Int, cursor: CKQueryOperation.Cursor?) async throws -> ([CKRecord], CKQueryOperation.Cursor?) { ([], nil) }
    func countRecords() async throws -> Int { 0 }
    func createTelemetryClient(clientId: String, created: Date, isEnabled: Bool) async throws -> TelemetryClientRecord {
        TelemetryClientRecord(recordID: nil, clientId: clientId, created: created, isEnabled: isEnabled)
    }
    func createTelemetryClient(_ telemetryClient: TelemetryClientRecord) async throws -> TelemetryClientRecord { telemetryClient }
    func updateTelemetryClient(recordID: CKRecord.ID, clientId: String?, created: Date?, isEnabled: Bool?) async throws -> TelemetryClientRecord {
        TelemetryClientRecord(recordID: recordID, clientId: clientId ?? "", created: created ?? .now, isEnabled: isEnabled ?? false)
    }
    func updateTelemetryClient(_ telemetryClient: TelemetryClientRecord) async throws -> TelemetryClientRecord { telemetryClient }
    func deleteTelemetryClient(recordID: CKRecord.ID) async throws {}
    func fetchTelemetryClients(clientId: String?, isEnabled: Bool?) async throws -> [TelemetryClientRecord] { [] }
    func debugDatabaseInfo() async {}
    func detectEnvironment() async -> String { "test" }
    func getDebugInfo() async -> DebugInfo {
        DebugInfo(containerID: "test", buildType: "DEBUG", environment: "test", testQueryResults: 0, firstRecordID: nil, firstRecordFields: [], recordCount: 0, errorMessage: nil)
    }
    func deleteAllRecords() async throws -> Int { 0 }
    func createCommand(_ command: TelemetryCommandRecord) async throws -> TelemetryCommandRecord { command }
    func fetchCommand(recordID: CKRecord.ID) async throws -> TelemetryCommandRecord? { nil }
    func fetchPendingCommands(for clientId: String) async throws -> [TelemetryCommandRecord] { [] }
    func updateCommandStatus(recordID: CKRecord.ID, status: TelemetrySchema.CommandStatus, executedAt: Date?, errorMessage: String?) async throws -> TelemetryCommandRecord {
        fatalError("not implemented")
    }
    func deleteCommand(recordID: CKRecord.ID) async throws {}
    func deleteAllCommands(for clientId: String) async throws -> Int { 0 }
    func createCommandSubscription(for clientId: String) async throws -> CKSubscription.ID { "test" }
    func removeCommandSubscription(_ subscriptionID: CKSubscription.ID) async throws {}
    func fetchCommandSubscription(for clientId: String) async throws -> CKSubscription.ID? { nil }
    func createClientRecordSubscription() async throws -> CKSubscription.ID { "test" }
    func removeSubscription(_ subscriptionID: CKSubscription.ID) async throws {}
    func fetchSubscription(id: CKSubscription.ID) async throws -> CKSubscription.ID? { nil }
}
