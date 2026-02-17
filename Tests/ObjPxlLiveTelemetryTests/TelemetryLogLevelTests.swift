import XCTest
@testable import ObjPxlLiveTelemetry

final class TelemetryLogLevelTests: XCTestCase {

    func testRawValues() {
        XCTAssertEqual(TelemetryLogLevel.info.rawValue, "info")
        XCTAssertEqual(TelemetryLogLevel.diagnostic.rawValue, "diagnostic")
    }

    func testAllCasesContainsBothLevels() {
        XCTAssertEqual(TelemetryLogLevel.allCases.count, 2)
        XCTAssertTrue(TelemetryLogLevel.allCases.contains(.info))
        XCTAssertTrue(TelemetryLogLevel.allCases.contains(.diagnostic))
    }

    func testComparableOrdering() {
        XCTAssertTrue(TelemetryLogLevel.info < .diagnostic)
        XCTAssertFalse(TelemetryLogLevel.diagnostic < .info)
        XCTAssertFalse(TelemetryLogLevel.info < .info)
    }

    func testRawValueRoundTrip() {
        for level in TelemetryLogLevel.allCases {
            let recreated = TelemetryLogLevel(rawValue: level.rawValue)
            XCTAssertEqual(recreated, level)
        }
    }
}
