import Foundation

struct CollectorSnapshot: Sendable, Codable {
    let availability: BluetoothAvailability
    let observations: [BatteryObservation]
}

protocol BatteryCollecting: Sendable {
    func collect() async -> CollectorSnapshot
}
