import AppKit
import UniformTypeIdentifiers

@MainActor
enum AppCommands {
    static func exportDebugSnapshot(_ capture: CollectorCapture) {
        let panel = NSSavePanel()
        panel.title = "Export Debug Snapshot"
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "BatteriesIncluded-debug-\(Int(capture.capturedAt.timeIntervalSince1970)).json"
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try capture.write(to: url)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Could not export debug snapshot"
            alert.runModal()
        }
    }

    static func quit() {
        NSApplication.shared.terminate(nil)
    }
}
