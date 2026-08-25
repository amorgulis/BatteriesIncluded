import Foundation

struct LogitechDeviceReading: Sendable {
    let id: String
    let name: String
    let batteryLevel: Int?
    let category: DeviceCategory
}

actor LogitechHIDCollector: BatteryCollecting {
    private struct Receiver {
        let productID: UInt16
        let interfaceNumber: Int32
    }

    private static let receivers: [Receiver] = [
        .init(productID: 0xC548, interfaceNumber: 2),
        .init(productID: 0xC52B, interfaceNumber: 2),
        .init(productID: 0xC532, interfaceNumber: 2),
        .init(productID: 0xC52F, interfaceNumber: 1),
        .init(productID: 0xC518, interfaceNumber: 1),
        .init(productID: 0xC51A, interfaceNumber: 1),
        .init(productID: 0xC51B, interfaceNumber: 1),
        .init(productID: 0xC521, interfaceNumber: 1),
        .init(productID: 0xC525, interfaceNumber: 1),
        .init(productID: 0xC526, interfaceNumber: 1),
        .init(productID: 0xC52E, interfaceNumber: 1),
        .init(productID: 0xC531, interfaceNumber: 1),
        .init(productID: 0xC534, interfaceNumber: 1),
        .init(productID: 0xC535, interfaceNumber: 1),
        .init(productID: 0xC537, interfaceNumber: 1),
        .init(productID: 0xC539, interfaceNumber: 2),
        .init(productID: 0xC53A, interfaceNumber: 2),
        .init(productID: 0xC53D, interfaceNumber: 2),
        .init(productID: 0xC53F, interfaceNumber: 2),
        .init(productID: 0xC541, interfaceNumber: 2),
        .init(productID: 0xC545, interfaceNumber: 2),
        .init(productID: 0xC547, interfaceNumber: 2),
        .init(productID: 0xC54D, interfaceNumber: 2)
    ]

    private static let directProductRanges: [ClosedRange<UInt16>] = [
        0xC07D...0xC094, 0xC32B...0xC344, 0xC08B...0xC0B0
    ]

    private let manager: HIDManager?

    init(manager: HIDManager? = HIDManager()) {
        self.manager = manager
    }

    func collect() async -> CollectorSnapshot {
        guard let manager else {
            SystemLogging.logitechHID.error("Unable to initialize I/O HID manager")
            return CollectorSnapshot(availability: .available, observations: [])
        }
        let observedAt = Date()
        let readings = scan(manager, deadline: observedAt.addingTimeInterval(2))
        SystemLogging.logitechHID.info(
            "Collected \(readings.count, privacy: .public) Logitech HID++ devices"
        )
        return CollectorSnapshot(
            availability: .available,
            observations: readings.map { Self.map($0, observedAt: observedAt) }
        )
    }

    nonisolated static func map(
        _ reading: LogitechDeviceReading, observedAt: Date
    ) -> BatteryObservation {
        BatteryObservation(
            sourceID: reading.id,
            stableID: nil,
            name: reading.name,
            isConnected: true,
            category: reading.category,
            component: .whole,
            percentage: reading.batteryLevel,
            source: .logitechHID,
            observedAt: observedAt
        )
    }

    nonisolated static func category(for name: String) -> DeviceCategory {
        let name = name.lowercased()
        if name.contains("mouse") || name.contains("master") || name.contains("anywhere") ||
            name.contains("superlight") || name.contains("trackball") {
            return .mouse
        }
        if name.contains("keyboard") || name.contains("keys") || name.contains("craft") {
            return .keyboard
        }
        if name.contains("headset") || name.contains("headphone") || name.contains("zone") ||
            name.contains("g pro x wireless") {
            return .headphones
        }
        if name.contains("gamepad") || name.contains("controller") { return .gameController }
        return .other
    }

    private func scan(_ manager: HIDManager, deadline: Date) -> [LogitechDeviceReading] {
        let descriptors = manager.enumerate(vendorID: logitechVendorID)
        var readings: [LogitechDeviceReading] = []
        var hidpp = HIDPPProtocol(operationDeadline: deadline)

        for receiver in Self.receivers {
            guard Date() < deadline, !Task.isCancelled else { break }
            for descriptor in descriptors where
                descriptor.productID == receiver.productID &&
                descriptor.interfaceNumber == receiver.interfaceNumber {
                guard Date() < deadline, !Task.isCancelled else { break }
                readings.append(contentsOf: scanReceiver(
                    descriptor, manager: manager, hidpp: &hidpp, deadline: deadline
                ))
            }
        }

        for descriptor in descriptors where isDirectDevice(descriptor) {
            guard Date() < deadline, !Task.isCancelled else { break }
            if let reading = scanDirectDevice(
                descriptor, manager: manager, hidpp: &hidpp
            ) {
                readings.append(reading)
            }
        }
        return readings
    }

    private func scanReceiver(
        _ descriptor: HIDDeviceDescriptor, manager: HIDManager,
        hidpp: inout HIDPPProtocol, deadline: Date
    ) -> [LogitechDeviceReading] {
        guard let handle = manager.open(descriptor) else { return [] }
        var readings: [LogitechDeviceReading] = []
        for deviceNumber: UInt8 in 1...6 {
            guard Date() < deadline, !Task.isCancelled else { break }
            guard let version = hidpp.ping(handle, deviceNumber: deviceNumber) else { continue }
            let name = hidpp.name(handle, deviceNumber: deviceNumber, version: version)
                ?? "Logitech Device \(deviceNumber)"
            let battery = hidpp.battery(handle, deviceNumber: deviceNumber, version: version)
            readings.append(LogitechDeviceReading(
                id: "\(descriptor.path):\(deviceNumber)",
                name: name,
                batteryLevel: battery?.level,
                category: Self.category(for: name)
            ))
        }
        return readings
    }

    private func scanDirectDevice(
        _ descriptor: HIDDeviceDescriptor, manager: HIDManager,
        hidpp: inout HIDPPProtocol
    ) -> LogitechDeviceReading? {
        guard let handle = manager.open(descriptor),
              let version = hidpp.ping(handle, deviceNumber: 0xFF) else { return nil }
        let name = hidpp.name(handle, deviceNumber: 0xFF, version: version)
            ?? descriptor.productName
        let battery = hidpp.battery(handle, deviceNumber: 0xFF, version: version)
        return LogitechDeviceReading(
            id: "\(descriptor.path):255",
            name: name,
            batteryLevel: battery?.level,
            category: Self.category(for: name)
        )
    }

    private func isDirectDevice(_ descriptor: HIDDeviceDescriptor) -> Bool {
        (descriptor.interfaceNumber == 1 || descriptor.interfaceNumber == 2) &&
            Self.directProductRanges.contains { $0.contains(descriptor.productID) }
    }
}
