//
//  livediagnostics_forceApp.swift
//  livediagnostics.force
//
//  Demonstrates the "force on" pattern: telemetry is enabled programmatically
//  at launch and all scenarios are forced to Debug level for the lifetime of
//  the build.  No viewer interaction is needed to start capturing events.
//
//  Created by James Clarke on 2/22/26.
//

import ObjPxlLiveTelemetry
import SwiftUI

enum ForceOnScenario: String, CaseIterable {
    case networking = "Networking"
    case persistence = "Persistence"
}

@main
struct livediagnostics_forceApp: App {
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
                    appDelegate.telemetryLifecycle = telemetryLifecycle

                    // 1. Clean up any stale force-on session from a previous build
                    await telemetryLifecycle.cleanupPreviousForceOnSession()

                    // 2. Start the lifecycle (loads settings, performs background restore)
                    await telemetryLifecycle.startup()

                    // 3. Immediately enable telemetry — creates the client record
                    //    without waiting for the user to tap a button.
                    await telemetryLifecycle.enableTelemetry(force: true)

                    // 4. Register scenarios
                    try? await telemetryLifecycle.registerScenarios(
                        ForceOnScenario.allCases.map(\.rawValue)
                    )

                    // 5. Force every scenario to Debug level so all events are captured
                    for scenario in ForceOnScenario.allCases {
                        try? await telemetryLifecycle.setScenarioDiagnosticLevel(
                            scenario.rawValue,
                            level: TelemetryLogLevel.debug.rawValue
                        )
                    }
                }
        }
    }
}
