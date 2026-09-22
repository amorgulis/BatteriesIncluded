#if DEBUG
import XCTest
@testable import BatteriesIncluded

@MainActor
final class DeviceSnapshotTests: XCTestCase {
    func testRefreshReloadsFileAndRecoversAfterError() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let monitor = DeviceMonitor.snapshot(path: url.path)
        await monitor.refresh()
        guard case .snapshotError = monitor.state else { return XCTFail("Missing file must show an error") }

        try Data("""
        [{"id":"mouse","name":"Mouse","category":"mouse","levels":[{"component":"whole","percentage":42}],"chargingState":"charging"}]
        """.utf8).write(to: url)
        await monitor.refresh()
        guard case .devices(let devices) = monitor.state else { return XCTFail("Expected devices") }
        XCTAssertEqual(devices.first?.menuRowText, "Mouse — 42%")
        XCTAssertEqual(devices.first?.menuBatteryParts.first?.isCharging, true)

        try Data("[]".utf8).write(to: url)
        await monitor.refresh()
        XCTAssertEqual(monitor.state, .noDevices)

        try Data("invalid".utf8).write(to: url)
        await monitor.refresh()
        guard case .snapshotError = monitor.state else { return XCTFail("Invalid JSON must show an error") }
    }

    func testRejectsInvalidDeviceData() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        for json in [
            #"[{"id":"x","name":"Mouse","category":"mouse","levels":[{"component":"whole","percentage":101}]}]"#,
            #"[{"id":"x","name":"Mouse","category":"mouse"},{"id":"x","name":"Keyboard","category":"keyboard"}]"#,
            #"[{"id":"x","name":"Mouse","category":"typo"}]"#,
            #"[{"id":"x","name":"Mouse","category":"mouse","chargingState":"typo"}]"#,
            #"[{"id":"x","name":"Mouse","category":"mouse","levels":[{"component":"whole","percentage":40},{"component":"whole","percentage":50}]}]"#
        ] {
            try Data(json.utf8).write(to: url)
            XCTAssertThrowsError(try DeviceSnapshot.load(path: url.path))
        }
        XCTAssertThrowsError(try DeviceSnapshot.load(path: ""))
    }

    func testFixtureIncludesMixedComponentStates() async throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/devices.json")
        let monitor = DeviceMonitor.snapshot(path: url.path)
        await monitor.refresh()
        guard case .devices(let devices) = monitor.state else { return XCTFail("Expected fixture devices") }
        XCTAssertEqual(devices.last?.menuRowText,
                       "Earbuds — Left 42% · Right 100% · Case 65%")
    }
}
#endif
