import SwiftUI

private struct CloudKitClientKey: EnvironmentKey {
    typealias Value = CloudKitClient
    static let defaultValue = CloudKitClient()
}

public extension EnvironmentValues {
    var cloudKitClient: CloudKitClient {
        get { self[CloudKitClientKey.self] }
        set { self[CloudKitClientKey.self] = newValue }
    }
}
