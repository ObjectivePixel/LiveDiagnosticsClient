import CloudKit
import XCTest
@testable import ObjPxlLiveTelemetry

@MainActor
final class TelemetryLifecycleServiceTests: XCTestCase {
    func testIdentifierGeneratorProducesExpectedLength() {
        let generator = TelemetryIdentifierGenerator(length: 10)
        let identifier = generator.generateIdentifier()

        XCTAssertEqual(identifier.count, 10)
        XCTAssertTrue(identifier.allSatisfy { TelemetryLifecycleServiceTests.allowedCharacters.contains($0) })
    }

    func testSettingsStoreRoundTripsValues() async {
        let defaults = UserDefaults(suiteName: "TelemetrySettings-\(UUID().uuidString)")!
        let store = UserDefaultsTelemetrySettingsStore(userDefaults: defaults)
        let expected = TelemetrySettings(
            telemetryRequested: true,
            telemetrySendingEnabled: true,
            clientIdentifier: "client-123"
        )

        _ = await store.save(expected)
        let loaded = await store.load()
        XCTAssertEqual(loaded, expected)

        let reset = await store.reset()
        XCTAssertEqual(reset, .defaults)
    }

    func testEnableCreatesClientAndUpdatesSettings() async throws {
        let cloudKit = MockCloudKitClient()
        let store = InMemoryTelemetrySettingsStore()

        let service = TelemetryLifecycleService(
            settingsStore: store,
            cloudKitClient: cloudKit,
            identifierGenerator: FixedIdentifierGenerator(identifier: "sampleid01"),
            configuration: .init(),
            logger: SpyTelemetryLogger(),
            syncCoordinator: TelemetrySettingsSyncCoordinator(backupClient: MockBackupClient())
        )

        await service.enableTelemetry()

        XCTAssertTrue(service.settings.telemetryRequested)
        XCTAssertTrue(service.settings.telemetrySendingEnabled)
        XCTAssertEqual(service.settings.clientIdentifier, "sampleid01")

        let clients = await cloudKit.telemetryClients()
        XCTAssertEqual(clients.count, 1)
        let client = try XCTUnwrap(clients.first)
        XCTAssertEqual(client.clientId, "sampleid01")
        XCTAssertTrue(client.isEnabled)
        XCTAssertNotNil(service.telemetryLogger as? SpyTelemetryLogger)
    }

    func testEnableReusesExistingClient() async throws {
        let cloudKit = MockCloudKitClient()
        let existing = try await cloudKit.createTelemetryClient(
            clientId: "sampleid01",
            created: .now,
            isEnabled: false
        )

        let store = InMemoryTelemetrySettingsStore()
        let service = TelemetryLifecycleService(
            settingsStore: store,
            cloudKitClient: cloudKit,
            identifierGenerator: FixedIdentifierGenerator(identifier: "sampleid01"),
            configuration: .init(),
            logger: SpyTelemetryLogger(),
            syncCoordinator: TelemetrySettingsSyncCoordinator(backupClient: MockBackupClient())
        )

        await service.enableTelemetry()

        let clients = await cloudKit.telemetryClients()
        XCTAssertEqual(clients.count, 1)
        let client = try XCTUnwrap(clients.first)
        XCTAssertEqual(client.recordID, existing.recordID)
        XCTAssertTrue(client.isEnabled)
        XCTAssertTrue(service.settings.telemetrySendingEnabled)
    }

    func testEnableRecoversFromServerRecordChanged() async throws {
        let cloudKit = MockCloudKitClient()
        _ = try await cloudKit.createTelemetryClient(
            clientId: "sampleid01",
            created: .now,
            isEnabled: false
        )
        await cloudKit.setCreateError(CKError(.serverRecordChanged))

        let store = InMemoryTelemetrySettingsStore()
        let service = TelemetryLifecycleService(
            settingsStore: store,
            cloudKitClient: cloudKit,
            identifierGenerator: FixedIdentifierGenerator(identifier: "sampleid01"),
            configuration: .init(),
            logger: SpyTelemetryLogger(),
            syncCoordinator: TelemetrySettingsSyncCoordinator(backupClient: MockBackupClient())
        )

        await service.enableTelemetry()

        let clients = await cloudKit.telemetryClients()
        XCTAssertEqual(clients.count, 1)
        let client = try XCTUnwrap(clients.first)
        XCTAssertTrue(client.isEnabled)
        XCTAssertTrue(service.settings.telemetrySendingEnabled)
    }

    func testReconcileEnablesLocalSendingWhenServerOn() async throws {
        let cloudKit = MockCloudKitClient()
        let store = InMemoryTelemetrySettingsStore()
        _ = await store.save(
            TelemetrySettings(
                telemetryRequested: true,
                telemetrySendingEnabled: false,
                clientIdentifier: "abc123"
            )
        )
        _ = try await cloudKit.createTelemetryClient(
            clientId: "abc123",
            created: .now,
            isEnabled: true
        )

        let service = TelemetryLifecycleService(
            settingsStore: store,
            cloudKitClient: cloudKit,
            identifierGenerator: FixedIdentifierGenerator(identifier: "abc123"),
            configuration: .init(),
            logger: SpyTelemetryLogger(),
            syncCoordinator: TelemetrySettingsSyncCoordinator(backupClient: MockBackupClient())
        )

        let outcome = await service.reconcile()

        XCTAssertEqual(outcome, .serverEnabledLocalDisabled)
        XCTAssertTrue(service.settings.telemetrySendingEnabled)
    }

    func testReconcileDisablesWhenServerOff() async throws {
        let cloudKit = MockCloudKitClient()
        let store = InMemoryTelemetrySettingsStore()
        _ = await store.save(
            TelemetrySettings(
                telemetryRequested: true,
                telemetrySendingEnabled: true,
                clientIdentifier: "client-off"
            )
        )
        _ = try await cloudKit.createTelemetryClient(
            clientId: "client-off",
            created: .now,
            isEnabled: false
        )
        _ = try await cloudKit.save(records: [
            CKRecord(recordType: TelemetrySchema.recordType)
        ])

        let service = TelemetryLifecycleService(
            settingsStore: store,
            cloudKitClient: cloudKit,
            identifierGenerator: FixedIdentifierGenerator(identifier: "client-off"),
            configuration: .init(),
            logger: SpyTelemetryLogger(),
            syncCoordinator: TelemetrySettingsSyncCoordinator(backupClient: MockBackupClient())
        )

        let outcome = await service.reconcile()

        XCTAssertEqual(outcome, .serverDisabledLocalEnabled)
        XCTAssertEqual(service.settings, .defaults)
        let remainingClients = await cloudKit.telemetryClients().count
        XCTAssertEqual(remainingClients, 0)
        let remainingRecordCount = try await cloudKit.countRecords()
        XCTAssertEqual(remainingRecordCount, 0)
    }
}

private extension TelemetryLifecycleServiceTests {
    static let allowedCharacters: Set<Character> = Set("abcdefghjkmnpqrstuvwxyz23456789")
}

private actor InMemoryTelemetrySettingsStore: TelemetrySettingsStoring {
    private var settings: TelemetrySettings = .defaults

    func load() async -> TelemetrySettings {
        settings
    }

    @discardableResult
    func save(_ settings: TelemetrySettings) async -> TelemetrySettings {
        self.settings = settings
        return settings
    }

    @discardableResult
    func update(_ transform: (inout TelemetrySettings) -> Void) async -> TelemetrySettings {
        var current = settings
        transform(&current)
        return await save(current)
    }

    @discardableResult
    func reset() async -> TelemetrySettings {
        settings = .defaults
        return settings
    }
}

private struct FixedIdentifierGenerator: TelemetryIdentifierGenerating {
    var identifier: String

    func generateIdentifier() -> String {
        identifier
    }
}

private actor SpyTelemetryLogger: TelemetryLogging {
    private(set) var events: [String] = []
    private(set) var didShutdown = false
    private(set) var isEnabled = false
    private(set) var isActivated = false
    nonisolated let currentSessionId: String = "test-session-id"

    nonisolated func logEvent(name: String, property1: String?) {
        Task { await register(name: name) }
    }

    func activate(enabled: Bool) async {
        isActivated = true
        isEnabled = enabled
    }

    func setEnabled(_ enabled: Bool) async {
        isEnabled = enabled
    }

    func flush() async {}

    func shutdown() async {
        didShutdown = true
    }

    private func register(name: String) {
        events.append(name)
    }
}

private actor MockCloudKitClient: CloudKitClientProtocol {
    private var records: [CKRecord] = []
    private var clients: [TelemetryClientRecord] = []
    private var createError: Error?

    func validateSchema() async -> Bool { true }

    func save(records: [CKRecord]) async throws {
        self.records.append(contentsOf: records)
    }

    func fetchAllRecords() async throws -> [CKRecord] {
        records
    }

    func fetchRecords(
        limit: Int,
        cursor: CKQueryOperation.Cursor?
    ) async throws -> ([CKRecord], CKQueryOperation.Cursor?) {
        let limited = Array(records.prefix(limit))
        return (limited, nil)
    }

    func countRecords() async throws -> Int {
        records.count
    }

    func createTelemetryClient(
        clientId: String,
        created: Date,
        isEnabled: Bool
    ) async throws -> TelemetryClientRecord {
        if let createError {
            throw createError
        }
        let record = TelemetryClientRecord(
            recordID: CKRecord.ID(recordName: UUID().uuidString),
            clientId: clientId,
            created: created,
            isEnabled: isEnabled
        )
        clients.append(record)
        return record
    }

    func createTelemetryClient(_ telemetryClient: TelemetryClientRecord) async throws -> TelemetryClientRecord {
        clients.append(telemetryClient)
        return telemetryClient
    }

    func updateTelemetryClient(
        recordID: CKRecord.ID,
        clientId: String?,
        created: Date?,
        isEnabled: Bool?
    ) async throws -> TelemetryClientRecord {
        guard let index = clients.firstIndex(where: { $0.recordID == recordID }) else {
            throw TelemetryClientRecord.Error.missingRecordID
        }

        let current = clients[index]
        let updated = TelemetryClientRecord(
            recordID: recordID,
            clientId: clientId ?? current.clientId,
            created: created ?? current.created,
            isEnabled: isEnabled ?? current.isEnabled
        )
        clients[index] = updated
        return updated
    }

    func updateTelemetryClient(_ telemetryClient: TelemetryClientRecord) async throws -> TelemetryClientRecord {
        guard let recordID = telemetryClient.recordID else {
            throw TelemetryClientRecord.Error.missingRecordID
        }
        return try await updateTelemetryClient(
            recordID: recordID,
            clientId: telemetryClient.clientId,
            created: telemetryClient.created,
            isEnabled: telemetryClient.isEnabled
        )
    }

    func deleteTelemetryClient(recordID: CKRecord.ID) async throws {
        clients.removeAll { $0.recordID == recordID }
    }

    func fetchTelemetryClients(clientId: String?, isEnabled: Bool?) async throws -> [TelemetryClientRecord] {
        clients.filter { client in
            let idMatches = clientId.map { $0 == client.clientId } ?? true
            let enabledMatches = isEnabled.map { $0 == client.isEnabled } ?? true
            return idMatches && enabledMatches
        }
    }

    func debugDatabaseInfo() async {}

    func detectEnvironment() async -> String { "mock" }

    func getDebugInfo() async -> DebugInfo {
        DebugInfo(
            containerID: "mock",
            buildType: "DEBUG",
            environment: "mock",
            testQueryResults: records.count,
            firstRecordID: records.first?.recordID.recordName,
            firstRecordFields: records.first?.allKeys() ?? [],
            recordCount: records.count,
            errorMessage: nil
        )
    }

    func deleteAllRecords() async throws -> Int {
        let count = records.count
        records.removeAll()
        return count
    }

    func setCreateError(_ error: Error?) async {
        createError = error
    }

    func telemetryClients() async -> [TelemetryClientRecord] {
        clients
    }
}

private struct MockBackupClient: CloudKitSettingsBackupClientProtocol {
    func saveSettings(_ settings: TelemetrySettings) async throws {}
    func loadSettings() async throws -> TelemetrySettings? { nil }
    func clearSettings() async throws {}
}
