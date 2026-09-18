import Foundation

enum HIDPPBatteryValue: Sendable, Equatable {
    case percentage(Int)
    case coarse(CoarseBatteryLevel)
}

struct HIDPPBatteryReading: Sendable, Equatable {
    let level: HIDPPBatteryValue?
    let chargingState: BatteryChargingState

    init?(level: HIDPPBatteryValue?, chargingState: BatteryChargingState) {
        guard level != nil || chargingState != .unknown else { return nil }
        self.level = level
        self.chargingState = chargingState
    }
}

enum HIDPPProtocol {
    static let shortReportID: UInt8 = 0x10
    static let longReportID: UInt8 = 0x11
    static let softwareID: UInt8 = 0x08

    static func pingRequest(deviceIndex: UInt8, marker: UInt8) -> [UInt8] {
        shortRequest(
            deviceIndex: deviceIndex,
            command: 0,
            address: 0x10,
            parameters: [0, 0, marker]
        )
    }

    static func shortRequest(
        deviceIndex: UInt8,
        command: UInt8,
        address: UInt8,
        parameters: [UInt8] = [],
        softwareID: UInt8 = softwareID
    ) -> [UInt8] {
        var report = [shortReportID, deviceIndex, command, address | (softwareID & 0x0F)]
        report.append(contentsOf: parameters.prefix(3))
        report.append(contentsOf: repeatElement(0, count: max(0, 7 - report.count)))
        return report
    }

    static func registerRead(deviceIndex: UInt8, register: UInt8) -> [UInt8] {
        [shortReportID, deviceIndex, 0x81, register, 0, 0, 0]
    }

    static func isReply(_ response: [UInt8], to request: [UInt8]) -> Bool {
        guard response.count >= 4, request.count >= 4 else { return false }
        if response[2] == 0x8F || response[2] == 0xFF { return false }
        return (response[1] == request[1] || response[1] == request[1] ^ 0xFF) &&
            response[2] == request[2] && response[3] == request[3]
    }

    static func isErrorReply(_ response: [UInt8], to request: [UInt8]) -> Bool {
        guard response.count >= 6, request.count >= 4,
              response[2] == 0x8F || response[2] == 0xFF else { return false }
        return (response[1] == request[1] || response[1] == request[1] ^ 0xFF) &&
            response[3] == request[2] && response[4] == request[3]
    }

    static func parseBatteryStatus(_ report: [UInt8]) -> HIDPPBatteryReading? {
        guard report.count >= 5 else { return nil }
        let percentage = Int(report[4])
        guard (0...100).contains(percentage) else { return nil }
        return HIDPPBatteryReading(
            level: percentage > 0 ? .percentage(percentage) : nil,
            chargingState: batteryState(report.count > 6 ? report[6] : nil)
        )
    }

    static func parseUnifiedBattery(_ report: [UInt8]) -> HIDPPBatteryReading? {
        guard report.count >= 6 else { return nil }
        let percentage = Int(report[4])
        guard percentage <= 100 else { return nil }
        let level: HIDPPBatteryValue?
        if percentage > 0 {
            level = .percentage(percentage)
        } else {
            switch report[5] {
            case 8: level = .coarse(.full)
            case 4: level = .coarse(.good)
            case 2: level = .coarse(.low)
            case 1: level = .coarse(.critical)
            default: level = nil
            }
        }
        return HIDPPBatteryReading(
            level: level,
            chargingState: batteryState(report.count > 6 ? report[6] : nil)
        )
    }

    static func parseBatteryCharge(_ report: [UInt8]) -> HIDPPBatteryReading? {
        guard report.count >= 5 else { return nil }
        let percentage = Int(report[4])
        guard (0...100).contains(percentage) else { return nil }
        let state: BatteryChargingState
        switch report.count > 6 ? report[6] & 0xF0 : nil {
        case 0x30: state = .discharging
        case 0x50: state = .charging
        case 0x90: state = .full
        default: state = .unknown
        }
        return HIDPPBatteryReading(level: .percentage(percentage), chargingState: state)
    }

    static func parseBatteryVoltage(_ report: [UInt8]) -> HIDPPBatteryReading? {
        guard report.count >= 6 else { return nil }
        let state: BatteryChargingState
        if report.count <= 6 {
            state = .unknown
        } else if report[6] & 0x80 == 0 {
            state = .discharging
        } else {
            switch report[6] & 0x03 {
            case 0: state = .charging
            case 1: state = .full
            default: state = .unknown
            }
        }
        let millivolts = Int(report[4]) << 8 | Int(report[5])
        return HIDPPBatteryReading(level: .percentage(percentage(for: millivolts)), chargingState: state)
    }

    private static func percentage(for millivolts: Int) -> Int {
        let points = [
            (4186, 100), (4067, 90), (3989, 80), (3922, 70), (3859, 60),
            (3811, 50), (3778, 40), (3751, 30), (3717, 20), (3671, 10),
            (3646, 5), (3579, 2), (3500, 0)
        ]
        if millivolts >= points[0].0 { return 100 }
        if millivolts <= points[points.count - 1].0 { return 0 }
        for (high, low) in zip(points, points.dropFirst()) where (low.0...high.0).contains(millivolts) {
            let fraction = Double(millivolts - low.0) / Double(high.0 - low.0)
            return Int((Double(low.1) + Double(high.1 - low.1) * fraction).rounded())
        }
        return 0
    }

    static func parseBatteryStatusRegister(_ report: [UInt8]) -> HIDPPBatteryReading? {
        guard report.count >= 5 else { return nil }
        let level: HIDPPBatteryValue?
        switch report[4] {
        case 7: level = .coarse(.full)
        case 5: level = .coarse(.good)
        case 3: level = .coarse(.low)
        case 1: level = .coarse(.critical)
        case 0: level = nil
        default: return nil
        }
        let state: BatteryChargingState
        if report.count <= 5 {
            state = .unknown
        } else if report[5] == 0 {
            state = .discharging
        } else if report[5] & 0x21 == 0x21 {
            state = .charging
        } else if report[5] & 0x22 == 0x22 {
            state = .full
        } else {
            state = .unknown
        }
        return HIDPPBatteryReading(level: level, chargingState: state)
    }

    private static func batteryState(_ byte: UInt8?) -> BatteryChargingState {
        switch byte {
        case 0: return .discharging
        case 1, 2, 4: return .charging
        case 3: return .full
        default: return .unknown
        }
    }
}
