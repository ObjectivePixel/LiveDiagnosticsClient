import SwiftUI

public struct TelemetryToggleView: View {
    @Environment(\.telemetryLifecycle) private var lifecycle
    @State private var viewState: ViewState = .idle
    @State private var isTelemetryRequested = false
    @State private var didBootstrap = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading) {
            TelemetryToggleHeader()

            Toggle(isOn: $isTelemetryRequested) {
                Label("Share diagnostics", systemImage: "antenna.radiowaves.left.and.right")
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

            if let identifier = lifecycle.settings.clientIdentifier, lifecycle.settings.telemetryRequested {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Client ID")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(identifier)
                            .textSelection(.enabled)
                    }
                } icon: {
                    Image(systemName: "person.text.rectangle")
                }
            }

            HStack {
                Button("Sync Status", systemImage: "arrow.clockwise") {
                    Task { await reconcile() }
                }
                .buttonStyle(.bordered)
                .disabled(viewState.isBusy)

                Button("Clear Telemetry", systemImage: "trash") {
                    Task { await disableTelemetry() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(viewState.isBusy)
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

private struct TelemetryToggleHeader: View {
    var body: some View {
        VStack(alignment: .leading) {
            Text("Telemetry")
                .font(.title2)
                .bold()
            Text("Control diagnostics collection and keep CloudKit in sync.")
                .foregroundStyle(.secondary)
        }
    }
}

private struct TelemetryStatusRow: View {
    var viewState: ViewState
    var status: TelemetryLifecycleService.Status
    var message: String?

    var body: some View {
        HStack {
            switch viewState {
            case .idle:
                Image(systemName: "checkmark.seal")
                    .foregroundStyle(.green)
            case .loading, .syncing:
                ProgressView()
            case .error:
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .bold()
                if let message {
                    Text(message)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if case .error(let detail) = viewState {
                    Text(detail)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var statusTitle: String {
        switch status {
        case .idle:
            return "Idle"
        case .loading:
            return "Loading telemetry"
        case .syncing:
            return "Syncing"
        case .enabled:
            return "Telemetry sending"
        case .disabled:
            return "Telemetry disabled"
        case .error:
            return "Error"
        }
    }
}

#Preview {
    TelemetryToggleView()
        .environment(\.telemetryLifecycle, TelemetryLifecycleService())
        .padding()
}
