import XCTest
@testable import BatteriesIncluded

final class HIDPPPacketTests: XCTestCase {
    func testBuildsShortRootGetFeatureRequest() throws {
        let packet = try HIDPPPacket.request(
            kind: .short, deviceIndex: 1, featureIndex: 0,
            functionID: 0, softwareID: 0x0D, parameters: [0x10, 0x04]
        )

        XCTAssertEqual(packet.bytes, [0x10, 1, 0, 0x0D, 0x10, 0x04, 0])
        XCTAssertEqual(packet.parameters, [0x10, 0x04, 0])
    }

    func testBuildsLongFunctionOneRequest() throws {
        let packet = try HIDPPPacket.request(
            kind: .long, deviceIndex: 0xFF, featureIndex: 7,
            functionID: 1, softwareID: 0x0D, parameters: []
        )

        XCTAssertEqual(packet.bytes.count, 20)
        XCTAssertEqual(Array(packet.bytes.prefix(4)), [0x11, 0xFF, 7, 0x1D])
        XCTAssertEqual(Array(packet.bytes.dropFirst(4)), .init(repeating: 0, count: 16))
    }

    func testResponseCorrelationUsesAllHeaderFields() throws {
        let packet = try HIDPPPacket.request(
            kind: .long, deviceIndex: 1, featureIndex: 7,
            functionID: 1, softwareID: 0x0D, parameters: []
        )

        XCTAssertTrue(packet.matchesResponse([0x11, 1, 7, 0x1D] + .init(repeating: 0, count: 16)))
        XCTAssertFalse(packet.matchesResponse([0x11, 2, 7, 0x1D] + .init(repeating: 0, count: 16)))
        XCTAssertFalse(packet.matchesResponse([0x11, 1, 8, 0x1D] + .init(repeating: 0, count: 16)))
        XCTAssertFalse(packet.matchesResponse([0x11, 1, 7, 0x2D] + .init(repeating: 0, count: 16)))
        XCTAssertFalse(packet.matchesResponse([0x10, 1, 7, 0x1D, 0, 0, 0]))
        XCTAssertFalse(packet.matchesResponse([0x11, 1, 7, 0x1D] + .init(repeating: 0, count: 15)))
    }

    func testRejectsFunctionAndSoftwareIDsOutsideFourBits() {
        XCTAssertThrowsError(try HIDPPPacket.request(
            kind: .short, deviceIndex: 1, featureIndex: 0,
            functionID: 0x10, softwareID: 0, parameters: []
        )) { XCTAssertEqual($0 as? HIDPPError, .invalidPacket) }
        XCTAssertThrowsError(try HIDPPPacket.request(
            kind: .short, deviceIndex: 1, featureIndex: 0,
            functionID: 0, softwareID: 0x10, parameters: []
        )) { XCTAssertEqual($0 as? HIDPPError, .invalidPacket) }
    }

    func testRejectsZeroSoftwareIDReservedForNotifications() {
        XCTAssertThrowsError(try HIDPPPacket.request(
            kind: .short, deviceIndex: 1, featureIndex: 0,
            functionID: 0, softwareID: 0, parameters: []
        )) { XCTAssertEqual($0 as? HIDPPError, .invalidPacket) }
    }

    func testRejectsParametersThatDoNotFitReport() {
        XCTAssertThrowsError(try HIDPPPacket.request(
            kind: .short, deviceIndex: 1, featureIndex: 0,
            functionID: 0, softwareID: 1, parameters: [0, 1, 2, 3]
        )) { XCTAssertEqual($0 as? HIDPPError, .invalidPacket) }
        XCTAssertThrowsError(try HIDPPPacket.request(
            kind: .long, deviceIndex: 1, featureIndex: 0,
            functionID: 0, softwareID: 1, parameters: .init(repeating: 0, count: 17)
        )) { XCTAssertEqual($0 as? HIDPPError, .invalidPacket) }
    }

    func testIgnoresUnrelatedNotification() throws {
        let packet = try HIDPPPacket.request(
            kind: .long, deviceIndex: 1, featureIndex: 7,
            functionID: 1, softwareID: 0x0D, parameters: []
        )
        let notification = [0x11, 1, 0x41, 0] + [UInt8](repeating: 0, count: 16)

        XCTAssertFalse(packet.matchesResponse(notification))
        XCTAssertNil(packet.protocolError(in: notification))
    }

    func testMapsLongInvalidFeatureProtocolError() throws {
        let packet = try HIDPPPacket.request(
            kind: .long, deviceIndex: 1, featureIndex: 7,
            functionID: 1, softwareID: 0x0D, parameters: []
        )
        let response = [0x11, 1, 0xFF, 0x1D, 7, 0x06] + [UInt8](repeating: 0, count: 14)

        XCTAssertEqual(packet.protocolError(in: response), .invalidFeatureIndex)
    }

    func testMapsLongProtocolErrorForShortRequest() throws {
        let packet = try HIDPPPacket.request(
            kind: .short, deviceIndex: 1, featureIndex: 0,
            functionID: 0, softwareID: 0x0D, parameters: []
        )
        let response = [0x11, 1, 0xFF, 0x0D, 0, 0x06] + [UInt8](repeating: 0, count: 14)

        XCTAssertEqual(packet.protocolError(in: response), .invalidFeatureIndex)
    }

    func testPreservesUnknownLongProtocolErrorCode() throws {
        let packet = try HIDPPPacket.request(
            kind: .long, deviceIndex: 1, featureIndex: 7,
            functionID: 1, softwareID: 0x0D, parameters: []
        )
        let response = [0x11, 1, 0xFF, 0x1D, 7, 0x99] + [UInt8](repeating: 0, count: 14)

        XCTAssertEqual(packet.protocolError(in: response), .protocolError(0x99))
    }
}
