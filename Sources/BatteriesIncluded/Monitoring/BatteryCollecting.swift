import Foundation

struct CollectorSnapshot: Sendable {
    let availability: BluetoothAvailability
    let observations: [BatteryObservation]
}

protocol BatteryCollecting: Sendable {
    func collect() async -> CollectorSnapshot
}
