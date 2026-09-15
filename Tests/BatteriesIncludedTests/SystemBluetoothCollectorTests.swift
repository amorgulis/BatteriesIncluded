import XCTest
@testable import BatteriesIncluded

final class SystemBluetoothCollectorTests: XCTestCase {
    func testReadsLowercaseSingleBatterySelector() {
        let percentages = SystemBluetoothCollector.percentages(fromDevice: SingleBatteryHeadphones())
        XCTAssertEqual(percentages[.whole] ?? nil, 90)
    }

    func testSingleBatteryHeadphonesIgnoreComponentZeros() {
        let reading = SystemDeviceReading(
            address: "AA-BB", name: "WH-1000XM5", isConnected: true,
            category: .headphones,
            percentages: [.whole: 90, .left: 0, .right: 0, .case: 0],
            isMultiBatteryDevice: false
        )
        let observations = SystemBluetoothCollector.map(reading, now: .distantPast)
        XCTAssertEqual(observations.map(\.component), [.whole])
        XCTAssertEqual(observations.map(\.percentage), [90])
    }

    func testSingleBatteryHeadphonesWithoutLevelReportUnavailable() {
        let reading = SystemDeviceReading(
            address: "AA-BB", name: "WH-1000XM5", isConnected: true,
            category: .headphones, percentages: [.left: 0, .right: 0, .case: 0],
            isMultiBatteryDevice: false
        )
        let observations = SystemBluetoothCollector.map(reading, now: .distantPast)
        XCTAssertEqual(observations.map(\.component), [.whole])
        XCTAssertNil(observations[0].percentage)
    }

    func testReadsMultiBatteryCapabilityWhenAvailable() {
        XCTAssertEqual(SystemBluetoothCollector.multiBatteryCapability(fromDevice: SingleBatteryHeadphones()), false)
        XCTAssertEqual(SystemBluetoothCollector.multiBatteryCapability(fromDevice: MultiBatteryHeadphones()), true)
        XCTAssertNil(SystemBluetoothCollector.multiBatteryCapability(fromDevice: NSObject()))
    }

    func testMapsConnectedMultiComponentDevice() {
        let reading = SystemDeviceReading(
            address: "AA-BB", name: "Buds", isConnected: true,
            category: .headphones,
            percentages: [.left: 81, .right: 79, .case: 55]
        )

        let observations = SystemBluetoothCollector.map(reading, now: .distantPast)

        XCTAssertEqual(observations.map(\.component), [.left, .right, .case])
        XCTAssertTrue(observations.allSatisfy(\.isConnected))
        XCTAssertEqual(observations.map(\.sourceID), ["AA:BB", "AA:BB", "AA:BB"])
        XCTAssertEqual(observations.map(\.stableID), ["AA:BB", "AA:BB", "AA:BB"])
    }

    func testMapsUnsupportedConnectedDeviceWithNilLevel() {
        let reading = SystemDeviceReading(
            address: "CC-DD", name: "Speaker", isConnected: true,
            category: .other, percentages: [:]
        )

        let observations = SystemBluetoothCollector.map(reading, now: .distantPast)

        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations[0].component, .whole)
        XCTAssertNil(observations[0].percentage)
    }

    func testDoesNotMapDisconnectedDevice() {
        let reading = SystemDeviceReading(
            address: "EE-FF", name: "Offline", isConnected: false,
            category: .headphones, percentages: [.whole: 90]
        )

        XCTAssertTrue(SystemBluetoothCollector.map(reading, now: .distantPast).isEmpty)
    }

    func testNormalizesRegistryAddressData() {
        let address = Data([0xAA, 0xBB, 0x01, 0x02, 0x0C, 0x0D])

        XCTAssertEqual(
            SystemBluetoothCollector.registryAddress(in: ["BD_ADDR": address]),
            "AA:BB:01:02:0C:0D"
        )
    }

    func testRegistryReducerMergesDisjointComponentMaps() {
        let result = SystemBluetoothCollector.mergeRegistryPercentageMaps([
            [.left: 81],
            [.right: 79, .case: 55]
        ])

        XCTAssertEqual(result[.left]!, 81)
        XCTAssertEqual(result[.right]!, 79)
        XCTAssertEqual(result[.case]!, 55)
    }

    func testRegistryReducerKeepsFirstValidComponentValue() {
        let result = SystemBluetoothCollector.mergeRegistryPercentageMaps([
            [.left: 81, .right: 101, .case: nil],
            [.left: 72, .right: 79, .case: 55]
        ])

        XCTAssertEqual(result[.left]!, 81)
        XCTAssertEqual(result[.right]!, 79)
        XCTAssertEqual(result[.case]!, 55)
    }

    func testMouseIgnoresBogusHeadphoneComponentSelectors() {
        let reading = SystemDeviceReading(
            address: "F0:CF:B8:FD:A9:B8",
            name: "M720 Triathlon",
            isConnected: true,
            category: .mouse,
            percentages: [.left: 0, .right: 0, .case: 0]
        )

        let observations = SystemBluetoothCollector.map(reading, now: .distantPast)

        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(observations[0].component, .whole)
        XCTAssertNil(observations[0].percentage)
    }
}

private final class SingleBatteryHeadphones: NSObject {
    @objc var batteryPercentSingle: Int { 90 }
    @objc var isMultiBatteryDevice: Bool { false }
}

private final class MultiBatteryHeadphones: NSObject {
    @objc var isMultiBatteryDevice: Bool { true }
}
