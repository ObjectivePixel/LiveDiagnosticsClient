#if canImport(UIKit) && !os(watchOS)
import UIKit

@MainActor
open class TelemetryAppDelegate: NSObject, UIApplicationDelegate {
    public var telemetryLifecycle: TelemetryLifecycleService?

    open func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard let lifecycle = telemetryLifecycle else {
            completionHandler(.noData)
            return
        }
        Task {
            let handled = await lifecycle.handleRemoteNotification(userInfo)
            completionHandler(handled ? .newData : .noData)
        }
    }
}

#elseif canImport(AppKit)
import AppKit

@MainActor
open class TelemetryAppDelegate: NSObject, NSApplicationDelegate {
    public var telemetryLifecycle: TelemetryLifecycleService?

    open func application(
        _ application: NSApplication,
        didReceiveRemoteNotification userInfo: [String: Any]
    ) {
        guard let lifecycle = telemetryLifecycle else { return }
        Task {
            await lifecycle.handleRemoteNotification(userInfo)
        }
    }
}
#endif
