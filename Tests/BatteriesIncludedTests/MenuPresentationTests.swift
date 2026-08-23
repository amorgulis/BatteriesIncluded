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
}
