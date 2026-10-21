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

    var contentWidth: CGFloat = 0

    static func contentWidth(for devices: [DeviceBattery], otherTitles: [String] = []) -> CGFloat {
        let nameWidth = devices.map { width(of: $0.name) }.max() ?? 0
        let batteryWidth = devices.map { batteryWidth(for: $0) }.max() ?? 0
        return max(nameWidth + 24 + batteryWidth, otherTitles.map { width(of: $0) }.max() ?? 0)
    }

    private static func width(of text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.menuFont(ofSize: 0)]).width
    }

    private static func batteryWidth(for device: DeviceBattery) -> CGFloat {
        device.menuBatteryParts.enumerated().reduce(0) { width, entry in
            let (index, part) = entry
            return width + (index > 0 ? Self.width(of: " · ") : 0)
                + Self.width(of: part.text)
                + (part.showsIcon ? Self.width(of: " ") + 23 : 0)
        }
    }

    private var title: Text {
        let rowWidth = max(contentWidth, Self.contentWidth(for: [device]))
        let gap = rowWidth - Self.width(of: device.name) - Self.batteryWidth(for: device)
        // Native menus flatten stacks, so preserve the trailing column in the
        // attributed title with a measured space between the name and status.
        var text = Text(verbatim: device.name)
            + Text(" ").kerning(gap - Self.width(of: " "))
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
