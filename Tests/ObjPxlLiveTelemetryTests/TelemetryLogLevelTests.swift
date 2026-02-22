import XCTest
@testable import ObjPxlLiveTelemetry

final class TelemetryLogLevelTests: XCTestCase {

    func testRawValues() {
        XCTAssertEqual(TelemetryLogLevel.debug.rawValue, 0)
        XCTAssertEqual(TelemetryLogLevel.info.rawValue, 1)
        XCTAssertEqual(TelemetryLogLevel.warning.rawValue, 2)
        XCTAssertEqual(TelemetryLogLevel.error.rawValue, 3)
    }

    func testAllCasesContainsAllLevels() {
        XCTAssertEqual(TelemetryLogLevel.allCases.count, 4)
        XCTAssertTrue(TelemetryLogLevel.allCases.contains(.debug))
        XCTAssertTrue(TelemetryLogLevel.allCases.contains(.info))
        XCTAssertTrue(TelemetryLogLevel.allCases.contains(.warning))
        XCTAssertTrue(TelemetryLogLevel.allCases.contains(.error))
    }

    func testComparableOrdering() {
        XCTAssertTrue(TelemetryLogLevel.debug < .info)
        XCTAssertTrue(TelemetryLogLevel.info < .warning)
        XCTAssertTrue(TelemetryLogLevel.warning < .error)
        XCTAssertFalse(TelemetryLogLevel.error < .debug)
        XCTAssertFalse(TelemetryLogLevel.info < .info)
    }

    func testRawValueRoundTrip() {
        for level in TelemetryLogLevel.allCases {
            let recreated = TelemetryLogLevel(rawValue: level.rawValue)
            XCTAssertEqual(recreated, level)
        }
    }

    func testDescription() {
        XCTAssertEqual(TelemetryLogLevel.debug.description, "Debug")
        XCTAssertEqual(TelemetryLogLevel.info.description, "Info")
        XCTAssertEqual(TelemetryLogLevel.warning.description, "Warning")
        XCTAssertEqual(TelemetryLogLevel.error.description, "Error")
    }
}
