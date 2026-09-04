import Foundation

enum HIDPPBatteryValue: Sendable, Equatable {
    case percentage(Int)
    case coarse(CoarseBatteryLevel)
}

enum HIDPPProtocol {
    static let shortReportID: UInt8 = 0x10
    static let longReportID: UInt8 = 0x11
    static let softwareID: UInt8 = 0x08

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

    static func parseBatteryStatus(_ report: [UInt8]) -> HIDPPBatteryValue? {
        guard report.count >= 5 else { return nil }
        let percentage = Int(report[4])
        guard (1...100).contains(percentage) else { return nil }
        return .percentage(percentage)
    }

    static func parseUnifiedBattery(_ report: [UInt8]) -> HIDPPBatteryValue? {
        guard report.count >= 6 else { return nil }
        let percentage = Int(report[4])
        if (1...100).contains(percentage) {
            return .percentage(percentage)
        }
        switch report[5] {
        case 8: return .coarse(.full)
        case 4: return .coarse(.good)
        case 2: return .coarse(.low)
        case 1: return .coarse(.critical)
        default: return nil
        }
    }

    static func parseBatteryCharge(_ report: [UInt8]) -> HIDPPBatteryValue? {
        guard report.count >= 5 else { return nil }
        let percentage = Int(report[4])
        guard (0...100).contains(percentage) else { return nil }
        return .percentage(percentage)
    }

    static func parseBatteryVoltage(_ report: [UInt8]) -> HIDPPBatteryValue? {
        guard report.count >= 6 else { return nil }
        let millivolts = Int(report[4]) << 8 | Int(report[5])
        let points = [
            (4186, 100), (4067, 90), (3989, 80), (3922, 70), (3859, 60),
            (3811, 50), (3778, 40), (3751, 30), (3717, 20), (3671, 10),
            (3646, 5), (3579, 2), (3500, 0)
        ]
        if millivolts >= points[0].0 { return .percentage(100) }
        if millivolts <= points[points.count - 1].0 { return .percentage(0) }
        for (high, low) in zip(points, points.dropFirst()) where (low.0...high.0).contains(millivolts) {
            let fraction = Double(millivolts - low.0) / Double(high.0 - low.0)
            return .percentage(Int((Double(low.1) + Double(high.1 - low.1) * fraction).rounded()))
        }
        return nil
    }

    static func parseBatteryStatusRegister(_ report: [UInt8]) -> HIDPPBatteryValue? {
        guard report.count >= 5 else { return nil }
        switch report[4] {
        case 7: return .coarse(.full)
        case 5: return .coarse(.good)
        case 3: return .coarse(.low)
        case 1: return .coarse(.critical)
        default: return nil
        }
    }
}
