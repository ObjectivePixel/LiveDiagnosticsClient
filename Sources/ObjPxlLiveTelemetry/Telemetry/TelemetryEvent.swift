import CloudKit
import Foundation

struct TelemetryEvent: Sendable {
    let id: UUID
    let name: String
    let timestamp: Date
    let sessionId: String
    let deviceInfo: DeviceInfo
    let threadId: String
    let property1: String?
    let scenario: String?
    let level: TelemetryLogLevel

    init(
        name: String,
        timestamp: Date,
        sessionId: String,
        deviceInfo: DeviceInfo,
        threadId: String,
        property1: String? = nil,
        scenario: String? = nil,
        level: TelemetryLogLevel = .info
    ) {
        self.id = UUID()
        self.name = name
        self.timestamp = timestamp
        self.sessionId = sessionId
        self.deviceInfo = deviceInfo
        self.threadId = threadId
        self.property1 = property1
        self.scenario = scenario
        self.level = level
    }

    func toCKRecord() -> CKRecord {
        let record = CKRecord(recordType: TelemetrySchema.recordType)

        record["eventId"] = id.uuidString
        record["eventName"] = name
        record["eventTimestamp"] = timestamp
        record["sessionId"] = sessionId
        record["deviceType"] = deviceInfo.deviceType
        record["deviceName"] = deviceInfo.deviceName
        record["deviceModel"] = deviceInfo.deviceModel
        record["osVersion"] = deviceInfo.osVersion
        record["appVersion"] = deviceInfo.appVersion
        record["threadId"] = threadId
        record["property1"] = property1
        record[TelemetrySchema.Field.scenario.rawValue] = scenario
        record[TelemetrySchema.Field.logLevel.rawValue] = level.rawValue as CKRecordValue

        return record
    }
}
