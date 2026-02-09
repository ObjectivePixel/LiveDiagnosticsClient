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
    #if os(iOS) || os(visionOS)
    @UIApplicationDelegateAdaptor(TelemetryAppDelegate.self) private var appDelegate
    #elseif os(macOS)
    @NSApplicationDelegateAdaptor(TelemetryAppDelegate.self) private var appDelegate
    #endif

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
