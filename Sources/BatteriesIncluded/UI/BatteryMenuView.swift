import SwiftUI

struct BatteryMenuView: View {
    let monitor: DeviceMonitor

    var body: some View {
        menuContent

        Divider()

        Button("Refresh") {
            Task { await monitor.refresh() }
        }
        .disabled(monitor.isRefreshing)

        Button("About Batteries Included") {
            AppCommands.showAbout()
        }

        Divider()

        Button("Quit") {
            AppCommands.quit()
        }
    }

    @ViewBuilder
    private var menuContent: some View {
        switch monitor.state {
        case .loading:
            ProgressView("Reading batteries…")
        case .devices(let devices):
            ForEach(devices) { device in
                DeviceRowView(device: device)
            }
        case .noDevices:
            Label("No supported devices connected", systemImage: "wave.3.right")
        case .bluetoothOff:
            Label(
                "Bluetooth is off",
                systemImage: "antenna.radiowaves.left.and.right.slash"
            )
        case .permissionDenied:
            Text("Bluetooth access is required to read battery levels.")
            Button("Open System Settings") {
                if !SettingsOpening.openBluetoothPrivacy() {
                    SystemLogging.monitor.error("Failed to open Bluetooth privacy settings")
                }
            }
        case .unavailable:
            Label("Bluetooth unavailable", systemImage: "exclamationmark.triangle")
        }
    }
}
