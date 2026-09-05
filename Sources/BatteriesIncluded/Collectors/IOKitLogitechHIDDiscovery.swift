import Foundation
import IOKit
import IOKit.hid

struct IOKitLogitechHIDDiscovery: LogitechHIDDiscovering {
    func discover() async -> [LogitechHIDEndpoint] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: 0x046D] as CFDictionary)
        let managerOpenResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        let copiedDevices = IOHIDManagerCopyDevices(manager)
        guard Self.canUseEnumeratedDevices(
            managerOpenResult: managerOpenResult,
            deviceSetAvailable: copiedDevices != nil
        ), let deviceSet = copiedDevices else { return [] }

        var devicesByPhysicalID: [String: IOHIDDevice] = [:]
        for value in (deviceSet as NSSet) {
            guard let device = value as! IOHIDDevice?, supportsHIDPP(device) else { continue }
            let physicalID = physicalID(for: device)
            if let existing = devicesByPhysicalID[physicalID] {
                let existingSize = intProperty(kIOHIDMaxOutputReportSizeKey, on: existing) ?? 0
                let candidateSize = intProperty(kIOHIDMaxOutputReportSizeKey, on: device) ?? 0
                if candidateSize <= existingSize { continue }
            }
            devicesByPhysicalID[physicalID] = device
        }

        return devicesByPhysicalID.sorted { $0.key < $1.key }.map { physicalID, device in
            let name = stringProperty(kIOHIDProductKey, on: device) ?? "Logitech Device"
            let receiver = name.localizedCaseInsensitiveContains("receiver")
            return LogitechHIDEndpoint(
                id: "iohid:\(physicalID)",
                name: name,
                category: category(for: name),
                deviceIndices: receiver ? Array(1...6) : [0xFF],
                transport: IOKitHIDPPTransport(device: device, manager: manager)
            )
        }
    }

    nonisolated static func canUseEnumeratedDevices(
        managerOpenResult: IOReturn,
        deviceSetAvailable: Bool
    ) -> Bool {
        // A composite receiver can make the manager-level open fail TCC while
        // its vendor-defined HID++ interface remains individually accessible.
        _ = managerOpenResult
        return deviceSetAvailable
    }

    private func supportsHIDPP(_ device: IOHIDDevice) -> Bool {
        let outputSize = intProperty(kIOHIDMaxOutputReportSizeKey, on: device) ?? 0
        let usagePage = intProperty(kIOHIDPrimaryUsagePageKey, on: device) ?? 0
        return outputSize >= 7 && usagePage >= 0xFF00
    }

    private func registryEntryID(for device: IOHIDDevice) -> UInt64 {
        var value: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &value)
        return value
    }

    private func physicalID(for device: IOHIDDevice) -> String {
        if let locationID = intProperty(kIOHIDLocationIDKey, on: device), locationID != 0 {
            return "location:\(locationID)"
        }
        if let uniqueID = IOHIDDeviceGetProperty(device, kIOHIDUniqueIDKey as CFString) {
            return "unique:\(String(describing: uniqueID))"
        }
        if let serial = stringProperty(kIOHIDSerialNumberKey, on: device), !serial.isEmpty {
            return "serial:\(serial)"
        }
        if let ancestorID = physicalTransportAncestorID(for: device) {
            return "ancestor:\(ancestorID)"
        }
        return "registry:\(registryEntryID(for: device))"
    }

    private func physicalTransportAncestorID(for device: IOHIDDevice) -> UInt64? {
        var current = IOHIDDeviceGetService(device)
        while current != 0 {
            var parent: io_registry_entry_t = 0
            guard IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent) == kIOReturnSuccess else {
                break
            }
            defer { IOObjectRelease(parent) }

            var className = [CChar](repeating: 0, count: 128)
            IOObjectGetClass(parent, &className)
            let name = String(cString: className).lowercased()
            let isPhysicalUSB = name.contains("usb") && name.contains("device")
            let isPhysicalBluetooth = name.contains("bluetooth") &&
                (name.contains("hid") || name.contains("device"))
            if isPhysicalUSB || isPhysicalBluetooth {
                var identifier: UInt64 = 0
                if IORegistryEntryGetRegistryEntryID(parent, &identifier) == kIOReturnSuccess {
                    return identifier
                }
            }
            current = parent
        }
        return nil
    }

    private func stringProperty(_ key: String, on device: IOHIDDevice) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    private func intProperty(_ key: String, on device: IOHIDDevice) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }

    private func category(for name: String) -> DeviceCategory {
        let lowered = name.lowercased()
        if lowered.contains("keyboard") || lowered.contains("keys") { return .keyboard }
        if lowered.contains("mouse") || lowered.contains("master") || lowered.contains("trackball") { return .mouse }
        if lowered.contains("trackpad") || lowered.contains("touchpad") { return .trackpad }
        if lowered.contains("headset") || lowered.contains("headphone") { return .headphones }
        if lowered.contains("gamepad") || lowered.contains("controller") { return .gameController }
        return .other
    }
}

private actor IOKitHIDPPTransport: HIDPPTransport {
    private let device: IOHIDDevice
    private let manager: IOHIDManager
    private let inputReports: HIDInputReportBuffer
    private let callbackQueue = DispatchQueue(label: "BatteriesIncluded.LogitechHID")

    init(device: IOHIDDevice, manager: IOHIDManager) {
        self.device = device
        self.manager = manager
        self.inputReports = HIDInputReportBuffer()
        let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard openResult == kIOReturnSuccess else {
            return
        }
        IOHIDDeviceSetDispatchQueue(device, callbackQueue)
        IOHIDDeviceRegisterInputReportCallback(
            device,
            inputReports.storage,
            inputReports.capacity,
            { context, result, _, _, reportID, report, reportLength in
                guard result == kIOReturnSuccess, let context else { return }
                Unmanaged<HIDInputReportBuffer>.fromOpaque(context)
                    .takeUnretainedValue()
                    .receive(reportID: UInt8(reportID), bytes: report, count: reportLength)
            },
            Unmanaged.passUnretained(inputReports).toOpaque()
        )
        IOHIDDeviceActivate(device)
    }

    deinit {
        IOHIDDeviceCancel(device)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func request(_ report: [UInt8]) async -> [UInt8]? {
        guard report.count >= 2 else { return nil }
        inputReports.discardBufferedReports()
        var output = report
        let outputCount = output.count
        let writeResult = output.withUnsafeMutableBytes { bytes in
            IOHIDDeviceSetReport(
                device, kIOHIDReportTypeOutput, CFIndex(report[0]),
                bytes.bindMemory(to: UInt8.self).baseAddress!, outputCount
            )
        }
        guard writeResult == kIOReturnSuccess else { return nil }

        for _ in 0..<200 {
            if let response = inputReports.popFirst(where: {
                HIDPPProtocol.isReply($0, to: report) || HIDPPProtocol.isErrorReply($0, to: report)
            }) {
                if HIDPPProtocol.isErrorReply(response, to: report) { return nil }
                return response
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return nil
    }

    func prepare(deviceIndex: UInt8) async {
        guard deviceIndex != 0xFF else { return }
        if await request(HIDPPProtocol.pingRequest(deviceIndex: deviceIndex, marker: 0xA5)) == nil {
            // Sleeping keyboards can take longer than a normal request timeout
            // to answer their first packet after radio wake-up.
            try? await Task.sleep(for: .milliseconds(350))
        }
    }

}

private final class HIDInputReportBuffer: @unchecked Sendable {
    let capacity = 64
    let storage: UnsafeMutablePointer<UInt8>
    private let lock = NSLock()
    private var reports: [[UInt8]] = []

    init() {
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    func receive(reportID: UInt8, bytes: UnsafeMutablePointer<UInt8>, count: Int) {
        guard count > 0 else { return }
        let received = Array(UnsafeBufferPointer(start: bytes, count: count))
        let normalized = received.first == reportID ? received : [reportID] + received
        lock.lock()
        reports.append(normalized)
        lock.unlock()
    }

    func discardBufferedReports() {
        lock.lock()
        reports.removeAll()
        lock.unlock()
    }

    func popFirst(where predicate: ([UInt8]) -> Bool) -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = reports.firstIndex(where: predicate) else { return nil }
        return reports.remove(at: index)
    }
}
