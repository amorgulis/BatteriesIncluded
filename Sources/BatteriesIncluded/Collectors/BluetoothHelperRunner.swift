import Foundation
import Darwin

/// Re-executes the app without its UI so IOBluetooth cannot reuse stale process state.
struct BluetoothHelperRunner: Sendable {
    static let argument = "--bluetooth-battery-snapshot"
    let executableURL: URL?
    let arguments: [String]
    let timeout: TimeInterval

    init(executableURL: URL? = Bundle.main.executableURL,
         arguments: [String] = [Self.argument], timeout: TimeInterval = 10) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.timeout = timeout
    }

    func run() async -> Data? {
        let task = Task.detached(priority: .utility) { () -> Data? in
            guard let executableURL, !Task.isCancelled else { return nil }
            // A file avoids blocking the child when its output exceeds a pipe's capacity.
            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("bluetooth-snapshot-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: outputURL) }
            do {
                try Data().write(to: outputURL, options: .atomic)
                let output = try FileHandle(forWritingTo: outputURL)
                defer { try? output.close() }
                let process = Process()
                process.executableURL = executableURL
                process.arguments = arguments
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                try process.run()
                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning {
                    if Task.isCancelled || Date() >= deadline {
                        // Kill only the child we own; a hung helper must not block refreshes.
                        kill(process.processIdentifier, SIGKILL)
                        while process.isRunning {
                            try? await Task.sleep(for: .milliseconds(10))
                        }
                        return nil
                    }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                guard process.terminationStatus == 0 else { return nil }
                return try Data(contentsOf: outputURL)
            } catch {
                return nil
            }
        }
        return await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
