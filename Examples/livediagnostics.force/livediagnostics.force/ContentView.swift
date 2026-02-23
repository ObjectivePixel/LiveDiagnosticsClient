//
//  ContentView.swift
//  livediagnostics.force
//
//  Minimal UI: telemetry control, test event buttons, and forced scenario levels.
//
//  Created by James Clarke on 2/22/26.
//

import SwiftUI
import ObjPxlLiveTelemetry

struct ContentView: View {
    let telemetryLifecycle: TelemetryLifecycleService
    @State private var lastEvent: String?

    var body: some View {
        NavigationStack {
            Form {
                TelemetryToggleView(lifecycle: telemetryLifecycle)

                Section("Send Events") {
                    ForEach(ForceOnScenario.allCases, id: \.rawValue) { scenario in
                        Button("Log \(scenario.rawValue)", systemImage: "paperplane") {
                            telemetryLifecycle.telemetryLogger.logEvent(
                                name: "force_on_test",
                                scenario: scenario.rawValue,
                                level: .info,
                                property1: "ts=\(Date().ISO8601Format())"
                            )
                            lastEvent = "Logged force_on_test [\(scenario.rawValue)] at \(Date().formatted(date: .omitted, time: .standard))"
                        }
                    }

                    Button("Flush", systemImage: "arrow.up.circle") {
                        Task {
                            await telemetryLifecycle.telemetryLogger.flush()
                            lastEvent = "Flushed at \(Date().formatted(date: .omitted, time: .standard))"
                        }
                    }
                    .buttonStyle(.bordered)

                    if let lastEvent {
                        Text(lastEvent)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    ForEach(ForceOnScenario.allCases, id: \.rawValue) { scenario in
                        let level = telemetryLifecycle.scenarioStates[scenario.rawValue]
                            ?? TelemetryScenarioRecord.levelOff
                        LabeledContent(scenario.rawValue) {
                            Text(level >= 0
                                 ? (TelemetryLogLevel(rawValue: level)?.description ?? "Level \(level)")
                                 : "Off")
                                .foregroundStyle(level >= 0 ? .green : .secondary)
                        }
                    }
                } header: {
                    Text("Forced Scenario Levels")
                } footer: {
                    Text("All scenarios are forced to Debug level at launch. Events at every level will be captured.")
                }
            }
            .navigationTitle("Force On Example")
        }
    }
}

#Preview {
    ContentView(
        telemetryLifecycle: TelemetryLifecycleService(
            configuration: .init(containerIdentifier: "iCloud.preview.telemetry")
        )
    )
}
