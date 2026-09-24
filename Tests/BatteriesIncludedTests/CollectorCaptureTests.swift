import XCTest
@testable import BatteriesIncluded

@MainActor
final class CollectorCaptureTests: XCTestCase {
    func testExportAndReplayPreserveSourcesAndOriginalTime() async throws {
        let time = Date(timeIntervalSince1970: 1_000)
        let readings = [
            BatteryObservation(sourceID: "native", stableID: "airpods", name: "AirPods", isConnected: true,
                category: .headphones, component: .case, percentage: 0, source: .system, observedAt: time),
            BatteryObservation(sourceID: "report", stableID: "airpods", name: "AirPods", isConnected: true,
                category: .headphones, component: .left, percentage: 80, source: .systemProfiler, observedAt: time),
            BatteryObservation(sourceID: "report", stableID: "airpods", name: "AirPods", isConnected: true,
                category: .headphones, component: .case, percentage: nil, source: .systemProfiler, observedAt: time)
        ]
        let monitor = DeviceMonitor(collectors: [
            CaptureFixture(snapshot: .init(availability: .available, observations: [readings[0]])),
            CaptureFixture(snapshot: .init(availability: .available, observations: Array(readings.dropFirst()))),
            CaptureFixture(snapshot: .init(availability: .permissionDenied, observations: []))
        ], now: { time })
        XCTAssertNil(monitor.collectorCapture)
        await monitor.refresh()
        let capture = try XCTUnwrap(monitor.collectorCapture)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try capture.write(to: url)
        let decoded = try CollectorCapture.load(path: url.path)
        XCTAssertEqual(decoded.capturedAt, time)
        XCTAssertEqual(decoded.collectors.count, 3)
        XCTAssertEqual(decoded.collectors.flatMap { $0.snapshot.observations }, readings)
        XCTAssertEqual(decoded.collectors[2].snapshot.availability, .permissionDenied)
        XCTAssertTrue(decoded.collectors[2].snapshot.observations.isEmpty)
        XCTAssertFalse(decoded.collectors[0].name.isEmpty)
        XCTAssertFalse(decoded.osVersion.isEmpty)
        XCTAssertFalse(decoded.appVersion.isEmpty)
        let replay = DeviceMonitor.collectorSnapshot(path: url.path)
        await replay.refresh()
        XCTAssertEqual(replay.state, monitor.state)
        guard case .devices(let devices) = replay.state else { return XCTFail("Expected replayed devices") }
        XCTAssertEqual(devices[0].levels.map(\.component), [.left])
        XCTAssertEqual(devices[0].levels.map(\.percentage), [80])
        await replay.refresh()
        XCTAssertEqual(replay.state, monitor.state)
    }

    func testReplayPreservesEmptyCollectorAvailability() async throws {
        let monitor = DeviceMonitor(collectors: [CaptureFixture(snapshot:
            .init(availability: .poweredOff, observations: []))])
        await monitor.refresh()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try XCTUnwrap(monitor.collectorCapture).write(to: url)
        let replay = DeviceMonitor.collectorSnapshot(path: url.path)
        await replay.refresh()
        XCTAssertEqual(replay.state, .bluetoothOff)
    }

    func testUnsupportedVersionIsRejected() async throws {
        let capture = CollectorCapture(capturedAt: Date(), collectors: [])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try capture.write(to: url)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["schemaVersion"] = 999
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        XCTAssertThrowsError(try CollectorCapture.load(path: url.path))
        let replay = DeviceMonitor.collectorSnapshot(path: url.path)
        await replay.refresh()
        guard case .snapshotError = replay.state else { return XCTFail("Expected unsupported version error") }
    }

    func testInvalidReplayReportsError() async {
        let replay = DeviceMonitor.collectorSnapshot(path: "/missing/capture.json")
        await replay.refresh()
        guard case .snapshotError = replay.state else { return XCTFail("Expected readable error") }
        XCTAssertNil(replay.collectorCapture)
    }
}

private struct CaptureFixture: BatteryCollecting {
    let snapshot: CollectorSnapshot
    func collect() async -> CollectorSnapshot { snapshot }
}
