import Foundation

#if os(iOS) || os(tvOS) || os(visionOS)
import UIKit
#elseif os(watchOS)
import WatchKit
#endif

struct DeviceInfo: Sendable {
    let deviceType: String
    let deviceName: String
    let deviceModel: String
    let osVersion: String
    let appVersion: String

    static var current: DeviceInfo {
        DeviceInfo(
            deviceType: Self.deviceType,
            deviceName: Self.deviceName,
            deviceModel: Self.deviceModel,
            osVersion: Self.osVersion,
            appVersion: Self.appVersion
        )
    }

    private static var deviceType: String {
        #if os(watchOS)
        return "Watch"
        #elseif os(tvOS)
        return "Apple TV"
        #elseif os(visionOS)
        return "Vision Pro"
        #elseif os(iOS)
        switch UIDevice.current.userInterfaceIdiom {
        case .pad:
            return "iPad"
        case .phone:
            return "iPhone"
        case .vision:
            return "Vision Pro"
        default:
            return "iOS"
        }
        #else
        return "Unknown"
        #endif
    }

    private static var deviceName: String {
        #if os(iOS) || os(tvOS) || os(visionOS)
        return UIDevice.current.name
        #elseif os(watchOS)
        return WKInterfaceDevice.current().name
        #else
        return "Unknown"
        #endif
    }

    private static var deviceModel: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let modelCode = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingCString: $0)
            }
        }
        return modelCode ?? "Unknown"
    }

    private static var osVersion: String {
        #if os(tvOS)
        let version = UIDevice.current.systemVersion
        return "tvOS \(version)"
        #elseif os(visionOS)
        let version = UIDevice.current.systemVersion
        return "visionOS \(version)"
        #elseif os(iOS)
        let version = UIDevice.current.systemVersion
        return "iOS \(version)"
        #elseif os(watchOS)
        let version = WKInterfaceDevice.current().systemVersion
        return "watchOS \(version)"
        #else
        return "Unknown"
        #endif
    }

    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }
}
