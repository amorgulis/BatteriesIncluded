import SwiftUI

extension DeviceBattery {
    var primaryBatteryText: String {
        if let coarseLevel { return coarseLevel.rawValue }
        guard !levels.isEmpty else { return "Battery unavailable" }
        if levels.count == 1, levels[0].component == .whole {
            return "\(levels[0].percentage)%"
        }
        return Self.componentSummary(levels)
    }

    var menuRowText: String {
        "\(name) — \(primaryBatteryText)"
    }
}

struct DeviceRowView: View {
    let device: DeviceBattery

    var body: some View {
        Label(device.menuRowText, systemImage: DeviceIcon.symbol(for: device.category))
    }
}
