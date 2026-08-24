import SwiftUI

@main
struct BatteriesIncludedApp: App {
    @State private var monitor = DeviceMonitor(collectors: [
        SystemBluetoothCollector(), CoreBluetoothCollector(), SystemProfilerCollector()
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
