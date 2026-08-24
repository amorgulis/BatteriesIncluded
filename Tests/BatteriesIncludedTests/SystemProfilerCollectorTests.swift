import XCTest
@testable import BatteriesIncluded

final class SystemProfilerCollectorTests: XCTestCase {
    private let capturedAt = Date(timeIntervalSince1970: 1_000)

    func testParsesConnectedMouseMainBatteryFromBluetoothReport() throws {
        let data = Data(#"""
        {
          "SPBluetoothDataType": [{
            "controller_properties": {},
            "device_connected": [{
                "M720 Triathlon": {
                  "device_address": "F0:CF:B8:FD:A9:B8",
                  "device_batteryLevelMain": "100%",
                  "device_minorType": "Mouse"
                }
              }],
            "device_not_connected": [{
                "Old Mouse": {
                  "device_address": "00:11:22:33:44:55",
                  "device_batteryLevelMain": "20%"
                }
              }]
          }]
        }
        """#.utf8)

        let observations = try SystemProfilerBluetoothParser().parse(data, observedAt: capturedAt)

        XCTAssertEqual(observations, [
            BatteryObservation(
                sourceID: "F0:CF:B8:FD:A9:B8",
                stableID: "F0:CF:B8:FD:A9:B8",
                name: "M720 Triathlon",
                isConnected: true,
                category: .mouse,
                component: .whole,
                percentage: 100,
                source: .systemProfiler,
                observedAt: capturedAt
            )
        ])
    }

    func testParsesSplitComponentBatteriesAndIgnoresMalformedValues() throws {
        let data = Data(#"""
        {
          "SPBluetoothDataType": [{
            "controller_properties": {
              "device_connected": [{
                "AirPods Pro": {
                  "device_address": "aa-bb-cc-dd-ee-ff",
                  "device_batteryLevelLeft": "93%",
                  "device_batteryLevelRight": "unknown",
                  "device_batteryLevelCase": "64%",
                  "device_minorType": "Headphones"
                }
              }]
            }
          }]
        }
        """#.utf8)

        let observations = try SystemProfilerBluetoothParser().parse(data, observedAt: capturedAt)

        XCTAssertEqual(observations.map(\.component), [.left, .case])
        XCTAssertEqual(observations.map(\.percentage), [93, 64])
        XCTAssertTrue(observations.allSatisfy { $0.stableID == "AA:BB:CC:DD:EE:FF" })
    }

    func testMalformedReportThrowsInsteadOfInventingDevices() {
        XCTAssertThrowsError(
            try SystemProfilerBluetoothParser().parse(Data("not-json".utf8), observedAt: capturedAt)
        )
    }

    func testCommandRunnerReturnsNilWhenProcessExceedsTimeout() async {
        let runner = SystemProfilerCommandRunner(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["1"],
            timeout: 0.02
        )

        let result = await runner.run()

        XCTAssertNil(result)
    }

    func testCommandRunnerReturnsNilForFailedCommand() async {
        let runner = SystemProfilerCommandRunner(
            executableURL: URL(fileURLWithPath: "/usr/bin/false"),
            arguments: [],
            timeout: 1
        )

        let result = await runner.run()

        XCTAssertNil(result)
    }

    func testFallbackDoesNotReplaceFreshNativeSystemReading() {
        let address = "F0:CF:B8:FD:A9:B8"
        let native = BatteryObservation(
            sourceID: address, stableID: address, name: "M720 Triathlon", isConnected: true,
            category: .mouse, component: .whole, percentage: 80, source: .system,
            observedAt: capturedAt
        )
        let fallback = BatteryObservation(
            sourceID: address, stableID: address, name: "M720 Triathlon", isConnected: true,
            category: .mouse, component: .whole, percentage: 100, source: .systemProfiler,
            observedAt: capturedAt.addingTimeInterval(10)
        )

        let devices = BatteryNormalizer().normalize(
            [native, fallback], now: capturedAt.addingTimeInterval(10)
        )

        XCTAssertEqual(devices.first?.levels.first?.percentage, 80)
    }
}
