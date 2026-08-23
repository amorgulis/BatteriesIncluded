import Foundation

enum BatteryComponent: Hashable, Sendable, Comparable {
    case whole, left, right, `case`, custom(String)

    private var sortKey: (Int, String) {
        switch self {
        case .whole: (0, "")
        case .left: (1, "")
        case .right: (2, "")
        case .case: (3, "")
        case .custom(let label): (4, label.localizedLowercase)
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.sortKey < rhs.sortKey
    }
}

enum BatterySource: Int, Sendable, Equatable { case system = 0, coreBluetooth = 1 }
enum DeviceCategory: Sendable, Equatable { case headphones, mouse, keyboard, trackpad, gameController, other }
enum BluetoothAvailability: Sendable, Equatable { case available, poweredOff, permissionDenied, unavailable }

struct BatteryObservation: Sendable, Equatable {
    let sourceID: String
    let stableID: String?
    let name: String
    let isConnected: Bool
    let category: DeviceCategory?
    let component: BatteryComponent
    let percentage: Int?
    let source: BatterySource
    let observedAt: Date
}

struct DeviceBattery: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let category: DeviceCategory
    let levels: [(component: BatteryComponent, percentage: Int)]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.category == rhs.category &&
        lhs.levels.map { "\($0.component):\($0.percentage)" } == rhs.levels.map { "\($0.component):\($0.percentage)" }
    }

    static func componentSummary(_ levels: [(BatteryComponent, Int)]) -> String {
        levels.map { component, percentage in
            "\(component.displayName) \(percentage)%"
        }.joined(separator: " · ")
    }
}

private extension BatteryComponent {
    var displayName: String {
        switch self {
        case .whole: "Battery"
        case .left: "Left"
        case .right: "Right"
        case .case: "Case"
        case .custom(let label): label
        }
    }
}

enum MenuState: Sendable, Equatable {
    case loading
    case devices([DeviceBattery])
    case noDevices
    case bluetoothOff
    case permissionDenied
    case unavailable
}
