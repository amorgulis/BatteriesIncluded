import XCTest
@testable import BatteriesIncluded

final class MenuBarBatteryTests: XCTestCase {
    func testLowestDeviceDeterminesFillAndTooltip() {
        let summary = MenuBarBattery(state: .devices([
            DeviceBattery(id: "m", name: "Mouse", category: .mouse, levels: [(.whole, 80)], chargingState: .charging),
            DeviceBattery(id: "k", name: "Keyboard", category: .keyboard, levels: [(.whole, 20)])
        ]))
        XCTAssertEqual(summary.percentage, 20)
        XCTAssertFalse(summary.isCharging)
        XCTAssertEqual(summary.tooltip, "Lowest battery: Keyboard — 20%")
    }

    func testLowestComponentStillSetsFillButUnknownComponentPreventsChargingBolt() {
        let summary = MenuBarBattery(state: .devices([
            DeviceBattery(id: "e", name: "Earbuds", category: .headphones,
                          levels: [(.left, 80), (.right, 65), (.case, 12)],
                          componentChargingStates: [.left: .charging, .case: .charging])
        ]))
        XCTAssertEqual(summary.percentage, 12)
        XCTAssertFalse(summary.isCharging)
        XCTAssertEqual(summary.tooltip, "Lowest battery: Earbuds — Case 12%, charging")
    }

    func testChargingBoltRequiresEveryDeviceToBeCharging() {
        for state: BatteryChargingState? in [.charging, .discharging, .full, .unknown, nil] {
            let summary = MenuBarBattery(state: .devices([
                DeviceBattery(id: "m", name: "Mouse", category: .mouse,
                              levels: [(.whole, 20)], chargingState: .charging),
                DeviceBattery(id: "k", name: "Keyboard", category: .keyboard,
                              levels: [(.whole, 80)], chargingState: state)
            ]))
            XCTAssertEqual(summary.percentage, 20)
            XCTAssertEqual(summary.isCharging, state == .charging)
        }
    }

    func testDischargingComponentPreventsBoltEvenWhenDeviceReportsCharging() {
        let summary = MenuBarBattery(state: .devices([
            DeviceBattery(id: "e", name: "Earbuds", category: .headphones,
                          levels: [(.left, 20), (.right, 80)], chargingState: .charging,
                          componentChargingStates: [.left: .charging, .right: .discharging])
        ]))
        XCTAssertFalse(summary.isCharging)
    }

    func testAllComponentsChargingShowsBolt() {
        let summary = MenuBarBattery(state: .devices([
            DeviceBattery(id: "e", name: "Earbuds", category: .headphones,
                          levels: [(.left, 20), (.right, 80), (.case, 60)],
                          componentChargingStates: [.left: .charging, .right: .charging, .case: .charging])
        ]))
        XCTAssertTrue(summary.isCharging)
    }

    func testDeviceWithoutReadingStillParticipatesInChargingDecision() {
        let summary = MenuBarBattery(state: .devices([
            DeviceBattery(id: "m", name: "Mouse", category: .mouse,
                          levels: [(.whole, 20)], chargingState: .charging),
            DeviceBattery(id: "u", name: "Speaker", category: .other, levels: [])
        ]))
        XCTAssertFalse(summary.isCharging)
    }

    func testMissingReadingsDoNotMasqueradeAsZero() {
        let summary = MenuBarBattery(state: .devices([
            DeviceBattery(id: "u", name: "Speaker", category: .other, levels: []),
            DeviceBattery(id: "m", name: "Mouse", category: .mouse, levels: [(.whole, 60)])
        ]))
        XCTAssertEqual(summary.percentage, 60)
        XCTAssertTrue(summary.tooltip.contains("Some battery levels unavailable"))
    }

    func testNoNumericReadingsShowUnknownIncludingCoarseLevels() {
        for state: MenuState in [.loading, .noDevices, .bluetoothOff, .permissionDenied, .unavailable,
                                 .devices([DeviceBattery(id: "k", name: "Keyboard", category: .keyboard,
                                                         levels: [], coarseLevel: .low)])] {
            let summary = MenuBarBattery(state: state)
            XCTAssertNil(summary.percentage)
            XCTAssertFalse(summary.isCharging)
            XCTAssertFalse(summary.tooltip.isEmpty)
        }
    }

    func testZeroIsAValidReadingAndFullIsNotCharging() {
        let summary = MenuBarBattery(state: .devices([
            DeviceBattery(id: "m", name: "Mouse", category: .mouse, levels: [(.whole, 0)], chargingState: .full)
        ]))
        XCTAssertEqual(summary.percentage, 0)
        XCTAssertFalse(summary.isCharging)
    }
}
