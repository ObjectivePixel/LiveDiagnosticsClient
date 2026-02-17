//
//  ContentView.swift
//  LiveDiagTestApp
//
//  Created by James Clarke on 12/7/25.
//

import SwiftUI
import ObjPxlLiveTelemetry

enum ExampleScenario: String, CaseIterable {
    case networkRequests = "NetworkRequests"
    case dataSync = "DataSync"
    case userInteraction = "UserInteraction"
}

struct ContentView: View {
    let telemetryLifecycle: TelemetryLifecycleService
    @State private var lastEvent: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    TelemetryToggleView(lifecycle: telemetryLifecycle)
                    Divider()
                    TestEventSection(
                        telemetryLogger: telemetryLogger,
                        lastEvent: $lastEvent
                    )
                    Divider()
                    ScenarioSection(lifecycle: telemetryLifecycle, telemetryLogger: telemetryLogger)
                    Divider()
                    CommandDebugView(lifecycle: telemetryLifecycle)
                }
                .padding()
            }
            .navigationTitle("Live Diagnostics")
        }
    }

    private var telemetryLogger: any TelemetryLogging {
        telemetryLifecycle.telemetryLogger
    }
}

#Preview {
    ContentView(
        telemetryLifecycle: TelemetryLifecycleService(
            configuration: .init(containerIdentifier: "iCloud.objpxl.example.telemetry")
        )
    )
}

private struct TestEventSection: View {
    let telemetryLogger: any TelemetryLogging
    @Binding var lastEvent: String?

    var body: some View {
        VStack(alignment: .leading) {
            Text("Verify telemetry")
                .font(.headline)

            HStack {
                Button("Send Test Event", systemImage: "paperplane") {
                    let timestamp = Date()
                    telemetryLogger.logEvent(
                        name: "test_button_tap",
                        property1: "timestamp=\(timestamp.ISO8601Format())"
                    )
                    lastEvent = "Logged test_button_tap at \(timestamp.formatted(date: .omitted, time: .standard))"
                }
                .buttonStyle(.borderedProminent)

                Button("Flush Events", systemImage: "arrow.up.circle") {
                    Task {
                        await telemetryLogger.flush()
                        lastEvent = "Events flushed at \(Date().formatted(date: .omitted, time: .standard))"
                    }
                }
                .buttonStyle(.bordered)
            }

            if let lastEvent {
                Text(lastEvent)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }

            Text("Events are batched (10) and flushed every 30s, or tap Flush to send immediately.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

private struct ScenarioSection: View {
    let lifecycle: TelemetryLifecycleService
    let telemetryLogger: any TelemetryLogging

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scenarios")
                .font(.headline)

            if lifecycle.scenarioStates.isEmpty {
                Text("No scenarios registered.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(ExampleScenario.allCases, id: \.rawValue) { scenario in
                    let isEnabled = lifecycle.scenarioStates[scenario.rawValue] ?? false
                    HStack {
                        VStack(alignment: .leading) {
                            Text(scenario.rawValue)
                                .font(.subheadline.weight(.medium))
                            Text(isEnabled ? "Enabled" : "Disabled")
                                .font(.caption)
                                .foregroundStyle(isEnabled ? .green : .secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { isEnabled },
                            set: { newValue in
                                Task {
                                    try? await lifecycle.setScenarioEnabled(scenario.rawValue, enabled: newValue)
                                }
                            }
                        ))
                        .labelsHidden()

                        Button("Log", systemImage: "text.badge.plus") {
                            telemetryLogger.logEvent(
                                name: "scenario_test_\(scenario.rawValue)",
                                scenario: scenario.rawValue,
                                level: .diagnostic,
                                property1: "manual_test"
                            )
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            Button("End Session") {
                Task {
                    try? await lifecycle.endSession()
                }
            }
            .buttonStyle(.bordered)
            .foregroundStyle(.red)

            Text("Toggle scenarios locally or wait for the viewer to send commands. End Session cleans up CloudKit records.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
