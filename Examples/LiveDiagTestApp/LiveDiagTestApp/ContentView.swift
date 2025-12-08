//
//  ContentView.swift
//  LiveDiagTestApp
//
//  Created by James Clarke on 12/7/25.
//

import SwiftUI
import ObjPxlLiveTelemetry

struct ContentView: View {
    @Environment(\.telemetryLogger) private var telemetryLogger
    @State private var lastEvent: String?

    var body: some View {
        VStack {
            Image(systemName: "waveform.path")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Live Diagnostics")
                .bold()

            if let lastEvent {
                Text(lastEvent)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top)
            }

            Button("Send Test Telemetry", systemImage: "paperplane") {
                let timestamp = Date()
                telemetryLogger.logEvent(
                    name: "test_button_tap",
                    property1: "timestamp=\(timestamp.ISO8601Format())"
                )
                lastEvent = "Logged test_button_tap at \(timestamp.formatted(date: .omitted, time: .standard))"
            }
            .buttonStyle(.borderedProminent)
            .padding(.top)
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
