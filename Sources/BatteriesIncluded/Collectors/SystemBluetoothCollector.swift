import Foundation
@preconcurrency import CoreBluetooth
@preconcurrency import IOBluetooth
@preconcurrency import IOKit

struct SystemDeviceReading: Sendable {
    let address: String
    let name: String
    let isConnected: Bool
    let category: DeviceCategory
    let percentages: [BatteryComponent: Int?]
}

actor SystemBluetoothCollector: BatteryCollecting {
    private static let componentKeys: [(BatteryComponent, [String])] = [
        (.left, ["BatteryPercentLeft", "batteryPercentLeft"]),
        (.right, ["BatteryPercentRight", "batteryPercentRight"]),
        (.case, ["BatteryPercentCase", "batteryPercentCase"]),
        (.whole, ["BatteryPercent", "BatteryPercentSingle", "batteryPercent"])
    ]

    private static let addressKeys = [
        "BluetoothAddress", "Bluetooth Address", "DeviceAddress", "deviceAddress",
        "BD_ADDR", "BTAddress", "Address"
    ]

    func collect() async -> CollectorSnapshot {
        let availability = bluetoothAvailability()
        guard availability == .available else {
            return CollectorSnapshot(availability: availability, observations: [])
        }

        let registryPercentages = registryPercentagesByAddress()
        let readings = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? [])
            .compactMap { device -> SystemDeviceReading? in
                guard device.isConnected() else { return nil }

                let address = Self.normalizedAddress(device.addressString)
                guard !address.isEmpty else { return nil }

                var percentages = Self.percentages(fromDevice: device)
                let registryValues = registryPercentages[address] ?? [:]
                for (component, value) in registryValues where percentages[component] == nil {
                    percentages[component] = value
                }

                return SystemDeviceReading(
                    address: address,
                    name: device.name ?? address,
                    isConnected: true,
                    category: Self.category(
                        major: device.deviceClassMajor,
                        minor: device.deviceClassMinor,
                        name: device.name ?? ""
                    ),
                    percentages: percentages
                )
            }

        return CollectorSnapshot(
            availability: availability,
            observations: readings.flatMap { Self.map($0, now: .now) }
        )
    }

    nonisolated static func map(_ reading: SystemDeviceReading, now: Date) -> [BatteryObservation] {
        guard reading.isConnected else { return [] }

        let address = normalizedAddress(reading.address)
        guard !address.isEmpty else { return [] }

        let levels = reading.percentages.compactMap { component, percentage in
            percentage.map { (component, $0) }
        }.sorted { $0.0 < $1.0 }

        if levels.isEmpty {
            return [observation(from: reading, address: address, component: .whole, percentage: nil, now: now)]
        }

        return levels.map { component, percentage in
            observation(from: reading, address: address, component: component, percentage: percentage, now: now)
        }
    }

    private nonisolated static func observation(
        from reading: SystemDeviceReading,
        address: String,
        component: BatteryComponent,
        percentage: Int?,
        now: Date
    ) -> BatteryObservation {
        BatteryObservation(
            sourceID: address,
            stableID: address,
            name: reading.name,
            isConnected: true,
            category: reading.category,
            component: component,
            percentage: percentage,
            source: .system,
            observedAt: now
        )
    }

    private func bluetoothAvailability() -> BluetoothAvailability {
        let authorization = CBManager.authorization
        if authorization == .denied || authorization == .restricted {
            return .permissionDenied
        }

        guard let controller = IOBluetoothHostController.default() else {
            SystemLogging.systemBluetooth.error("Bluetooth host controller is unavailable")
            return .unavailable
        }

        return controller.powerState == kBluetoothHCIPowerStateOFF ? .poweredOff : .available
    }

    private static func percentages(fromDevice device: IOBluetoothDevice) -> [BatteryComponent: Int?] {
        var result: [BatteryComponent: Int?] = [:]

        for (component, keys) in componentKeys {
            for key in keys {
                let selector = NSSelectorFromString(key)
                guard device.responds(to: selector) else { continue }
                if let percentage = percentage(device.value(forKey: key)) {
                    result[component] = percentage
                    break
                }
            }
        }

        return result
    }

    private func registryPercentagesByAddress() -> [String: [BatteryComponent: Int?]] {
        guard let matching = IOServiceMatching("IOBluetoothDevice") else {
            SystemLogging.systemBluetooth.error("Failed to create I/O Registry Bluetooth matcher")
            return [:]
        }

        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS else {
            SystemLogging.systemBluetooth.error(
                "I/O Registry Bluetooth lookup failed with code \(result)"
            )
            return [:]
        }
        defer { IOObjectRelease(iterator) }

        var valuesByAddress: [String: [BatteryComponent: Int?]] = [:]
        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            guard let properties = Self.properties(of: service),
                  let address = Self.registryAddress(in: properties),
                  !address.isEmpty else {
                continue
            }

            let percentages = Self.percentages(in: properties)
            guard !percentages.isEmpty else { continue }
            valuesByAddress[address] = Self.mergeRegistryPercentageMaps([
                valuesByAddress[address] ?? [:],
                percentages
            ])
        }

        return valuesByAddress
    }

    private static func properties(of service: io_service_t) -> [String: Any]? {
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties else {
            return nil
        }

        return properties.takeRetainedValue() as? [String: Any]
    }

    nonisolated static func registryAddress(in properties: [String: Any]) -> String? {
        for key in addressKeys {
            guard let value = properties[key] else { continue }
            if let address = value as? String {
                return normalizedAddress(address)
            }
            if let address = value as? Data, address.count == 6 {
                return address.map { String(format: "%02X", $0) }.joined(separator: ":")
            }
        }
        return nil
    }

    nonisolated static func mergeRegistryPercentageMaps(
        _ percentageMaps: [[BatteryComponent: Int?]]
    ) -> [BatteryComponent: Int?] {
        var merged: [BatteryComponent: Int?] = [:]

        for percentages in percentageMaps {
            for (component, percentage) in percentages {
                guard merged[component] == nil,
                      let percentage,
                      (0...100).contains(percentage) else { continue }
                merged[component] = percentage
            }
        }

        return merged
    }

    private static func percentages(in properties: [String: Any]) -> [BatteryComponent: Int?] {
        var result: [BatteryComponent: Int?] = [:]
        for (component, keys) in componentKeys {
            for key in keys {
                if let percentage = percentage(properties[key]) {
                    result[component] = percentage
                    break
                }
            }
        }
        return result
    }

    private static func percentage(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            return number.intValue
        case let value as Int:
            return value
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }

    private static func normalizedAddress(_ address: String) -> String {
        address.uppercased().replacingOccurrences(of: "-", with: ":")
    }

    private static func category(
        major: BluetoothDeviceClassMajor,
        minor: BluetoothDeviceClassMinor,
        name: String
    ) -> DeviceCategory {
        let hint = name.localizedLowercase
        if hint.contains("trackpad") { return .trackpad }
        if hint.contains("keyboard") { return .keyboard }
        if hint.contains("mouse") { return .mouse }
        if ["controller", "gamepad", "dualshock", "xbox", "playstation"].contains(where: hint.contains) {
            return .gameController
        }
        if ["airpods", "headphone", "headset", "earbud", "buds"].contains(where: hint.contains) {
            return .headphones
        }

        if major == kBluetoothDeviceClassMajorAudio {
            return .headphones
        }
        guard major == kBluetoothDeviceClassMajorPeripheral else { return .other }

        let minorValue = Int(minor)
        switch minorValue & 0x30 {
        case 0x10:
            return .keyboard
        case 0x20:
            return .mouse
        default:
            break
        }

        switch minorValue & 0x0F {
        case 0x01, 0x02:
            return .gameController
        default:
            return .other
        }
    }
}
