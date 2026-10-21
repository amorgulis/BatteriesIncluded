import Observation
import ServiceManagement

@MainActor
@Observable
final class LaunchAtLogin {
    private(set) var isEnabled = false
    private(set) var requiresApproval = false

    private let status: () -> SMAppService.Status
    private let register: () throws -> Void
    private let unregister: () throws -> Void

    init(
        status: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
        register: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
        unregister: @escaping () throws -> Void = { try SMAppService.mainApp.unregister() }
    ) {
        self.status = status
        self.register = register
        self.unregister = unregister
        refresh()
    }

    func refresh() {
        let current = status()
        isEnabled = current == .enabled
        requiresApproval = current == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) throws {
        defer { refresh() }
        if enabled {
            // A pending registration already exists; approval happens in System Settings.
            guard status() != .requiresApproval else { return }
            try register()
        } else {
            try unregister()
        }
    }
}
