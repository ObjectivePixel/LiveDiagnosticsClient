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
    private let telemetryLifecycle = TelemetryLifecycleService(
        configuration: .init(containerIdentifier: "iCloud.objpxl.example.telemetry")
    )

    var body: some Scene {
        WindowGroup {
            ContentView(telemetryLifecycle: telemetryLifecycle)
        }
    }
}
