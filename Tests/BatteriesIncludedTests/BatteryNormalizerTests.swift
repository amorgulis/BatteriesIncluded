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

    func testPositiveWholeReplacesPlaceholderHeadphoneZeros() {
        let result = BatteryNormalizer().normalize([
            observation(percentage: 80, source: .systemProfiler),
            observation(component: .left, percentage: 0),
            observation(component: .right, percentage: 0),
            observation(component: .case, percentage: 0)
        ], now: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(result[0].levels.map(\.component), [.whole])
        XCTAssertEqual(result[0].levels.map(\.percentage), [80])
    }

    func testPreservesExplicitZeroComponentsFromSystemReport() {
        let result = BatteryNormalizer().normalize([
            observation(percentage: 80),
            observation(component: .left, percentage: 0, source: .systemProfiler),
            observation(component: .right, percentage: 0, source: .systemProfiler),
            observation(component: .case, percentage: 0, source: .systemProfiler)
        ], now: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(result[0].levels.map(\.component), [.left, .right, .case])
        XCTAssertEqual(result[0].levels.map(\.percentage), [0, 0, 0])
    }

    func testPreservesEmptyComponentAlongsideChargedComponents() {
        let result = BatteryNormalizer().normalize([
            observation(percentage: 80),
            observation(component: .left, percentage: 80),
            observation(component: .right, percentage: 80),
            observation(component: .case, percentage: 0)
        ], now: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(result[0].levels.map(\.component), [.left, .right, .case])
        XCTAssertEqual(result[0].levels.map(\.percentage), [80, 80, 0])
    }

    func testZeroComponentsRemainWithoutFreshPositiveWhole() {
        for (percentage, age): (Int?, TimeInterval) in [(nil, 0), (0, 0), (80, 61)] {
            let result = BatteryNormalizer().normalize([
                observation(percentage: percentage, age: age),
                observation(component: .left, percentage: 0),
                observation(component: .right, percentage: 0),
                observation(component: .case, percentage: 0)
            ], now: Date(timeIntervalSince1970: 1_000))

            XCTAssertEqual(result[0].levels.map(\.component), [.left, .right, .case])
            XCTAssertEqual(result[0].levels.map(\.percentage), [0, 0, 0])
        }
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

    func testDropsDisconnectedObservations() {
        let result = BatteryNormalizer().normalize([
            observation(connected: false)
        ], now: Date(timeIntervalSince1970: 1_000))
        XCTAssertTrue(result.isEmpty)
    }

    func testKeepsFreshCoarseLevelWhenExactPercentageIsUnavailable() {
        let result = BatteryNormalizer().normalize([
            BatteryObservation(
                sourceID: "receiver:1", stableID: "unit-1", name: "MX Keyboard",
                isConnected: true, category: .keyboard, component: .whole,
                percentage: nil, source: .logitechHID,
                observedAt: Date(timeIntervalSince1970: 1_000), coarseLevel: .low
            )
        ], now: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result[0].levels.isEmpty)
        XCTAssertEqual(result[0].coarseLevel, .low)
    }

    func testExactPercentageOutranksNewerCoarseLevel() {
        let result = BatteryNormalizer().normalize([
            observation(percentage: 67, source: .system, age: 1),
            BatteryObservation(
                sourceID: "hid", stableID: "stable-1", name: "AirPods Pro",
                isConnected: true, category: .headphones, component: .whole,
                percentage: nil, source: .logitechHID,
                observedAt: Date(timeIntervalSince1970: 1_000), coarseLevel: .good
            )
        ], now: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(result[0].levels.first?.percentage, 67)
        XCTAssertNil(result[0].coarseLevel)
    }

    func testMergesUniqueLogitechAndBluetoothGroupsWithSameName() {
        let result = BatteryNormalizer().normalize([
            observation(id: "bluetooth", stableID: "address", name: "MX Master", percentage: nil),
            BatteryObservation(
                sourceID: "hid", stableID: "unit", name: "MX Master", isConnected: true,
                category: .mouse, component: .whole, percentage: 88,
                source: .logitechHID, observedAt: Date(timeIntervalSince1970: 1_000)
            )
        ], now: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].levels.first?.percentage, 88)
    }
}
