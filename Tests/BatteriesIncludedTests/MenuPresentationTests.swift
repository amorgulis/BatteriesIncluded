import XCTest
@testable import BatteriesIncluded

final class MenuPresentationTests: XCTestCase {
    func testComponentSummaryUsesBalancedCopy() {
        let levels: [(BatteryComponent, Int)] = [(.left, 82), (.right, 76), (.case, 64)]

        XCTAssertEqual(DeviceBattery.componentSummary(levels), "Left 82% · Right 76% · Case 64%")
    }

    func testComponentSummaryUsesWholeAndExactCustomLabels() {
        let levels: [(BatteryComponent, Int)] = [(.whole, 91), (.custom("Stylus"), 48)]

        XCTAssertEqual(DeviceBattery.componentSummary(levels), "Battery 91% · Stylus 48%")
    }

    func testUnavailableDeviceShowsExpectedLabel() {
        let device = DeviceBattery(id: "x", name: "Speaker", category: .other, levels: [])

        XCTAssertEqual(device.primaryBatteryText, "Battery unavailable")
    }

    func testSingleWholeDeviceShowsPercentage() {
        let device = DeviceBattery(
            id: "x",
            name: "Mouse",
            category: .mouse,
            levels: [(component: .whole, percentage: 73)]
        )

        XCTAssertEqual(device.primaryBatteryText, "73%")
    }

    func testComponentDeviceUsesSummaryAsPrimaryText() {
        let device = DeviceBattery(
            id: "x",
            name: "Headphones",
            category: .headphones,
            levels: [(component: .left, percentage: 82), (component: .right, percentage: 76)]
        )

        XCTAssertEqual(device.primaryBatteryText, "Left 82% · Right 76%")
    }

    func testDeviceSymbols() {
        XCTAssertEqual(DeviceIcon.symbol(for: .headphones), "headphones")
        XCTAssertEqual(DeviceIcon.symbol(for: .mouse), "computermouse")
        XCTAssertEqual(DeviceIcon.symbol(for: .keyboard), "keyboard")
        XCTAssertEqual(DeviceIcon.symbol(for: .trackpad), "rectangle.and.hand.point.up.left")
        XCTAssertEqual(DeviceIcon.symbol(for: .gameController), "gamecontroller")
        XCTAssertEqual(DeviceIcon.symbol(for: .other), "hifispeaker")
    }
}
