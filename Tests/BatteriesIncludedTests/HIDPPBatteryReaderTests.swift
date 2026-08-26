import XCTest
@testable import BatteriesIncluded

final class HIDPPBatteryReaderTests: XCTestCase {
    func testReadsStateOfChargeFromDynamicallyResolvedUnifiedBatteryFeature() async throws {
        let requester = ScriptedRequester(featureIndices: [0x1004: 7])
        await requester.setParameters(deviceIndex: 1, featureIndex: 7, functionID: 0, parameters: [0, 0x02])
        await requester.setParameters(deviceIndex: 1, featureIndex: 7, functionID: 1, parameters: [73])
        let reader = HIDPPBatteryReader(requester: requester)

        let reading = try await reader.read(deviceIndex: 1, fallbackIdentity: identity())

        XCTAssertEqual(reading, HIDPPDeviceReading(
            deviceIndex: 1, stableID: "receiver-1", name: "MX Master", category: .mouse, percentage: 73
        ))
        let requestedFeatureIDs = await requester.requestedFeatureIDs()
        XCTAssertEqual(requestedFeatureIDs, [0x1004])
    }

    func testMapsUnifiedBatteryDiscreteLevelWhenStateOfChargeIsUnsupported() async throws {
        let requester = ScriptedRequester(featureIndices: [0x1004: 7])
        await requester.setParameters(deviceIndex: 1, featureIndex: 7, functionID: 0, parameters: [0, 0])
        await requester.setParameters(deviceIndex: 1, featureIndex: 7, functionID: 1, parameters: [0x04])
        let reader = HIDPPBatteryReader(requester: requester)

        let reading = try await reader.read(deviceIndex: 1, fallbackIdentity: identity())

        XCTAssertEqual(reading?.percentage, 60)
    }

    func testFallsBackToLegacyBatteryLevelWhenUnifiedBatteryIsUnavailable() async throws {
        let requester = ScriptedRequester(featureIndices: [0x1000: 9])
        await requester.setParameters(deviceIndex: 1, featureIndex: 9, functionID: 0, parameters: [50])
        let reader = HIDPPBatteryReader(requester: requester)

        let reading = try await reader.read(deviceIndex: 1, fallbackIdentity: identity())

        XCTAssertEqual(reading?.percentage, 50)
        let requestedFeatureIDs = await requester.requestedFeatureIDs()
        XCTAssertEqual(requestedFeatureIDs, [0x1004, 0x1000])
        XCTAssertFalse(requestedFeatureIDs.contains(0x1001))
    }

    func testAcceptsZeroStateOfChargeWhenUnifiedBatteryReportsThatCapability() async throws {
        let requester = ScriptedRequester(featureIndices: [0x1004: 7])
        await requester.setParameters(deviceIndex: 1, featureIndex: 7, functionID: 0, parameters: [0, 0x02])
        await requester.setParameters(deviceIndex: 1, featureIndex: 7, functionID: 1, parameters: [0])
        let reader = HIDPPBatteryReader(requester: requester)

        let reading = try await reader.read(deviceIndex: 1, fallbackIdentity: identity())

        XCTAssertEqual(reading?.percentage, 0)
    }

    func testRejectsOutOfRangeUnifiedAndZeroLegacyPercentages() async throws {
        for unifiedPercentage in [UInt8(101), 255] {
            let requester = ScriptedRequester(featureIndices: [0x1004: 7, 0x1000: 9])
            await requester.setParameters(deviceIndex: 1, featureIndex: 7, functionID: 0, parameters: [0, 0x02])
            await requester.setParameters(deviceIndex: 1, featureIndex: 7, functionID: 1, parameters: [unifiedPercentage])
            await requester.setParameters(deviceIndex: 1, featureIndex: 9, functionID: 0, parameters: [0])
            let reader = HIDPPBatteryReader(requester: requester)

            let reading = try await reader.read(deviceIndex: 1, fallbackIdentity: identity())

            XCTAssertNil(reading?.percentage, "\(unifiedPercentage) must not become a display percentage")
        }
    }

    func testFallsBackToLegacyLevelForUnknownUnifiedBatteryDiscreteLevel() async throws {
        let requester = ScriptedRequester(featureIndices: [0x1004: 7, 0x1000: 9])
        await requester.setParameters(deviceIndex: 1, featureIndex: 7, functionID: 0, parameters: [0, 0])
        await requester.setParameters(deviceIndex: 1, featureIndex: 7, functionID: 1, parameters: [0x03])
        await requester.setParameters(deviceIndex: 1, featureIndex: 9, functionID: 0, parameters: [50])
        let reader = HIDPPBatteryReader(requester: requester)

        let reading = try await reader.read(deviceIndex: 1, fallbackIdentity: identity())

        XCTAssertEqual(reading?.percentage, 50)
    }

    func testReturnsKnownVoltageOnlyDeviceWithNoPercentage() async throws {
        let requester = ScriptedRequester()
        let reader = HIDPPBatteryReader(requester: requester)

        let reading = try await reader.read(deviceIndex: 1, fallbackIdentity: identity())

        XCTAssertEqual(reading?.stableID, "receiver-1")
        XCTAssertNil(reading?.percentage)
        let requestedFeatureIDs = await requester.requestedFeatureIDs()
        XCTAssertFalse(requestedFeatureIDs.contains(0x1001))
    }

    func testUsesDeviceNameFeatureForUnnamedReceiverChild() async throws {
        let requester = ScriptedRequester(featureIndices: [0x0005: 5, 0x1004: 7])
        await requester.setParameters(deviceIndex: 1, featureIndex: 5, functionID: 0, parameters: [0x4D, 0x58, 0])
        await requester.setParameters(deviceIndex: 1, featureIndex: 7, functionID: 0, parameters: [0, 0x02])
        await requester.setParameters(deviceIndex: 1, featureIndex: 7, functionID: 1, parameters: [73])
        let reader = HIDPPBatteryReader(requester: requester)

        let reading = try await reader.read(deviceIndex: 1, fallbackIdentity: identity(name: nil, isReceiverChild: true))

        XCTAssertEqual(reading?.name, "MX")
        let requestedFeatureIDs = await requester.requestedFeatureIDs()
        XCTAssertEqual(requestedFeatureIDs, [0x0005, 0x1004])
    }

    func testOmitsUnnamedReceiverChildWhenDeviceNameFeatureIsUnavailable() async throws {
        let requester = ScriptedRequester(featureIndices: [0x1004: 7])
        let reader = HIDPPBatteryReader(requester: requester)

        let reading = try await reader.read(deviceIndex: 1, fallbackIdentity: identity(name: nil, isReceiverChild: true))

        XCTAssertNil(reading)
        let requestedFeatureIDs = await requester.requestedFeatureIDs()
        XCTAssertEqual(requestedFeatureIDs, [0x0005])
    }

    func testCachesUnifiedBatteryFeatureAndCapabilitiesPerDevice() async throws {
        let requester = ScriptedRequester(featureIndices: [0x1004: 7])
        await requester.setParameters(deviceIndex: 1, featureIndex: 7, functionID: 0, parameters: [0, 0x02])
        await requester.setParameters(deviceIndex: 1, featureIndex: 7, functionID: 1, parameters: [73])
        let reader = HIDPPBatteryReader(requester: requester)

        _ = try await reader.read(deviceIndex: 1, fallbackIdentity: identity())
        _ = try await reader.read(deviceIndex: 1, fallbackIdentity: identity())

        let requestedFeatureIDs = await requester.requestedFeatureIDs()
        let capabilityRequests = await requester.requestCount(deviceIndex: 1, featureIndex: 7, functionID: 0)
        let statusRequests = await requester.requestCount(deviceIndex: 1, featureIndex: 7, functionID: 1)
        XCTAssertEqual(requestedFeatureIDs, [0x1004])
        XCTAssertEqual(capabilityRequests, 1)
        XCTAssertEqual(statusRequests, 2)
    }

    func testEvictsInvalidUnifiedBatteryFeatureAndResolvesItAgainOnNextRead() async throws {
        let requester = ScriptedRequester(featureIndices: [0x0005: 5, 0x1004: 7, 0x1000: 9])
        await requester.setParameters(deviceIndex: 1, featureIndex: 5, functionID: 0, parameters: [0x4D, 0x58, 0])
        await requester.setRawResponse(
            deviceIndex: 1, featureIndex: 7, functionID: 0,
            response: invalidFeatureResponse(deviceIndex: 1, softwareID: 0x0D, featureIndex: 7)
        )
        await requester.setParameters(deviceIndex: 1, featureIndex: 9, functionID: 0, parameters: [50])
        let reader = HIDPPBatteryReader(requester: requester)

        let unnamedChild = identity(name: nil, isReceiverChild: true)
        let firstReading = try await reader.read(deviceIndex: 1, fallbackIdentity: unnamedChild)
        await requester.setFeatureIndex(8, for: 0x1004)
        await requester.setParameters(deviceIndex: 1, featureIndex: 8, functionID: 0, parameters: [0, 0x02])
        await requester.setParameters(deviceIndex: 1, featureIndex: 8, functionID: 1, parameters: [73])
        let secondReading = try await reader.read(deviceIndex: 1, fallbackIdentity: unnamedChild)

        XCTAssertEqual(firstReading?.percentage, 50)
        XCTAssertEqual(secondReading?.percentage, 73)
        let requestedFeatureIDs = await requester.requestedFeatureIDs()
        XCTAssertEqual(requestedFeatureIDs, [0x0005, 0x1004, 0x1000, 0x0005, 0x1004])
    }

    private func identity(
        name: String? = "MX Master",
        isReceiverChild: Bool = false
    ) -> HIDPPFallbackIdentity {
        HIDPPFallbackIdentity(stableID: "receiver-1", name: name, category: .mouse, isReceiverChild: isReceiverChild)
    }

    private func invalidFeatureResponse(deviceIndex: UInt8, softwareID: UInt8, featureIndex: UInt8) -> [UInt8] {
        [0x11, deviceIndex, 0xFF, softwareID, featureIndex, 0x06] + Array(repeating: 0, count: 14)
    }
}

private actor ScriptedRequester: HIDPPRequesting {
    private struct Function: Hashable {
        let deviceIndex: UInt8
        let featureIndex: UInt8
        let functionID: UInt8
    }

    private var featureIndices: [UInt16: UInt8]
    private var parameterResponses: [Function: [UInt8]] = [:]
    private var rawResponses: [Function: [UInt8]] = [:]
    private var requests: [HIDPPPacket] = []

    init(featureIndices: [UInt16: UInt8] = [:]) {
        self.featureIndices = featureIndices
    }

    func send(_ packet: HIDPPPacket) async throws -> [UInt8] {
        requests.append(packet)
        let functionID = packet.bytes[3] >> 4
        if packet.bytes[2] == 0, functionID == 0 {
            let featureID = UInt16(packet.bytes[4]) << 8 | UInt16(packet.bytes[5])
            guard let featureIndex = featureIndices[featureID] else {
                return invalidFeatureResponse(for: packet)
            }
            return response(for: packet, parameters: [featureIndex])
        }

        let function = Function(deviceIndex: packet.bytes[1], featureIndex: packet.bytes[2], functionID: functionID)
        if let response = rawResponses[function] {
            return response
        }
        guard let parameters = parameterResponses[function] else {
            throw HIDPPError.invalidPacket
        }
        return response(for: packet, parameters: parameters)
    }

    func setFeatureIndex(_ featureIndex: UInt8, for featureID: UInt16) {
        featureIndices[featureID] = featureIndex
    }

    func setParameters(deviceIndex: UInt8, featureIndex: UInt8, functionID: UInt8, parameters: [UInt8]) {
        parameterResponses[Function(deviceIndex: deviceIndex, featureIndex: featureIndex, functionID: functionID)] = parameters
    }

    func setRawResponse(deviceIndex: UInt8, featureIndex: UInt8, functionID: UInt8, response: [UInt8]) {
        rawResponses[Function(deviceIndex: deviceIndex, featureIndex: featureIndex, functionID: functionID)] = response
    }

    func requestedFeatureIDs() -> [UInt16] {
        requests.compactMap { packet in
            guard packet.bytes[2] == 0, packet.bytes[3] >> 4 == 0 else { return nil }
            return UInt16(packet.bytes[4]) << 8 | UInt16(packet.bytes[5])
        }
    }

    func requestCount(deviceIndex: UInt8, featureIndex: UInt8, functionID: UInt8) -> Int {
        requests.count {
            $0.bytes[1] == deviceIndex && $0.bytes[2] == featureIndex && $0.bytes[3] >> 4 == functionID
        }
    }

    private func response(for request: HIDPPPacket, parameters: [UInt8]) -> [UInt8] {
        Array(request.bytes.prefix(4)) + parameters + Array(repeating: 0, count: request.bytes.count - 4 - parameters.count)
    }

    private func invalidFeatureResponse(for request: HIDPPPacket) -> [UInt8] {
        [0x11, request.bytes[1], 0xFF, request.bytes[3], request.bytes[2], 0x06] + Array(repeating: 0, count: 14)
    }
}
