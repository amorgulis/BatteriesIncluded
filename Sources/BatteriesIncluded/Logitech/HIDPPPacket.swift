enum HIDPPReportKind: UInt8, Sendable {
    case short = 0x10
    case long = 0x11

    var length: Int {
        self == .short ? 7 : 20
    }
}

enum HIDPPError: Error, Sendable, Equatable {
    case invalidPacket
    case invalidFeatureIndex
    case timeout
    case disconnected
    case protocolError(UInt8)
}

struct HIDPPPacket: Sendable, Equatable {
    let bytes: [UInt8]

    static func request(
        kind: HIDPPReportKind,
        deviceIndex: UInt8,
        featureIndex: UInt8,
        functionID: UInt8,
        softwareID: UInt8,
        parameters: [UInt8]
    ) throws -> Self {
        guard functionID < 0x10, softwareID > 0, softwareID < 0x10,
              parameters.count <= kind.length - 4 else {
            throw HIDPPError.invalidPacket
        }

        let header = [kind.rawValue, deviceIndex, featureIndex, (functionID << 4) | softwareID]
        return .init(bytes: header + parameters + .init(repeating: 0, count: kind.length - header.count - parameters.count))
    }

    var parameters: ArraySlice<UInt8> {
        bytes.dropFirst(4)
    }

    func replacingSoftwareID(_ softwareID: UInt8) throws -> Self {
        guard softwareID > 0, softwareID < 0x10, bytes.count >= 4 else {
            throw HIDPPError.invalidPacket
        }
        var updatedBytes = bytes
        updatedBytes[3] = (updatedBytes[3] & 0xF0) | softwareID
        return .init(bytes: updatedBytes)
    }

    func matchesResponse(_ response: [UInt8]) -> Bool {
        response.count == bytes.count && response.prefix(4).elementsEqual(bytes.prefix(4))
    }

    func protocolError(in response: [UInt8]) -> HIDPPError? {
        guard response.count == HIDPPReportKind.long.length,
              response[0] == HIDPPReportKind.long.rawValue,
              response[1] == bytes[1],
              response[2] == 0xFF,
              response[3] == bytes[3],
              response[4] == bytes[2] else {
            return nil
        }

        switch response[5] {
        case 0x06:
            return .invalidFeatureIndex
        default:
            return .protocolError(response[5])
        }
    }
}
