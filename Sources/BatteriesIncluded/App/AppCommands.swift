import AppKit

@MainActor
enum AppCommands {
    static func quit() {
        NSApplication.shared.terminate(nil)
    }
}
