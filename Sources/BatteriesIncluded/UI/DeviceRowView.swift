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
        let components = Set(levels.map(\.component)).union(
            componentChargingStates.filter { $0.value != .unknown }.keys
        ).filter { $0 != .whole }.sorted()
        if !components.isEmpty {
            let summary = components.map { component in
                let percentage = levels.first { $0.component == component }?.percentage
                let levelText = percentage.map { "\($0)%" } ?? "Battery unavailable"
                return "\(component.displayName) \(levelText)" +
                    (componentChargingStates[component]?.menuSuffix ?? "")
            }.joined(separator: " · ")
            return "\(name) — \(summary)"
        }
        return "\(name) — \(primaryBatteryText)" + (chargingState?.menuSuffix ?? "")
    }
}

private extension BatteryChargingState {
    var menuSuffix: String {
        switch self {
        case .charging: " ⚡"
        case .full: ""
        case .discharging: ""
        case .unknown: ""
        }
    }
}

struct DeviceRowView: View {
    let device: DeviceBattery

    var body: some View {
        Label(device.menuRowText, systemImage: DeviceIcon.symbol(for: device.category))
    }
}
