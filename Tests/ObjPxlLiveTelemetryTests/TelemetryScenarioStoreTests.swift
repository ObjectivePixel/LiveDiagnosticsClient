import XCTest
@testable import ObjPxlLiveTelemetry

final class TelemetryScenarioStoreTests: XCTestCase {
    private var store: UserDefaultsTelemetryScenarioStore!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "TelemetryScenarioStore-\(UUID().uuidString)")!
        store = UserDefaultsTelemetryScenarioStore(userDefaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaults.description)
        super.tearDown()
    }

    func testSaveAndLoadLevel() async {
        await store.saveLevel(for: "NetworkRequests", diagnosticLevel: TelemetryLogLevel.info.rawValue)
        let loaded = await store.loadLevel(for: "NetworkRequests")
        XCTAssertEqual(loaded, TelemetryLogLevel.info.rawValue)
    }

    func testLoadLevelReturnsNilForUnknownScenario() async {
        let loaded = await store.loadLevel(for: "NeverSaved")
        XCTAssertNil(loaded)
    }

    func testOverwriteLevel() async {
        await store.saveLevel(for: "DataSync", diagnosticLevel: TelemetryLogLevel.debug.rawValue)
        await store.saveLevel(for: "DataSync", diagnosticLevel: TelemetryScenarioRecord.levelOff)
        let loaded = await store.loadLevel(for: "DataSync")
        XCTAssertEqual(loaded, TelemetryScenarioRecord.levelOff)
    }

    func testMultipleScenariosIndependent() async {
        await store.saveLevel(for: "A", diagnosticLevel: TelemetryLogLevel.debug.rawValue)
        await store.saveLevel(for: "B", diagnosticLevel: TelemetryScenarioRecord.levelOff)
        await store.saveLevel(for: "C", diagnosticLevel: TelemetryLogLevel.warning.rawValue)

        let a = await store.loadLevel(for: "A")
        let b = await store.loadLevel(for: "B")
        let c = await store.loadLevel(for: "C")
        XCTAssertEqual(a, TelemetryLogLevel.debug.rawValue)
        XCTAssertEqual(b, TelemetryScenarioRecord.levelOff)
        XCTAssertEqual(c, TelemetryLogLevel.warning.rawValue)
    }

    func testLoadAllLevels() async {
        await store.saveLevel(for: "X", diagnosticLevel: TelemetryLogLevel.info.rawValue)
        await store.saveLevel(for: "Y", diagnosticLevel: TelemetryScenarioRecord.levelOff)

        let all = await store.loadAllLevels()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all["X"], TelemetryLogLevel.info.rawValue)
        XCTAssertEqual(all["Y"], TelemetryScenarioRecord.levelOff)
    }

    func testRemoveState() async {
        await store.saveLevel(for: "ToRemove", diagnosticLevel: TelemetryLogLevel.info.rawValue)
        await store.saveLevel(for: "ToKeep", diagnosticLevel: TelemetryScenarioRecord.levelOff)
        await store.removeState(for: "ToRemove")

        let removed = await store.loadLevel(for: "ToRemove")
        let kept = await store.loadLevel(for: "ToKeep")
        XCTAssertNil(removed)
        XCTAssertEqual(kept, TelemetryScenarioRecord.levelOff)
    }

    func testRemoveAllStates() async {
        await store.saveLevel(for: "A", diagnosticLevel: TelemetryLogLevel.debug.rawValue)
        await store.saveLevel(for: "B", diagnosticLevel: TelemetryScenarioRecord.levelOff)
        await store.removeAllStates()

        let all = await store.loadAllLevels()
        XCTAssertTrue(all.isEmpty)
        let a = await store.loadLevel(for: "A")
        let b = await store.loadLevel(for: "B")
        XCTAssertNil(a)
        XCTAssertNil(b)
    }
}
