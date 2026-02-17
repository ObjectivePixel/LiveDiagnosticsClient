import Foundation

public enum TelemetryLogLevel: String, Sendable, CaseIterable, Comparable {
    case info
    case diagnostic

    public static func < (lhs: TelemetryLogLevel, rhs: TelemetryLogLevel) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }

    private var sortOrder: Int {
        switch self {
        case .info: return 0
        case .diagnostic: return 1
        }
    }
}
