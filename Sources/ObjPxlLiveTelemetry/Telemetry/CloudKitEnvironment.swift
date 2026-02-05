import SwiftUI

private struct CloudKitClientKey: EnvironmentKey {
    typealias Value = CloudKitClient
    static var defaultValue: CloudKitClient {
        preconditionFailure("CloudKitClient must be injected via .environment(\\.cloudKitClient, client)")
    }
}

public extension EnvironmentValues {
    var cloudKitClient: CloudKitClient {
        get { self[CloudKitClientKey.self] }
        set { self[CloudKitClientKey.self] = newValue }
    }
}
