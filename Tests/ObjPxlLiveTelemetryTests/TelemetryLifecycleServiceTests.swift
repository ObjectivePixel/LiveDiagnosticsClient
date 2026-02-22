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
        // Client identifier is stable across sessions — only session flags are reset
        XCTAssertFalse(service.settings.telemetryRequested)
        XCTAssertFalse(service.settings.telemetrySendingEnabled)
        XCTAssertEqual(service.settings.clientIdentifier, "delete-test")
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
        // Client identifier is stable across sessions — only session flags are reset
        XCTAssertFalse(service.settings.telemetryRequested)
        XCTAssertFalse(service.settings.telemetrySendingEnabled)
        XCTAssertEqual(service.settings.clientIdentifier, "client-off")
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

    // MARK: - Zero CloudKit Calls When Disabled

    func testStartupWithNeverEnabledTelemetryMakesNoCloudKitCalls() async throws {
        let cloudKit = MockCloudKitClient()
        let store = InMemoryTelemetrySettingsStore()
        let backupClient = MockBackupClient()

        let service = TelemetryLifecycleService(
            settingsStore: store,
            cloudKitClient: cloudKit,
            identifierGenerator: FixedIdentifierGenerator(identifier: "no-call-test"),
            configuration: .init(containerIdentifier: "iCloud.test.container"),
            logger: SpyTelemetryLogger(),
            syncCoordinator: TelemetrySettingsSyncCoordinator(backupClient: backupClient)
        )

        // Default settings: telemetryRequested=false, clientIdentifier=nil
        await service.startup()

        // Wait for background restore to complete
        try await Task.sleep(for: .milliseconds(200))

        // Backup restore should have been skipped entirely
        let loadCount = await backupClient.loadCallCount
        XCTAssertEqual(loadCount, 0, "Backup restore should be skipped when telemetry was never enabled")
        XCTAssertEqual(service.status, TelemetryLifecycleService.Status.disabled)
        XCTAssertFalse(service.isRestorationInProgress)
    }

    func testRegisterScenariosDoesNotCreateDuplicates() async throws {
        let cloudKit = MockCloudKitClient()
        let store = InMemoryTelemetrySettingsStore()
        _ = await store.save(
            TelemetrySettings(
                telemetryRequested: true,
                telemetrySendingEnabled: true,
                clientIdentifier: "dup-test"
            )
        )
        _ = try await cloudKit.createTelemetryClient(
            clientId: "dup-test",
            created: .now,
            isEnabled: true
        )
        let scenarioStore = InMemoryScenarioStore()

        let service = TelemetryLifecycleService(
            settingsStore: store,
            cloudKitClient: cloudKit,
            identifierGenerator: FixedIdentifierGenerator(identifier: "dup-test"),
            configuration: .init(containerIdentifier: "iCloud.test.container"),
            logger: SpyTelemetryLogger(),
            syncCoordinator: TelemetrySettingsSyncCoordinator(backupClient: MockBackupClient()),
            subscriptionManager: MockSubscriptionManager(),
            scenarioStore: scenarioStore
        )

        _ = await service.reconcile()

        // Register scenarios the first time
        try await service.registerScenarios(["NetworkRequests", "DataSync"])
        let firstCount = await cloudKit.scenarioList().count
        XCTAssertEqual(firstCount, 2)

        // Register the same scenarios again
        try await service.registerScenarios(["NetworkRequests", "DataSync"])
        let secondCount = await cloudKit.scenarioList().count
        XCTAssertEqual(secondCount, 2, "Registering the same scenarios again should not create duplicates")
    }

    // MARK: - Scenario Tests

    func testRegisterScenariosWritesToCloudKit() async throws {
        let cloudKit = MockCloudKitClient()
        let store = InMemoryTelemetrySettingsStore()
        _ = await store.save(
            TelemetrySettings(
                telemetryRequested: true,
                telemetrySendingEnabled: true,
                clientIdentifier: "scenario-test"
            )
        )
        _ = try await cloudKit.createTelemetryClient(
            clientId: "scenario-test",
            created: .now,
            isEnabled: true
        )
        let scenarioStore = InMemoryScenarioStore()

        let service = TelemetryLifecycleService(
            settingsStore: store,
            cloudKitClient: cloudKit,
            identifierGenerator: FixedIdentifierGenerator(identifier: "scenario-test"),
            configuration: .init(containerIdentifier: "iCloud.test.container"),
            logger: SpyTelemetryLogger(),
            syncCoordinator: TelemetrySettingsSyncCoordinator(backupClient: MockBackupClient()),
            subscriptionManager: MockSubscriptionManager(),
            scenarioStore: scenarioStore
        )

        _ = await service.reconcile()
        try await service.registerScenarios(["NetworkRequests", "DataSync"])

        let scenarios = await cloudKit.scenarioList()
        XCTAssertEqual(scenarios.count, 2)
        XCTAssertTrue(scenarios.contains { $0.scenarioName == "NetworkRequests" })
        XCTAssertTrue(scenarios.contains { $0.scenarioName == "DataSync" })
        // Default state is off (levelOff = -1)
        XCTAssertTrue(scenarios.allSatisfy { $0.diagnosticLevel == TelemetryScenarioRecord.levelOff })

        XCTAssertEqual(service.scenarioStates.count, 2)
        XCTAssertEqual(service.scenarioStates["NetworkRequests"], TelemetryScenarioRecord.levelOff)
        XCTAssertEqual(service.scenarioStates["DataSync"], TelemetryScenarioRecord.levelOff)
    }

    func testRegisterScenariosRestoresPersistedState() async throws {
        let cloudKit = MockCloudKitClient()
        let store = InMemoryTelemetrySettingsStore()
        _ = await store.save(
            TelemetrySettings(
                telemetryRequested: true,
                telemetrySendingEnabled: true,
                clientIdentifier: "scenario-restore"
            )
        )
        _ = try await cloudKit.createTelemetryClient(
            clientId: "scenario-restore",
            created: .now,
            isEnabled: true
        )
        let scenarioStore = InMemoryScenarioStore()
        await scenarioStore.saveLevel(for: "NetworkRequests", diagnosticLevel: TelemetryLogLevel.info.rawValue)

        let service = TelemetryLifecycleService(
            settingsStore: store,
            cloudKitClient: cloudKit,
            identifierGenerator: FixedIdentifierGenerator(identifier: "scenario-restore"),
            configuration: .init(containerIdentifier: "iCloud.test.container"),
            logger: SpyTelemetryLogger(),
            syncCoordinator: TelemetrySettingsSyncCoordinator(backupClient: MockBackupClient()),
            subscriptionManager: MockSubscriptionManager(),
            scenarioStore: scenarioStore
        )

        _ = await service.reconcile()
        try await service.registerScenarios(["NetworkRequests", "DataSync"])

        XCTAssertEqual(service.scenarioStates["NetworkRequests"], TelemetryLogLevel.info.rawValue, "Previously enabled scenario should be restored")
        XCTAssertEqual(service.scenarioStates["DataSync"], TelemetryScenarioRecord.levelOff, "New scenario should default to off")

        let scenarios = await cloudKit.scenarioList()
        let network = try XCTUnwrap(scenarios.first { $0.scenarioName == "NetworkRequests" })
        XCTAssertEqual(network.diagnosticLevel, TelemetryLogLevel.info.rawValue, "CloudKit record should reflect persisted level")
    }

    func testSetScenarioDiagnosticLevelUpdatesState() async throws {
        let cloudKit = MockCloudKitClient()
        let store = InMemoryTelemetrySettingsStore()
        _ = await store.save(
            TelemetrySettings(
                telemetryRequested: true,
                telemetrySendingEnabled: true,
                clientIdentifier: "scenario-toggle"
            )
        )
        _ = try await cloudKit.createTelemetryClient(
            clientId: "scenario-toggle",
            created: .now,
            isEnabled: true
        )
        let scenarioStore = InMemoryScenarioStore()
        let spyLogger = SpyTelemetryLogger()

        let service = TelemetryLifecycleService(
            settingsStore: store,
            cloudKitClient: cloudKit,
            identifierGenerator: FixedIdentifierGenerator(identifier: "scenario-toggle"),
            configuration: .init(containerIdentifier: "iCloud.test.container"),
            logger: spyLogger,
            syncCoordinator: TelemetrySettingsSyncCoordinator(backupClient: MockBackupClient()),
            subscriptionManager: MockSubscriptionManager(),
            scenarioStore: scenarioStore
        )

        _ = await service.reconcile()
        try await service.registerScenarios(["NetworkRequests"])
        try await service.setScenarioDiagnosticLevel("NetworkRequests", level: TelemetryLogLevel.debug.rawValue)

        XCTAssertEqual(service.scenarioStates["NetworkRequests"], TelemetryLogLevel.debug.rawValue)

        // Verify persistence
        let persisted = await scenarioStore.loadLevel(for: "NetworkRequests")
        XCTAssertEqual(persisted, TelemetryLogLevel.debug.rawValue)

        // Verify CloudKit record updated
        let scenarios = await cloudKit.scenarioList()
        let record = try XCTUnwrap(scenarios.first { $0.scenarioName == "NetworkRequests" })
        XCTAssertEqual(record.diagnosticLevel, TelemetryLogLevel.debug.rawValue)

        // Verify logger received state push
        let loggerStates = await spyLogger.lastScenarioStates
        XCTAssertEqual(loggerStates["NetworkRequests"], TelemetryLogLevel.debug.rawValue)
    }

    func testEndSessionDeletesScenariosFromCloudKit() async throws {
        let cloudKit = MockCloudKitClient()
        let store = InMemoryTelemetrySettingsStore()
        _ = await store.save(
            TelemetrySettings(
                telemetryRequested: true,
                telemetrySendingEnabled: true,
                clientIdentifier: "scenario-end"
            )
        )
        _ = try await cloudKit.createTelemetryClient(
            clientId: "scenario-end",
            created: .now,
            isEnabled: true
        )
        let scenarioStore = InMemoryScenarioStore()

        let service = TelemetryLifecycleService(
            settingsStore: store,
            cloudKitClient: cloudKit,
            identifierGenerator: FixedIdentifierGenerator(identifier: "scenario-end"),
            configuration: .init(containerIdentifier: "iCloud.test.container"),
            logger: SpyTelemetryLogger(),
            syncCoordinator: TelemetrySettingsSyncCoordinator(backupClient: MockBackupClient()),
            subscriptionManager: MockSubscriptionManager(),
            scenarioStore: scenarioStore
        )

        _ = await service.reconcile()
        try await service.registerScenarios(["NetworkRequests"])
        try await service.setScenarioDiagnosticLevel("NetworkRequests", level: TelemetryLogLevel.info.rawValue)

        try await service.endSession()

        let scenarios = await cloudKit.scenarioList()
        XCTAssertTrue(scenarios.isEmpty, "CloudKit scenarios should be deleted after endSession")
        XCTAssertTrue(service.scenarioStates.isEmpty, "Local scenario states should be cleared")

        // But persisted level should be preserved
        let persisted = await scenarioStore.loadLevel(for: "NetworkRequests")
        XCTAssertEqual(persisted, TelemetryLogLevel.info.rawValue, "Persisted scenario level should survive endSession")
    }

    func testDisableTelemetryDeletesOrphanClientRecords() async throws {
        let cloudKit = MockCloudKitClient()
        let store = InMemoryTelemetrySettingsStore()
        _ = await store.save(
            TelemetrySettings(
                telemetryRequested: true,
                telemetrySendingEnabled: true,
                clientIdentifier: "current-client"
            )
        )

        // Current client record
        _ = try await cloudKit.createTelemetryClient(
            clientId: "current-client",
            created: .now,
            isEnabled: true
        )
        // Orphan from a previous failed session with a different client code
        _ = try await cloudKit.createTelemetryClient(
            clientId: "old-orphan-client",
            created: .now,
            isEnabled: false
        )

        let allClientsBefore = await cloudKit.telemetryClients()
        XCTAssertEqual(allClientsBefore.count, 2)

        let service = TelemetryLifecycleService(
            settingsStore: store,
            cloudKitClient: cloudKit,
            identifierGenerator: FixedIdentifierGenerator(identifier: "current-client"),
            configuration: .init(containerIdentifier: "iCloud.test.container"),
            logger: SpyTelemetryLogger(),
            syncCoordinator: TelemetrySettingsSyncCoordinator(backupClient: MockBackupClient()),
            subscriptionManager: MockSubscriptionManager()
        )

        await service.disableTelemetry()

        let allClientsAfter = await cloudKit.telemetryClients()
        XCTAssertEqual(allClientsAfter.count, 0, "Both current and orphan client records should be deleted")
    }

    func testDisableTelemetryCleansUpAllScenarioState() async throws {
        let cloudKit = MockCloudKitClient()
        let store = InMemoryTelemetrySettingsStore()
        _ = await store.save(
            TelemetrySettings(
                telemetryRequested: true,
                telemetrySendingEnabled: true,
                clientIdentifier: "scenario-cleanup"
            )
        )
        _ = try await cloudKit.createTelemetryClient(
            clientId: "scenario-cleanup",
            created: .now,
            isEnabled: true
        )
        let scenarioStore = InMemoryScenarioStore()

        let service = TelemetryLifecycleService(
            settingsStore: store,
            cloudKitClient: cloudKit,
            identifierGenerator: FixedIdentifierGenerator(identifier: "scenario-cleanup"),
            configuration: .init(containerIdentifier: "iCloud.test.container"),
            logger: SpyTelemetryLogger(),
            syncCoordinator: TelemetrySettingsSyncCoordinator(backupClient: MockBackupClient()),
            subscriptionManager: MockSubscriptionManager(),
            scenarioStore: scenarioStore
        )

        _ = await service.reconcile()
        try await service.registerScenarios(["NetworkRequests", "DataSync"])
        try await service.setScenarioDiagnosticLevel("NetworkRequests", level: TelemetryLogLevel.info.rawValue)
        try await service.setScenarioDiagnosticLevel("DataSync", level: TelemetryLogLevel.debug.rawValue)

        // Verify scenarios exist before disable
        let preScenarios = await cloudKit.scenarioList()
        XCTAssertEqual(preScenarios.count, 2)
        let prePersisted = await scenarioStore.loadAllLevels()
        XCTAssertEqual(prePersisted.count, 2)

        await service.disableTelemetry()

        // CloudKit scenarios should be deleted
        let postScenarios = await cloudKit.scenarioList()
        XCTAssertTrue(postScenarios.isEmpty, "CloudKit scenarios should be deleted on disable")

        // In-memory state should be cleared
        XCTAssertTrue(service.scenarioStates.isEmpty, "In-memory scenario states should be cleared")

        // Local persisted scenario levels should also be cleared
        let postPersisted = await scenarioStore.loadAllLevels()
        XCTAssertTrue(postPersisted.isEmpty, "Persisted scenario levels should be cleared on disable")
    }

    func testSetScenarioLevelCommandUpdatesState() async throws {
        let cloudKit = MockCloudKitClient()
        let store = InMemoryTelemetrySettingsStore()
        _ = await store.save(
            TelemetrySettings(
                telemetryRequested: true,
                telemetrySendingEnabled: true,
                clientIdentifier: "cmd-scenario-test"
            )
        )
        _ = try await cloudKit.createTelemetryClient(
            clientId: "cmd-scenario-test",
            created: .now,
            isEnabled: true
        )
        let scenarioStore = InMemoryScenarioStore()

        // Create a pending setScenarioLevel command
        _ = try await cloudKit.createCommand(
            TelemetryCommandRecord(
                clientId: "cmd-scenario-test",
                action: .setScenarioLevel,
                scenarioName: "NetworkRequests",
                diagnosticLevel: TelemetryLogLevel.debug.rawValue
            )
        )

        let service = TelemetryLifecycleService(
            settingsStore: store,
            cloudKitClient: cloudKit,
            identifierGenerator: FixedIdentifierGenerator(identifier: "cmd-scenario-test"),
            configuration: .init(containerIdentifier: "iCloud.test.container"),
            logger: SpyTelemetryLogger(),
            syncCoordinator: TelemetrySettingsSyncCoordinator(backupClient: MockBackupClient()),
            subscriptionManager: MockSubscriptionManager(),
            scenarioStore: scenarioStore
        )

        _ = await service.reconcile()

        // Register scenarios so the service knows about them
        try await service.registerScenarios(["NetworkRequests"])

        // Process the pending command
        try await Task.sleep(for: .milliseconds(100))

        // The setScenarioLevel command should have been processed during reconcile
        let commands = await cloudKit.fetchAllCommands()
        let cmd = try XCTUnwrap(commands.first)
        XCTAssertEqual(cmd.action, .setScenarioLevel)
        XCTAssertEqual(cmd.scenarioName, "NetworkRequests")
        XCTAssertEqual(cmd.diagnosticLevel, TelemetryLogLevel.debug.rawValue)
    }

    func testScenarioCommandWithoutNameMarkedFailed() async throws {
        let cloudKit = MockCloudKitClient()
        let store = InMemoryTelemetrySettingsStore()
        _ = await store.save(
            TelemetrySettings(
                telemetryRequested: true,
                telemetrySendingEnabled: true,
                clientIdentifier: "cmd-no-name"
            )
        )
        _ = try await cloudKit.createTelemetryClient(
            clientId: "cmd-no-name",
            created: .now,
            isEnabled: true
        )

        // Create a command without scenarioName
        _ = try await cloudKit.createCommand(
            TelemetryCommandRecord(
                clientId: "cmd-no-name",
                action: .setScenarioLevel,
                scenarioName: nil,
                diagnosticLevel: TelemetryLogLevel.debug.rawValue
            )
        )

        let service = TelemetryLifecycleService(
            settingsStore: store,
            cloudKitClient: cloudKit,
            identifierGenerator: FixedIdentifierGenerator(identifier: "cmd-no-name"),
            configuration: .init(containerIdentifier: "iCloud.test.container"),
            logger: SpyTelemetryLogger(),
            syncCoordinator: TelemetrySettingsSyncCoordinator(backupClient: MockBackupClient()),
            subscriptionManager: MockSubscriptionManager()
        )

        _ = await service.reconcile()
        try await Task.sleep(for: .milliseconds(100))

        let commands = await cloudKit.fetchAllCommands()
        let cmd = try XCTUnwrap(commands.first)
        XCTAssertEqual(cmd.status, .failed, "Scenario command without scenarioName should be marked failed")
        XCTAssertNotNil(cmd.errorMessage)
    }

    /// Uses the REAL TelemetryLogger (not the spy) so regressions in the
    /// actual logger code are caught by this test.
    func testEventsRejectedAfterDisableTelemetry() async throws {
        let cloudKit = MockCloudKitClient()
        let store = InMemoryTelemetrySettingsStore()
        _ = await store.save(
            TelemetrySettings(
                telemetryRequested: true,
                telemetrySendingEnabled: true,
                clientIdentifier: "event-reject-test"
            )
        )
        _ = try await cloudKit.createTelemetryClient(
            clientId: "event-reject-test",
            created: .now,
            isEnabled: true
        )

        // Use the real TelemetryLogger backed by the mock CloudKit client
        let realLogger = TelemetryLogger(
            configuration: .init(batchSize: 10, flushInterval: 60, maxRetries: 1),
            client: cloudKit
        )
        let service = TelemetryLifecycleService(
            settingsStore: store,
            cloudKitClient: cloudKit,
            identifierGenerator: FixedIdentifierGenerator(identifier: "event-reject-test"),
            configuration: .init(containerIdentifier: "iCloud.test.container"),
            logger: realLogger,
            syncCoordinator: TelemetrySettingsSyncCoordinator(backupClient: MockBackupClient()),
            subscriptionManager: MockSubscriptionManager()
        )

        // Reconcile to activate the logger
        _ = await service.reconcile()
        try await Task.sleep(for: .milliseconds(100))

        // Log an event while enabled — should be accepted
        service.telemetryLogger.logEvent(name: "before_disable")
        try await Task.sleep(for: .milliseconds(50))
        await realLogger.flush()

        let preDisableCount = try await cloudKit.countRecords()
        XCTAssertEqual(preDisableCount, 1, "Event logged while enabled should reach CloudKit")

        // Disable telemetry — this calls setEnabled(false) then shutdown() on the real logger
        await service.disableTelemetry()

        // countRecords is 0 now because disableTelemetry deletes all events
        let postCleanupCount = try await cloudKit.countRecords()
        XCTAssertEqual(postCleanupCount, 0, "disableTelemetry should delete all events")

        // Log events after disable — the real logger must reject these
        service.telemetryLogger.logEvent(name: "after_disable_1")
        service.telemetryLogger.logEvent(name: "after_disable_2")
        try await Task.sleep(for: .milliseconds(50))
        await realLogger.flush()

        let postDisableCount = try await cloudKit.countRecords()
        XCTAssertEqual(postDisableCount, 0, "Events logged after disable must not reach CloudKit")
    }

    func testScenariosReregisteredAfterDisableAndReactivate() async throws {
        let cloudKit = MockCloudKitClient()
        let store = InMemoryTelemetrySettingsStore()
        _ = await store.save(
            TelemetrySettings(
                telemetryRequested: true,
                telemetrySendingEnabled: true,
                clientIdentifier: "reregister-test"
            )
        )
        _ = try await cloudKit.createTelemetryClient(
            clientId: "reregister-test",
            created: .now,
            isEnabled: true
        )
        let scenarioStore = InMemoryScenarioStore()

        let service = TelemetryLifecycleService(
            settingsStore: store,
            cloudKitClient: cloudKit,
            identifierGenerator: FixedIdentifierGenerator(identifier: "reregister-test"),
            configuration: .init(containerIdentifier: "iCloud.test.container"),
            logger: SpyTelemetryLogger(),
            syncCoordinator: TelemetrySettingsSyncCoordinator(backupClient: MockBackupClient()),
            subscriptionManager: MockSubscriptionManager(),
            scenarioStore: scenarioStore
        )

        _ = await service.reconcile()

        // Register scenarios
        try await service.registerScenarios(["NetworkRequests", "DataSync"])
        let firstCount = await cloudKit.scenarioList().count
        XCTAssertEqual(firstCount, 2, "Scenarios should be registered initially")

        // Disable telemetry — should delete all scenarios
        await service.disableTelemetry()
        let afterDisableCount = await cloudKit.scenarioList().count
        XCTAssertEqual(afterDisableCount, 0, "Scenarios should be deleted on disable")

        // Simulate re-activation via requestDiagnostics flow:
        // Re-create the client record (simulating admin enabling)
        _ = try await cloudKit.createTelemetryClient(
            clientId: "reregister-test",
            created: .now,
            isEnabled: true
        )
        let command = TelemetryCommandRecord(
            clientId: "reregister-test",
            action: .activate
        )
        let savedCommand = try await cloudKit.createCommand(command)
        await service.requestDiagnostics()

        // Give async processing time
        try await Task.sleep(for: .milliseconds(100))

        // Scenarios should be re-registered
        let afterReactivateCount = await cloudKit.scenarioList().count
        XCTAssertEqual(afterReactivateCount, 2, "Scenarios should be re-registered after re-activation")

        let scenarioNames = await cloudKit.scenarioList().map(\.scenarioName).sorted()
        XCTAssertEqual(scenarioNames, ["DataSync", "NetworkRequests"])
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
    private(set) var lastScenarioStates: [String: Int] = [:]
    nonisolated let currentSessionId: String = "test-session-id"

    nonisolated func logEvent(name: String, property1: String?) {
        Task { await register(name: name) }
    }

    nonisolated func logEvent(name: String, scenario: String, level: TelemetryLogLevel, property1: String?) {
        Task { await register(name: name) }
    }

    func updateScenarioStates(_ states: [String: Int]) {
        lastScenarioStates = states
    }

    func activate(enabled: Bool) async {
        isActivated = true
        isEnabled = enabled
        didShutdown = false
    }

    func setEnabled(_ enabled: Bool) async {
        isEnabled = enabled
    }

    func flush() async {}

    func shutdown() async {
        didShutdown = true
        isEnabled = false
    }

    private func register(name: String) {
        guard isEnabled, !didShutdown else { return }
        events.append(name)
    }
}

private actor MockCloudKitClient: CloudKitClientProtocol {
    private var records: [CKRecord] = []
    private var clients: [TelemetryClientRecord] = []
    private var commands: [TelemetryCommandRecord] = []
    private var scenarios: [TelemetryScenarioRecord] = []
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
            scenarioName: command.scenarioName,
            diagnosticLevel: command.diagnosticLevel,
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

    // MARK: - Scenario Methods

    func createScenarios(_ newScenarios: [TelemetryScenarioRecord]) async throws -> [TelemetryScenarioRecord] {
        let saved = newScenarios.map { scenario in
            TelemetryScenarioRecord(
                recordID: CKRecord.ID(recordName: UUID().uuidString),
                clientId: scenario.clientId,
                scenarioName: scenario.scenarioName,
                diagnosticLevel: scenario.diagnosticLevel,
                created: scenario.created
            )
        }
        scenarios.append(contentsOf: saved)
        return saved
    }

    func fetchScenarios(forClient clientId: String?) async throws -> [TelemetryScenarioRecord] {
        if let clientId {
            return scenarios.filter { $0.clientId == clientId }
        }
        return scenarios
    }

    func updateScenario(_ scenario: TelemetryScenarioRecord) async throws -> TelemetryScenarioRecord {
        guard let index = scenarios.firstIndex(where: { $0.recordID == scenario.recordID }) else {
            throw TelemetryScenarioRecord.Error.missingRecordID
        }
        scenarios[index] = scenario
        return scenario
    }

    func deleteScenarios(forClient clientId: String?) async throws -> Int {
        if let clientId {
            let matching = scenarios.filter { $0.clientId == clientId }
            scenarios.removeAll { $0.clientId == clientId }
            return matching.count
        } else {
            let count = scenarios.count
            scenarios.removeAll()
            return count
        }
    }

    func createScenarioSubscription() async throws -> CKSubscription.ID {
        "TelemetryScenario-All"
    }

    func scenarioList() async -> [TelemetryScenarioRecord] {
        scenarios
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

private actor MockBackupClient: CloudKitSettingsBackupClientProtocol {
    private(set) var loadCallCount = 0

    func saveSettings(_ settings: TelemetrySettings) async throws {}
    func loadSettings() async throws -> TelemetrySettings? {
        loadCallCount += 1
        return nil
    }
    func clearSettings() async throws {}
}

private actor InMemoryScenarioStore: TelemetryScenarioStoring {
    private var levels: [String: Int] = [:]

    func loadLevel(for scenarioName: String) async -> Int? {
        levels[scenarioName]
    }

    func loadAllLevels() async -> [String: Int] {
        levels
    }

    func saveLevel(for scenarioName: String, diagnosticLevel: Int) async {
        levels[scenarioName] = diagnosticLevel
    }

    func removeState(for scenarioName: String) async {
        levels.removeValue(forKey: scenarioName)
    }

    func removeAllStates() async {
        levels.removeAll()
    }
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
