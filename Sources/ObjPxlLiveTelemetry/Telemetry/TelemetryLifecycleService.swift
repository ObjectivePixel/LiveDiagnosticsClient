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
        case error(String)
    }

    public enum ReconciliationResult: Equatable {
        case localAndServerEnabled
        case serverEnabledLocalDisabled
        case serverDisabledLocalEnabled
        case allDisabled
        case missingClient
    }

    public struct Configuration: Sendable {
        public var distribution: Distribution
        public var containerIdentifier: String?
        public var loggerConfiguration: TelemetryLogger.Configuration

        public init(
            distribution: Distribution = .debug,
            containerIdentifier: String? = TelemetrySchema.cloudKitContainerIdentifierTelemetry,
            loggerConfiguration: TelemetryLogger.Configuration = .default
        ) {
            self.distribution = distribution
            self.containerIdentifier = containerIdentifier
            self.loggerConfiguration = loggerConfiguration
        }
    }

    public private(set) var status: Status = .idle
    public private(set) var reconciliation: ReconciliationResult?
    public private(set) var settings: TelemetrySettings = .defaults
    public private(set) var clientRecord: TelemetryClientRecord?
    public private(set) var statusMessage: String?

    public var telemetryLogger: any TelemetryLogging { logger }

    private let settingsStore: any TelemetrySettingsStoring
    private let cloudKitClient: CloudKitClientProtocol
    private let identifierGenerator: any TelemetryIdentifierGenerating
    private let configuration: Configuration
    private let loggerFactory: @Sendable () -> any TelemetryLogging
    private var logger: any TelemetryLogging

    public init(
        settingsStore: any TelemetrySettingsStoring = UserDefaultsTelemetrySettingsStore(),
        cloudKitClient: CloudKitClientProtocol? = nil,
        identifierGenerator: any TelemetryIdentifierGenerating = TelemetryIdentifierGenerator(),
        configuration: Configuration = .init(),
        loggerFactory: (@Sendable () -> any TelemetryLogging)? = nil
    ) {
        let resolvedConfiguration = configuration
        self.settingsStore = settingsStore
        self.cloudKitClient = cloudKitClient ?? CloudKitClient(containerIdentifier: resolvedConfiguration.containerIdentifier)
        self.identifierGenerator = identifierGenerator
        self.configuration = resolvedConfiguration
        if let loggerFactory {
            self.loggerFactory = loggerFactory
        } else {
            let configuration = resolvedConfiguration
            self.loggerFactory = {
                let client = CloudKitClient(containerIdentifier: configuration.containerIdentifier)
                return TelemetryLogger(configuration: configuration.loggerConfiguration, client: client)
            }
        }
        logger = NoopTelemetryLogger.shared
    }

    @discardableResult
    public func startup() async -> TelemetrySettings {
        setStatus(.loading, message: "Loading telemetry preferences")
        let loaded = await settingsStore.load()
        settings = loaded
        await refreshLogger()

        guard loaded.telemetryRequested, loaded.clientIdentifier != nil else {
            if loaded.telemetryRequested || loaded.clientIdentifier != nil {
                settings = await settingsStore.reset()
            }
            reconciliation = .allDisabled
            setStatus(.disabled, message: "Telemetry disabled")
            return settings
        }

        _ = await reconcile()
        return settings
    }

    @discardableResult
    public func enableTelemetry() async -> TelemetrySettings {
        setStatus(.syncing, message: "Enabling telemetry…")

        var currentSettings = await settingsStore.load()
        let identifier = currentSettings.clientIdentifier ?? identifierGenerator.generateIdentifier()
        currentSettings.clientIdentifier = identifier
        currentSettings.telemetryRequested = true
        currentSettings.telemetrySendingEnabled = false

        settings = await settingsStore.save(currentSettings)
        await refreshLogger()

        do {
            let existingClients = try await cloudKitClient.fetchTelemetryClients(clientId: identifier, isEnabled: nil)
            if let existing = existingClients.first, let recordID = existing.recordID {
                clientRecord = try await cloudKitClient.updateTelemetryClient(
                    recordID: recordID,
                    clientId: existing.clientId,
                    created: existing.created,
                    isEnabled: true
                )
            } else {
                do {
                    let pendingRecord = try await cloudKitClient.createTelemetryClient(
                        clientId: identifier,
                        created: .now,
                        isEnabled: false
                    )
                    clientRecord = pendingRecord

                    if let recordID = pendingRecord.recordID {
                        clientRecord = try await cloudKitClient.updateTelemetryClient(
                            recordID: recordID,
                            clientId: pendingRecord.clientId,
                            created: pendingRecord.created,
                            isEnabled: true
                        )
                    }
                } catch {
                    if let ckError = error as? CKError, ckError.code == .serverRecordChanged {
                        let recovered = try await recoverExistingClient(identifier: identifier)
                        clientRecord = recovered
                    } else {
                        throw error
                    }
                }
            }

            currentSettings.telemetrySendingEnabled = true
            settings = await settingsStore.save(currentSettings)

            reconciliation = .localAndServerEnabled
            setStatus(.enabled, message: "Telemetry enabled. Client ID: \(identifier)")
            await refreshLogger()
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
        settings = await settingsStore.reset()
        await refreshLogger()
        let message: String
        if let reason, let identifier {
            message = statusMessage(for: reason, identifier: identifier)
        } else {
            message = "Telemetry disabled"
        }
        setStatus(.disabled, message: message)
        return settings
    }

    @discardableResult
    public func reconcile() async -> ReconciliationResult? {
        setStatus(.syncing, message: "Syncing telemetry…")

        var currentSettings = await settingsStore.load()
        settings = currentSettings
        guard currentSettings.telemetryRequested, let identifier = currentSettings.clientIdentifier else {
            reconciliation = .allDisabled
            await refreshLogger()
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
                settings = await settingsStore.save(currentSettings)
                outcome = .serverEnabledLocalDisabled
            case (true, false):
                outcome = .serverDisabledLocalEnabled
                reconciliation = outcome
                _ = await disableTelemetry(reason: outcome)
                return outcome
            case (false, false):
                outcome = clients.isEmpty ? .missingClient : .allDisabled
                currentSettings = .defaults
                clientRecord = nil
                settings = await settingsStore.save(currentSettings)
            }

            reconciliation = outcome
            setStatus(
                settings.telemetrySendingEnabled ? .enabled : .disabled,
                message: statusMessage(for: outcome, identifier: identifier)
            )
            await refreshLogger()
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

    func recoverExistingClient(identifier: String) async throws -> TelemetryClientRecord? {
        let clients = try await cloudKitClient.fetchTelemetryClients(clientId: identifier, isEnabled: nil)
        guard let existing = clients.first, let recordID = existing.recordID else {
            return nil
        }
        return try await cloudKitClient.updateTelemetryClient(
            recordID: recordID,
            clientId: existing.clientId,
            created: existing.created,
            isEnabled: true
        )
    }

    func refreshLogger() async {
        let shouldUseTelemetryLogger = settings.telemetryRequested &&
        settings.telemetrySendingEnabled &&
        configuration.distribution.isDebug

        if shouldUseTelemetryLogger {
            guard logger is NoopTelemetryLogger else { return }
            logger = loggerFactory()
        } else if !(logger is NoopTelemetryLogger) {
            let loggerToShutdown = logger
            logger = NoopTelemetryLogger.shared
            await loggerToShutdown.shutdown()
        }
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
        }
    }
}
