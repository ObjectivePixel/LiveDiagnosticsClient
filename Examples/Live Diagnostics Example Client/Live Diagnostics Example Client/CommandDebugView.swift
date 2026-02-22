//
//  CommandDebugView.swift
//  Live Diagnostics Example Client
//
//  Debug view to help diagnose command queue issues.
//

import SwiftUI
import ObjPxlLiveTelemetry

struct CommandDebugView: View {
    let lifecycle: TelemetryLifecycleService
    @State private var debugLog: [DebugLogEntry] = []
    @State private var isPolling = false
    @State private var lastPollResult: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Command Queue Debug")
                .font(.headline)

            // Status section
            GroupBox("Status") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Lifecycle Status:")
                            .foregroundStyle(.secondary)
                        Text(statusDescription)
                            .bold()
                    }

                    if let clientId = lifecycle.settings.clientIdentifier {
                        HStack {
                            Text("Client ID:")
                                .foregroundStyle(.secondary)
                            Text(clientId)
                                .font(.caption)
                                .monospaced()
                        }
                    }

                    HStack {
                        Text("Telemetry Requested:")
                            .foregroundStyle(.secondary)
                        Text(lifecycle.settings.telemetryRequested ? "Yes" : "No")
                            .foregroundStyle(lifecycle.settings.telemetryRequested ? .green : .red)
                    }

                    HStack {
                        Text("Sending Enabled:")
                            .foregroundStyle(.secondary)
                        Text(lifecycle.settings.telemetrySendingEnabled ? "Yes" : "No")
                            .foregroundStyle(lifecycle.settings.telemetrySendingEnabled ? .green : .red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Actions section
            GroupBox("Actions") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Button("Poll Commands Now", systemImage: "arrow.down.circle") {
                            pollCommands()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isPolling)

                        if isPolling {
                            ProgressView()
                        }
                    }

                    Button("Request Diagnostics", systemImage: "antenna.radiowaves.left.and.right") {
                        Task {
                            addLog("Requesting diagnostics...")
                            await lifecycle.requestDiagnostics()
                            addLog("Request complete. Status: \(statusDescription)")
                        }
                    }
                    .buttonStyle(.bordered)

                    Button("Trigger Reconcile", systemImage: "arrow.triangle.2.circlepath") {
                        Task {
                            addLog("Triggering reconcile...")
                            _ = await lifecycle.reconcile()
                            addLog("Reconcile complete. Status: \(statusDescription)")
                        }
                    }
                    .buttonStyle(.bordered)

                    if let result = lastPollResult {
                        Text(result)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Log section
            GroupBox("Debug Log") {
                VStack(alignment: .leading, spacing: 4) {
                    if debugLog.isEmpty {
                        Text("No log entries yet. Use buttons above to trigger actions.")
                            .foregroundStyle(.tertiary)
                            .font(.caption)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(debugLog.reversed()) { entry in
                                    HStack(alignment: .top) {
                                        Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .monospacedDigit()
                                        Text(entry.message)
                                            .font(.caption)
                                            .foregroundStyle(entry.isError ? .red : .primary)
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 200)
                    }

                    if !debugLog.isEmpty {
                        Button("Clear Log", systemImage: "trash") {
                            debugLog.removeAll()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("Check Xcode console for detailed [CommandProcessor], [LifecycleService], and [SubscriptionManager] logs.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var statusDescription: String {
        switch lifecycle.status {
        case .idle:
            return "Idle"
        case .loading:
            return "Loading"
        case .syncing:
            return "Syncing"
        case .enabled:
            return "Enabled"
        case .disabled:
            return "Disabled"
        case .pendingApproval:
            return "Pending Approval"
        case .noRegistration:
            return "No Registration"
        case .error(let message):
            return "Error: \(message)"
        }
    }

    private func pollCommands() {
        guard let clientId = lifecycle.settings.clientIdentifier else {
            addLog("Cannot poll: No client ID", isError: true)
            lastPollResult = "No client ID available"
            return
        }

        isPolling = true
        addLog("Polling commands for client: \(clientId)")

        Task {
            // Trigger a reconcile which will process pending commands
            _ = await lifecycle.reconcile()
            await MainActor.run {
                isPolling = false
                addLog("Poll complete. Check console for details.")
                lastPollResult = "Poll completed at \(Date().formatted(date: .omitted, time: .standard))"
            }
        }
    }

    private func addLog(_ message: String, isError: Bool = false) {
        debugLog.append(DebugLogEntry(message: message, isError: isError))
    }
}

private struct DebugLogEntry: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let message: String
    let isError: Bool
}

#Preview {
    ScrollView {
        CommandDebugView(
            lifecycle: TelemetryLifecycleService(
                configuration: .init(containerIdentifier: "iCloud.preview.telemetry")
            )
        )
        .padding()
    }
}
