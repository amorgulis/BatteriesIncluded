import XCTest
@testable import BatteriesIncluded

final class BatteryNormalizerTests: XCTestCase {
    private func observation(
        id: String = "device-1", stableID: String? = "stable-1",
        name: String = "AirPods Pro", connected: Bool = true,
        component: BatteryComponent = .whole, percentage: Int? = 50,
        source: BatterySource = .system, age: TimeInterval = 0
    ) -> BatteryObservation {
        .init(sourceID: id, stableID: stableID, name: name, isConnected: connected,
              category: .headphones, component: component, percentage: percentage,
              source: source, observedAt: Date(timeIntervalSince1970: 1_000 - age))
    }

    func testKnownComponentsHaveDeterministicOrder() {
        let values: [BatteryComponent] = [.custom("Stem"), .case, .right, .left, .whole]
        XCTAssertEqual(values.sorted(), [.whole, .left, .right, .case, .custom("Stem")])
    }

    func testRejectsInvalidAndStalePercentagesButKeepsDevice() {
        let observations = [
            observation(component: .left, percentage: -1),
            observation(component: .right, percentage: 101),
            observation(component: .case, percentage: 70, age: 61)
        ]
        let result = BatteryNormalizer().normalize(
            observations, now: Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].levels.isEmpty)
    }

    func testMergesMatchingStableIDsAndOrdersComponents() {
        let result = BatteryNormalizer().normalize([
            observation(id: "system", component: .case, percentage: 60),
            observation(id: "ble", component: .right, percentage: 70, source: .coreBluetooth),
            observation(id: "ble", component: .left, percentage: 80, source: .coreBluetooth)
        ], now: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].levels.map(\.component), [.left, .right, .case])
    }

    func testSuppressesWholeWhenFreshValidComponentExists() {
        let result = BatteryNormalizer().normalize([
            observation(component: .whole, percentage: 90),
            observation(component: .left, percentage: 80)
        ], now: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(result[0].levels.map(\.component), [.left])
        XCTAssertEqual(result[0].levels.map(\.percentage), [80])
    }

    func testKeepsValidWholeWhenComponentsAreInvalidOrStale() {
        let result = BatteryNormalizer().normalize([
            observation(component: .whole, percentage: 90),
            observation(component: .left, percentage: -1),
            observation(component: .right, percentage: 101),
            observation(component: .case, percentage: 70, age: 61)
        ], now: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(result[0].levels.map(\.component), [.whole])
        XCTAssertEqual(result[0].levels.map(\.percentage), [90])
    }

    func testPrefersBLEReadingWithinOneSecond() {
        let result = BatteryNormalizer().normalize([
            observation(percentage: 90, source: .system),
            observation(percentage: 80, source: .coreBluetooth, age: 1)
        ], now: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(result[0].levels[0].percentage, 80)
    }

    func testDoesNotMergeAmbiguousDevicesWithoutStableID() {
        let result = BatteryNormalizer().normalize([
            observation(id: "one", stableID: nil, name: "Headphones"),
            observation(id: "two", stableID: nil, name: "Headphones")
        ], now: Date(timeIntervalSince1970: 1_000))
        XCTAssertEqual(result.count, 2)
    }

    func testMergesUniqueSystemAndBLEGroupsWithSameDeviceName() {
        let result = BatteryNormalizer().normalize([
            observation(
                id: "D0:28:33:06:B7:96",
                stableID: "D0:28:33:06:B7:96",
                name: "Keychron K1 Max (work)",
                percentage: nil,
                source: .system
            ),
            observation(
                id: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                stableID: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                name: "Keychron K1 Max (work)",
                percentage: 62,
                source: .coreBluetooth
            )
        ], now: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, "stable:D0:28:33:06:B7:96")
        XCTAssertEqual(result[0].levels.map(\.percentage), [62])
    }

    func testMergesUniqueBluetoothAndLogitechHIDGroupsWithSameDeviceName() {
        let result = BatteryNormalizer().normalize([
            observation(
                id: "D0:28:33:06:B7:96", stableID: "D0:28:33:06:B7:96",
                name: "MX Master 3S", percentage: 44, source: .system
            ),
            observation(
                id: "receiver:1", stableID: nil, name: "MX Master 3S",
                percentage: 72, source: .logitechHID
            )
        ], now: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].levels.map(\.percentage), [72])
    }

    func testMergesUniqueSystemBLEAndLogitechHIDGroupsWithSameDeviceName() {
        let result = BatteryNormalizer().normalize([
            observation(
                id: "D0:28:33:06:B7:96", stableID: "D0:28:33:06:B7:96",
                name: "MX Master 3S", percentage: nil, source: .system
            ),
            observation(
                id: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                stableID: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                name: "MX Master 3S", percentage: 44, source: .coreBluetooth
            ),
            observation(
                id: "receiver:1", stableID: nil, name: "MX Master 3S",
                percentage: 72, source: .logitechHID
            )
        ], now: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].levels.map(\.percentage), [72])
    }

    func testDropsDisconnectedObservations() {
        let result = BatteryNormalizer().normalize([
            observation(connected: false)
        ], now: Date(timeIntervalSince1970: 1_000))
        XCTAssertTrue(result.isEmpty)
    }
}
