#if DEBUG
import Foundation

/// Reads external development data. No fixture content is included in the app.
enum DeviceSnapshot {
    static func load(path: String) throws -> [DeviceBattery] {
        guard !path.isEmpty else {
            throw SnapshotError.invalid("Supply a JSON file path after --device-snapshot.")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        guard Set(entries.map(\.id)).count == entries.count else {
            throw SnapshotError.invalid("Device IDs must be unique.")
        }
        return try entries.map { entry in
            guard !entry.id.isEmpty, !entry.name.isEmpty else {
                throw SnapshotError.invalid("Device IDs and names must not be empty.")
            }
            let levels = entry.levels ?? []
            guard levels.allSatisfy({ (0...100).contains($0.percentage) }),
                  Set(levels.map(\.component)).count == levels.count else {
                throw SnapshotError.invalid("Levels must have unique components and percentages from 0 to 100.")
            }
            return DeviceBattery(
                id: entry.id, name: entry.name, category: entry.category.value,
                levels: levels.map { (component($0.component), $0.percentage) }.sorted { $0.0 < $1.0 },
                coarseLevel: entry.coarseLevel, chargingState: entry.chargingState,
                componentChargingStates: Dictionary(uniqueKeysWithValues:
                    (entry.componentChargingStates ?? [:]).map { (component($0.key), $0.value) })
            )
        }
    }

    private static func component(_ name: String) -> BatteryComponent {
        switch name {
        case "whole": .whole
        case "left": .left
        case "right": .right
        case "case": .case
        default: .custom(name)
        }
    }

    private struct Entry: Decodable {
        let id: String
        let name: String
        let category: Category
        let levels: [Level]?
        let coarseLevel: CoarseBatteryLevel?
        let chargingState: BatteryChargingState?
        let componentChargingStates: [String: BatteryChargingState]?
    }

    private struct Level: Decodable {
        let component: String
        let percentage: Int
    }

    private enum Category: String, Decodable {
        case headphones, mouse, keyboard, trackpad, gameController, other

        var value: DeviceCategory {
            switch self {
            case .headphones: .headphones
            case .mouse: .mouse
            case .keyboard: .keyboard
            case .trackpad: .trackpad
            case .gameController: .gameController
            case .other: .other
            }
        }
    }

    private enum SnapshotError: LocalizedError {
        case invalid(String)
        var errorDescription: String? {
            switch self { case .invalid(let message): message }
        }
    }
}
#endif
