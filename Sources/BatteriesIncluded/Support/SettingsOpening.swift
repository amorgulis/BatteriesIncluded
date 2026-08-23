import AppKit

enum SettingsOpening {
    @discardableResult
    static func openBluetoothPrivacy() -> Bool {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!
        )
    }
}
