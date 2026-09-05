import XCTest
@testable import BatteriesIncluded

final class HIDPPProtocolTests: XCTestCase {
    func testPingRequestUsesFunctionOneAndEchoMarker() {
        XCTAssertEqual(
            HIDPPProtocol.pingRequest(deviceIndex: 1, marker: 0xA5),
            [0x10, 1, 0, 0x18, 0, 0, 0xA5]
        )
    }

    func testShortRequestUsesHIDPPFramingAndSoftwareID() {
        XCTAssertEqual(
            HIDPPProtocol.shortRequest(deviceIndex: 2, command: 0x00, address: 0x10, parameters: [0x10, 0x04]),
            [0x10, 0x02, 0x00, 0x18, 0x10, 0x04, 0x00]
        )
    }

    func testParsesExactBatteryStatusResponse() {
        XCTAssertEqual(
            HIDPPProtocol.parseBatteryStatus([0x10, 0x01, 0x05, 0x08, 73, 60, 0]),
            .percentage(73)
        )
    }

    func testParsesUnifiedExactAndCoarseBatteryResponses() {
        XCTAssertEqual(
            HIDPPProtocol.parseUnifiedBattery([0x10, 0x01, 0x07, 0x18, 82, 4, 0]),
            .percentage(82)
        )
        XCTAssertEqual(
            HIDPPProtocol.parseUnifiedBattery([0x10, 0x01, 0x07, 0x18, 0, 2, 0]),
            .coarse(.low)
        )
    }

    func testRejectsMalformedAndOutOfRangeBatteryResponses() {
        XCTAssertNil(HIDPPProtocol.parseBatteryStatus([0x10, 0x01, 0x05]))
        XCTAssertNil(HIDPPProtocol.parseBatteryStatus([0x10, 0x01, 0x05, 0x08, 101, 0, 0]))
        XCTAssertNil(HIDPPProtocol.parseUnifiedBattery([0x10, 0x01, 0x07, 0x18, 0, 0, 0]))
    }

    func testParsesHIDPP10ExactAndCoarseRegisters() {
        XCTAssertEqual(HIDPPProtocol.parseBatteryCharge([0x10, 1, 0x81, 0x0D, 64, 0, 0]), .percentage(64))
        XCTAssertEqual(HIDPPProtocol.parseBatteryStatusRegister([0x10, 1, 0x81, 0x07, 5, 0, 0]), .coarse(.good))
        XCTAssertEqual(HIDPPProtocol.parseBatteryStatusRegister([0x10, 1, 0x81, 0x07, 1, 0, 0]), .coarse(.critical))
    }

    func testInterpolatesBatteryVoltageToPercentage() {
        XCTAssertEqual(
            HIDPPProtocol.parseBatteryVoltage([0x10, 1, 5, 8, 0x0E, 0x57, 0]),
            .percentage(10)
        )
    }

    func testReplyMustMatchRequestSoftwareID() {
        let request = HIDPPProtocol.shortRequest(
            deviceIndex: 1, command: 5, address: 0x10, parameters: [], softwareID: 9
        )

        XCTAssertTrue(HIDPPProtocol.isReply([0x10, 1, 5, 0x19, 50, 0, 0], to: request))
        XCTAssertFalse(HIDPPProtocol.isReply([0x10, 1, 5, 0x1A, 50, 0, 0], to: request))
    }

    func testErrorReplyMatchesOriginalRequest() {
        let request = HIDPPProtocol.shortRequest(
            deviceIndex: 2, command: 0, address: 0, parameters: [0x10, 0x04], softwareID: 9
        )
        XCTAssertTrue(HIDPPProtocol.isErrorReply([0x10, 2, 0x8F, 0, 9, 9, 0], to: request))
        XCTAssertFalse(HIDPPProtocol.isErrorReply([0x10, 3, 0x8F, 0, 9, 9, 0], to: request))
    }
}
