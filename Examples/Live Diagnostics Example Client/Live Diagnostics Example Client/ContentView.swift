//
//  ContentView.swift
//  LiveDiagTestApp
//
//  Created by James Clarke on 12/7/25.
//

import SwiftUI
import ObjPxlLiveTelemetry

struct ContentView: View {
    @Environment(\.telemetryLifecycle) private var telemetryLifecycle
    @State private var lastEvent: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading) {
                    TelemetryToggleView()
                    Divider()
                    TestEventSection(
                        telemetryLogger: telemetryLogger,
                        lastEvent: $lastEvent
                    )
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
    ContentView()
}

private struct TestEventSection: View {
    let telemetryLogger: any TelemetryLogging
    @Binding var lastEvent: String?

    var body: some View {
        VStack(alignment: .leading) {
            Text("Verify telemetry")
                .font(.headline)
            Button("Send Test Telemetry", systemImage: "paperplane") {
                let timestamp = Date()
                telemetryLogger.logEvent(
                    name: "test_button_tap",
                    property1: "timestamp=\(timestamp.ISO8601Format())"
                )
                lastEvent = "Logged test_button_tap at \(timestamp.formatted(date: .omitted, time: .standard))"
            }
            .buttonStyle(.borderedProminent)

            if let lastEvent {
                Text(lastEvent)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
        }
    }
}
