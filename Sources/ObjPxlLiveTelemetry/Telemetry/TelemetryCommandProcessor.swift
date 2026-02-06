import CloudKit
import Foundation

public actor TelemetryCommandProcessor {
    public typealias EnableHandler = @Sendable () async throws -> Void
    public typealias DisableHandler = @Sendable () async throws -> Void
    public typealias DeleteEventsHandler = @Sendable () async throws -> Void

    private let cloudKitClient: CloudKitClientProtocol
    private let clientId: String
    private let onEnable: EnableHandler
    private let onDisable: DisableHandler
    private let onDeleteEvents: DeleteEventsHandler

    public init(
        cloudKitClient: CloudKitClientProtocol,
        clientId: String,
        onEnable: @escaping EnableHandler,
        onDisable: @escaping DisableHandler,
        onDeleteEvents: @escaping DeleteEventsHandler
    ) {
        self.cloudKitClient = cloudKitClient
        self.clientId = clientId
        self.onEnable = onEnable
        self.onDisable = onDisable
        self.onDeleteEvents = onDeleteEvents
    }

    public func processCommands() async {
        do {
            let commands = try await cloudKitClient.fetchPendingCommands(for: clientId)
            for command in commands {
                await processCommand(command)
            }
        } catch {
            print("❌ Failed to fetch pending commands: \(error)")
        }
    }

    public func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) async -> Bool {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
            return false
        }

        guard notification.subscriptionID?.hasPrefix("TelemetryCommand-") == true else {
            return false
        }

        await processCommands()
        return true
    }

    private func processCommand(_ command: TelemetryCommandRecord) async {
        guard let recordID = command.recordID else {
            print("❌ Command missing recordID, skipping")
            return
        }

        do {
            switch command.action {
            case .enable:
                try await onEnable()
            case .disable:
                try await onDisable()
            case .deleteEvents:
                try await onDeleteEvents()
            }

            // Mark command as executed
            _ = try await cloudKitClient.updateCommandStatus(
                recordID: recordID,
                status: .executed,
                executedAt: .now,
                errorMessage: nil
            )
        } catch {
            // Mark command as failed
            do {
                _ = try await cloudKitClient.updateCommandStatus(
                    recordID: recordID,
                    status: .failed,
                    executedAt: .now,
                    errorMessage: error.localizedDescription
                )
            } catch {
                print("❌ Failed to update command status to failed: \(error)")
            }
        }
    }
}
