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
    private let telemetryLogger: any TelemetryLogging

    init() {
        // Replace this value with your CloudKit container identifier.
        let cloudKitContainerIdentifier: String? = "iCloud.objpxl.example.telemetry"
        telemetryLogger = TelemetryBootstrap.makeLogger(
            distribution: .debug,
            containerIdentifier: cloudKitContainerIdentifier,
            configuration: .default
        )
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.telemetryLogger, telemetryLogger)
        }
    }
}
