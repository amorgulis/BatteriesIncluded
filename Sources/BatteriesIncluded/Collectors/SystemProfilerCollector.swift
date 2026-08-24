import Foundation

struct SystemProfilerBluetoothParser: Sendable {
    func parse(_ data: Data, observedAt: Date) throws -> [BatteryObservation] {
        let root = try JSONSerialization.jsonObject(with: data)
        guard let root = root as? [String: Any],
              let reports = root["SPBluetoothDataType"] as? [[String: Any]] else {
            throw CocoaError(.propertyListReadCorrupt)
        }

        var observations: [BatteryObservation] = []
        for report in reports {
            guard let controller = report["controller_properties"] as? [String: Any],
                  let connected = controller["device_connected"] as? [[String: Any]] else {
                continue
            }

            for namedDevice in connected {
                for (name, untypedProperties) in namedDevice {
                    guard let properties = untypedProperties as? [String: Any],
                          let rawAddress = properties["device_address"] as? String else {
                        continue
                    }
                    let address = normalizedAddress(rawAddress)
                    guard !address.isEmpty else { continue }

                    let category = deviceCategory(properties["device_minorType"] as? String)
                    for (component, key) in batteryKeys {
                        guard let percentage = percentage(properties[key]) else { continue }
                        observations.append(BatteryObservation(
                            sourceID: address,
                            stableID: address,
                            name: name,
                            isConnected: true,
                            category: category,
                            component: component,
                            percentage: percentage,
                            source: .systemProfiler,
                            observedAt: observedAt
                        ))
                    }
                }
            }
        }

        return observations.sorted {
            if $0.name != $1.name { return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return $0.component < $1.component
        }
    }

    private let batteryKeys: [(BatteryComponent, String)] = [
        (.whole, "device_batteryLevelMain"),
        (.left, "device_batteryLevelLeft"),
        (.right, "device_batteryLevelRight"),
        (.case, "device_batteryLevelCase")
    ]

    private func percentage(_ value: Any?) -> Int? {
        guard let string = value as? String,
              let value = Int(string.trimmingCharacters(in: CharacterSet(charactersIn: "%"))),
              (0...100).contains(value) else {
            return nil
        }
        return value
    }

    private func normalizedAddress(_ address: String) -> String {
        address.uppercased().replacingOccurrences(of: "-", with: ":")
    }

    private func deviceCategory(_ minorType: String?) -> DeviceCategory {
        switch minorType?.localizedLowercase {
        case "mouse": .mouse
        case "keyboard": .keyboard
        case "trackpad": .trackpad
        case "headphones", "headset": .headphones
        case "gamepad", "controller": .gameController
        default: .other
        }
    }
}

struct SystemProfilerCommandRunner: Sendable {
    let executableURL: URL
    let arguments: [String]
    let timeout: TimeInterval

    init(
        executableURL: URL = URL(fileURLWithPath: "/usr/sbin/system_profiler"),
        arguments: [String] = ["SPBluetoothDataType", "-json"],
        timeout: TimeInterval = 15
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.timeout = timeout
    }

    func run() async -> Data? {
        await Task.detached(priority: .utility) {
            let output = Pipe()
            let process = Process()
            process.executableURL = executableURL
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
            } catch {
                return nil
            }

            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
                return nil
            }
            guard process.terminationStatus == 0 else { return nil }
            return output.fileHandleForReading.readDataToEndOfFile()
        }.value
    }
}

actor SystemProfilerCollector: BatteryCollecting {
    private let runner: SystemProfilerCommandRunner
    private let parser = SystemProfilerBluetoothParser()

    init(runner: SystemProfilerCommandRunner = .init()) {
        self.runner = runner
    }

    func collect() async -> CollectorSnapshot {
        let observedAt = Date.now
        guard let data = await runner.run() else {
            SystemLogging.systemBluetooth.error("Bluetooth system report failed or timed out")
            return CollectorSnapshot(availability: .available, observations: [])
        }

        do {
            return CollectorSnapshot(
                availability: .available,
                observations: try parser.parse(data, observedAt: observedAt)
            )
        } catch {
            SystemLogging.systemBluetooth.error("Bluetooth system report was malformed")
            return CollectorSnapshot(availability: .available, observations: [])
        }
    }
}
