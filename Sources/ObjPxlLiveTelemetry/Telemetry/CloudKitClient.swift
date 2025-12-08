//
//  CloudkitClient.swift
//  RemindfullShared
//
//  Created by James Clarke on 12/5/25.
//

import CloudKit

public protocol CloudKitClientProtocol: Sendable {
    func validateSchema() async -> Bool
    func save(records: [CKRecord]) async throws
}

public struct CloudKitClient: CloudKitClientProtocol {
    public let container: CKContainer
    public let database: CKDatabase
    public let identifier: String

    public init(
        containerIdentifier: String? = CKContainer.default().containerIdentifier
    ) {
        let resolvedContainer = containerIdentifier.map { CKContainer(identifier: $0) } ?? .default()
        container = resolvedContainer
        database = resolvedContainer.publicCloudDatabase
        identifier = containerIdentifier ?? resolvedContainer.containerIdentifier ?? "unknown"
    }

    public func validateSchema() async -> Bool {
        do {
            try await TelemetrySchema.validateSchema(in: database)
            return true
        } catch {
            print("Telemetry schema validation failed: \(error)")
            return false
        }
    }

    public func save(records: [CKRecord]) async throws {
        let operation = CKModifyRecordsOperation(recordsToSave: records)
        operation.savePolicy = .allKeys

        return try await withCheckedThrowingContinuation { continuation in
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            database.add(operation)
        }
    }
}
