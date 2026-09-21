import Foundation

/// Bluetooth GATT Specification Supplement, Battery Level Status (0x2BED).
/// Neither an inactive charge state nor a level of 100 indicates full charge.
enum BLEBatteryStatus {
    static func decode(_ data: Data) -> BatteryChargingState {
        let bytes = Array(data)
        guard bytes.count >= 3 else { return .unknown }
        let flags = bytes[0]
        let additionalOffset = 3 + (flags & 1 != 0 ? 2 : 0) + (flags & 2 != 0 ? 1 : 0)
        let length = additionalOffset + (flags & 4 != 0 ? 1 : 0)
        guard bytes.count >= length else { return .unknown }
        let power = UInt16(bytes[1]) | UInt16(bytes[2]) << 8
        guard power & 1 != 0, power & 0x7000 == 0 else { return .unknown }
        if flags & 4 != 0, bytes[additionalOffset] & 4 != 0 { return .unknown }
        switch (power >> 5) & 3 {
        case 1: return .charging
        case 2, 3: return .discharging
        default: return .unknown
        }
    }
}

struct BLEBatteryReadProgress {
    var awaitingLevel: Bool
    var awaitingStatus: Bool
    private(set) var level: Int?
    private(set) var chargingState: BatteryChargingState?
    private(set) var chargingObservedAt: Date?

    var isFinished: Bool { !awaitingLevel && !awaitingStatus }

    mutating func receiveLevel(_ value: Int?) {
        level = value
        awaitingLevel = false
    }

    mutating func receiveStatus(_ value: BatteryChargingState, at date: Date = .now) {
        chargingState = value
        chargingObservedAt = date
        awaitingStatus = false
    }
}
