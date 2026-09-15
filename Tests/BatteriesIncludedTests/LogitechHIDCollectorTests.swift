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
                observedAt: capturedAt
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
