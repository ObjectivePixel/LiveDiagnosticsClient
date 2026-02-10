import CloudKit
import Foundation

public struct DebugInfo: Sendable {
    public let containerID: String
    public let buildType: String
    public let environment: String
    public let testQueryResults: Int
    public let firstRecordID: String?
    public let firstRecordFields: [String]
    public let recordCount: Int?
    public let errorMessage: String?
}

public protocol CloudKitClientProtocol: Sendable {
    func validateSchema() async -> Bool
    func save(records: [CKRecord]) async throws
    func fetchAllRecords() async throws -> [CKRecord]
    func fetchRecords(limit: Int, cursor: CKQueryOperation.Cursor?) async throws -> ([CKRecord], CKQueryOperation.Cursor?)
    func countRecords() async throws -> Int
    func createTelemetryClient(clientId: String, created: Date, isEnabled: Bool) async throws -> TelemetryClientRecord
    func createTelemetryClient(_ telemetryClient: TelemetryClientRecord) async throws -> TelemetryClientRecord
    func updateTelemetryClient(recordID: CKRecord.ID, clientId: String?, created: Date?, isEnabled: Bool?) async throws -> TelemetryClientRecord
    func updateTelemetryClient(_ telemetryClient: TelemetryClientRecord) async throws -> TelemetryClientRecord
    func deleteTelemetryClient(recordID: CKRecord.ID) async throws
    func fetchTelemetryClients(clientId: String?, isEnabled: Bool?) async throws -> [TelemetryClientRecord]
    func debugDatabaseInfo() async
    func detectEnvironment() async -> String
    func getDebugInfo() async -> DebugInfo
    func deleteAllRecords() async throws -> Int

    // Command CRUD
    func createCommand(_ command: TelemetryCommandRecord) async throws -> TelemetryCommandRecord
    func fetchCommand(recordID: CKRecord.ID) async throws -> TelemetryCommandRecord?
    func fetchPendingCommands(for clientId: String) async throws -> [TelemetryCommandRecord]
    func updateCommandStatus(recordID: CKRecord.ID, status: TelemetrySchema.CommandStatus, executedAt: Date?, errorMessage: String?) async throws -> TelemetryCommandRecord
    func deleteCommand(recordID: CKRecord.ID) async throws
    func deleteAllCommands(for clientId: String) async throws -> Int

    // Subscription management
    func createCommandSubscription(for clientId: String) async throws -> CKSubscription.ID
    func removeCommandSubscription(_ subscriptionID: CKSubscription.ID) async throws
    func fetchCommandSubscription(for clientId: String) async throws -> CKSubscription.ID?

    // TelemetryClient subscriptions (for viewer)
    func createClientRecordSubscription() async throws -> CKSubscription.ID
    func removeSubscription(_ subscriptionID: CKSubscription.ID) async throws
    func fetchSubscription(id: CKSubscription.ID) async throws -> CKSubscription.ID?
}

public extension CloudKitClientProtocol {
    func deleteAllTelemetryEvents() async throws -> Int {
        try await deleteAllRecords()
    }
}

public struct CloudKitClient: CloudKitClientProtocol {
    public let container: CKContainer
    public let database: CKDatabase
    public let identifier: String

    public init(containerIdentifier: String) {
        let resolvedContainer = CKContainer(identifier: containerIdentifier)
        container = resolvedContainer
        database = resolvedContainer.publicCloudDatabase
        identifier = containerIdentifier
        print("☁️ [CloudKitClient] Initialized with container: \(containerIdentifier)")
    }

    public func validateSchema() async -> Bool {
        print("☁️ [CloudKitClient] Validating schema for container: \(identifier)")
        do {
            try await TelemetrySchema.validateSchema(in: database)
            print("✅ [CloudKitClient] Schema validation passed")
            return true
        } catch {
            print("❌ [CloudKitClient] Schema validation failed for container '\(identifier)': \(error)")
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
    
    public func fetchAllRecords() async throws -> [CKRecord] {
        var allRecords: [CKRecord] = []
        var cursor: CKQueryOperation.Cursor?

        repeat {
            let result = try await fetchRecords(limit: CKQueryOperation.maximumResults, cursor: cursor)
            allRecords.append(contentsOf: result.0)
            cursor = result.1
        } while cursor != nil

        return allRecords
    }

    public func fetchRecords(
        limit: Int = CKQueryOperation.maximumResults,
        cursor: CKQueryOperation.Cursor? = nil
    ) async throws -> ([CKRecord], CKQueryOperation.Cursor?) {
        let operation: CKQueryOperation

        if let cursor {
            operation = CKQueryOperation(cursor: cursor)
            print("🔍 Fetching next page of records with cursor")
        } else {
            let query = CKQuery(
                recordType: TelemetrySchema.recordType,
                predicate: NSPredicate(value: true)
            )
            query.sortDescriptors = [
                NSSortDescriptor(key: TelemetrySchema.Field.eventTimestamp.rawValue, ascending: false)
            ]
            print("🔍 Fetching first page of records from database: \(database)")
            operation = CKQueryOperation(query: query)
        }

        operation.resultsLimit = limit
        operation.qualityOfService = .userInitiated

        return try await withCheckedThrowingContinuation { continuation in
            var pageRecords: [CKRecord] = []

            operation.recordMatchedBlock = { recordID, result in
                switch result {
                case .success(let record):
                    print("✅ Found record: \(record.recordID.recordName)")
                    pageRecords.append(record)
                case .failure(let error):
                    print("❌ Failed to fetch record \(recordID): \(error)")
                }
            }

            operation.queryResultBlock = { result in
                switch result {
                case .success(let cursor):
                    print("📊 Fetched \(pageRecords.count) records in this batch (limit \(limit))")
                    if cursor != nil {
                        print("➡️ More records available, returning cursor for next page")
                    } else {
                        print("✅ No more records available")
                    }
                    continuation.resume(returning: (pageRecords, cursor))
                case .failure(let error):
                    print("❌ Query failed: \(error)")
                    continuation.resume(throwing: error)
                }
            }

            database.add(operation)
        }
    }

    /// Counts all records with minimal payload (no desired keys, no sort) to reduce latency.
    public func countRecords() async throws -> Int {
        let query = CKQuery(recordType: TelemetrySchema.recordType, predicate: NSPredicate(value: true))
        query.sortDescriptors = []

        var totalCount = 0

        func makeOperation(cursor: CKQueryOperation.Cursor?) -> CKQueryOperation {
            let op = cursor.map(CKQueryOperation.init) ?? CKQueryOperation(query: query)
            op.desiredKeys = []
            op.resultsLimit = CKQueryOperation.maximumResults
            op.qualityOfService = .utility
            return op
        }

        return try await withCheckedThrowingContinuation { continuation in
            func run(cursor: CKQueryOperation.Cursor?) {
                let operation = makeOperation(cursor: cursor)

                operation.recordMatchedBlock = { _, result in
                    if case .success = result {
                        totalCount += 1
                    }
                }

                operation.queryResultBlock = { result in
                    switch result {
                    case .success(let nextCursor):
                        if let nextCursor {
                            run(cursor: nextCursor)
                        } else {
                            continuation.resume(returning: totalCount)
                        }
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }

                database.add(operation)
            }

            run(cursor: nil)
        }
    }

    // MARK: - Telemetry Clients

    public func createTelemetryClient(
        clientId: String,
        created: Date = .now,
        isEnabled: Bool
    ) async throws -> TelemetryClientRecord {
        try await createTelemetryClient(
            TelemetryClientRecord(
                recordID: nil,
                clientId: clientId,
                created: created,
                isEnabled: isEnabled
            )
        )
    }

    public func createTelemetryClient(_ telemetryClient: TelemetryClientRecord) async throws -> TelemetryClientRecord {
        let savedRecord = try await database.save(telemetryClient.toCKRecord())
        return try TelemetryClientRecord(record: savedRecord)
    }

    public func updateTelemetryClient(
        recordID: CKRecord.ID,
        clientId: String? = nil,
        created: Date? = nil,
        isEnabled: Bool? = nil
    ) async throws -> TelemetryClientRecord {
        let existingRecord = try await database.record(for: recordID)
        guard existingRecord.recordType == TelemetrySchema.clientRecordType else {
            throw TelemetryClientRecord.Error.unexpectedRecordType(existingRecord.recordType)
        }

        let current = try TelemetryClientRecord(record: existingRecord)
        let updated = TelemetryClientRecord(
            recordID: recordID,
            clientId: clientId ?? current.clientId,
            created: created ?? current.created,
            isEnabled: isEnabled ?? current.isEnabled
        )

        let savedRecord = try await database.save(updated.applying(to: existingRecord))

        return try TelemetryClientRecord(record: savedRecord)
    }

    public func updateTelemetryClient(_ telemetryClient: TelemetryClientRecord) async throws -> TelemetryClientRecord {
        guard let recordID = telemetryClient.recordID else {
            throw TelemetryClientRecord.Error.missingRecordID
        }

        let record = try await database.record(for: recordID)
        let updatedRecord = try telemetryClient.applying(to: record)
        let saved = try await database.save(updatedRecord)
        return try TelemetryClientRecord(record: saved)
    }

    public func deleteTelemetryClient(recordID: CKRecord.ID) async throws {
        _ = try await database.deleteRecord(withID: recordID)
    }

    public func fetchTelemetryClients(
        clientId: String? = nil,
        isEnabled: Bool? = nil
    ) async throws -> [TelemetryClientRecord] {
        let predicate: NSPredicate
        switch (clientId, isEnabled) {
        case (let clientId?, let isEnabled?):
            predicate = NSPredicate(
                format: "%K == %@ AND %K == %@",
                TelemetrySchema.ClientField.clientId.rawValue,
                clientId,
                TelemetrySchema.ClientField.isEnabled.rawValue,
                NSNumber(value: isEnabled)
            )
        case (let clientId?, nil):
            predicate = NSPredicate(
                format: "%K == %@",
                TelemetrySchema.ClientField.clientId.rawValue,
                clientId
            )
        case (nil, let isEnabled?):
            predicate = NSPredicate(
                format: "%K == %@",
                TelemetrySchema.ClientField.isEnabled.rawValue,
                NSNumber(value: isEnabled)
            )
        default:
            predicate = NSPredicate(value: true)
        }

        let query = CKQuery(recordType: TelemetrySchema.clientRecordType, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: TelemetrySchema.ClientField.created.rawValue, ascending: false)]

        return try await withCheckedThrowingContinuation { continuation in
            var allClients: [TelemetryClientRecord] = []
            var didResume = false

            func resume(with result: Result<[TelemetryClientRecord], Error>) {
                guard !didResume else { return }
                didResume = true
                switch result {
                case .success(let clients):
                    continuation.resume(returning: clients)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            func configure(operation: CKQueryOperation) {
                operation.resultsLimit = CKQueryOperation.maximumResults
                operation.qualityOfService = .userInitiated

                operation.recordMatchedBlock = { recordID, result in
                    switch result {
                    case .success(let record):
                        do {
                            let client = try TelemetryClientRecord(record: record)
                            allClients.append(client)
                        } catch {
                            print("❌ Failed to parse record \(recordID): \(error)")
                        }
                    case .failure(let error):
                        print("❌ Failed to fetch record \(recordID): \(error)")
                    }
                }

                operation.queryResultBlock = { result in
                    switch result {
                    case .success(let cursor):
                        if let cursor {
                            let nextOperation = CKQueryOperation(cursor: cursor)
                            configure(operation: nextOperation)
                            self.database.add(nextOperation)
                        } else {
                            resume(with: .success(allClients))
                        }
                    case .failure(let error):
                        resume(with: .failure(error))
                    }
                }
            }

            let operation = CKQueryOperation(query: query)
            configure(operation: operation)
            database.add(operation)
        }
    }

    // Debug method to check what databases we're working with
    public func debugDatabaseInfo() async {
        print("🔍 Database Debug Info:")
        print("   Container ID: \(container.containerIdentifier ?? "unknown")")
        print("   Database: \(database)")
        print("   Database scope: Public")
        
        #if DEBUG
        print("   Build Type: DEBUG")
        print("   ⚠️ Debug builds typically use Development environment")
        #else
        print("   Build Type: RELEASE")
        print("   🚀 Release builds use Production environment")
        #endif
        
        // Try to fetch a single record to see what happens
        let query = CKQuery(recordType: TelemetrySchema.recordType, predicate: NSPredicate(value: true))
        query.sortDescriptors = []
        
        do {
            let result = try await database.records(matching: query, resultsLimit: 1)
            print("   Test query found \(result.matchResults.count) results")
            if let first = result.matchResults.first {
                switch first.1 {
                case .success(let record):
                    print("   First record ID: \(record.recordID.recordName)")
                    print("   First record fields: \(record.allKeys())")
                case .failure(let error):
                    print("   First record error: \(error)")
                }
            }
        } catch {
            print("   Test query failed: \(error)")
        }
    }
    
    public func getDebugInfo() async -> DebugInfo {
        let containerID = container.containerIdentifier ?? "unknown"
        
        #if DEBUG
        let buildType = "DEBUG"
        let environment = "🔧 Development"
        #else
        let buildType = "RELEASE"
        let environment = "🚀 Production"
        #endif
        
        // Try to fetch a single record to see what happens
        let query = CKQuery(recordType: TelemetrySchema.recordType, predicate: NSPredicate(value: true))
        query.sortDescriptors = []
        
        do {
            let result = try await database.records(matching: query, resultsLimit: 1)
            let testQueryResults = result.matchResults.count
            let countResult: Int?
            do {
                countResult = try await countRecords()
            } catch {
                countResult = nil
                print("ℹ️ Count failed: \(error)")
            }
            
            if let first = result.matchResults.first {
                switch first.1 {
                case .success(let record):
                    return DebugInfo(
                        containerID: containerID,
                        buildType: buildType,
                        environment: environment,
                        testQueryResults: testQueryResults,
                        firstRecordID: record.recordID.recordName,
                        firstRecordFields: record.allKeys().sorted(),
                        recordCount: countResult,
                        errorMessage: nil
                    )
                case .failure(let error):
                    return DebugInfo(
                        containerID: containerID,
                        buildType: buildType,
                        environment: environment,
                        testQueryResults: 0,
                        firstRecordID: nil,
                        firstRecordFields: [],
                        recordCount: countResult,
                        errorMessage: "First record error: \(error.localizedDescription)"
                    )
                }
            } else {
                return DebugInfo(
                    containerID: containerID,
                    buildType: buildType,
                    environment: environment,
                    testQueryResults: testQueryResults,
                    firstRecordID: nil,
                    firstRecordFields: [],
                    recordCount: countResult,
                    errorMessage: nil
                )
            }
        } catch {
            let countResult: Int?
            do {
                countResult = try await countRecords()
            } catch {
                countResult = nil
                print("ℹ️ Count failed: \(error)")
            }

            return DebugInfo(
                containerID: containerID,
                buildType: buildType,
                environment: environment,
                testQueryResults: 0,
                firstRecordID: nil,
                firstRecordFields: [],
                recordCount: countResult,
                errorMessage: "Test query failed: \(error.localizedDescription)"
            )
        }
    }
    
    public func detectEnvironment() async -> String {
        let debugInfo = await getDebugInfo()
        return debugInfo.environment
    }
    
    public func deleteAllRecords() async throws -> Int {
        print("🗑️ Starting to delete all records...")

        let query = CKQuery(recordType: TelemetrySchema.recordType, predicate: NSPredicate(value: true))
        query.sortDescriptors = []

        func fetchIDs(cursor: CKQueryOperation.Cursor?) async throws -> ([CKRecord.ID], CKQueryOperation.Cursor?) {
            let op: CKQueryOperation = cursor.map(CKQueryOperation.init) ?? CKQueryOperation(query: query)
            op.desiredKeys = []
            op.resultsLimit = CKQueryOperation.maximumResults
            op.qualityOfService = .utility

            return try await withCheckedThrowingContinuation { continuation in
                var ids: [CKRecord.ID] = []

                op.recordMatchedBlock = { _, result in
                    if case .success(let record) = result {
                        ids.append(record.recordID)
                    }
                }

                op.queryResultBlock = { result in
                    switch result {
                    case .success(let cursor):
                        continuation.resume(returning: (ids, cursor))
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }

                database.add(op)
            }
        }

        var recordIDs: [CKRecord.ID] = []
        var cursor: CKQueryOperation.Cursor?
        repeat {
            let page = try await fetchIDs(cursor: cursor)
            recordIDs.append(contentsOf: page.0)
            cursor = page.1
            print("📄 Collected \(recordIDs.count) record IDs so far")
        } while cursor != nil

        guard !recordIDs.isEmpty else {
            print("✅ No records to delete")
            return 0
        }

        print("🗑️ Found \(recordIDs.count) records to delete")

        let batchSize = 400
        var totalDeleted = 0

        for i in stride(from: 0, to: recordIDs.count, by: batchSize) {
            let endIndex = min(i + batchSize, recordIDs.count)
            let batch = Array(recordIDs[i..<endIndex])

            let operation = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: batch)

            let _: Void = try await withCheckedThrowingContinuation { continuation in
                operation.modifyRecordsResultBlock = { result in
                    switch result {
                    case .success:
                        print("✅ Deleted batch of \(batch.count) records")
                        continuation.resume()
                    case .failure(let error):
                        print("❌ Failed to delete batch: \(error)")
                        continuation.resume(throwing: error)
                    }
                }

                database.add(operation)
            }

            totalDeleted += batch.count
        }

        print("✅ Successfully deleted \(totalDeleted) records")
        return totalDeleted
    }

    // MARK: - Commands

    public func createCommand(_ command: TelemetryCommandRecord) async throws -> TelemetryCommandRecord {
        let savedRecord = try await database.save(command.toCKRecord())
        return try TelemetryCommandRecord(record: savedRecord)
    }

    public func fetchCommand(recordID: CKRecord.ID) async throws -> TelemetryCommandRecord? {
        do {
            let record = try await database.record(for: recordID)
            return try TelemetryCommandRecord(record: record)
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    public func fetchPendingCommands(for clientId: String) async throws -> [TelemetryCommandRecord] {
        let predicate = NSPredicate(
            format: "%K == %@ AND %K == %@",
            TelemetrySchema.CommandField.clientId.rawValue,
            clientId,
            TelemetrySchema.CommandField.status.rawValue,
            TelemetrySchema.CommandStatus.pending.rawValue
        )

        let query = CKQuery(recordType: TelemetrySchema.commandRecordType, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: TelemetrySchema.CommandField.created.rawValue, ascending: true)]

        return try await withCheckedThrowingContinuation { continuation in
            var allCommands: [TelemetryCommandRecord] = []
            var didResume = false

            func resume(with result: Result<[TelemetryCommandRecord], Error>) {
                guard !didResume else { return }
                didResume = true
                switch result {
                case .success(let commands):
                    continuation.resume(returning: commands)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            func configure(operation: CKQueryOperation) {
                operation.resultsLimit = CKQueryOperation.maximumResults
                operation.qualityOfService = .userInitiated

                operation.recordMatchedBlock = { recordID, result in
                    switch result {
                    case .success(let record):
                        do {
                            let command = try TelemetryCommandRecord(record: record)
                            allCommands.append(command)
                        } catch {
                            print("❌ Failed to parse command record \(recordID): \(error)")
                        }
                    case .failure(let error):
                        print("❌ Failed to fetch command record \(recordID): \(error)")
                    }
                }

                operation.queryResultBlock = { result in
                    switch result {
                    case .success(let cursor):
                        if let cursor {
                            let nextOperation = CKQueryOperation(cursor: cursor)
                            configure(operation: nextOperation)
                            self.database.add(nextOperation)
                        } else {
                            resume(with: .success(allCommands))
                        }
                    case .failure(let error):
                        resume(with: .failure(error))
                    }
                }
            }

            let operation = CKQueryOperation(query: query)
            configure(operation: operation)
            database.add(operation)
        }
    }

    public func updateCommandStatus(
        recordID: CKRecord.ID,
        status: TelemetrySchema.CommandStatus,
        executedAt: Date?,
        errorMessage: String?
    ) async throws -> TelemetryCommandRecord {
        let existingRecord = try await database.record(for: recordID)
        guard existingRecord.recordType == TelemetrySchema.commandRecordType else {
            throw TelemetryCommandRecord.Error.unexpectedRecordType(existingRecord.recordType)
        }

        existingRecord[TelemetrySchema.CommandField.status.rawValue] = status.rawValue as CKRecordValue
        existingRecord[TelemetrySchema.CommandField.executedAt.rawValue] = executedAt as CKRecordValue?
        existingRecord[TelemetrySchema.CommandField.errorMessage.rawValue] = errorMessage as CKRecordValue?

        let savedRecord = try await database.save(existingRecord)
        return try TelemetryCommandRecord(record: savedRecord)
    }

    public func deleteCommand(recordID: CKRecord.ID) async throws {
        _ = try await database.deleteRecord(withID: recordID)
    }

    public func deleteAllCommands(for clientId: String) async throws -> Int {
        let predicate = NSPredicate(
            format: "%K == %@",
            TelemetrySchema.CommandField.clientId.rawValue,
            clientId
        )
        let query = CKQuery(recordType: TelemetrySchema.commandRecordType, predicate: predicate)
        query.sortDescriptors = []

        func fetchIDs(cursor: CKQueryOperation.Cursor?) async throws -> ([CKRecord.ID], CKQueryOperation.Cursor?) {
            let op: CKQueryOperation = cursor.map(CKQueryOperation.init) ?? CKQueryOperation(query: query)
            op.desiredKeys = []
            op.resultsLimit = CKQueryOperation.maximumResults
            op.qualityOfService = .utility

            return try await withCheckedThrowingContinuation { continuation in
                var ids: [CKRecord.ID] = []

                op.recordMatchedBlock = { _, result in
                    if case .success(let record) = result {
                        ids.append(record.recordID)
                    }
                }

                op.queryResultBlock = { result in
                    switch result {
                    case .success(let cursor):
                        continuation.resume(returning: (ids, cursor))
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }

                database.add(op)
            }
        }

        var recordIDs: [CKRecord.ID] = []
        var cursor: CKQueryOperation.Cursor?
        repeat {
            let page = try await fetchIDs(cursor: cursor)
            recordIDs.append(contentsOf: page.0)
            cursor = page.1
        } while cursor != nil

        guard !recordIDs.isEmpty else { return 0 }

        let batchSize = 400
        var totalDeleted = 0

        for i in stride(from: 0, to: recordIDs.count, by: batchSize) {
            let endIndex = min(i + batchSize, recordIDs.count)
            let batch = Array(recordIDs[i..<endIndex])

            let operation = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: batch)

            let _: Void = try await withCheckedThrowingContinuation { continuation in
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

            totalDeleted += batch.count
        }

        return totalDeleted
    }

    // MARK: - Subscriptions

    private static func commandSubscriptionID(for clientId: String) -> CKSubscription.ID {
        "TelemetryCommand-\(clientId)"
    }

    public func createCommandSubscription(for clientId: String) async throws -> CKSubscription.ID {
        print("📡 [CloudKitClient] Creating subscription for clientId: \(clientId)")
        print("📡 [CloudKitClient] Container: \(identifier), Database scope: \(database.databaseScope.rawValue)")

        let predicate = NSPredicate(
            format: "%K == %@ AND %K == %@",
            TelemetrySchema.CommandField.clientId.rawValue,
            clientId,
            TelemetrySchema.CommandField.status.rawValue,
            TelemetrySchema.CommandStatus.pending.rawValue
        )
        print("📡 [CloudKitClient] Predicate: \(predicate)")

        let subscriptionID = Self.commandSubscriptionID(for: clientId)
        print("📡 [CloudKitClient] Subscription ID will be: \(subscriptionID)")

        let subscription = CKQuerySubscription(
            recordType: TelemetrySchema.commandRecordType,
            predicate: predicate,
            subscriptionID: subscriptionID,
            options: [.firesOnRecordCreation]
        )

        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        notificationInfo.shouldBadge = false
        notificationInfo.soundName = nil
        subscription.notificationInfo = notificationInfo

        do {
            let savedSubscription = try await database.save(subscription)
            print("✅ [CloudKitClient] Subscription saved successfully: \(savedSubscription.subscriptionID)")
            return savedSubscription.subscriptionID
        } catch {
            print("❌ [CloudKitClient] Failed to save subscription: \(error)")
            throw error
        }
    }

    public func removeCommandSubscription(_ subscriptionID: CKSubscription.ID) async throws {
        _ = try await database.deleteSubscription(withID: subscriptionID)
    }

    public func fetchCommandSubscription(for clientId: String) async throws -> CKSubscription.ID? {
        let subscriptionID = Self.commandSubscriptionID(for: clientId)
        do {
            let subscription = try await database.subscription(for: subscriptionID)
            return subscription.subscriptionID
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }

    // MARK: - TelemetryClient Subscriptions

    private static let clientRecordSubscriptionID: CKSubscription.ID = "TelemetryClient-All"

    public func createClientRecordSubscription() async throws -> CKSubscription.ID {
        print("📡 [CloudKitClient] Creating TelemetryClient subscription")

        let subscription = CKQuerySubscription(
            recordType: TelemetrySchema.clientRecordType,
            predicate: NSPredicate(value: true),
            subscriptionID: Self.clientRecordSubscriptionID,
            options: [.firesOnRecordCreation, .firesOnRecordUpdate, .firesOnRecordDeletion]
        )

        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        notificationInfo.shouldBadge = false
        notificationInfo.alertBody = "Client list changed"
        notificationInfo.soundName = "default"
        subscription.notificationInfo = notificationInfo

        let saved = try await database.save(subscription)
        print("✅ [CloudKitClient] TelemetryClient subscription saved: \(saved.subscriptionID)")
        return saved.subscriptionID
    }

    public func removeSubscription(_ subscriptionID: CKSubscription.ID) async throws {
        try await database.deleteSubscription(withID: subscriptionID)
    }

    public func fetchSubscription(id: CKSubscription.ID) async throws -> CKSubscription.ID? {
        do {
            let subscription = try await database.subscription(for: id)
            return subscription.subscriptionID
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
    }
}
