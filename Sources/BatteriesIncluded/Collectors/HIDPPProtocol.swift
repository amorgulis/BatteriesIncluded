import Foundation

let logitechVendorID: UInt16 = 0x046D

protocol HIDPPTransport: AnyObject {
    func write(_ data: [UInt8]) -> Int32
    func read(maxLength: Int, timeoutMilliseconds: Int32) -> [UInt8]?
}

struct HIDPPBattery: Equatable, Sendable {
    enum Status: Equatable, Sendable {
        case discharging, charging, full, almostFull, notCharging, error, unknown
    }

    let level: Int?
    let status: Status
    let voltage: Int?
}

enum HIDPPBatteryDecoder {
    static func unifiedBattery(payload: [UInt8]) -> HIDPPBattery? {
        guard payload.count >= 3 else { return nil }
        return HIDPPBattery(
            level: payload[0] > 0 ? Int(payload[0]) : nil,
            status: status(payload[2]),
            voltage: nil
        )
    }

    static func statusBattery(payload: [UInt8]) -> HIDPPBattery? {
        guard payload.count >= 3 else { return nil }
        return HIDPPBattery(
            level: payload[0] > 0 ? Int(payload[0]) : nil,
            status: status(payload[2]),
            voltage: nil
        )
    }

    static func voltageBattery(payload: [UInt8]) -> HIDPPBattery? {
        guard payload.count >= 3 else { return nil }
        let voltage = (Int(payload[0]) << 8) | Int(payload[1])
        let level: Int? = voltage > 0
            ? (min(max(voltage, 3_500), 4_200) - 3_500) * 100 / 700
            : nil
        return HIDPPBattery(level: level, status: status(payload[2]), voltage: voltage)
    }

    static func registerBattery(payload: [UInt8]) -> HIDPPBattery? {
        guard payload.count >= 2, payload[0] > 0 else { return nil }
        return HIDPPBattery(
            level: Int(payload[0]), status: status(payload[1]), voltage: nil
        )
    }

    private static func status(_ byte: UInt8) -> HIDPPBattery.Status {
        switch byte {
        case 0: .discharging
        case 1: .charging
        case 2: .notCharging
        case 3: .full
        case 4: .almostFull
        case 5...7: .error
        default: .unknown
        }
    }
}

struct HIDPPProtocol {
    private static let shortReport: UInt8 = 0x10
    private static let longReport: UInt8 = 0x11
    private static let shortSize = 7
    private static let longSize = 20

    private var softwareID: UInt8 = 1
    private let requestTimeout: TimeInterval
    private let operationDeadline: Date?

    init(requestTimeout: TimeInterval = 0.2, operationDeadline: Date? = nil) {
        self.requestTimeout = requestTimeout
        self.operationDeadline = operationDeadline
    }

    mutating func ping(_ handle: any HIDPPTransport, deviceNumber: UInt8) -> Float? {
        let softwareID = nextSoftwareID()
        let marker = UInt8.random(in: 1...255)
        var data = [UInt8](repeating: 0, count: Self.shortSize)
        data[0] = Self.shortReport
        data[1] = deviceNumber
        data[2] = 0
        data[3] = 0x10 | softwareID
        data[6] = marker
        guard handle.write(data) >= 0 else { return nil }

        let deadline = nextDeadline()
        while Date() < deadline && !currentTaskIsCancelled() {
            let remaining = max(1, Int32(deadline.timeIntervalSinceNow * 1_000))
            guard let reply = handle.read(maxLength: Self.longSize, timeoutMilliseconds: remaining),
                  reply.count >= Self.shortSize, reply[1] == deviceNumber else { continue }
            if reply[0] == Self.shortReport, reply[2] == 0x8F {
                return [0x09, 0x0A].contains(reply[5]) ? nil : 1
            }
            if reply[2] == 0, reply[3] & 0x0F == softwareID, reply[6] == marker {
                return Float(reply[4]) + Float(reply[5]) / 10
            }
        }
        return nil
    }

    mutating func featureIndex(
        _ featureID: UInt16, handle: any HIDPPTransport, deviceNumber: UInt8
    ) -> UInt8? {
        let payload = request(
            handle, deviceNumber: deviceNumber, requestID: 0,
            parameters: [UInt8(featureID >> 8), UInt8(featureID & 0xFF)]
        )
        guard let index = payload?.first, index > 0 else { return nil }
        return index
    }

    mutating func battery(
        _ handle: any HIDPPTransport, deviceNumber: UInt8, version: Float
    ) -> HIDPPBattery? {
        if version < 2 {
            for register: UInt8 in [0x07, 0x0D] {
                if let battery = legacyRegisterRequest(
                    handle, deviceNumber: deviceNumber, register: register
                ).flatMap(HIDPPBatteryDecoder.registerBattery) { return battery }
            }
            return nil
        }

        let candidates: [(UInt16, UInt16, ([UInt8]) -> HIDPPBattery?)] = [
            (0x1004, 0x10, HIDPPBatteryDecoder.unifiedBattery),
            (0x1000, 0x00, HIDPPBatteryDecoder.statusBattery),
            (0x1001, 0x00, HIDPPBatteryDecoder.voltageBattery)
        ]
        for (featureID, functionID, decode) in candidates {
            guard let index = featureIndex(
                featureID, handle: handle, deviceNumber: deviceNumber
            ) else { continue }
            if let battery = request(
                handle, deviceNumber: deviceNumber,
                requestID: UInt16(index) << 8 | functionID
            ).flatMap(decode) { return battery }
        }
        return nil
    }

    mutating func name(
        _ handle: any HIDPPTransport, deviceNumber: UInt8, version: Float
    ) -> String? {
        guard version >= 2,
              let index = featureIndex(0x0005, handle: handle, deviceNumber: deviceNumber),
              let count = request(
                handle, deviceNumber: deviceNumber, requestID: UInt16(index) << 8
              )?.first,
              count > 0, count < 50 else { return nil }

        var bytes: [UInt8] = []
        while bytes.count < Int(count) {
            guard let chunk = request(
                handle, deviceNumber: deviceNumber,
                requestID: UInt16(index) << 8 | 0x10,
                parameters: [UInt8(bytes.count)]
            ), !chunk.isEmpty else { break }
            bytes.append(contentsOf: chunk.prefix(Int(count) - bytes.count))
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    private mutating func request(
        _ handle: any HIDPPTransport, deviceNumber: UInt8, requestID: UInt16,
        parameters: [UInt8] = []
    ) -> [UInt8]? {
        let softwareID = nextSoftwareID()
        let maskedID = requestID & 0xFFF0 | UInt16(softwareID)
        let subID = UInt8(maskedID >> 8)
        let address = UInt8(maskedID & 0xFF)
        var data = [UInt8](
            repeating: 0,
            count: parameters.count > 3 ? Self.longSize : Self.shortSize
        )
        data[0] = parameters.count > 3 ? Self.longReport : Self.shortReport
        data[1] = deviceNumber
        data[2] = subID
        data[3] = address
        for (index, value) in parameters.prefix(16).enumerated() { data[index + 4] = value }
        guard handle.write(data) >= 0 else { return nil }

        let deadline = nextDeadline()
        while Date() < deadline && !currentTaskIsCancelled() {
            let remaining = max(1, Int32(deadline.timeIntervalSinceNow * 1_000))
            guard let reply = handle.read(maxLength: Self.longSize, timeoutMilliseconds: remaining),
                  reply.count >= Self.shortSize, reply[1] == deviceNumber else { continue }
            if reply[0] == Self.shortReport, reply[2] == 0x8F, reply[3] == subID { return nil }
            if reply[2] == 0xFF, reply[3] == subID, reply.count >= 5,
               reply[4] & 0x0F == softwareID { return nil }
            if reply[2] == subID, reply[3] & 0xF0 == address & 0xF0 {
                return Array(reply.dropFirst(4))
            }
        }
        return nil
    }

    private func legacyRegisterRequest(
        _ handle: any HIDPPTransport, deviceNumber: UInt8, register: UInt8
    ) -> [UInt8]? {
        let data: [UInt8] = [
            Self.shortReport, deviceNumber, 0x81, register, 0, 0, 0
        ]
        guard handle.write(data) >= 0 else { return nil }
        let deadline = nextDeadline()
        while Date() < deadline && !currentTaskIsCancelled() {
            let remaining = max(1, Int32(deadline.timeIntervalSinceNow * 1_000))
            guard let reply = handle.read(
                maxLength: Self.longSize, timeoutMilliseconds: remaining
            ), reply.count >= Self.shortSize, reply[1] == deviceNumber else { continue }
            if reply[0] == Self.shortReport, reply[2] == 0x8F,
               reply[3] == 0x81, reply[4] == register { return nil }
            if reply[2] == 0x81, reply[3] == register {
                return Array(reply.dropFirst(4))
            }
        }
        return nil
    }

    private mutating func nextSoftwareID() -> UInt8 {
        softwareID = softwareID % 15 + 1
        return softwareID | 0x08
    }

    private func currentTaskIsCancelled() -> Bool {
        withUnsafeCurrentTask { $0?.isCancelled ?? false }
    }

    private func nextDeadline() -> Date {
        let requestDeadline = Date().addingTimeInterval(requestTimeout)
        return operationDeadline.map { min($0, requestDeadline) } ?? requestDeadline
    }
}
