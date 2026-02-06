import CloudKit
import Foundation

public protocol TelemetrySubscriptionManaging: Sendable {
    var currentSubscriptionID: CKSubscription.ID? { get async }
    func registerSubscription(for clientId: String) async throws
    func unregisterSubscription() async throws
}

public actor TelemetrySubscriptionManager: TelemetrySubscriptionManaging {
    private let cloudKitClient: CloudKitClientProtocol
    private var _currentSubscriptionID: CKSubscription.ID?
    private var currentClientId: String?

    public var currentSubscriptionID: CKSubscription.ID? {
        _currentSubscriptionID
    }

    public init(cloudKitClient: CloudKitClientProtocol) {
        self.cloudKitClient = cloudKitClient
    }

    public func registerSubscription(for clientId: String) async throws {
        // If already registered for this client, skip
        if currentClientId == clientId, _currentSubscriptionID != nil {
            return
        }

        // Unregister any existing subscription first
        if let existingID = _currentSubscriptionID {
            try? await cloudKitClient.removeCommandSubscription(existingID)
            _currentSubscriptionID = nil
            currentClientId = nil
        }

        // Check if subscription already exists on server
        if let existingSubscriptionID = try await cloudKitClient.fetchCommandSubscription(for: clientId) {
            _currentSubscriptionID = existingSubscriptionID
            currentClientId = clientId
            return
        }

        // Create new subscription
        let subscriptionID = try await cloudKitClient.createCommandSubscription(for: clientId)
        _currentSubscriptionID = subscriptionID
        currentClientId = clientId
    }

    public func unregisterSubscription() async throws {
        guard let subscriptionID = _currentSubscriptionID else {
            return
        }

        try await cloudKitClient.removeCommandSubscription(subscriptionID)
        _currentSubscriptionID = nil
        currentClientId = nil
    }
}
