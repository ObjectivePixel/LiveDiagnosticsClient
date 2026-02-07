//
//  AppDelegate.swift
//  Live Diagnostics Example Client
//

import ObjPxlLiveTelemetry

#if os(iOS) || os(visionOS)
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    var telemetryLifecycle: TelemetryLifecycleService?

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Register for remote notifications to receive command push notifications
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let tokenString = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("Registered for remote notifications with token: \(tokenString)")
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        print("Failed to register for remote notifications: \(error)")
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        print("📲 [AppDelegate] didReceiveRemoteNotification called")
        print("📲 [AppDelegate] userInfo: \(userInfo)")

        guard let lifecycle = telemetryLifecycle else {
            print("⚠️ [AppDelegate] telemetryLifecycle is nil, cannot handle notification")
            completionHandler(.noData)
            return
        }

        Task {
            print("📲 [AppDelegate] Forwarding notification to lifecycle service...")
            let handled = await lifecycle.handleRemoteNotification(userInfo)
            print("📲 [AppDelegate] Notification handled: \(handled)")
            completionHandler(handled ? .newData : .noData)
        }
    }
}

#elseif os(macOS)
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var telemetryLifecycle: TelemetryLifecycleService?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register for remote notifications to receive command push notifications
        NSApplication.shared.registerForRemoteNotifications()
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let tokenString = deviceToken.map { String(format: "%02x", $0) }.joined()
        print("Registered for remote notifications with token: \(tokenString)")
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("Failed to register for remote notifications: \(error)")
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        print("📲 [AppDelegate] didReceiveRemoteNotification called")
        print("📲 [AppDelegate] userInfo: \(userInfo)")

        guard let lifecycle = telemetryLifecycle else {
            print("⚠️ [AppDelegate] telemetryLifecycle is nil, cannot handle notification")
            return
        }

        Task {
            print("📲 [AppDelegate] Forwarding notification to lifecycle service...")
            let handled = await lifecycle.handleRemoteNotification(userInfo)
            print("📲 [AppDelegate] Notification handled: \(handled)")
        }
    }
}
#endif
