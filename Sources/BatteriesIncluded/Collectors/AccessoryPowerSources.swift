import Foundation
import Darwin
import IOKit.ps

/// Accessory enumeration is private API, so resolve it at runtime and degrade to no data.
enum AccessoryPowerSources {
    static func descriptions() -> [[String: Any]] {
        guard let library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else { return [] }
        defer { dlclose(library) }
        guard let symbol = dlsym(library, "IOPSCopyPowerSourcesByType") else { return [] }
        typealias CopySources = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?
        let copySources = unsafeBitCast(symbol, to: CopySources.self)
        // kIOPSSourceForAccessories, from Apple's IOPowerSourcesPrivate.h.
        guard let info = copySources(4)?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return [] }
        return sources.compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
    }

    static func enrich(_ readings: [SystemDeviceReading], descriptions: [[String: Any]]) -> [SystemDeviceReading] {
        let expanded = descriptions.flatMap { source -> [[String: Any]] in
            let inheritedKeys = ["Type", "Transport Type", "Name", "Is Present", "Group Identifier", "Accessory Identifier"]
            let identity = source.filter { inheritedKeys.contains($0.key) }
            let parts = (source["Combined Parts"] as? [[String: Any]] ?? []).map {
                identity.merging($0) { _, partValue in partValue }
            }
            return [source] + parts
        }
        let sources = expanded.filter {
            $0["Type"] as? String == "Accessory Source" &&
            ["Bluetooth", "Bluetooth LE"].contains($0["Transport Type"] as? String ?? "") &&
            ($0["Is Present"] as? NSNumber)?.boolValue != false
        }
        var result = readings
        for source in sources {
            let identities = [source["Group Identifier"], source["Accessory Identifier"]].compactMap { $0 as? String }
            var addresses = identities.compactMap(address)
            if let group = source["Group Identifier"] as? String {
                addresses += sources.filter { $0["Group Identifier"] as? String == group }
                    .compactMap { $0["Accessory Identifier"] as? String }.compactMap(address)
            }
            var matches = readings.indices.filter { readings[$0].isConnected && addresses.contains(address(readings[$0].address) ?? "") }
            if matches.isEmpty && addresses.isEmpty, let name = source["Name"] as? String, !name.isEmpty {
                // Same-name sources are safe only when they belong to one explicit group.
                let sameName = sources.filter { ($0["Name"] as? String)?.lowercased() == name.lowercased() }
                let groups = Set(sameName.compactMap { ($0["Group Identifier"] ?? $0["Accessory Identifier"]) as? String })
                guard groups.count <= 1 else { continue }
                matches = readings.indices.filter { readings[$0].isConnected && readings[$0].name.caseInsensitiveCompare(name) == .orderedSame }
            }
            guard matches.count == 1, let index = matches.first, let component = component(source["Part Identifier"] as? String) else { continue }
            if let percentage = percentage(source) {
                result[index].percentages[component] = percentage
                result[index].chargingStates[component] = .unknown
            }
            if let state = chargingState(source) { result[index].chargingStates[component] = state }
            if component != .whole { result[index].isMultiBatteryDevice = true }
        }
        return result
    }

    private static func address(_ value: String) -> String? {
        let digits = value.filter { $0 != ":" && $0 != "-" }.uppercased()
        guard digits.count == 12, digits.allSatisfy({ $0.isHexDigit }) else { return nil }
        return digits
    }

    private static func component(_ part: String?) -> BatteryComponent? {
        switch part {
        case "Left": .left
        case "Right": .right
        case "Case": .case
        case nil, "Single", "Combined": .whole
        default: nil
        }
    }

    private static func percentage(_ source: [String: Any]) -> Int? {
        guard let current = (source["Current Capacity"] as? NSNumber)?.doubleValue,
              let maximum = (source["Max Capacity"] as? NSNumber)?.doubleValue,
              current.isFinite, maximum.isFinite, maximum > 0, current >= 0, current <= maximum else { return nil }
        return Int((current / maximum * 100).rounded())
    }

    private static func chargingState(_ source: [String: Any]) -> BatteryChargingState? {
        if (source["Is Charging"] as? NSNumber)?.doubleValue == 1 { return .charging }
        if (source["Is Charged"] as? NSNumber)?.doubleValue == 1 { return .full }
        if source["Power Source State"] as? String == "Battery Power" { return .discharging }
        return nil
    }
}
