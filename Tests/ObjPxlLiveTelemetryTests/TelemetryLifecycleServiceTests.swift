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
            configuration: .init(containerIdentifier: "iCloud.test.container"),
            logger: SpyTelemetryLogger(),
            syncCoordinator: TelemetrySettingsSyncCoordinator(backupClient: MockBackupClient())
        )

        await service.enableTelemetry()

        XCTAssertTrue(service.settings.telemetryRequested)
        // telemetrySendingEnabled should be false until admin enables the client
        XCTAssertFalse(service.settings.telemetrySendingEnabled)
        XCTAssertEqual(service.settings.clientIdentifier, "sampleid01")

        let clients = await cloudKit.telemetryClients()
        XCTAssertEqual(clients.count, 1)
        let client = try XCTUnwrap(clients.first)
        XCTAssertEqual(client.clientId, "sampleid01")
        // Client should be created with isEnabled = false; admin tool enables it
        XCTAssertFalse(client.isEnabled)
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
            configuration: .init(containerIdentifier: "iCloud.test.container"),
            logger: SpyTelemetryLogger(),
            syncCoordinator: TelemetrySettingsSyncCoordinator(backupClient: MockBackupClient())
        )

        await service.enableTelemetry()

        let clients = await cloudKit.telemetryClients()
        XCTAssertEqual(clients.count, 1)
        let client = try XCTUnwrap(clients.first)
        XCTAssertEqual(client.recordID, existing.recordID)
        // Client should not modify isEnabled - only admin tool does that
        XCTAssertFalse(client.isEnabled)
        // telemetrySendingEnabled should be false since server has isEnabled = false
        XCTAssertFalse(service.settings.telemetrySendingEnabled)
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
            configuration: .init(containerIdentifier: "iCloud.test.container"),
            logger: SpyTelemetryLogger(),
            syncCoordinator: TelemetrySettingsSyncCoordinator(backupClient: MockBackupClient())
        )

        await service.enableTelemetry()

        let clients = await cloudKit.telemetryClients()
        XCTAssertEqual(clients.count, 1)
        let client = try XCTUnwrap(clients.first)
        // Recovery should just fetch the existing client, not enable it
        XCTAssertFalse(client.isEnabled)
        // telemetrySendingEnabled should be false since server has isEnabled = false
        XCTAssertFalse(service.settings.telemetrySendingEnabled)
    }

    func testDisableTelemetryDeletesClientRecord() async throws {
        let cloudKit = MockCloudKitClient()
        let store = InMemoryTelemetrySettingsStore()

        let service = TelemetryLifecycleService(
            settingsStore: store,
            cloudKitClient: cloudKit,
            identifierGenerator: FixedIdentifierGenerator(identifier: "delete-test"),
            configuration: .init(containerIdentifier: "iCloud.test.container"),
            logger: SpyTelemetryLogger(),
            syncCoordinator: TelemetrySettingsSyncCoordinator(backupClient: MockBackupClient())
        )

        // Enable telemetry (creates client with isEnabled = false)
        await service.enableTelemetry()

        // Verify client was created
        var clients = await cloudKit.telemetryClients()
        XCTAssertEqual(clients.count, 1)
        XCTAssertEqual(clients.first?.clientId, "delete-test")

        // Disable telemetry
        await service.disableTelemetry()

        // Verify client was deleted
        clients = await cloudKit.telemetryClients()
        XCTAssertEqual(clients.count, 0, "TelemetryClientRecord should be deleted when telemetry is disabled")
        XCTAssertEqual(service.settings, .defaults)
    }

    func testDisableTelemetryDeletesCommands() async throws {
        let cloudKit = MockCloudKitClient()
        let store = InMemoryTelemetrySettingsStore()

        let service = TelemetryLifecycleService(
            settingsStore: store,
            cloudKitClient: cloudKit,
            identifierGenerator: FixedIdentifierGenerator(identifier: "cmd-cleanup"),
            configuration: .init(containerIdentifier: "iCloud.test.container"),
            logger: SpyTelemetryLogger(),
            syncCoordinator: TelemetrySettingsSyncCoordinator(backupClient: MockBackupClient()),
            subscriptionManager: MockSubscriptionManager()
        )

        // Enable telemetry
        await service.enableTelemetry()

        // Simulate some commands existing for this client
        _ = try await cloudKit.createCommand(
            TelemetryCommandRecord(clientId: "cmd-cleanup", action: .enable)
        )
        _ = try await cloudKit.createCommand(
            TelemetryCommandRecord(clientId: "cmd-cleanup", action: .deleteEvents)
        )

        // Verify commands exist
        var commands = await cloudKit.fetchAllCommands()
        XCTAssertEqual(commands.count, 2)

        // Disable telemetry
        await service.disableTelemetry()

        // Verify commands were deleted
        commands = await cloudKit.fetchAllCommands()
        XCTAssertEqual(commands.count, 0, "TelemetryCommand records should be deleted when telemetry is disabled")
    }

    func testPendingApprovalPersistsAcrossReconcile() async throws {
        let cloudKit = MockCloudKitClient()
        let store = InMemoryTelemetrySettingsStore()

        let service = TelemetryLifecycleService(
            settingsStore: store,
            cloudKitClient: cloudKit,
            identifierGenerator: FixedIdentifierGenerator(identifier: "pending-test"),
            configuration: .init(containerIdentifier: "iCloud.test.container"),
            logger: SpyTelemetryLogger(),
            syncCoordinator: TelemetrySettingsSyncCoordinator(backupClient: MockBackupClient())
        )

        // Enable telemetry (creates client with isEnabled = false, waiting for admin)
        await service.enableTelemetry()

        // Verify initial state
        XCTAssertTrue(service.settings.telemetryRequested)
        XCTAssertFalse(service.settings.telemetrySendingEnabled)
        XCTAssertEqual(service.settings.clientIdentifier, "pending-test")

        // Simulate app restart by calling reconcile (which happens on startup)
        let outcome = await service.reconcile()

        // Should still be pending approval, not reset
        XCTAssertEqual(outcome, .pendingApproval)
        XCTAssertTrue(service.settings.telemetryRequested, "telemetryRequested should persist")
        XCTAssertEqual(service.settings.clientIdentifier, "pending-test", "clientIdentifier should persist")
        XCTAssertEqual(service.status, .pendingApproval)

        // Client record should still exist
        let clients = await cloudKit.telemetryClients()
        XCTAssertEqual(clients.count, 1)
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

        let spyLogger = SpyTelemetryLogger()
        let service = TelemetryLifecycleService(
            settingsStore: store,
            cloudKitClient: cloudKit,
            identifierGenerator: FixedIdentifierGenerator(identifier: "abc123"),
            configuration: .init(containerIdentifier: "iCloud.test.container"),
            logger: spyLogger,
            syncCoordinator: TelemetrySettingsSyncCoordinator(backupClient: MockBackupClient())
        )

        let outcome = await service.reconcile()

        XCTAssertEqual(outcome, .serverEnabledLocalDisabled)
        XCTAssertTrue(service.settings.telemetrySendingEnabled)

        // Verify the logger was enabled
        let loggerEnabled = await spyLogger.isEnabled
        XCTAssertTrue(loggerEnabled, "Logger should be enabled after admin approval")
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
            configuration: .init(containerIdentifier: "iCloud.test.container"),
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

    // MARK: - Command Processing Tests

    func testEnableCommandProcessed() async throws {
        let cloudKit = MockCloudKitClient()
        let store = InMemoryTelemetrySettingsStore()
        _ = await store.save(
            TelemetrySettings(
                telemetryRequested: true,
                telemetrySendingEnabled: false,
                clientIdentifier: "cmd-enable-test"
            )
        )
        _ = try await cloudKit.createTelemetryClient(
            clientId: "cmd-enable-test",
            created: .now,
            isEnabled: false
        )

        // Create a pending enable command
        _ = try await cloudKit.createCommand(
            TelemetryCommandRecord(
                clientId: "cmd-enable-test",
                action: .enable
            )
        )

        let spyLogger = SpyTelemetryLogger()
        let service = TelemetryLifecycleService(
            settingsStore: store,
            cloudKitClient: cloudKit,
            identifierGenerator: FixedIdentifierGenerator(identifier: "cmd-enable-test"),
            configuration: .init(containerIdentifier: "iCloud.test.container"),
            logger: spyLogger,
            syncCoordinator: TelemetrySettingsSyncCoordinator(backupClient: MockBackupClient()),
            subscriptionManager: MockSubscriptionManager()
        )

        // Reconcile will set up command processing and process pending commands
        _ = await service.reconcile()

        // Give async command processing time to complete
        try await Task.sleep(for: .milliseconds(100))

        // Verify telemetrySendingEnabled was turned on
        XCTAssertTrue(service.settings.telemetrySendingEnabled)
        XCTAssertEqual(service.status, TelemetryLifecycleService.Status.enabled)

        // Verify command was marked as executed
        let commands = await cloudKit.fetchAllCommands()
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?.status, .executed)
        XCTAssertNotNil(commands.first?.executedAt)
    }

    func testDisableCommandProcessed() async throws {
        let cloudKit = MockCloudKitClient()
        let store = InMemoryTelemetrySettingsStore()
        _ = await store.save(
            TelemetrySettings(
                telemetryRequested: true,
                telemetrySendingEnabled: true,
                clientIdentifier: "cmd-disable-test"
            )
        )
        _ = try await cloudKit.createTelemetryClient(
            clientId: "cmd-disable-test",
            created: .now,
            isEnabled: true
        )

        // Create a pending disable command
        _ = try await cloudKit.createCommand(
            TelemetryCommandRecord(
                clientId: "cmd-disable-test",
                action: .disable
            )
        )

        let service = TelemetryLifecycleService(
            settingsStore: store,
            cloudKitClient: cloudKit,
            identifierGenerator: FixedIdentifierGenerator(identifier: "cmd-disable-test"),
            configuration: .init(containerIdentifier: "iCloud.test.container"),
            logger: SpyTelemetryLogger(),
            syncCoordinator: TelemetrySettingsSyncCoordinator(backupClient: MockBackupClient()),
            subscriptionManager: MockSubscriptionManager()
        )

        // Reconcile will set up command processing and process pending commands
        _ = await service.reconcile()

        // Give async command processing time to complete
        try await Task.sleep(for: .milliseconds(100))

        // Verify telemetry was disabled
        XCTAssertFalse(service.settings.telemetrySendingEnabled)
        XCTAssertFalse(service.settings.telemetryRequested)
        XCTAssertEqual(service.status, TelemetryLifecycleService.Status.disabled)

        // Commands are cleaned up as part of disableTelemetry
        let commands = await cloudKit.fetchAllCommands()
        XCTAssertEqual(commands.count, 0, "Commands should be deleted when telemetry is disabled")
    }

    func testDeleteEventsCommandProcessed() async throws {
        let cloudKit = MockCloudKitClient()
        let store = InMemoryTelemetrySettingsStore()
        _ = await store.save(
            TelemetrySettings(
                telemetryRequested: true,
                telemetrySendingEnabled: true,
                clientIdentifier: "cmd-delete-test"
            )
        )
        _ = try await cloudKit.createTelemetryClient(
            clientId: "cmd-delete-test",
            created: .now,
            isEnabled: true
        )
        // Add some telemetry events
        _ = try await cloudKit.save(records: [
            CKRecord(recordType: TelemetrySchema.recordType),
            CKRecord(recordType: TelemetrySchema.recordType),
        ])

        // Create a pending deleteEvents command
        _ = try await cloudKit.createCommand(
            TelemetryCommandRecord(
                clientId: "cmd-delete-test",
                action: .deleteEvents
            )
        )

        let service = TelemetryLifecycleService(
            settingsStore: store,
            cloudKitClient: cloudKit,
            identifierGenerator: FixedIdentifierGenerator(identifier: "cmd-delete-test"),
            configuration: .init(containerIdentifier: "iCloud.test.container"),
            logger: SpyTelemetryLogger(),
            syncCoordinator: TelemetrySettingsSyncCoordinator(backupClient: MockBackupClient()),
            subscriptionManager: MockSubscriptionManager()
        )

        // Reconcile will set up command processing and process pending commands
        _ = await service.reconcile()

        // Give async command processing time to complete
        try await Task.sleep(for: .milliseconds(100))

        // Verify events were deleted
        let recordCount = try await cloudKit.countRecords()
        XCTAssertEqual(recordCount, 0)

        // Verify command was marked as executed
        let commands = await cloudKit.fetchAllCommands()
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?.status, .executed)
    }

    func testCommandsProcessedInOrder() async throws {
        let cloudKit = MockCloudKitClient()
        let store = InMemoryTelemetrySettingsStore()
        _ = await store.save(
            TelemetrySettings(
                telemetryRequested: true,
                telemetrySendingEnabled: false,
                clientIdentifier: "cmd-order-test"
            )
        )
        _ = try await cloudKit.createTelemetryClient(
            clientId: "cmd-order-test",
            created: .now,
            isEnabled: false
        )

        // Create commands with different timestamps (oldest first)
        _ = try await cloudKit.createCommand(
            TelemetryCommandRecord(
                commandId: "first",
                clientId: "cmd-order-test",
                action: .enable,
                created: Date(timeIntervalSince1970: 1000)
            )
        )
        _ = try await cloudKit.createCommand(
            TelemetryCommandRecord(
                commandId: "second",
                clientId: "cmd-order-test",
                action: .deleteEvents,
                created: Date(timeIntervalSince1970: 2000)
            )
        )

        let service = TelemetryLifecycleService(
            settingsStore: store,
            cloudKitClient: cloudKit,
            identifierGenerator: FixedIdentifierGenerator(identifier: "cmd-order-test"),
            configuration: .init(containerIdentifier: "iCloud.test.container"),
            logger: SpyTelemetryLogger(),
            syncCoordinator: TelemetrySettingsSyncCoordinator(backupClient: MockBackupClient()),
            subscriptionManager: MockSubscriptionManager()
        )

        _ = await service.reconcile()

        // Give async command processing time to complete
        try await Task.sleep(for: .milliseconds(100))

        // Verify both commands were executed
        let commands = await cloudKit.fetchAllCommands()
        XCTAssertEqual(commands.count, 2)
        XCTAssertTrue(commands.allSatisfy { $0.status == .executed })
    }

    func testFailedCommandMarkedFailed() async throws {
        let cloudKit = MockCloudKitClient()
        let store = InMemoryTelemetrySettingsStore()
        _ = await store.save(
            TelemetrySettings(
                telemetryRequested: true,
                telemetrySendingEnabled: true,
                clientIdentifier: "cmd-fail-test"
            )
        )
        _ = try await cloudKit.createTelemetryClient(
            clientId: "cmd-fail-test",
            created: .now,
            isEnabled: true
        )

        // Create a deleteEvents command that will fail
        _ = try await cloudKit.createCommand(
            TelemetryCommandRecord(
                clientId: "cmd-fail-test",
                action: .deleteEvents
            )
        )

        // Set up the mock to throw an error on deleteAllRecords
        await cloudKit.setDeleteError(NSError(domain: "TestError", code: 1, userInfo: [NSLocalizedDescriptionKey: "Test error"]))

        let service = TelemetryLifecycleService(
            settingsStore: store,
            cloudKitClient: cloudKit,
            identifierGenerator: FixedIdentifierGenerator(identifier: "cmd-fail-test"),
            configuration: .init(containerIdentifier: "iCloud.test.container"),
            logger: SpyTelemetryLogger(),
            syncCoordinator: TelemetrySettingsSyncCoordinator(backupClient: MockBackupClient()),
            subscriptionManager: MockSubscriptionManager()
        )

        _ = await service.reconcile()

        // Give async command processing time to complete
        try await Task.sleep(for: .milliseconds(100))

        // Verify command was marked as failed
        let commands = await cloudKit.fetchAllCommands()
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?.status, .failed)
        XCTAssertNotNil(commands.first?.errorMessage)
    }

    func testEnableTelemetryRegistersSubscription() async throws {
        let cloudKit = MockCloudKitClient()
        let store = InMemoryTelemetrySettingsStore()
        let mockSubscriptionManager = MockSubscriptionManager()

        let service = TelemetryLifecycleService(
            settingsStore: store,
            cloudKitClient: cloudKit,
            identifierGenerator: FixedIdentifierGenerator(identifier: "sub-test"),
            configuration: .init(containerIdentifier: "iCloud.test.container"),
            logger: SpyTelemetryLogger(),
            syncCoordinator: TelemetrySettingsSyncCoordinator(backupClient: MockBackupClient()),
            subscriptionManager: mockSubscriptionManager
        )

        await service.enableTelemetry()

        let registered = await mockSubscriptionManager.registeredClientId
        XCTAssertEqual(registered, "sub-test")
    }

    func testDisableTelemetryUnregistersSubscription() async throws {
        let cloudKit = MockCloudKitClient()
        let store = InMemoryTelemetrySettingsStore()
        let mockSubscriptionManager = MockSubscriptionManager()

        let service = TelemetryLifecycleService(
            settingsStore: store,
            cloudKitClient: cloudKit,
            identifierGenerator: FixedIdentifierGenerator(identifier: "unsub-test"),
            configuration: .init(containerIdentifier: "iCloud.test.container"),
            logger: SpyTelemetryLogger(),
            syncCoordinator: TelemetrySettingsSyncCoordinator(backupClient: MockBackupClient()),
            subscriptionManager: mockSubscriptionManager
        )

        await service.enableTelemetry()
        await service.disableTelemetry()

        let unregistered = await mockSubscriptionManager.didUnregister
        XCTAssertTrue(unregistered)
    }

    func testGracefulDegradationOnSubscriptionFailure() async throws {
        let cloudKit = MockCloudKitClient()
        let store = InMemoryTelemetrySettingsStore()
        let mockSubscriptionManager = MockSubscriptionManager()
        await mockSubscriptionManager.setError(NSError(domain: "TestError", code: 1))

        let service = TelemetryLifecycleService(
            settingsStore: store,
            cloudKitClient: cloudKit,
            identifierGenerator: FixedIdentifierGenerator(identifier: "graceful-test"),
            configuration: .init(containerIdentifier: "iCloud.test.container"),
            logger: SpyTelemetryLogger(),
            syncCoordinator: TelemetrySettingsSyncCoordinator(backupClient: MockBackupClient()),
            subscriptionManager: mockSubscriptionManager
        )

        // This should not throw even though subscription fails
        await service.enableTelemetry()

        // Service should still be in pending state (not error state)
        XCTAssertEqual(service.status, TelemetryLifecycleService.Status.pendingApproval)
        XCTAssertTrue(service.settings.telemetryRequested)
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
    private var commands: [TelemetryCommandRecord] = []
    private var subscriptions: [String: CKSubscription.ID] = [:]
    private var createError: Error?
    private var subscriptionError: Error?
    private var deleteError: Error?

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
        if let deleteError {
            throw deleteError
        }
        let count = records.count
        records.removeAll()
        return count
    }

    // MARK: - Command Methods

    func createCommand(_ command: TelemetryCommandRecord) async throws -> TelemetryCommandRecord {
        let newCommand = TelemetryCommandRecord(
            recordID: CKRecord.ID(recordName: UUID().uuidString),
            commandId: command.commandId,
            clientId: command.clientId,
            action: command.action,
            created: command.created,
            status: command.status,
            executedAt: command.executedAt,
            errorMessage: command.errorMessage
        )
        commands.append(newCommand)
        return newCommand
    }

    func fetchPendingCommands(for clientId: String) async throws -> [TelemetryCommandRecord] {
        commands
            .filter { $0.clientId == clientId && $0.status == .pending }
            .sorted { $0.created < $1.created }
    }

    func updateCommandStatus(
        recordID: CKRecord.ID,
        status: TelemetrySchema.CommandStatus,
        executedAt: Date?,
        errorMessage: String?
    ) async throws -> TelemetryCommandRecord {
        guard let index = commands.firstIndex(where: { $0.recordID == recordID }) else {
            throw TelemetryCommandRecord.Error.missingRecordID
        }

        var updated = commands[index]
        updated.status = status
        updated.executedAt = executedAt
        updated.errorMessage = errorMessage
        commands[index] = updated
        return updated
    }

    func deleteCommand(recordID: CKRecord.ID) async throws {
        commands.removeAll { $0.recordID == recordID }
    }

    func deleteAllCommands(for clientId: String) async throws -> Int {
        let matching = commands.filter { $0.clientId == clientId }
        commands.removeAll { $0.clientId == clientId }
        return matching.count
    }

    func fetchCommand(recordID: CKRecord.ID) async throws -> TelemetryCommandRecord? {
        commands.first { $0.recordID == recordID }
    }

    // MARK: - Subscription Methods

    func createCommandSubscription(for clientId: String) async throws -> CKSubscription.ID {
        if let subscriptionError {
            throw subscriptionError
        }
        let subscriptionID = "TelemetryCommand-\(clientId)"
        subscriptions[clientId] = subscriptionID
        return subscriptionID
    }

    func removeCommandSubscription(_ subscriptionID: CKSubscription.ID) async throws {
        subscriptions = subscriptions.filter { $0.value != subscriptionID }
    }

    func fetchCommandSubscription(for clientId: String) async throws -> CKSubscription.ID? {
        subscriptions[clientId]
    }

    func createClientRecordSubscription() async throws -> CKSubscription.ID {
        "TelemetryClient-All"
    }

    func removeSubscription(_ subscriptionID: CKSubscription.ID) async throws {
        subscriptions = subscriptions.filter { $0.value != subscriptionID }
    }

    func fetchSubscription(id: CKSubscription.ID) async throws -> CKSubscription.ID? {
        subscriptions.values.first { $0 == id }
    }

    // MARK: - Test Helpers

    func setCreateError(_ error: Error?) async {
        createError = error
    }

    func setSubscriptionError(_ error: Error?) async {
        subscriptionError = error
    }

    func setDeleteError(_ error: Error?) async {
        deleteError = error
    }

    func telemetryClients() async -> [TelemetryClientRecord] {
        clients
    }

    func fetchAllCommands() async -> [TelemetryCommandRecord] {
        commands
    }
}

private struct MockBackupClient: CloudKitSettingsBackupClientProtocol {
    func saveSettings(_ settings: TelemetrySettings) async throws {}
    func loadSettings() async throws -> TelemetrySettings? { nil }
    func clearSettings() async throws {}
}

private actor MockSubscriptionManager: TelemetrySubscriptionManaging {
    private(set) var registeredClientId: String?
    private(set) var didUnregister: Bool = false
    private var error: Error?
    private var _currentSubscriptionID: CKSubscription.ID?

    var currentSubscriptionID: CKSubscription.ID? {
        _currentSubscriptionID
    }

    func setError(_ error: Error?) {
        self.error = error
    }

    func registerSubscription(for clientId: String) async throws {
        if let error {
            throw error
        }
        registeredClientId = clientId
        _currentSubscriptionID = "TelemetryCommand-\(clientId)"
    }

    func unregisterSubscription() async throws {
        if let error {
            throw error
        }
        didUnregister = true
        _currentSubscriptionID = nil
        registeredClientId = nil
    }
}
