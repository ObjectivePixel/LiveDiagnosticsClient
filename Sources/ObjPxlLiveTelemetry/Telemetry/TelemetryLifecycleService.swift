import CloudKit
import Foundation
import Observation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

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
        case noRegistration
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
    public private(set) var isForceOn = false
    public private(set) var scenarioStates: [String: Int] = [:]
    private var hasStartedUp = false

    public var telemetryLogger: any TelemetryLogging { logger }

    private let settingsStore: any TelemetrySettingsStoring
    private let cloudKitClient: CloudKitClientProtocol
    private let identifierGenerator: any TelemetryIdentifierGenerating
    private let configuration: Configuration
    private let logger: any TelemetryLogging
    private let syncCoordinator: TelemetrySettingsSyncCoordinator
    private var commandProcessor: TelemetryCommandProcessor?
    private var subscriptionManager: (any TelemetrySubscriptionManaging)?
    private let scenarioStore: any TelemetryScenarioStoring
    private var scenarioRecords: [String: TelemetryScenarioRecord] = [:]
    private var pendingScenarioNames: [String]?
    private var registeredScenarioNames: [String] = []

    public init(
        settingsStore: any TelemetrySettingsStoring = UserDefaultsTelemetrySettingsStore(),
        cloudKitClient: CloudKitClientProtocol? = nil,
        identifierGenerator: any TelemetryIdentifierGenerating = TelemetryIdentifierGenerator(),
        configuration: Configuration,
        logger: (any TelemetryLogging)? = nil,
        syncCoordinator: TelemetrySettingsSyncCoordinator? = nil,
        subscriptionManager: (any TelemetrySubscriptionManaging)? = nil,
        scenarioStore: (any TelemetryScenarioStoring)? = nil
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
        self.scenarioStore = scenarioStore ?? UserDefaultsTelemetryScenarioStore()
        if let logger {
            self.logger = logger
        } else {
            self.logger = TelemetryLogger(configuration: configuration.loggerConfiguration, client: resolvedCloudKitClient)
        }
    }

    @discardableResult
    public func startup() async -> TelemetrySettings {
        if hasStartedUp { return settings }

        setStatus(.loading, message: "Loading telemetry preferences")

        // Load from UserDefaults (single read for both cleanup and restore)
        let localSettings = await settingsStore.load()
        settings = localSettings

        // Re-check after the await — another caller may have raced through the
        // same load while we were suspended.  Settings are now populated so the
        // second caller can return safely, but only one should start the
        // background restore.
        if hasStartedUp { return settings }
        hasStartedUp = true

        // Clean up any stale force-on session from a previous build before
        // proceeding with the normal restore path.
        if localSettings.forceOnActive {
            _ = await disableTelemetry()
            return settings
        }

        // Kick off background restoration (non-blocking on telemetry thread)
        isRestorationInProgress = true
        Task {
            await performBackgroundRestore()
        }

        return localSettings
    }

    private func performBackgroundRestore() async {
        // If telemetry was never enabled, skip the CloudKit backup restore entirely
        if !settings.telemetryRequested {
            reconciliation = .allDisabled
            setStatus(.disabled, message: "Telemetry disabled")
            await logger.activate(enabled: false)
            await MainActor.run {
                self.isRestorationInProgress = false
            }
            return
        }

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
        let shouldBeEnabled = settings.telemetryRequested && (settings.telemetrySendingEnabled || isForceOn)
        await logger.activate(enabled: shouldBeEnabled)

        // Register any scenarios that were deferred because clientIdentifier wasn't available.
        // Guard on telemetryRequested — reconcile() may have called disableTelemetry()
        // internally, which resets telemetryRequested to false and cleans up scenarios.
        // Without this check, scenarios would be re-created in CloudKit immediately
        // after being deleted.
        if settings.telemetryRequested, let clientId = settings.clientIdentifier {
            let scenariosToRegister = pendingScenarioNames ?? (registeredScenarioNames.isEmpty ? nil : registeredScenarioNames)
            if let names = scenariosToRegister {
                await performScenarioRegistration(names, clientId: clientId)
            }
        }

        await MainActor.run {
            self.isRestorationInProgress = false
        }
    }

    @discardableResult
    public func enableTelemetry(force: Bool = false) async -> TelemetrySettings {
        setStatus(.syncing, message: "Enabling telemetry…")

        if force {
            isForceOn = true
        }

        var currentSettings = await settingsStore.load()
        let identifier = currentSettings.clientIdentifier ?? identifierGenerator.generateIdentifier()
        currentSettings.clientIdentifier = identifier
        currentSettings.telemetryRequested = true
        currentSettings.telemetrySendingEnabled = force
        if force {
            currentSettings.forceOnActive = true
        }

        settings = await saveAndBackupSettings(currentSettings)
        await updateLoggerEnabled()

        do {
            let existingClients = try await cloudKitClient.fetchTelemetryClients(clientId: identifier, isEnabled: nil)
            if let existing = existingClients.first {
                if force && !existing.isEnabled, let recordID = existing.recordID {
                    // Force mode: update existing record to enabled
                    clientRecord = try await cloudKitClient.updateTelemetryClient(
                        recordID: recordID, clientId: nil, created: nil, isEnabled: true
                    )
                } else {
                    clientRecord = existing
                }
            } else {
                do {
                    // Create client record with isEnabled matching force flag
                    let pendingRecord = try await cloudKitClient.createTelemetryClient(
                        clientId: identifier,
                        created: .now,
                        isEnabled: force
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

            let serverEnabled = clientRecord?.isEnabled ?? false
            if serverEnabled || force {
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

            // Register any deferred or previously-registered scenarios
            let scenariosToRegister = pendingScenarioNames ?? (registeredScenarioNames.isEmpty ? nil : registeredScenarioNames)
            if let names = scenariosToRegister {
                await performScenarioRegistration(names, clientId: identifier)
            }
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
        isForceOn = false

        // 1. Teardown command processing (unregister subscription)
        await teardownCommandProcessing()

        // 2. Stop the logger immediately so no new events are accepted or flushed
        let identifier = settings.clientIdentifier
        await logger.setEnabled(false)
        await logger.shutdown()

        // 3. Reset local state before CloudKit cleanup
        clientRecord = nil
        reconciliation = reason ?? .allDisabled
        settings = await resetAndClearBackup()

        // 4. Delete remote records — each step is independent so one failure
        //    does not prevent cleanup of the others.
        var errors: [String] = []

        // Delete ALL client records, including orphans from previous failed sessions
        do {
            let remoteClients = try await cloudKitClient.fetchTelemetryClients(clientId: nil, isEnabled: nil)
            for client in remoteClients {
                if let recordID = client.recordID {
                    try await cloudKitClient.deleteTelemetryClient(recordID: recordID)
                }
            }
        } catch {
            errors.append("clients: \(error.localizedDescription)")
        }

        do {
            // Pass nil to delete ALL scenarios, including orphans from old client identifiers
            _ = try await cloudKitClient.deleteScenarios(forClient: nil)
        } catch {
            errors.append("scenarios: \(error.localizedDescription)")
        }

        if let identifier {
            do {
                _ = try await cloudKitClient.deleteAllCommands(for: identifier)
            } catch {
                errors.append("commands: \(error.localizedDescription)")
            }
        }

        do {
            _ = try await cloudKitClient.deleteAllTelemetryEvents()
        } catch {
            errors.append("events: \(error.localizedDescription)")
        }

        // Always clean up local state regardless of CloudKit errors
        scenarioRecords.removeAll()
        scenarioStates.removeAll()
        pendingScenarioNames = nil
        await scenarioStore.removeAllStates()
        await pushScenarioStatesToLogger()

        if !errors.isEmpty {
            let detail = errors.joined(separator: "; ")
            setStatus(.error("Disable partially failed: \(detail)"), message: "Disable partially failed: \(detail)")
        } else {
            let message: String
            if let reason, let identifier {
                message = statusMessage(for: reason, identifier: identifier)
            } else {
                message = "Telemetry disabled"
            }
            setStatus(.disabled, message: message)
        }
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

    // MARK: - Scenarios

    public func registerScenarios(_ scenarioNames: [String]) async throws {
        registeredScenarioNames = scenarioNames
        guard let clientId = settings.clientIdentifier,
              settings.telemetryRequested else {
            // No client ID yet or telemetry not active — store for later registration
            pendingScenarioNames = scenarioNames
            // Still load persisted levels so the UI shows something immediately
            var levels: [String: Int] = [:]
            for name in scenarioNames {
                let persisted = await scenarioStore.loadLevel(for: name)
                levels[name] = persisted ?? TelemetryScenarioRecord.levelOff
            }
            scenarioStates = levels
            await pushScenarioStatesToLogger()
            return
        }

        pendingScenarioNames = nil
        await performScenarioRegistration(scenarioNames, clientId: clientId)
    }

    private func performScenarioRegistration(_ scenarioNames: [String], clientId: String) async {
        var levels: [String: Int] = [:]

        // 1. Load local persisted levels for all scenarios
        for name in scenarioNames {
            let persisted = await scenarioStore.loadLevel(for: name)
            levels[name] = persisted ?? TelemetryScenarioRecord.levelOff
        }

        do {
            // 2. Fetch existing scenarios from CloudKit
            let existingScenarios = try await cloudKitClient.fetchScenarios(forClient: clientId)

            // 3. Build lookup by scenarioName
            var existingByName: [String: TelemetryScenarioRecord] = [:]
            for scenario in existingScenarios {
                existingByName[scenario.scenarioName] = scenario
            }

            // 4. Separate into existing and new
            var newRecords: [TelemetryScenarioRecord] = []
            for name in scenarioNames {
                if let existing = existingByName[name] {
                    scenarioRecords[name] = existing
                } else {
                    newRecords.append(TelemetryScenarioRecord(
                        clientId: clientId,
                        scenarioName: name,
                        diagnosticLevel: levels[name] ?? TelemetryScenarioRecord.levelOff
                    ))
                }
            }

            // 5. Only create if there are new scenarios
            if !newRecords.isEmpty {
                let saved = try await cloudKitClient.createScenarios(newRecords)
                for record in saved {
                    scenarioRecords[record.scenarioName] = record
                }
            }
        } catch {
            print("⚠️ [LifecycleService] Failed to register scenarios in CloudKit: \(error)")
        }

        scenarioStates = levels
        await pushScenarioStatesToLogger()
    }

    public func setScenarioDiagnosticLevel(_ scenarioName: String, level: Int) async throws {
        scenarioStates[scenarioName] = level
        await scenarioStore.saveLevel(for: scenarioName, diagnosticLevel: level)

        if var record = scenarioRecords[scenarioName] {
            record.diagnosticLevel = level
            let updated = try await cloudKitClient.updateScenario(record)
            scenarioRecords[scenarioName] = updated
        }

        await pushScenarioStatesToLogger()
    }

    /// Ensures a stable client identifier is persisted locally without touching CloudKit.
    public func generateAndPersistClientIdentifier() async {
        guard settings.clientIdentifier == nil else { return }
        let identifier = identifierGenerator.generateIdentifier()
        var currentSettings = await settingsStore.load()
        currentSettings.clientIdentifier = identifier
        settings = await settingsStore.save(currentSettings)
    }

    /// Viewer-initiated activation: polls for an activate/enable command and processes it.
    public func requestDiagnostics() async {
        guard let clientId = settings.clientIdentifier else {
            setStatus(.error("No client identifier"), message: "Client code not generated.")
            return
        }

        setStatus(.syncing, message: "Checking for activation...")

        do {
            let pendingCommands = try await cloudKitClient.fetchPendingCommands(for: clientId)

            if let activateCommand = pendingCommands.first(where: { $0.action == .activate }) {
                await handleActivateCommand(activateCommand)
            } else if let enableCommand = pendingCommands.first(where: { $0.action == .enable }) {
                await handleActivateCommand(enableCommand)
            } else {
                setStatus(.noRegistration, message: "Not registered.")
            }
        } catch {
            setStatus(.error("Check failed: \(error.localizedDescription)"),
                      message: "Failed to check for activation: \(error.localizedDescription)")
        }
    }

    public func endSession() async throws {
        guard let clientId = settings.clientIdentifier else { return }
        _ = try await cloudKitClient.deleteScenarios(forClient: clientId)
        _ = try await cloudKitClient.deleteAllRecords()
        scenarioRecords.removeAll()
        scenarioStates.removeAll()
        await pushScenarioStatesToLogger()
        // Local scenario persistence intentionally kept
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
                if isForceOn {
                    // Force-on mode: keep enabled regardless of server state
                    outcome = .localAndServerEnabled
                } else {
                    outcome = .serverDisabledLocalEnabled
                    reconciliation = outcome
                    _ = await disableTelemetry(reason: outcome)
                    return outcome
                }
            case (false, false):
                if clients.isEmpty, !isForceOn {
                    // No client record exists - reset session state (identifier preserved)
                    outcome = .missingClient
                    currentSettings = .defaults
                    clientRecord = nil
                    settings = await resetAndClearBackup()
                } else if isForceOn {
                    // Force-on mode: treat as enabled regardless of server state
                    currentSettings.telemetrySendingEnabled = true
                    settings = await saveAndBackupSettings(currentSettings)
                    outcome = .localAndServerEnabled
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
        #if canImport(UIKit) && !os(watchOS)
        UIApplication.shared.registerForRemoteNotifications()
        #elseif canImport(AppKit)
        NSApplication.shared.registerForRemoteNotifications()
        #endif

        print("🔧 [LifecycleService] Setting up command processing for clientId: \(clientId)")

        // Create command processor with callbacks
        let processor = TelemetryCommandProcessor(
            cloudKitClient: cloudKitClient,
            clientId: clientId,
            onActivate: { [weak self] in
                guard let self else { return }
                print("🎯 [LifecycleService] onActivate callback triggered")
                await self.handleActivateCommand()
            },
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
            },
            onSetScenarioLevel: { [weak self] scenarioName, level in
                guard let self else { return }
                print("🎯 [LifecycleService] onSetScenarioLevel callback triggered for '\(scenarioName)' level=\(level)")
                try await self.setScenarioDiagnosticLevel(scenarioName, level: level)
            }
        )
        commandProcessor = processor
        print("✅ [LifecycleService] Command processor created")

        // Register subscription (graceful degradation if it fails)
        if let manager = subscriptionManager {
            do {
                print("📡 [LifecycleService] Registering subscription with manager...")
                try await manager.registerSubscription(for: clientId)
                let subId = await manager.currentSubscriptionID
                print("✅ [LifecycleService] Subscription registered successfully, current ID: \(subId ?? "nil")")
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

    func handleActivateCommand() async {
        print("✅ [LifecycleService] Handling ACTIVATE command (push)")
        await handleEnableCommand()

        // Re-register scenarios after re-enabling
        if let clientId = settings.clientIdentifier, !registeredScenarioNames.isEmpty {
            await performScenarioRegistration(registeredScenarioNames, clientId: clientId)
        }
    }

    func handleActivateCommand(_ command: TelemetryCommandRecord) async {
        guard let clientId = settings.clientIdentifier else { return }

        setStatus(.syncing, message: "Activating telemetry...")

        var currentSettings = await settingsStore.load()
        currentSettings.telemetryRequested = true
        currentSettings.telemetrySendingEnabled = true
        currentSettings.clientIdentifier = clientId
        settings = await saveAndBackupSettings(currentSettings)

        do {
            let existingClients = try await cloudKitClient.fetchTelemetryClients(clientId: clientId, isEnabled: nil)
            if let existing = existingClients.first {
                if !existing.isEnabled, let recordID = existing.recordID {
                    clientRecord = try await cloudKitClient.updateTelemetryClient(
                        recordID: recordID, clientId: nil, created: nil, isEnabled: true
                    )
                } else {
                    clientRecord = existing
                }
            } else {
                clientRecord = try await cloudKitClient.createTelemetryClient(
                    clientId: clientId, created: .now, isEnabled: true
                )
            }

            if let recordID = command.recordID {
                _ = try await cloudKitClient.updateCommandStatus(
                    recordID: recordID, status: .executed, executedAt: .now, errorMessage: nil
                )
            }

            await setupCommandProcessing(for: clientId)
            await logger.activate(enabled: true)

            // Re-register scenarios (uses registeredScenarioNames which survives disable/enable cycles)
            let scenariosToRegister = pendingScenarioNames ?? (registeredScenarioNames.isEmpty ? nil : registeredScenarioNames)
            if let names = scenariosToRegister {
                await performScenarioRegistration(names, clientId: clientId)
            }

            reconciliation = .localAndServerEnabled
            setStatus(.enabled, message: "Telemetry active. Client ID: \(clientId)")
        } catch {
            setStatus(.error("Activation failed: \(error.localizedDescription)"),
                      message: "Activation failed: \(error.localizedDescription)")
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
        let shouldBeEnabled = settings.telemetryRequested && (settings.telemetrySendingEnabled || isForceOn)
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
        // Preserve the stable client identifier — it is generated once per install
        let existingIdentifier = settings.clientIdentifier
        var resetSettings = TelemetrySettings.defaults
        resetSettings.clientIdentifier = existingIdentifier
        let saved = await settingsStore.save(resetSettings)
        // Clear backup from private CloudKit (fire and forget)
        Task {
            try? await syncCoordinator.clearBackup()
        }
        return saved
    }

    func pushScenarioStatesToLogger() async {
        await logger.updateScenarioStates(scenarioStates)
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
