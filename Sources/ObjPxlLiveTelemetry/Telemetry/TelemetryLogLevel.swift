import Foundation

public enum TelemetryLogLevel: Int, Sendable, CaseIterable, Comparable, CustomStringConvertible {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    public var description: String {
        switch self {
        case .debug: "Debug"
        case .info: "Info"
        case .warning: "Warning"
        case .error: "Error"
        }
    }
}
