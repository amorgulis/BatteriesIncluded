import XCTest
@testable import BatteriesIncluded

final class LogitechHIDCollectorTests: XCTestCase {
    func testMapsLogitechDeviceToWholeBatteryObservation() {
        let observedAt = Date(timeIntervalSince1970: 1_000)
        let device = LogitechDeviceReading(
            id: "IOHIDDevice_00100000_FF00_0001:1",
            name: "MX Master 3S",
            batteryLevel: 72,
            category: .mouse
        )

        let observation = LogitechHIDCollector.map(device, observedAt: observedAt)

        XCTAssertEqual(observation, BatteryObservation(
            sourceID: "IOHIDDevice_00100000_FF00_0001:1",
            stableID: nil,
            name: "MX Master 3S",
            isConnected: true,
            category: .mouse,
            component: .whole,
            percentage: 72,
            source: .logitechHID,
            observedAt: observedAt
        ))
    }

    func testClassifiesCommonLogitechDeviceNames() {
        XCTAssertEqual(LogitechHIDCollector.category(for: "MX Master 3S"), .mouse)
        XCTAssertEqual(LogitechHIDCollector.category(for: "MX Keys S"), .keyboard)
        XCTAssertEqual(LogitechHIDCollector.category(for: "G Pro X Wireless"), .headphones)
        XCTAssertEqual(LogitechHIDCollector.category(for: "Logitech Device 1"), .other)
    }
}
