import XCTest
@testable import BatteriesIncluded

final class BatteryNormalizerTests: XCTestCase {
    func testChargingStatesStayWithTheirHeadphoneComponents() {
        var left = observation(component: .left, percentage: 50)
        left.chargingState = .charging
        var right = observation(component: .right, percentage: 100)
        right.chargingState = .full
        var caseBattery = observation(component: .case, percentage: 80)
        caseBattery.chargingState = .discharging
        let device = BatteryNormalizer().normalize([left, right, caseBattery],
            now: Date(timeIntervalSince1970: 1_000))[0]

        XCTAssertEqual(device.menuRowText,
            "AirPods Pro — Left 50% · Right 100% · Case 80%")
        XCTAssertEqual(device.menuBatteryParts.map(\.isCharging), [true, false, false])
    }

    func testComponentStatusExpiresAndDoesNotKeepDeviceInChargingState() {
        var stale = observation(component: .left, percentage: nil, age: 61)
        stale.chargingState = .charging
        let fresh = observation(component: .left, percentage: 70)
        let device = BatteryNormalizer().normalize([stale, fresh],
            now: Date(timeIntervalSince1970: 1_000))[0]

        XCTAssertEqual(device.menuRowText, "AirPods Pro — Left 70%")
        XCTAssertTrue(device.componentChargingStates.isEmpty)
    }

    func testChangingOnlyComponentChargingStatusChangesDeviceEquality() {
        var component = observation(component: .left, percentage: 70)
        component.chargingState = .charging
        let before = BatteryNormalizer().normalize([component], now: Date(timeIntervalSince1970: 1_000))[0]
        component.chargingState = .discharging
        let after = BatteryNormalizer().normalize([component], now: Date(timeIntervalSince1970: 1_000))[0]

        XCTAssertNotEqual(before, after)
    }

    func testComponentChargingWithoutPercentageIsStillVisible() {
        var left = observation(component: .left, percentage: nil)
        left.chargingState = .charging
        let device = BatteryNormalizer().normalize([left, observation(percentage: 80)],
            now: Date(timeIntervalSince1970: 1_000))[0]

        XCTAssertEqual(device.menuRowText, "AirPods Pro — Left Battery unavailable")
        XCTAssertTrue(device.menuBatteryParts[0].isCharging)
    }

    func testUnknownFromDifferentSourceDoesNotHideKnownChargingState() {
        var native = observation(percentage: 80, source: .system, age: 1)
        native.chargingState = .charging
        var ble = observation(percentage: 80, source: .coreBluetooth)
        ble.chargingState = .unknown
        let device = BatteryNormalizer().normalize([native, ble],
            now: Date(timeIntervalSince1970: 1_000))[0]

        XCTAssertEqual(device.menuRowText, "AirPods Pro — 80%")
        XCTAssertTrue(device.menuBatteryParts[0].isCharging)
    }

    func testExplicitZeroComponentsWithChargingReportsAreNotPlaceholders() {
        var components = [BatteryComponent.left, .right, .case].map {
            observation(component: $0, percentage: 0)
        }
        for index in components.indices { components[index].chargingState = .charging }
        let device = BatteryNormalizer().normalize(components + [observation(percentage: 80)],
            now: Date(timeIntervalSince1970: 1_000))[0]

        XCTAssertEqual(device.levels.map(\.component), [.left, .right, .case])
        XCTAssertTrue(device.menuRowText.contains("Left 0%"))
        XCTAssertTrue(device.menuBatteryParts.allSatisfy(\.isCharging))
    }

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
                name: "Keychron K1 Max",
                percentage: nil,
                source: .system
            ),
            observation(
                id: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                stableID: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                name: "Keychron K1 Max",
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

    func testPreservesChargingStatusWhenAnotherSourceSuppliesExactLevel() {
        var hid = observation(percentage: nil, source: .logitechHID)
        hid.coarseLevel = .good
        hid.chargingState = .charging
        let result = BatteryNormalizer().normalize([
            observation(percentage: 67, source: .system, age: 1), hid
        ], now: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(result[0].levels.first?.percentage, 67)
        XCTAssertEqual(result[0].chargingState, .charging)
    }

    func testNewerUnknownStatusClearsOlderChargingReport() {
        var older = observation(source: .logitechHID, age: 1)
        older.chargingState = .charging
        var newer = observation(source: .logitechHID)
        newer.chargingState = .unknown
        let result = BatteryNormalizer().normalize(
            [older, newer], now: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(result[0].chargingState, .unknown)
        XCTAssertFalse(result[0].menuBatteryParts[0].isCharging)
    }

    func testDoesNotApplyWholeDeviceChargingStatusToIndividualComponents() {
        var whole = observation(source: .logitechHID)
        whole.chargingState = .charging
        let result = BatteryNormalizer().normalize([
            whole, observation(component: .left, percentage: 80)
        ], now: Date(timeIntervalSince1970: 1_000))

        XCTAssertEqual(result[0].levels.map(\.component), [.left])
        XCTAssertNil(result[0].chargingState)
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
