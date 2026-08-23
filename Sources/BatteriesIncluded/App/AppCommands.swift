import AppKit

@MainActor
enum AppCommands {
    static func showAbout() {
        NSApplication.shared.orderFrontStandardAboutPanel(nil)
    }

    static func quit() {
        NSApplication.shared.terminate(nil)
    }
}
