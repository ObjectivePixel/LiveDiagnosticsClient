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

    func testSaveAndLoadState() async {
        await store.saveState(for: "NetworkRequests", isEnabled: true)
        let loaded = await store.loadState(for: "NetworkRequests")
        XCTAssertEqual(loaded, true)
    }

    func testLoadStateReturnsNilForUnknownScenario() async {
        let loaded = await store.loadState(for: "NeverSaved")
        XCTAssertNil(loaded)
    }

    func testOverwriteState() async {
        await store.saveState(for: "DataSync", isEnabled: true)
        await store.saveState(for: "DataSync", isEnabled: false)
        let loaded = await store.loadState(for: "DataSync")
        XCTAssertEqual(loaded, false)
    }

    func testMultipleScenariosIndependent() async {
        await store.saveState(for: "A", isEnabled: true)
        await store.saveState(for: "B", isEnabled: false)
        await store.saveState(for: "C", isEnabled: true)

        let a = await store.loadState(for: "A")
        let b = await store.loadState(for: "B")
        let c = await store.loadState(for: "C")
        XCTAssertEqual(a, true)
        XCTAssertEqual(b, false)
        XCTAssertEqual(c, true)
    }

    func testLoadAllStates() async {
        await store.saveState(for: "X", isEnabled: true)
        await store.saveState(for: "Y", isEnabled: false)

        let all = await store.loadAllStates()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all["X"], true)
        XCTAssertEqual(all["Y"], false)
    }

    func testRemoveState() async {
        await store.saveState(for: "ToRemove", isEnabled: true)
        await store.saveState(for: "ToKeep", isEnabled: false)
        await store.removeState(for: "ToRemove")

        let removed = await store.loadState(for: "ToRemove")
        let kept = await store.loadState(for: "ToKeep")
        XCTAssertNil(removed)
        XCTAssertEqual(kept, false)
    }

    func testRemoveAllStates() async {
        await store.saveState(for: "A", isEnabled: true)
        await store.saveState(for: "B", isEnabled: false)
        await store.removeAllStates()

        let all = await store.loadAllStates()
        XCTAssertTrue(all.isEmpty)
        let a = await store.loadState(for: "A")
        let b = await store.loadState(for: "B")
        XCTAssertNil(a)
        XCTAssertNil(b)
    }
}
