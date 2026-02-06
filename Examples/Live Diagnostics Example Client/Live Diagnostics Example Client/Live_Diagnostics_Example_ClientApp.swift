//
//  Live_Diagnostics_Example_ClientApp.swift
//  Live Diagnostics Example Client
//
//  Created by James Clarke on 12/19/25.
//

import ObjPxlLiveTelemetry
import SwiftUI

@main
struct Live_Diagnostics_Example_ClientApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let telemetryLifecycle = TelemetryLifecycleService(
        configuration: .init(containerIdentifier: "iCloud.objpxl.example.telemetry")
    )

    var body: some Scene {
        WindowGroup {
            ContentView(telemetryLifecycle: telemetryLifecycle)
                .task {
                    // Wire up the lifecycle to the AppDelegate for push notification handling
                    appDelegate.telemetryLifecycle = telemetryLifecycle

                    // Start the telemetry lifecycle (loads settings, reconciles with server, sets up command processing)
                    await telemetryLifecycle.startup()
                }
        }
    }
}
