import XCTest
@testable import BatteriesIncluded

final class BluetoothHelperTests: XCTestCase {
    func testSnapshotRoundTripPreservesBatteryAndAvailability() throws {
        let snapshot = CollectorSnapshot(availability: .available, observations: [
            BatteryObservation(sourceID: "headphones", stableID: "headphones", name: "WH-1000XM5",
                isConnected: true, category: .headphones, component: .whole, percentage: 80,
                source: .system, observedAt: Date(timeIntervalSince1970: 123))
        ])
        let decoded = try JSONDecoder().decode(CollectorSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.availability, .available)
        XCTAssertEqual(decoded.observations, snapshot.observations)
    }

    func testRunnerStartsFreshProcessForEveryRead() async throws {
        let runner = BluetoothHelperRunner(executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%s' $$"])
        let first = await runner.run()
        let second = await runner.run()
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first, second)
    }

    func testRunnerDrainsOutputLargerThanPipeBuffer() async {
        let runner = BluetoothHelperRunner(executableURL: URL(fileURLWithPath: "/usr/bin/head"),
            arguments: ["-c", "100000", "/dev/zero"])
        let result = await runner.run()
        XCTAssertEqual(result?.count, 100000)
    }

    func testCollectorRejectsMalformedHelperOutput() async {
        let runner = BluetoothHelperRunner(executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["invalid snapshot"])
        let snapshot = await SystemBluetoothCollector(runner: runner).collect()
        XCTAssertEqual(snapshot.availability, .unavailable)
        XCTAssertTrue(snapshot.observations.isEmpty)
    }

    func testCancellingReadStopsHelperPromptly() async {
        let runner = BluetoothHelperRunner(executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["10"])
        let task = Task { await runner.run() }
        try? await Task.sleep(for: .milliseconds(100))
        let start = Date()
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testRunnerRejectsFailedProcess() async {
        let runner = BluetoothHelperRunner(executableURL: URL(fileURLWithPath: "/usr/bin/false"))
        let result = await runner.run()
        XCTAssertNil(result)
    }

    func testRunnerTimesOutUnresponsiveProcess() async {
        let runner = BluetoothHelperRunner(executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["10"], timeout: 0.1)
        let start = Date()
        let result = await runner.run()
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }
}
