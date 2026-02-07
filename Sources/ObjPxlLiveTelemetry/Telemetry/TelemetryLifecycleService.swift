import CloudKit
import Foundation
import Observation

@MainActor
@Observable
public final class TelemetryLifecycleService {
    public enum Status: Equatable {
        case idle
        case loading
        case syncing
        case enabled
        case disabled
        case pendingApproval
        case error(String)
    }

    public enum ReconciliationResult: Equatable {
        case localAndServerEnabled
        case serverEnabledLocalDisabled
        case serverDisabledLocalEnabled
        case allDisabled
        case missingClient
        case pendingApproval
    }

    public struct Configuration: Sendable {
        public var containerIdentifier: String
        public var loggerConfiguration: TelemetryLogger.Configuration

        public init(
            containerIdentifier: String,
            loggerConfiguration: TelemetryLogger.Configuration = .default
        ) {
            self.containerIdentifier = containerIdentifier
            self.loggerConfiguration = loggerConfiguration
        }
    }

    public private(set) var status: Status = .idle
    public private(set) var reconciliation: ReconciliationResult?
    public private(set) var settings: TelemetrySettings = .defaults
    public private(set) var clientRecord: TelemetryClientRecord?
    public private(set) var statusMessage: String?
    public private(set) var isRestorationInProgress = false

    public var telemetryLogger: any TelemetryLogging { logger }

    private let settingsStore: any TelemetrySettingsStoring
    private let cloudKitClient: CloudKitClientProtocol
    private let identifierGenerator: any TelemetryIdentifierGenerating
    private let configuration: Configuration
    private let logger: any TelemetryLogging
    private let syncCoordinator: TelemetrySettingsSyncCoordinator
    private var commandProcessor: TelemetryCommandProcessor?
    private var subscriptionManager: (any TelemetrySubscriptionManaging)?

    public init(
        settingsStore: any TelemetrySettingsStoring = UserDefaultsTelemetrySettingsStore(),
        cloudKitClient: CloudKitClientProtocol? = nil,
        identifierGenerator: any TelemetryIdentifierGenerating = TelemetryIdentifierGenerator(),
        configuration: Configuration,
        logger: (any TelemetryLogging)? = nil,
        syncCoordinator: TelemetrySettingsSyncCoordinator? = nil,
        subscriptionManager: (any TelemetrySubscriptionManaging)? = nil
    ) {
        let resolvedCloudKitClient = cloudKitClient ?? CloudKitClient(containerIdentifier: configuration.containerIdentifier)
        self.settingsStore = settingsStore
        self.cloudKitClient = resolvedCloudKitClient
        self.identifierGenerator = identifierGenerator
        self.configuration = configuration
        self.syncCoordinator = syncCoordinator ?? TelemetrySettingsSyncCoordinator(
            backupClient: CloudKitSettingsBackupClient(containerIdentifier: configuration.containerIdentifier)
        )
        self.subscriptionManager = subscriptionManager ?? TelemetrySubscriptionManager(cloudKitClient: resolvedCloudKitClient)
        if let logger {
            self.logger = logger
        } else {
            let client = CloudKitClient(containerIdentifier: configuration.containerIdentifier)
            self.logger = TelemetryLogger(configuration: configuration.loggerConfiguration, client: client)
        }
    }

    @discardableResult
    public func startup() async -> TelemetrySettings {
        setStatus(.loading, message: "Loading telemetry preferences")

        // Load from UserDefaults (fast)
        let localSettings = await settingsStore.load()
        settings = localSettings

        // Kick off background restoration (non-blocking on telemetry thread)
        isRestorationInProgress = true
        Task {
            await performBackgroundRestore()
        }

        return localSettings
    }

    private func performBackgroundRestore() async {
        let backupResult = await syncCoordinator.restoreSettingsFromBackup()

        await MainActor.run {
            switch backupResult {
            case .restored(let restoredSettings):
                // Use restored settings
                self.settings = restoredSettings
                Task {
                    _ = await self.settingsStore.save(restoredSettings)
                }
            case .fresh, .failed, .pending, .restoring:
                // Use local settings (already set)
                break
            }
        }

        // Now reconcile and activate based on final settings
        if settings.telemetryRequested, let identifier = settings.clientIdentifier {
            _ = await reconcile()

            // Set up command processor and subscription if telemetry is requested
            await setupCommandProcessing(for: identifier)
        } else {
            if settings.telemetryRequested || settings.clientIdentifier != nil {
                settings = await resetAndClearBackup()
            }
            reconciliation = .allDisabled
            setStatus(.disabled, message: "Telemetry disabled")
        }

        // Activate logger with final enabled state
        let shouldBeEnabled = settings.telemetryRequested && settings.telemetrySendingEnabled
        await logger.activate(enabled: shouldBeEnabled)

        await MainActor.run {
            self.isRestorationInProgress = false
        }
    }

    @discardableResult
    public func enableTelemetry() async -> TelemetrySettings {
        setStatus(.syncing, message: "Enabling telemetry…")

        var currentSettings = await settingsStore.load()
        let identifier = currentSettings.clientIdentifier ?? identifierGenerator.generateIdentifier()
        currentSettings.clientIdentifier = identifier
        currentSettings.telemetryRequested = true
        currentSettings.telemetrySendingEnabled = false

        settings = await saveAndBackupSettings(currentSettings)
        await updateLoggerEnabled()

        do {
            let existingClients = try await cloudKitClient.fetchTelemetryClients(clientId: identifier, isEnabled: nil)
            if let existing = existingClients.first {
                // Use existing client record as-is (don't modify isEnabled - only admin tool should do that)
                clientRecord = existing
            } else {
                do {
                    // Create client record with isEnabled = false; admin tool will enable it
                    let pendingRecord = try await cloudKitClient.createTelemetryClient(
                        clientId: identifier,
                        created: .now,
                        isEnabled: false
                    )
                    clientRecord = pendingRecord
                } catch {
                    // Handle various CloudKit conflict errors that indicate record already exists
                    if let ckError = error as? CKError,
                       ckError.code == .serverRecordChanged || ckError.code == .constraintViolation {
                        let recovered = try await recoverExistingClient(identifier: identifier)
                        clientRecord = recovered
                    } else if (error as NSError).domain == CKErrorDomain {
                        // Catch any other CK "record exists" errors by attempting recovery
                        let recovered = try await recoverExistingClient(identifier: identifier)
                        clientRecord = recovered
                    } else {
                        throw error
                    }
                }
            }

            // Only enable local sending if the server has isEnabled = true (set by admin tool)
            let serverEnabled = clientRecord?.isEnabled ?? false
            if serverEnabled {
                currentSettings.telemetrySendingEnabled = true
                settings = await saveAndBackupSettings(currentSettings)
                reconciliation = .localAndServerEnabled
                setStatus(.enabled, message: "Telemetry enabled. Client ID: \(identifier)")
            } else {
                reconciliation = .pendingApproval
                setStatus(.pendingApproval, message: "Telemetry requested. Waiting for admin approval. Client ID: \(identifier)")
            }
            await updateLoggerEnabled()

            // Set up command processing and subscription
            await setupCommandProcessing(for: identifier)
        } catch {
            let description = error.localizedDescription
            reconciliation = nil
            setStatus(.error("Enable failed: \(description)"), message: "Enable failed: \(description)")
        }

        return settings
    }

    @discardableResult
    public func disableTelemetry(reason: ReconciliationResult? = nil) async -> TelemetrySettings {
        setStatus(.syncing, message: "Disabling telemetry…")

        // Unregister subscription first
        await teardownCommandProcessing()

        do {
            if let identifier = settings.clientIdentifier {
                let remoteClients = try await cloudKitClient.fetchTelemetryClients(clientId: identifier, isEnabled: nil)
                for client in remoteClients {
                    if let recordID = client.recordID {
                        try await cloudKitClient.deleteTelemetryClient(recordID: recordID)
                    }
                }
            }
            _ = try await cloudKitClient.deleteAllTelemetryEvents()
        } catch {
            let description = error.localizedDescription
            setStatus(.error("Disable failed: \(description)"), message: "Disable failed: \(description)")
            return settings
        }

        let identifier = settings.clientIdentifier
        clientRecord = nil
        reconciliation = reason ?? .allDisabled
        settings = await resetAndClearBackup()
        await updateLoggerEnabled()
        let message: String
        if let reason, let identifier {
            message = statusMessage(for: reason, identifier: identifier)
        } else {
            message = "Telemetry disabled"
        }
        setStatus(.disabled, message: message)
        return settings
    }

    public func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) async -> Bool {
        print("📲 [LifecycleService] handleRemoteNotification called")
        guard let processor = commandProcessor else {
            print("⚠️ [LifecycleService] No command processor available")
            return false
        }
        print("📲 [LifecycleService] Forwarding to command processor...")
        return await processor.handleRemoteNotification(userInfo)
    }

    @discardableResult
    public func reconcile() async -> ReconciliationResult? {
        setStatus(.syncing, message: "Syncing telemetry…")

        var currentSettings = await settingsStore.load()
        settings = currentSettings
        guard currentSettings.telemetryRequested, let identifier = currentSettings.clientIdentifier else {
            reconciliation = .allDisabled
            await updateLoggerEnabled()
            setStatus(.disabled, message: "Telemetry disabled")
            return reconciliation
        }

        do {
            let clients = try await cloudKitClient.fetchTelemetryClients(clientId: identifier, isEnabled: nil)
            clientRecord = clients.first
            let serverEnabled = clientRecord?.isEnabled ?? false
            let localEnabled = currentSettings.telemetrySendingEnabled

            let outcome: ReconciliationResult

            switch (localEnabled, serverEnabled) {
            case (true, true):
                outcome = .localAndServerEnabled
            case (false, true):
                currentSettings.telemetrySendingEnabled = true
                settings = await saveAndBackupSettings(currentSettings)
                outcome = .serverEnabledLocalDisabled
            case (true, false):
                outcome = .serverDisabledLocalEnabled
                reconciliation = outcome
                _ = await disableTelemetry(reason: outcome)
                return outcome
            case (false, false):
                if clients.isEmpty {
                    // No client record exists - reset everything
                    outcome = .missingClient
                    currentSettings = .defaults
                    clientRecord = nil
                    settings = await resetAndClearBackup()
                } else {
                    // Client exists but not yet enabled by admin - keep requested state
                    outcome = .pendingApproval
                }
            }

            reconciliation = outcome
            let status: Status = switch outcome {
            case .localAndServerEnabled, .serverEnabledLocalDisabled:
                .enabled
            case .pendingApproval:
                .pendingApproval
            default:
                .disabled
            }
            setStatus(status, message: statusMessage(for: outcome, identifier: identifier))
            await updateLoggerEnabled()

            // Set up command processing (skips if already set up for this client)
            if outcome != .missingClient {
                await setupCommandProcessing(for: identifier)
            }

            return outcome
        } catch {
            let description = error.localizedDescription
            setStatus(.error("Reconciliation failed: \(description)"), message: "Reconciliation failed: \(description)")
            return nil
        }
    }
}

private extension TelemetryLifecycleService {
    func setStatus(_ status: Status, message: String?) {
        self.status = status
        statusMessage = message
    }

    func setupCommandProcessing(for clientId: String) async {
        print("🔧 [LifecycleService] Setting up command processing for clientId: \(clientId)")

        // Create command processor with callbacks
        let processor = TelemetryCommandProcessor(
            cloudKitClient: cloudKitClient,
            clientId: clientId,
            onEnable: { [weak self] in
                guard let self else { return }
                print("🎯 [LifecycleService] onEnable callback triggered")
                await self.handleEnableCommand()
            },
            onDisable: { [weak self] in
                guard let self else { return }
                print("🎯 [LifecycleService] onDisable callback triggered")
                await self.handleDisableCommand()
            },
            onDeleteEvents: { [weak self] in
                guard let self else { return }
                print("🎯 [LifecycleService] onDeleteEvents callback triggered")
                try await self.handleDeleteEventsCommand()
            }
        )
        commandProcessor = processor
        print("✅ [LifecycleService] Command processor created")

        // Register subscription (graceful degradation if it fails)
        if let manager = subscriptionManager {
            do {
                print("📡 [LifecycleService] Registering subscription...")
                try await manager.registerSubscription(for: clientId)
                print("✅ [LifecycleService] Subscription registered successfully")
            } catch {
                print("⚠️ [LifecycleService] Failed to register command subscription (push notifications may not work): \(error)")
                // Continue without push - commands will still be processed on reconcile
            }
        } else {
            print("⚠️ [LifecycleService] No subscription manager available")
        }

        // Process any pending commands
        print("📥 [LifecycleService] Processing any pending commands...")
        await processor.processCommands()
        print("✅ [LifecycleService] Command processing setup complete")
    }

    func teardownCommandProcessing() async {
        commandProcessor = nil

        if let manager = subscriptionManager {
            do {
                try await manager.unregisterSubscription()
            } catch {
                print("⚠️ Failed to unregister command subscription: \(error)")
            }
        }
    }

    func handleEnableCommand() async {
        print("✅ [LifecycleService] Handling ENABLE command")
        var currentSettings = await settingsStore.load()
        currentSettings.telemetrySendingEnabled = true
        settings = await saveAndBackupSettings(currentSettings)
        await updateLoggerEnabled()

        // Update client record's isEnabled to true (client owns this record)
        if let recordID = clientRecord?.recordID {
            do {
                print("✅ [LifecycleService] Updating client record isEnabled to true")
                clientRecord = try await cloudKitClient.updateTelemetryClient(
                    recordID: recordID,
                    clientId: nil,
                    created: nil,
                    isEnabled: true
                )
                print("✅ [LifecycleService] Client record updated successfully")
            } catch {
                print("⚠️ [LifecycleService] Failed to update client record isEnabled: \(error)")
            }
        }

        reconciliation = .localAndServerEnabled
        if let identifier = settings.clientIdentifier {
            setStatus(.enabled, message: "Telemetry enabled. Client ID: \(identifier)")
            print("✅ [LifecycleService] Telemetry enabled for client: \(identifier)")
        }
    }

    func handleDisableCommand() async {
        print("🚫 [LifecycleService] Handling DISABLE command")
        _ = await disableTelemetry(reason: .serverDisabledLocalEnabled)
        print("🚫 [LifecycleService] Telemetry disabled")
    }

    func handleDeleteEventsCommand() async throws {
        print("🗑️ [LifecycleService] Handling DELETE_EVENTS command")
        _ = try await cloudKitClient.deleteAllRecords()
        print("🗑️ [LifecycleService] All events deleted")
    }

    func recoverExistingClient(identifier: String) async throws -> TelemetryClientRecord? {
        // Just fetch the existing client as-is (don't modify isEnabled - only admin tool should do that)
        let clients = try await cloudKitClient.fetchTelemetryClients(clientId: identifier, isEnabled: nil)
        return clients.first
    }

    func updateLoggerEnabled() async {
        let shouldBeEnabled = settings.telemetryRequested && settings.telemetrySendingEnabled
        await logger.setEnabled(shouldBeEnabled)
    }

    func saveAndBackupSettings(_ settings: TelemetrySettings) async -> TelemetrySettings {
        let saved = await settingsStore.save(settings)
        // Backup to private CloudKit (fire and forget)
        Task {
            try? await syncCoordinator.backupSettings(settings)
        }
        return saved
    }

    func resetAndClearBackup() async -> TelemetrySettings {
        let reset = await settingsStore.reset()
        // Clear backup from private CloudKit (fire and forget)
        Task {
            try? await syncCoordinator.clearBackup()
        }
        return reset
    }

    func statusMessage(for outcome: ReconciliationResult, identifier: String) -> String {
        switch outcome {
        case .localAndServerEnabled:
            return "Telemetry sending is enabled. Client ID: \(identifier)"
        case .serverEnabledLocalDisabled:
            return "Server expects telemetry. Resuming sending for \(identifier)."
        case .serverDisabledLocalEnabled:
            return "Server disabled telemetry. Local sending stopped."
        case .allDisabled:
            return "Telemetry is disabled."
        case .missingClient:
            return "No client found on server. Telemetry is paused."
        case .pendingApproval:
            return "Telemetry requested. Waiting for admin approval. Client ID: \(identifier)"
        }
    }
}
