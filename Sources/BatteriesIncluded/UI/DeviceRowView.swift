import SwiftUI

struct MenuBatteryPart {
    let text: String
    let percentage: Int?
    let isCharging: Bool

    var showsIcon: Bool { percentage != nil || isCharging }
    var accessibilityText: String { text + (isCharging ? ", charging" : "") }
}

extension DeviceBattery {
    var primaryBatteryText: String {
        if let coarseLevel { return coarseLevel.rawValue }
        guard !levels.isEmpty else { return "Battery unavailable" }
        if levels.count == 1, levels[0].component == .whole {
            return "\(levels[0].percentage)%"
        }
        return Self.componentSummary(levels)
    }

    var menuBatteryParts: [MenuBatteryPart] {
        let components = Set(levels.map(\.component)).union(
            componentChargingStates.filter { $0.value != .unknown }.keys
        ).filter { $0 != .whole }.sorted()
        if !components.isEmpty {
            return components.map { component in
                let percentage = levels.first { $0.component == component }?.percentage
                let levelText = percentage.map { "\($0)%" } ?? "Battery unavailable"
                return MenuBatteryPart(
                    text: "\(component.displayName) \(levelText)",
                    percentage: percentage,
                    isCharging: componentChargingStates[component] == .charging
                )
            }
        }
        return [MenuBatteryPart(
            text: primaryBatteryText,
            percentage: coarseLevel == nil ? levels.first?.percentage : nil,
            isCharging: chargingState == .charging
        )]
    }

    var menuRowText: String {
        "\(name) — " + menuBatteryParts.map(\.text).joined(separator: " · ")
    }

    var menuAccessibilityText: String {
        "\(name) — " + menuBatteryParts.map(\.accessibilityText).joined(separator: ", ")
    }
}

struct DeviceRowView: View {
    let device: DeviceBattery

    private var title: Text {
        var text = Text(verbatim: "\(device.name) — ")
        for (index, part) in device.menuBatteryParts.enumerated() {
            if index > 0 { text = text + Text(verbatim: " · ") }
            text = text + Text(verbatim: part.text)
            if part.showsIcon {
                let image = BatteryLevelIcon.image(percentage: part.percentage, isCharging: part.isCharging)
                text = text + Text(" ") + Text(Image(nsImage: image)).baselineOffset(-2)
            }
        }
        return text
    }

    var body: some View {
        // A plain Label becomes a disabled NSMenuItem, dimming its text.
        // An enabled row preserves native foreground and selection colors.
        Button {
            // Selecting a read-only device row only dismisses the menu.
        } label: {
            Label {
                title
            } icon: {
                Image(systemName: DeviceIcon.symbol(for: device.category))
            }
        }
        .accessibilityLabel(device.menuAccessibilityText)
    }
}
