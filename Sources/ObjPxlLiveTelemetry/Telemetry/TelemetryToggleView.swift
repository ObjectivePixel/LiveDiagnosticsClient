import SwiftUI

/// A view for controlling telemetry settings, designed to be embedded in a Form or List.
///
/// Usage:
/// ```swift
/// Form {
///     TelemetryToggleView(lifecycle: telemetryService)
/// }
/// ```
public struct TelemetryToggleView: View {
    private let lifecycle: TelemetryLifecycleService
    @State private var viewState: ViewState = .idle
    @State private var isTelemetryRequested = false
    @State private var didBootstrap = false
    @State private var showClearConfirmation = false

    public init(lifecycle: TelemetryLifecycleService) {
        self.lifecycle = lifecycle
    }

    public var body: some View {
        Section {
            Toggle(isOn: $isTelemetryRequested) {
                Label("Share Diagnostics", systemImage: "antenna.radiowaves.left.and.right")
            }
            .onChange(of: isTelemetryRequested) { oldValue, newValue in
                guard oldValue != newValue, didBootstrap else { return }
                Task { await handleToggleChange(newValue) }
            }
            .disabled(viewState.isBusy)

            TelemetryStatusRow(
                viewState: viewState,
                status: lifecycle.status,
                message: lifecycle.statusMessage
            )

            if let identifier = lifecycle.settings.clientIdentifier,
               lifecycle.settings.telemetryRequested {
                LabeledContent {
                    Text(identifier)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    #if !os(watchOS)
                        .textSelection(.enabled)
                    #endif
                } label: {
                    Label("Client ID", systemImage: "person.text.rectangle")
                }

                let sessionId = lifecycle.telemetryLogger.currentSessionId
                if !sessionId.isEmpty {
                    LabeledContent {
                        Text(sessionId)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        #if !os(watchOS)
                            .textSelection(.enabled)
                        #endif
                    } label: {
                        Label("Session ID", systemImage: "clock.badge.checkmark")
                    }
                }
            }
        } header: {
            Text("Telemetry")
        } footer: {
            Text("Share diagnostic data to help improve the app. Data is transmitted securely via CloudKit.")
        }

        Section {
            Button {
                Task { await reconcile() }
            } label: {
                HStack {
                    Label("Sync Status", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if viewState == .syncing {
                        ProgressView()
                    }
                }
            }
            .disabled(viewState.isBusy)

            Button(role: .destructive) {
                showClearConfirmation = true
            } label: {
                Label("Clear Telemetry Data", systemImage: "trash")
            }
            .disabled(viewState.isBusy)
            .confirmationDialog(
                "Clear Telemetry Data?",
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear Data", role: .destructive) {
                    Task { await disableTelemetry() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will disable telemetry and remove your client registration. This action cannot be undone.")
            }
        }
        .task {
            await bootstrap()
        }
        .onChange(of: lifecycle.settings.telemetryRequested) { _, newValue in
            isTelemetryRequested = newValue
        }
    }
}

private extension TelemetryToggleView {
    func bootstrap() async {
        viewState = .loading
        _ = await lifecycle.startup()
        isTelemetryRequested = lifecycle.settings.telemetryRequested
        didBootstrap = true
        settleViewState()
    }

    func handleToggleChange(_ isEnabled: Bool) async {
        viewState = .syncing
        if isEnabled {
            _ = await lifecycle.enableTelemetry()
        } else {
            _ = await lifecycle.disableTelemetry()
        }
        settleViewState()
    }

    func reconcile() async {
        viewState = .syncing
        _ = await lifecycle.reconcile()
        settleViewState()
    }

    func disableTelemetry() async {
        viewState = .syncing
        _ = await lifecycle.disableTelemetry()
        settleViewState()
    }

    func settleViewState() {
        if case .error(let message) = lifecycle.status {
            viewState = .error(message)
        } else {
            viewState = .idle
        }
    }
}

private enum ViewState: Equatable {
    case idle
    case loading
    case syncing
    case error(String)

    var isBusy: Bool {
        switch self {
        case .loading, .syncing:
            return true
        case .idle, .error:
            return false
        }
    }
}

private struct TelemetryStatusRow: View {
    var viewState: ViewState
    var status: TelemetryLifecycleService.Status
    var message: String?

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                Text(statusTitle)
                    .foregroundStyle(statusColor)
                statusIcon
            }
        } label: {
            Label("Status", systemImage: "info.circle")
        }

        if let message, !message.isEmpty {
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }

        if case .error(let detail) = viewState {
            Text(detail)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch viewState {
        case .idle:
            Image(systemName: statusImageName)
                .foregroundStyle(statusColor)
                .imageScale(.small)
        case .loading, .syncing:
            ProgressView()
                .controlSize(.small)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .imageScale(.small)
        }
    }

    private var statusImageName: String {
        switch status {
        case .enabled:
            return "checkmark.circle.fill"
        case .disabled:
            return "minus.circle.fill"
        case .pendingApproval:
            return "clock.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        default:
            return "circle.fill"
        }
    }

    private var statusColor: Color {
        switch status {
        case .enabled:
            return .green
        case .disabled:
            return .secondary
        case .pendingApproval:
            return .orange
        case .error:
            return .red
        default:
            return .secondary
        }
    }

    private var statusTitle: String {
        switch status {
        case .idle:
            return "Ready"
        case .loading:
            return "Loading…"
        case .syncing:
            return "Syncing…"
        case .enabled:
            return "Active"
        case .disabled:
            return "Disabled"
        case .pendingApproval:
            return "Pending"
        case .error:
            return "Error"
        }
    }
}

#Preview {
    Form {
        TelemetryToggleView(
            lifecycle: TelemetryLifecycleService(
                configuration: .init(containerIdentifier: "iCloud.preview.telemetry")
            )
        )
    }
}
