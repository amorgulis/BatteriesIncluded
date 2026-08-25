import XCTest
@testable import BatteriesIncluded

final class HIDPPProtocolTests: XCTestCase {
    private final class FixtureTransport: HIDPPTransport {
        var writes: [[UInt8]] = []
        var readTimeouts: [Int32] = []
        var replies: [[UInt8]]

        init(replies: [[UInt8]]) {
            self.replies = replies
        }

        func write(_ data: [UInt8]) -> Int32 {
            writes.append(data)
            return Int32(data.count)
        }

        func read(maxLength: Int, timeoutMilliseconds: Int32) -> [UInt8]? {
            readTimeouts.append(timeoutMilliseconds)
            return replies.isEmpty ? nil : replies.removeFirst()
        }
    }

    func testDecodesUnifiedBatteryPayload() {
        XCTAssertEqual(
            HIDPPBatteryDecoder.unifiedBattery(payload: [72, 4, 0]),
            HIDPPBattery(level: 72, status: .discharging, voltage: nil)
        )
    }

    func testRejectsShortUnifiedBatteryPayload() {
        XCTAssertNil(HIDPPBatteryDecoder.unifiedBattery(payload: [72, 4]))
    }

    func testEstimatesVoltageBatteryWithinBounds() {
        XCTAssertEqual(
            HIDPPBatteryDecoder.voltageBattery(payload: [0x0F, 0x0A, 1]),
            HIDPPBattery(level: 50, status: .charging, voltage: 3850)
        )
    }

    func testLegacyBatteryRequestPreservesRegisterAddress() {
        let transport = FixtureTransport(replies: [[0x10, 1, 0x81, 0x07, 72, 0, 0]])
        var hidpp = HIDPPProtocol(requestTimeout: 0.01)

        let battery = hidpp.battery(transport, deviceNumber: 1, version: 1)

        XCTAssertEqual(transport.writes.first, [0x10, 1, 0x81, 0x07, 0, 0, 0])
        XCTAssertEqual(battery?.level, 72)
    }

    func testLegacyBatteryRequestIgnoresErrorForAnotherRegister() {
        let transport = FixtureTransport(replies: [
            [0x10, 1, 0x8F, 0x81, 0x0D, 0x09, 0],
            [0x10, 1, 0x81, 0x07, 72, 0, 0]
        ])
        var hidpp = HIDPPProtocol(requestTimeout: 0.01)

        let battery = hidpp.battery(transport, deviceNumber: 1, version: 1)

        XCTAssertEqual(battery?.level, 72)
    }

    func testOperationDeadlineBoundsAnUnresponsiveRequest() {
        let transport = FixtureTransport(replies: [])
        var hidpp = HIDPPProtocol(
            requestTimeout: 1,
            operationDeadline: Date().addingTimeInterval(0.01)
        )
        let startedAt = Date()

        XCTAssertNil(hidpp.ping(transport, deviceNumber: 1))

        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 0.1)
        XCTAssertLessThanOrEqual(transport.readTimeouts.max() ?? .max, 10)
    }
}
