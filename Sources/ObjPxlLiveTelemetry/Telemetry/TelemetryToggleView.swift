import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

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
    @State private var showEndSessionConfirmation = false
    @State private var showCopyConfirmation = false

    public init(lifecycle: TelemetryLifecycleService) {
        self.lifecycle = lifecycle
    }

    public var body: some View {
        Section {
            // 1. Client Code — always shown
            #if os(watchOS)
            VStack(alignment: .leading, spacing: 4) {
                Label("Client Code", systemImage: "person.text.rectangle")
                if clientCode.isEmpty {
                    Text("Generating…")
                        .font(.body.monospaced())
                        .foregroundStyle(.secondary)
                } else {
                    Text(clientCode)
                        .font(.body.monospaced())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            #else
            LabeledContent {
                HStack {
                    if clientCode.isEmpty {
                        Text("Generating…")
                            .font(.body.monospaced())
                            .foregroundStyle(.secondary)
                    } else {
                        Text(clientCode)
                            .font(.body.monospaced())
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button {
                            copyClientCode()
                        } label: {
                            Image(systemName: showCopyConfirmation ? "checkmark.circle.fill" : "doc.on.doc")
                                .foregroundStyle(showCopyConfirmation ? .green : .accentColor)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } label: {
                Label("Client Code", systemImage: "person.text.rectangle")
            }
            #endif

            // 2. Status row — always shown
            TelemetryStatusRow(
                viewState: viewState,
                status: lifecycle.status,
                message: lifecycle.statusMessage,
                scenarioSummary: scenarioSummary
            )

            // 3. Session ID — shown when active
            if isActive {
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

            // 4. Request Diagnostics button — shown when NOT active and not force-on
            if !isActive, !lifecycle.isForceOn {
                HStack {
                    Button {
                        Task { await requestDiagnostics() }
                    } label: {
                        Label("Request Diagnostics", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewState.isBusy)
                    if viewState == .syncing {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }

            // 5. Refresh / End Session buttons — shown when active and not force-on
            if isActive, !lifecycle.isForceOn {
                HStack {
                    Button {
                        Task { await refreshSession() }
                    } label: {
                        Label("Refresh Session", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewState.isBusy)

                    Button(role: .destructive) {
                        showEndSessionConfirmation = true
                    } label: {
                        Label("End Session", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(viewState.isBusy)
                }
                .confirmationDialog(
                    "End Diagnostic Session?",
                    isPresented: $showEndSessionConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("End Session", role: .destructive) {
                        Task { await endSession() }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will disable telemetry and remove your client registration. This action cannot be undone.")
                }
            }
        } header: {
            Text("Telemetry")
        }
        .task {
            await bootstrap()
        }
    }

    private var clientCode: String {
        lifecycle.settings.clientIdentifier ?? ""
    }

    private var isActive: Bool {
        lifecycle.status == .enabled || lifecycle.isForceOn
    }

    private var scenarioSummary: String {
        let enabled = lifecycle.scenarioStates
            .filter { $0.value >= 0 }
            .sorted { $0.key < $1.key }
            .map { name, level in
                let levelName = TelemetryLogLevel(rawValue: level)?.description ?? "Level \(level)"
                return "\(name): \(levelName)"
            }

        if enabled.isEmpty {
            return "No diagnostic scenarios enabled."
        }
        return enabled.joined(separator: ", ")
    }
}

private extension TelemetryToggleView {
    func bootstrap() async {
        viewState = .loading
        _ = await lifecycle.startup()

        if lifecycle.settings.clientIdentifier == nil {
            await lifecycle.generateAndPersistClientIdentifier()
        }

        settleViewState()
    }

    func requestDiagnostics() async {
        viewState = .syncing
        await lifecycle.requestDiagnostics()
        settleViewState()
    }

    func refreshSession() async {
        viewState = .syncing
        await lifecycle.reconcile()
        settleViewState()
    }

    func endSession() async {
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

    func copyClientCode() {
        let code = clientCode
        guard !code.isEmpty else { return }
        #if canImport(UIKit) && !os(watchOS)
        UIPasteboard.general.string = code
        #elseif canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        #endif
        withAnimation {
            showCopyConfirmation = true
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation {
                showCopyConfirmation = false
            }
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
    var scenarioSummary: String

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
            Text("\(message) — \(scenarioSummary)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            Text(scenarioSummary)
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
        case .noRegistration:
            return "info.circle"
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
        case .noRegistration:
            return .secondary
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
        case .noRegistration:
            return "No Registration Found"
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
