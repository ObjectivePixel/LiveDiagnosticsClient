//
//  LiveDiagTestAppApp.swift
//  LiveDiagTestApp
//
//  Created by James Clarke on 12/7/25.
//

import SwiftUI
import ObjPxlLiveTelemetry

@main
struct LiveDiagTestAppApp: App {
    private let telemetryLogger = TelemetryBootstrap.makeLogger(
        distribution: .debug,
        configuration: .default
    )

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.telemetryLogger, telemetryLogger)
        }
    }
}
