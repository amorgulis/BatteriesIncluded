import XCTest
@testable import BatteriesIncluded

final class SystemBluetoothCollectorTests: XCTestCase {
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
