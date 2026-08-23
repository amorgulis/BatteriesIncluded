import XCTest
@testable import BatteriesIncluded

final class BatteryNormalizerTests: XCTestCase {
    func testKnownComponentsHaveDeterministicOrder() {
        let values: [BatteryComponent] = [.custom("Stem"), .case, .right, .left, .whole]
        XCTAssertEqual(values.sorted(), [.whole, .left, .right, .case, .custom("Stem")])
    }
}
