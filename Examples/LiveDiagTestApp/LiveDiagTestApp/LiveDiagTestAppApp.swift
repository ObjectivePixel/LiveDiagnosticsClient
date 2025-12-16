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
    private let telemetryLifecycle: TelemetryLifecycleService

    init() {
        telemetryLifecycle = TelemetryLifecycleService(
            configuration: .init(
                containerIdentifier: TelemetrySchema.cloudKitContainerIdentifierTelemetry,
                loggerConfiguration: .default
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.telemetryLifecycle, telemetryLifecycle)
                .environment(\.telemetryLogger, telemetryLifecycle.telemetryLogger)
        }
    }
}
