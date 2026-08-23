import SwiftUI

extension DeviceBattery {
    var primaryBatteryText: String {
        guard !levels.isEmpty else { return "Battery unavailable" }
        if levels.count == 1, levels[0].component == .whole {
            return "\(levels[0].percentage)%"
        }
        return Self.componentSummary(levels)
    }

    fileprivate var hasTrailingWholeBatteryLevel: Bool {
        levels.count == 1 && levels[0].component == .whole
    }
}

struct DeviceRowView: View {
    let device: DeviceBattery

    var body: some View {
        Label {
            HStack {
                VStack(alignment: .leading) {
                    Text(device.name)
                    if !device.hasTrailingWholeBatteryLevel {
                        Text(device.primaryBatteryText)
                            .foregroundStyle(.secondary)
                    }
                }

                if device.hasTrailingWholeBatteryLevel {
                    Spacer()
                    Text(device.primaryBatteryText)
                        .monospacedDigit()
                }
            }
        } icon: {
            DeviceIcon(category: device.category)
        }
    }
}
