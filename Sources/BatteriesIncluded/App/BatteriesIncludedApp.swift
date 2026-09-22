import SwiftUI

struct BatteriesIncludedApp: App {
    @State private var monitor = makeMonitor()

    @MainActor
    private static func makeMonitor() -> DeviceMonitor {
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--device-snapshot") {
            let path = CommandLine.arguments.dropFirst(index + 1).first ?? ""
            return .snapshot(path: path)
        }
        #endif
        return DeviceMonitor(collectors: [
            SystemBluetoothCollector(), CoreBluetoothCollector(), SystemProfilerCollector(),
            LogitechHIDCollector()
        ])
    }

    var body: some Scene {
        MenuBarExtra {
            BatteryMenuView(monitor: monitor)
                .onAppear { Task { await monitor.refresh() } }
        } label: {
            let battery = MenuBarBattery(state: monitor.state)
            Image(nsImage: BatteryLevelIcon.image(
                percentage: battery.percentage, isCharging: battery.isCharging, showsUnknown: true
            ))
            .help(battery.tooltip)
            .accessibilityLabel("Batteries Included. " + battery.tooltip)
            .task { monitor.start() }
        }
        .menuBarExtraStyle(.menu)
    }
}

@main
@MainActor
enum BatteriesIncludedEntryPoint {
    static func main() async {
        if CommandLine.arguments.dropFirst().first == BluetoothHelperRunner.argument {
            let snapshot = await SystemBluetoothCollector().collectInCurrentProcess()
            do {
                let data = try JSONEncoder().encode(snapshot)
                try FileHandle.standardOutput.write(contentsOf: data)
            } catch {
                exit(1)
            }
            return
        }
        BatteriesIncludedApp.main()
    }
}
