import XCTest
@testable import BatteriesIncluded

private actor QueuedHIDPPTransport: HIDPPTransport {
    private var responses: [[UInt8]?]

    init(_ responses: [[UInt8]?]) {
        self.responses = responses
    }

    func request(_ report: [UInt8]) async -> [UInt8]? {
        responses.isEmpty ? nil : responses.removeFirst()
    }
}

private actor RecordingHIDPPTransport: HIDPPTransport {
    private(set) var requests: [[UInt8]] = []

    func request(_ report: [UInt8]) async -> [UInt8]? {
        requests.append(report)
        return nil
    }
}

private struct FixtureLogitechDiscovery: LogitechHIDDiscovering {
    let endpoints: [LogitechHIDEndpoint]

    func discover() async -> [LogitechHIDEndpoint] { endpoints }
}

final class LogitechHIDCollectorTests: XCTestCase {
    func testStatusOnlyReplyStillFallsBackForBatteryLevel() async {
        for fallback: [[UInt8]?] in [
            [[0x10, 0xFF, 0, 8, 6, 0, 0], [0x10, 0xFF, 6, 9, 73, 60, 0]],
            [nil, nil, [0x10, 0xFF, 0x81, 0x0D, 73, 0, 0]],
            [nil, nil, nil, [0x10, 0xFF, 0x81, 0x07, 5, 0, 0]]
        ] {
            let transport = QueuedHIDPPTransport([
                [0x10, 0xFF, 0, 8, 5, 0, 0],
                [0x10, 0xFF, 5, 9, 0, 0, 1]
            ] + fallback)
            let endpoint = LogitechHIDEndpoint(
                id: "usb:123", name: "MX", category: .mouse,
                deviceIndices: [0xFF], transport: transport
            )
            let capturedAt = Date(timeIntervalSince1970: 1_000)
            let collector = LogitechHIDCollector(
                discovery: FixtureLogitechDiscovery(endpoints: [endpoint]), now: { capturedAt }
            )
            let snapshot = await collector.collect()
            let device = BatteryNormalizer().normalize(snapshot.observations, now: capturedAt).first
            XCTAssertEqual(device?.chargingState, .charging)
            XCTAssertEqual(device?.primaryBatteryText, fallback.count == 4 ? "Good" : "73%")
        }
    }

    func testChargingReportsReachMenuWithoutInferringStatusFromPercentage() async {
        let cases: [(Int, [UInt8], String)] = [
            (0, [76, 4, 1], "76% ⚡"),
            (0, [99, 8, 2], "99% ⚡"),
            (0, [100, 8, 3], "100%"),
            (0, [15, 2, 4], "15% ⚡"),
            (0, [100, 8, 0], "100%"),
            (0, [76, 4, 5], "76%"),
            (0, [76, 4, 6], "76%"),
            (0, [76, 4, 255], "76%"),
            (0, [76, 4], "76%"),
            (0, [0, 2, 1], "Low ⚡"),
            (0, [0, 0, 1], "Battery unavailable ⚡"),
            (1, [73, 60, 1], "73% ⚡"),
            (1, [0, 0, 1], "Battery unavailable ⚡"),
            (2, [0x0E, 0x57, 0x80], "10% ⚡"),
            (2, [0x0E, 0x57, 0x81], "10%"),
            (2, [0x0E, 0x57, 0], "10%"),
            (3, [64, 0, 0x50], "64% ⚡"),
            (3, [100, 0, 0x90], "100%"),
            (3, [64, 0, 0x30], "64%"),
            (4, [5, 0x21, 0], "Good ⚡"),
            (4, [7, 0x22, 0], "Full"),
            (4, [3, 0, 0], "Low"),
            (4, [0, 0x21, 0], "Battery unavailable ⚡")
        ]
        let capturedAt = Date(timeIntervalSince1970: 1_000)
        for (feature, payload, expected) in cases {
            var replies: [[UInt8]?] = Array(repeating: nil, count: feature)
            if feature < 3 { replies.append([0x10, 0xFF, 0, 8, 5, 0, 0]) }
            replies.append([0x10, 0xFF, 5, 9] + payload)
            let endpoint = LogitechHIDEndpoint(
                id: "usb:123", name: "MX", category: .mouse,
                deviceIndices: [0xFF], transport: QueuedHIDPPTransport(replies)
            )
            let collector = LogitechHIDCollector(
                discovery: FixtureLogitechDiscovery(endpoints: [endpoint]), now: { capturedAt }
            )
            let snapshot = await collector.collect()
            let devices = BatteryNormalizer().normalize(snapshot.observations, now: capturedAt)
            XCTAssertEqual(devices.first?.menuRowText, "MX — " + expected, "feature \(feature), \(payload)")
            let stale = BatteryNormalizer().normalize(snapshot.observations, now: capturedAt.addingTimeInterval(61))
            if let device = stale.first {
                XCTAssertEqual(device.menuRowText, "MX — Battery unavailable")
            }
        }
    }

    func testRootFeatureLookupUsesFunctionZero() async {
        let transport = RecordingHIDPPTransport()
        let endpoint = LogitechHIDEndpoint(
            id: "receiver:9", name: "Logitech Receiver", category: .other,
            deviceIndices: [1], transport: transport
        )
        let collector = LogitechHIDCollector(
            discovery: FixtureLogitechDiscovery(endpoints: [endpoint])
        )

        _ = await collector.collect()

        let requests = await transport.requests
        XCTAssertEqual(Array(requests[0].prefix(4)), [0x10, 1, 0, 0x08])
    }

    func testCollectsExactHIDPP20BatteryFromDirectDevice() async {
        let transport = QueuedHIDPPTransport([
            [0x10, 0xFF, 0x00, 0x18, 0x05, 0, 0],
            [0x10, 0xFF, 0x05, 0x19, 76, 4, 0]
        ])
        let endpoint = LogitechHIDEndpoint(
            id: "usb:123", name: "MX Master 3S", category: .mouse,
            deviceIndices: [0xFF], transport: transport
        )
        let capturedAt = Date(timeIntervalSince1970: 123)
        let collector = LogitechHIDCollector(
            discovery: FixtureLogitechDiscovery(endpoints: [endpoint]), now: { capturedAt }
        )

        let snapshot = await collector.collect()

        XCTAssertEqual(snapshot.availability, .available)
        XCTAssertEqual(snapshot.observations, [
            BatteryObservation(
                sourceID: "usb:123:255", stableID: "logitech:usb:123:255",
                name: "MX Master 3S", isConnected: true, category: .mouse,
                component: .whole, percentage: 76, source: .logitechHID,
                observedAt: capturedAt, chargingState: .discharging
            )
        ])
    }

    func testCollectsCoarseHIDPP10BatteryFromReceiverSlot() async {
        let transport = QueuedHIDPPTransport([
            nil, nil, nil,
            nil,
            [0x10, 1, 0x81, 0x07, 3, 0, 0]
        ])
        let endpoint = LogitechHIDEndpoint(
            id: "receiver:9", name: "Logitech Receiver", category: .other,
            deviceIndices: [1], transport: transport
        )
        let collector = LogitechHIDCollector(
            discovery: FixtureLogitechDiscovery(endpoints: [endpoint]), now: { .distantPast }
        )

        let snapshot = await collector.collect()

        XCTAssertEqual(snapshot.observations.count, 1)
        XCTAssertEqual(snapshot.observations.first?.name, "Logitech Device 1")
        XCTAssertEqual(snapshot.observations.first?.coarseLevel, .low)
        XCTAssertNil(snapshot.observations.first?.percentage)
    }

    func testTimeoutAndMalformedRepliesDoNotInventDevices() async {
        let transport = QueuedHIDPPTransport([nil, nil, nil, nil, [0x10, 1, 0x81]])
        let endpoint = LogitechHIDEndpoint(
            id: "receiver:9", name: "Receiver", category: .other,
            deviceIndices: [1], transport: transport
        )
        let collector = LogitechHIDCollector(
            discovery: FixtureLogitechDiscovery(endpoints: [endpoint])
        )

        let snapshot = await collector.collect()

        XCTAssertTrue(snapshot.observations.isEmpty)
    }

    func testReadsHIDPP20DeviceNameForReceiverSlot() async {
        let transport = QueuedHIDPPTransport([
            [0x10, 1, 0, 0x18, 5, 0, 0],
            [0x10, 1, 5, 0x19, 91, 4, 0],
            [0x10, 1, 0, 0x1A, 6, 0, 0],
            [0x10, 1, 6, 0x0B, 9, 0, 0],
            [0x11, 1, 6, 0x1C] + Array("MX Master".utf8) + [0, 0, 0, 0, 0, 0, 0]
        ])
        let endpoint = LogitechHIDEndpoint(
            id: "receiver:9", name: "Logitech Receiver", category: .other,
            deviceIndices: [1], transport: transport
        )
        let collector = LogitechHIDCollector(
            discovery: FixtureLogitechDiscovery(endpoints: [endpoint]), now: { .distantPast }
        )

        let snapshot = await collector.collect()

        XCTAssertEqual(snapshot.observations.first?.name, "MX Master")
    }
}
