import Foundation

/// Summarizes known readings without inventing percentages for coarse or missing levels.
struct MenuBarBattery {
    let percentage: Int?
    let isCharging: Bool
    let tooltip: String

    init(state: MenuState) {
        guard case .devices(let devices) = state else {
            percentage = nil
            isCharging = false
            switch state {
            case .loading: tooltip = "Batteries Included — Checking battery levels…"
            case .bluetoothOff: tooltip = "Batteries Included — Bluetooth is off"
            case .permissionDenied: tooltip = "Batteries Included — Bluetooth permission required"
            case .unavailable: tooltip = "Batteries Included — Battery levels unavailable"
            #if DEBUG
            case .snapshotError(let message): tooltip = message
            #endif
            default: tooltip = "Batteries Included — No connected devices"
            }
            return
        }

        let readings = devices.flatMap { device in
            device.menuBatteryParts.map { (name: device.name, part: $0) }
        }
        let lowest = readings.filter { $0.part.percentage != nil }.min {
            $0.part.percentage! < $1.part.percentage!
        }
        percentage = lowest?.part.percentage
        isCharging = !readings.isEmpty && readings.allSatisfy { $0.part.isCharging }
        if let lowest {
            tooltip = "Lowest battery: \(lowest.name) — \(lowest.part.accessibilityText)"
                + (readings.contains { $0.part.percentage == nil } ? "\nSome battery levels unavailable" : "")
        } else if devices.isEmpty {
            tooltip = "Batteries Included — No connected devices"
        } else {
            tooltip = "Batteries Included — Battery percentage unavailable\n"
                + devices.map(\.menuAccessibilityText).joined(separator: "\n")
        }
    }
}
