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
        print("📥 [CommandProcessor] Fetching pending commands for clientId: \(clientId)")
        do {
            let commands = try await cloudKitClient.fetchPendingCommands(for: clientId)
            print("📥 [CommandProcessor] Found \(commands.count) pending command(s)")
            for command in commands {
                print("📥 [CommandProcessor] Processing command: \(command.commandId) action=\(command.action.rawValue)")
                await processCommand(command)
            }
        } catch {
            print("❌ [CommandProcessor] Failed to fetch pending commands: \(error)")
        }
    }

    public func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) async -> Bool {
        print("📲 [CommandProcessor] Received remote notification")
        print("📲 [CommandProcessor] userInfo: \(userInfo)")

        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else {
            print("⚠️ [CommandProcessor] Could not parse CKNotification from userInfo")
            return false
        }

        print("📲 [CommandProcessor] CKNotification type: \(notification.notificationType.rawValue), subscriptionID: \(notification.subscriptionID ?? "nil")")

        guard notification.subscriptionID?.hasPrefix("TelemetryCommand-") == true else {
            print("⚠️ [CommandProcessor] Notification subscriptionID does not match TelemetryCommand prefix, ignoring")
            return false
        }

        print("✅ [CommandProcessor] Valid command notification, processing commands...")
        await processCommands()
        return true
    }

    private func processCommand(_ command: TelemetryCommandRecord) async {
        guard let recordID = command.recordID else {
            print("❌ [CommandProcessor] Command \(command.commandId) missing recordID, skipping")
            return
        }

        print("🔄 [CommandProcessor] Executing command \(command.commandId): \(command.action.rawValue)")
        do {
            switch command.action {
            case .enable:
                print("🔄 [CommandProcessor] Calling onEnable handler...")
                try await onEnable()
            case .disable:
                print("🔄 [CommandProcessor] Calling onDisable handler...")
                try await onDisable()
            case .deleteEvents:
                print("🔄 [CommandProcessor] Calling onDeleteEvents handler...")
                try await onDeleteEvents()
            }

            print("✅ [CommandProcessor] Command \(command.commandId) executed successfully, updating status...")
            // Mark command as executed
            _ = try await cloudKitClient.updateCommandStatus(
                recordID: recordID,
                status: .executed,
                executedAt: .now,
                errorMessage: nil
            )
            print("✅ [CommandProcessor] Command \(command.commandId) marked as executed")
        } catch {
            print("❌ [CommandProcessor] Command \(command.commandId) failed: \(error)")
            // Mark command as failed
            do {
                _ = try await cloudKitClient.updateCommandStatus(
                    recordID: recordID,
                    status: .failed,
                    executedAt: .now,
                    errorMessage: error.localizedDescription
                )
                print("⚠️ [CommandProcessor] Command \(command.commandId) marked as failed")
            } catch {
                print("❌ [CommandProcessor] Failed to update command status to failed: \(error)")
            }
        }
    }
}
