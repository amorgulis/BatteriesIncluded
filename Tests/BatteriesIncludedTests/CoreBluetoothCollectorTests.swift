import XCTest
@testable import BatteriesIncluded

final class CoreBluetoothCollectorTests: XCTestCase {
    func testMapsStandardBatteryLevelCharacteristic() {
        let reading = BLEDeviceReading(
            identifier: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "Heart Rate Strap",
            isConnected: true,
            batteryLevel: 72
        )

        let result = CoreBluetoothCollector.map(reading, now: .distantPast)

        XCTAssertEqual(result.single?.component, .whole)
        XCTAssertEqual(result.single?.percentage, 72)
        XCTAssertEqual(result.single?.source, .coreBluetooth)
        XCTAssertEqual(result.single?.sourceID, "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        XCTAssertEqual(result.single?.stableID, "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        XCTAssertEqual(result.single?.name, "Heart Rate Strap")
        XCTAssertEqual(result.single?.observedAt, .distantPast)
    }

    func testPreservesUnavailableAndInvalidLevelsForNormalizer() {
        let identifier = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

        let unavailable = CoreBluetoothCollector.map(
            BLEDeviceReading(
                identifier: identifier,
                name: "Unavailable Sensor",
                isConnected: true,
                batteryLevel: nil
            ),
            now: .distantPast
        )
        let invalid = CoreBluetoothCollector.map(
            BLEDeviceReading(
                identifier: identifier,
                name: "Invalid Sensor",
                isConnected: true,
                batteryLevel: 101
            ),
            now: .distantPast
        )

        XCTAssertNil(unavailable.single?.percentage)
        XCTAssertEqual(invalid.single?.percentage, 101)
    }

    func testDoesNotReportDisconnectedPeripheral() {
        let reading = BLEDeviceReading(
            identifier: UUID(),
            name: "Sensor",
            isConnected: false,
            batteryLevel: 50
        )

        XCTAssertTrue(CoreBluetoothCollector.map(reading, now: .distantPast).isEmpty)
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
