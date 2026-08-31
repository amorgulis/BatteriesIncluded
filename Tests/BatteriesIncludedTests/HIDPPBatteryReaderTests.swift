import XCTest
@testable import BatteriesIncluded

final class HIDPPBatteryReaderTests: XCTestCase {
    func testRejectsTargetBelowHIDPP20AfterProtocolPing() async throws {
        let requester = ScriptedRequester(
            featureIndices: [0x1004: 7],
            protocolVersion: (major: 1, minor: 0)
        )
        await requester.setParameters(deviceIndex: 1, featureIndex: 7, functionID: 0, parameters: [0, 0x02])
        await requester.setParameters(deviceIndex: 1, featureIndex: 7, functionID: 1, parameters: [73, 0])
        let reader = HIDPPBatteryReader(requester: requester)

        let reading = try await reader.read(deviceIndex: 1, fallbackIdentity: identity())
        let protocolPingCount = await requester.requestCount(
            deviceIndex: 1,
            featureIndex: 0,
            functionID: 1
        )

        XCTAssertNil(reading)
        XCTAssertEqual(protocolPingCount, 1)
    }

    func testReadsStateOfChargeFromLongDynamicallyResolvedUnifiedBatteryFeature() async throws {
        let requester = ScriptedRequester(featureIndices: [0x1004: 7])
        await requester.setParameters(deviceIndex: 1, featureIndex: 7, functionID: 0, parameters: [0, 0x02])
        await requester.setParameters(deviceIndex: 1, featureIndex: 7, functionID: 1, parameters: [73, 0])
        let reader = HIDPPBatteryReader(requester: requester)

        let reading = try await reader.read(deviceIndex: 1, fallbackIdentity: identity())
        let featureIDs = await requester.requestedFeatureIDs()
        let reportIDs = await requester.reportIDs()

        XCTAssertEqual(reading, HIDPPDeviceReading(
            deviceIndex: 1, stableID: "receiver-1", name: "MX Master", category: .mouse, percentage: 73
        ))
        XCTAssertEqual(featureIDs, [0x1004])
        XCTAssertEqual(reportIDs, [0x10, 0x11, 0x11, 0x11])
    }

    func testMapsUnifiedBatteryDiscreteLevelFromStatusParameterOne() async throws {
        let requester = ScriptedRequester(featureIndices: [0x1004: 7])
        await requester.setParameters(deviceIndex: 1, featureIndex: 7, functionID: 0, parameters: [0, 0])
        await requester.setParameters(deviceIndex: 1, featureIndex: 7, functionID: 1, parameters: [0, 0x04])
        let reader = HIDPPBatteryReader(requester: requester)

        let reading = try await reader.read(deviceIndex: 1, fallbackIdentity: identity())

        XCTAssertEqual(reading?.percentage, 60)
    }

    func testFallsBackToLegacyBatteryLevelAndCachesUnifiedFeatureAbsence() async throws {
        let requester = ScriptedRequester(featureIndices: [0x1000: 9])
        await requester.setParameters(deviceIndex: 1, featureIndex: 9, functionID: 0, parameters: [50])
        let reader = HIDPPBatteryReader(requester: requester)

        let firstReading = try await reader.read(deviceIndex: 1, fallbackIdentity: identity())
        let secondReading = try await reader.read(deviceIndex: 1, fallbackIdentity: identity())
        let featureIDs = await requester.requestedFeatureIDs()
        let legacyRequestCount = await requester.requestCount(deviceIndex: 1, featureIndex: 9, functionID: 0)

        XCTAssertEqual(firstReading?.percentage, 50)
        XCTAssertEqual(secondReading?.percentage, 50)
        XCTAssertEqual(featureIDs, [0x1004, 0x1000])
        XCTAssertEqual(legacyRequestCount, 2)
        XCTAssertFalse(featureIDs.contains(0x1001))
    }

    func testAcceptsZeroStateOfChargeWhenUnifiedBatteryReportsThatCapability() async throws {
        let requester = ScriptedRequester(featureIndices: [0x1004: 7])
        await requester.setParameters(deviceIndex: 1, featureIndex: 7, functionID: 0, parameters: [0, 0x02])
        await requester.setParameters(deviceIndex: 1, featureIndex: 7, functionID: 1, parameters: [0, 0])
        let reader = HIDPPBatteryReader(requester: requester)

        let reading = try await reader.read(deviceIndex: 1, fallbackIdentity: identity())

        XCTAssertEqual(reading?.percentage, 0)
    }

    func testRejectsOutOfRangeUnifiedAndZeroLegacyPercentages() async throws {
        for unifiedPercentage in [UInt8(101), 255] {
            let requester = ScriptedRequester(featureIndices: [0x1004: 7, 0x1000: 9])
            await requester.setParameters(deviceIndex: 1, featureIndex: 7, functionID: 0, parameters: [0, 0x02])
            await requester.setParameters(deviceIndex: 1, featureIndex: 7, functionID: 1, parameters: [unifiedPercentage, 0])
            await requester.setParameters(deviceIndex: 1, featureIndex: 9, functionID: 0, parameters: [0])
            let reader = HIDPPBatteryReader(requester: requester)

            let reading = try await reader.read(deviceIndex: 1, fallbackIdentity: identity())

            XCTAssertNil(reading?.percentage)
        }
    }

    func testFallsBackToLegacyLevelForUnknownUnifiedBatteryDiscreteLevel() async throws {
        let requester = ScriptedRequester(featureIndices: [0x1004: 7, 0x1000: 9])
        await requester.setParameters(deviceIndex: 1, featureIndex: 7, functionID: 0, parameters: [0, 0])
        await requester.setParameters(deviceIndex: 1, featureIndex: 7, functionID: 1, parameters: [0, 0x03])
        await requester.setParameters(deviceIndex: 1, featureIndex: 9, functionID: 0, parameters: [50])
        let reader = HIDPPBatteryReader(requester: requester)

        let reading = try await reader.read(deviceIndex: 1, fallbackIdentity: identity())

        XCTAssertEqual(reading?.percentage, 50)
    }

    func testReturnsKnownVoltageOnlyDeviceWithNoPercentage() async throws {
        let requester = ScriptedRequester()
        let reader = HIDPPBatteryReader(requester: requester)

        let reading = try await reader.read(deviceIndex: 1, fallbackIdentity: identity())
        let featureIDs = await requester.requestedFeatureIDs()

        XCTAssertEqual(reading?.stableID, "receiver-1")
        XCTAssertNil(reading?.percentage)
        XCTAssertFalse(featureIDs.contains(0x1001))
    }

    func testReadsUnnamedReceiverChildNameInLongFeatureChunks() async throws {
        let requester = ScriptedRequester(featureIndices: [0x0005: 5, 0x1004: 7])
        let nameBytes = Array("Logitech MX Master".utf8)
        await requester.setParameters(deviceIndex: 1, featureIndex: 5, functionID: 0, parameters: [UInt8(nameBytes.count)])
        await requester.setParameters(deviceIndex: 1, featureIndex: 5, functionID: 1, requestParameters: [0], parameters: Array(nameBytes.prefix(16)))
        await requester.setParameters(deviceIndex: 1, featureIndex: 5, functionID: 1, requestParameters: [16], parameters: Array(nameBytes.dropFirst(16)))
        await requester.setParameters(deviceIndex: 1, featureIndex: 7, functionID: 0, parameters: [0, 0x02])
        await requester.setParameters(deviceIndex: 1, featureIndex: 7, functionID: 1, parameters: [73, 0])
        let reader = HIDPPBatteryReader(requester: requester)

        let reading = try await reader.read(deviceIndex: 1, fallbackIdentity: identity(name: nil, isReceiverChild: true))
        let offsets = await requester.requestedParameters(deviceIndex: 1, featureIndex: 5, functionID: 1)

        XCTAssertEqual(reading?.name, "Logitech MX Master")
        XCTAssertEqual(offsets, [[0], [16]])
    }

    func testOmitsUnnamedReceiverChildWhenDeviceNameCountIsZero() async throws {
        let requester = ScriptedRequester(featureIndices: [0x0005: 5])
        await requester.setParameters(deviceIndex: 1, featureIndex: 5, functionID: 0, parameters: [0])
        let reader = HIDPPBatteryReader(requester: requester)

        let reading = try await reader.read(deviceIndex: 1, fallbackIdentity: identity(name: nil, isReceiverChild: true))

        XCTAssertNil(reading)
    }

    func testRetriesReceiverChildNameAfterZeroLengthResponse() async throws {
        let requester = ScriptedRequester(featureIndices: [0x0005: 5])
        await requester.setParameters(deviceIndex: 1, featureIndex: 5, functionID: 0, parameters: [0])
        let reader = HIDPPBatteryReader(requester: requester)
        let child = identity(name: nil, isReceiverChild: true)

        let firstReading = try await reader.read(deviceIndex: 1, fallbackIdentity: child)
        await requester.setParameters(deviceIndex: 1, featureIndex: 5, functionID: 0, parameters: [2])
        await requester.setParameters(
            deviceIndex: 1,
            featureIndex: 5,
            functionID: 1,
            requestParameters: [0],
            parameters: Array("MX".utf8)
        )
        let secondReading = try await reader.read(deviceIndex: 1, fallbackIdentity: child)

        XCTAssertNil(firstReading)
        XCTAssertEqual(secondReading?.name, "MX")
    }

    func testCachesUnifiedBatteryFeatureAndCapabilitiesPerDevice() async throws {
        let requester = ScriptedRequester(featureIndices: [0x1004: 7])
        await requester.setParameters(deviceIndex: 1, featureIndex: 7, functionID: 0, parameters: [0, 0x02])
        await requester.setParameters(deviceIndex: 1, featureIndex: 7, functionID: 1, parameters: [73, 0])
        let reader = HIDPPBatteryReader(requester: requester)

        _ = try await reader.read(deviceIndex: 1, fallbackIdentity: identity())
        _ = try await reader.read(deviceIndex: 1, fallbackIdentity: identity())
        let featureIDs = await requester.requestedFeatureIDs()
        let capabilitiesCount = await requester.requestCount(deviceIndex: 1, featureIndex: 7, functionID: 0)
        let statusCount = await requester.requestCount(deviceIndex: 1, featureIndex: 7, functionID: 1)
        let protocolPingCount = await requester.requestCount(deviceIndex: 1, featureIndex: 0, functionID: 1)

        XCTAssertEqual(featureIDs, [0x1004])
        XCTAssertEqual(protocolPingCount, 1)
        XCTAssertEqual(capabilitiesCount, 1)
        XCTAssertEqual(statusCount, 2)
    }

    func testEvictsCompleteTargetCacheAfterInvalidUnifiedFeature() async throws {
        let requester = await childRequesterWithBatteryFeatures()
        await requester.setRawResponse(
            deviceIndex: 1, featureIndex: 7, functionID: 0,
            response: invalidFeatureResponse(deviceIndex: 1, softwareID: 0x0D, featureIndex: 7)
        )
        await requester.setParameters(deviceIndex: 1, featureIndex: 9, functionID: 0, parameters: [50])
        let reader = HIDPPBatteryReader(requester: requester)
        let child = identity(name: nil, isReceiverChild: true)

        let firstReading = try await reader.read(deviceIndex: 1, fallbackIdentity: child)
        await requester.clearRawResponse(deviceIndex: 1, featureIndex: 7, functionID: 0)
        await requester.setParameters(deviceIndex: 1, featureIndex: 7, functionID: 0, parameters: [0, 0x02])
        await requester.setParameters(deviceIndex: 1, featureIndex: 7, functionID: 1, parameters: [73, 0])
        let secondReading = try await reader.read(deviceIndex: 1, fallbackIdentity: child)
        let featureIDs = await requester.requestedFeatureIDs()

        XCTAssertEqual(firstReading?.percentage, 50)
        XCTAssertEqual(secondReading?.percentage, 73)
        XCTAssertEqual(featureIDs, [0x0005, 0x1004, 0x1000, 0x0005, 0x1004])
    }

    func testDoesNotCacheNilNameAfterInvalidDeviceNameFeature() async throws {
        let requester = await childRequesterWithBatteryFeatures()
        await requester.setParameters(deviceIndex: 1, featureIndex: 7, functionID: 0, parameters: [0, 0x02])
        await requester.setParameters(deviceIndex: 1, featureIndex: 7, functionID: 1, parameters: [73, 0])
        await requester.setRawResponse(
            deviceIndex: 1, featureIndex: 5, functionID: 1,
            requestParameters: [0], response: invalidFeatureResponse(deviceIndex: 1, softwareID: 0x1D, featureIndex: 5)
        )
        let reader = HIDPPBatteryReader(requester: requester)
        let child = identity(name: nil, isReceiverChild: true)

        let firstReading = try await reader.read(deviceIndex: 1, fallbackIdentity: child)
        await requester.clearRawResponse(deviceIndex: 1, featureIndex: 5, functionID: 1, requestParameters: [0])
        let secondReading = try await reader.read(deviceIndex: 1, fallbackIdentity: child)
        let countRequests = await requester.requestCount(deviceIndex: 1, featureIndex: 5, functionID: 0)

        XCTAssertNil(firstReading)
        XCTAssertEqual(secondReading?.percentage, 73)
        XCTAssertEqual(countRequests, 2)
    }

    func testEvictsCompleteTargetCacheAfterInvalidLegacyFeatureStatus() async throws {
        let requester = await childRequesterWithBatteryFeatures(featureIndices: [0x0005: 5, 0x1000: 9])
        await requester.setRawResponse(
            deviceIndex: 1, featureIndex: 9, functionID: 0,
            response: invalidFeatureResponse(deviceIndex: 1, softwareID: 0x0D, featureIndex: 9)
        )
        let reader = HIDPPBatteryReader(requester: requester)
        let child = identity(name: nil, isReceiverChild: true)

        let firstReading = try await reader.read(deviceIndex: 1, fallbackIdentity: child)
        await requester.clearRawResponse(deviceIndex: 1, featureIndex: 9, functionID: 0)
        await requester.setParameters(deviceIndex: 1, featureIndex: 9, functionID: 0, parameters: [50])
        let secondReading = try await reader.read(deviceIndex: 1, fallbackIdentity: child)
        let countRequests = await requester.requestCount(deviceIndex: 1, featureIndex: 5, functionID: 0)

        XCTAssertNil(firstReading?.percentage)
        XCTAssertEqual(secondReading?.percentage, 50)
        XCTAssertEqual(countRequests, 2)
    }

    private func identity(name: String? = "MX Master", isReceiverChild: Bool = false) -> HIDPPFallbackIdentity {
        HIDPPFallbackIdentity(stableID: "receiver-1", name: name, category: .mouse, isReceiverChild: isReceiverChild)
    }

    private func childRequesterWithBatteryFeatures(
        featureIndices: [UInt16: UInt8] = [0x0005: 5, 0x1004: 7, 0x1000: 9]
    ) async -> ScriptedRequester {
        let requester = ScriptedRequester(featureIndices: featureIndices)
        await requester.setParameters(deviceIndex: 1, featureIndex: 5, functionID: 0, parameters: [2])
        await requester.setParameters(deviceIndex: 1, featureIndex: 5, functionID: 1, requestParameters: [0], parameters: [0x4D, 0x58])
        return requester
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
        let requestParameters: [UInt8]
    }

    private var featureIndices: [UInt16: UInt8]
    private let protocolVersion: (major: UInt8, minor: UInt8)
    private var parameterResponses: [Function: [UInt8]] = [:]
    private var rawResponses: [Function: [UInt8]] = [:]
    private var requests: [HIDPPPacket] = []

    init(
        featureIndices: [UInt16: UInt8] = [:],
        protocolVersion: (major: UInt8, minor: UInt8) = (2, 0)
    ) {
        self.featureIndices = featureIndices
        self.protocolVersion = protocolVersion
    }

    func send(_ packet: HIDPPPacket) async throws -> [UInt8] {
        requests.append(packet)
        let functionID = packet.bytes[3] >> 4
        if packet.bytes[2] == 0, functionID == 1 {
            return response(
                for: packet,
                parameters: [
                    protocolVersion.major, protocolVersion.minor, packet.bytes[6]
                ]
            )
        }
        if packet.bytes[2] == 0, functionID == 0 {
            let featureID = UInt16(packet.bytes[4]) << 8 | UInt16(packet.bytes[5])
            guard let featureIndex = featureIndices[featureID] else { return invalidFeatureResponse(for: packet) }
            return response(for: packet, parameters: [featureIndex])
        }

        let function = Function(
            deviceIndex: packet.bytes[1], featureIndex: packet.bytes[2], functionID: functionID,
            requestParameters: requestParameters(for: packet)
        )
        if let response = rawResponses[function] { return response }
        guard let parameters = parameterResponses[function] else { throw HIDPPError.invalidPacket }
        return response(for: packet, parameters: parameters)
    }

    func setFeatureIndex(_ featureIndex: UInt8, for featureID: UInt16) { featureIndices[featureID] = featureIndex }

    func setParameters(
        deviceIndex: UInt8, featureIndex: UInt8, functionID: UInt8,
        requestParameters: [UInt8] = [], parameters: [UInt8]
    ) {
        parameterResponses[Function(
            deviceIndex: deviceIndex, featureIndex: featureIndex, functionID: functionID,
            requestParameters: requestParameters
        )] = parameters
    }

    func setRawResponse(
        deviceIndex: UInt8, featureIndex: UInt8, functionID: UInt8,
        requestParameters: [UInt8] = [], response: [UInt8]
    ) {
        rawResponses[Function(
            deviceIndex: deviceIndex, featureIndex: featureIndex, functionID: functionID,
            requestParameters: requestParameters
        )] = response
    }

    func clearRawResponse(deviceIndex: UInt8, featureIndex: UInt8, functionID: UInt8, requestParameters: [UInt8] = []) {
        rawResponses.removeValue(forKey: Function(
            deviceIndex: deviceIndex, featureIndex: featureIndex, functionID: functionID,
            requestParameters: requestParameters
        ))
    }

    func requestedFeatureIDs() -> [UInt16] {
        requests.compactMap { packet in
            guard packet.bytes[2] == 0, packet.bytes[3] >> 4 == 0 else { return nil }
            return UInt16(packet.bytes[4]) << 8 | UInt16(packet.bytes[5])
        }
    }

    func reportIDs() -> [UInt8] { requests.map { $0.bytes[0] } }

    func requestCount(deviceIndex: UInt8, featureIndex: UInt8, functionID: UInt8) -> Int {
        requests.count {
            $0.bytes[1] == deviceIndex && $0.bytes[2] == featureIndex && $0.bytes[3] >> 4 == functionID
        }
    }

    func requestedParameters(deviceIndex: UInt8, featureIndex: UInt8, functionID: UInt8) -> [[UInt8]] {
        requests.filter {
            $0.bytes[1] == deviceIndex && $0.bytes[2] == featureIndex && $0.bytes[3] >> 4 == functionID
        }.map(requestParameters(for:))
    }

    private func requestParameters(for packet: HIDPPPacket) -> [UInt8] {
        packet.bytes[2] == 5 && packet.bytes[3] >> 4 == 1 ? [packet.bytes[4]] : []
    }

    private func response(for request: HIDPPPacket, parameters: [UInt8]) -> [UInt8] {
        [request.bytes[0], request.bytes[1], request.bytes[2], request.bytes[3]] + parameters
            + Array(repeating: 0, count: request.bytes.count - 4 - parameters.count)
    }

    private func invalidFeatureResponse(for request: HIDPPPacket) -> [UInt8] {
        [0x11, request.bytes[1], 0xFF, request.bytes[3], request.bytes[2], 0x06] + Array(repeating: 0, count: 14)
    }
}
