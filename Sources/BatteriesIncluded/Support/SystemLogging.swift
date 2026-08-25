import OSLog

enum SystemLogging {
    private static let subsystem = "com.batteriesincluded.app"

    static let monitor = Logger(subsystem: subsystem, category: "monitor")
    static let systemBluetooth = Logger(subsystem: subsystem, category: "system-bluetooth")
    static let coreBluetooth = Logger(subsystem: subsystem, category: "core-bluetooth")
    static let logitechHID = Logger(subsystem: subsystem, category: "logitech-hid")
}
