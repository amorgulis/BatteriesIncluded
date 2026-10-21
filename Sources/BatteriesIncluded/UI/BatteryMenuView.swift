import SwiftUI
import ServiceManagement

struct BatteryMenuView: View {
    let monitor: DeviceMonitor
    @State private var launchAtLogin = LaunchAtLogin()

    var body: some View {
        menuContent
            .onAppear { launchAtLogin.refresh() }

        Divider()

        Button("Refresh") {
            Task { await monitor.refresh() }
        }
        .disabled(monitor.isRefreshing)

        Button(DebugMenuVisibility.exportTitle) {
            if let capture = monitor.collectorCapture {
                AppCommands.exportDebugSnapshot(capture)
            }
        }
        .disabled(monitor.collectorCapture == nil)

        Divider()

        Toggle("Launch at Login", isOn: Binding(
            get: { launchAtLogin.isEnabled },
            set: { enabled in
                do {
                    try launchAtLogin.setEnabled(enabled)
                    if launchAtLogin.requiresApproval {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                } catch {
                    let alert = NSAlert(error: error)
                    alert.messageText = "Could not change Launch at Login"
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
            }
        ))

        if launchAtLogin.requiresApproval {
            Button("Approve Launch at Login…") {
                SMAppService.openSystemSettingsLoginItems()
            }
        }

        Button("Quit") {
            AppCommands.quit()
        }
    }

    @ViewBuilder
    private var menuContent: some View {
        switch monitor.state {
        #if DEBUG
        case .snapshotError(let message):
            Text(message)
        #endif
        case .loading:
            ProgressView("Reading batteries…")
        case .devices(let devices):
            ForEach(devices) { device in
                DeviceRowView(device: device, contentWidth: DeviceRowView.contentWidth(
                    for: devices, otherTitles: ["Refresh", DebugMenuVisibility.exportTitle, "Launch at Login", "Approve Launch at Login…", "Quit"]
                ))
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
