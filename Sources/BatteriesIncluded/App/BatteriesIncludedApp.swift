import SwiftUI

struct BatteriesIncludedApp: App {
    @State private var monitor = DeviceMonitor(collectors: [
        SystemBluetoothCollector(), CoreBluetoothCollector(), SystemProfilerCollector(),
        LogitechHIDCollector()
    ])

    var body: some Scene {
        MenuBarExtra("Batteries Included", systemImage: "battery.75percent") {
            BatteryMenuView(monitor: monitor)
                .task { monitor.start() }
                .onAppear { Task { await monitor.refresh() } }
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
