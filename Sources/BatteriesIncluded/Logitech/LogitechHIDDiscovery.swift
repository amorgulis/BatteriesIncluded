import Foundation
import IOKit
import IOKit.hid

struct LogitechHIDInterfaceDescriptor: Sendable, Equatable, Identifiable {
    let id: String
    let physicalKey: String
    let vendorID: Int
    let productID: Int
    let serialNumber: String?
    let locationID: Int?
    let transport: String?
    let productName: String?
    let primaryUsagePage: Int?
    let primaryUsage: Int?
    let inputReportIDs: Set<UInt8>
    let outputReportIDs: Set<UInt8>

    func identity(deviceIndex: UInt8) -> HIDPPFallbackIdentity {
        let isReceiverChild = deviceIndex != 0xFF
        let directStableID = directStableID

        return HIDPPFallbackIdentity(
            stableID: isReceiverChild ? "\(directStableID):device:\(deviceIndex)" : directStableID,
            name: isReceiverChild ? nil : productName?.nilIfEmpty,
            category: category,
            isReceiverChild: isReceiverChild
        )
    }

    fileprivate var bidirectionalHIDPPReportIDs: Set<UInt8> {
        inputReportIDs.intersection(outputReportIDs).intersection([0x10, 0x11])
    }

    private var directStableID: String {
        let transportComponent = transport?.nilIfEmpty?.lowercased() ?? "unknown"
        let prefix = String(
            format: "logitech-hid:%@:%04x:%04x",
            transportComponent,
            vendorID,
            productID
        )

        if let serialNumber = serialNumber?.nilIfEmpty {
            return "\(prefix):serial:\(serialNumber)"
        }
        if let locationID {
            return String(format: "%@:location:%08x", prefix, locationID)
        }
        return "\(prefix):physical:\(physicalKey)"
    }

    private var category: DeviceCategory? {
        guard primaryUsagePage == 0x01 else { return nil }
        return switch primaryUsage {
        case 0x02: .mouse
        case 0x06: .keyboard
        default: nil
        }
    }
}

enum LogitechHIDDiscoveryPolicy {
    private static let logitechVendorID = 0x046D

    static func select(
        _ candidates: [LogitechHIDInterfaceDescriptor]
    ) -> [LogitechHIDInterfaceDescriptor] {
        var selectedByPhysicalKey: [String: LogitechHIDInterfaceDescriptor] = [:]

        for candidate in candidates where candidate.vendorID == logitechVendorID {
            guard !candidate.bidirectionalHIDPPReportIDs.isEmpty else { continue }

            if let selected = selectedByPhysicalKey[candidate.physicalKey] {
                if preferred(candidate, over: selected) {
                    selectedByPhysicalKey[candidate.physicalKey] = candidate
                }
            } else {
                selectedByPhysicalKey[candidate.physicalKey] = candidate
            }
        }

        return selectedByPhysicalKey.values.sorted { $0.id < $1.id }
    }

    private static func preferred(
        _ candidate: LogitechHIDInterfaceDescriptor,
        over selected: LogitechHIDInterfaceDescriptor
    ) -> Bool {
        let candidateScore = reportCapabilityScore(candidate)
        let selectedScore = reportCapabilityScore(selected)
        if candidateScore != selectedScore {
            return candidateScore > selectedScore
        }
        return candidate.id < selected.id
    }

    private static func reportCapabilityScore(_ descriptor: LogitechHIDInterfaceDescriptor) -> Int {
        let reportIDs = descriptor.bidirectionalHIDPPReportIDs
        return (reportIDs.contains(0x11) ? 2 : 0) + (reportIDs.contains(0x10) ? 1 : 0)
    }
}

struct LogitechHIDInterface: Sendable {
    let descriptor: LogitechHIDInterfaceDescriptor
    let transport: HIDPPTransport
}

protocol LogitechHIDDiscovering: Sendable {
    func interfaces() async -> [LogitechHIDInterface]
}

actor LogitechHIDDiscovery: LogitechHIDDiscovering {
    private struct OpenedInterface {
        let device: IOKitHIDDevice
        let interface: LogitechHIDInterface
    }

    private let manager: IOHIDManager
    private let managerOpenResult: IOReturn
    private var openedByID: [String: OpenedInterface] = [:]

    init() {
        let manager = IOHIDManagerCreate(
            kCFAllocatorDefault,
            IOOptionBits(kIOHIDOptionsTypeNone)
        )
        self.manager = manager
        IOHIDManagerSetDeviceMatching(
            manager,
            [kIOHIDVendorIDKey: 0x046D] as CFDictionary
        )
        self.managerOpenResult = IOHIDManagerOpen(
            manager,
            IOOptionBits(kIOHIDOptionsTypeNone)
        )

        if managerOpenResult != kIOReturnSuccess {
            SystemLogging.logitechHID.error(
                "Unable to open Logitech HID manager (IOKit result \(self.managerOpenResult, privacy: .public))"
            )
        }
    }

    deinit {
        for opened in openedByID.values {
            opened.device.close()
        }
        _ = IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func interfaces() async -> [LogitechHIDInterface] {
        guard managerOpenResult == kIOReturnSuccess else { return [] }

        let describedDevices = currentDevices().compactMap { device in
            Self.descriptor(for: device).map { ($0, device) }
        }
        let candidates = describedDevices.map(\.0)
        let selected = LogitechHIDDiscoveryPolicy.select(candidates)
        let devicesByID = Dictionary(
            uniqueKeysWithValues: describedDevices.map { ($0.0.id, $0.1) }
        )
        let selectedIDs = Set(selected.map(\.id))

        let removedIDs = openedByID.keys.filter { !selectedIDs.contains($0) }
        for id in removedIDs {
            openedByID.removeValue(forKey: id)?.device.close()
        }

        var interfaces: [LogitechHIDInterface] = []
        for descriptor in selected {
            if let opened = openedByID[descriptor.id] {
                interfaces.append(opened.interface)
                continue
            }

            guard let device = devicesByID[descriptor.id],
                  let maxInputReportSize = Self.integerProperty(
                      kIOHIDMaxInputReportSizeKey,
                      on: device
                  ),
                  maxInputReportSize > 0 else {
                SystemLogging.logitechHID.error(
                    "Skipping selected Logitech HID interface with no input-report buffer size"
                )
                continue
            }

            let io = IOKitHIDDevice(
                device: device,
                maxInputReportSize: maxInputReportSize
            )
            let transport = HIDPPTransport(io: io)
            do {
                try io.open(transport: transport)
            } catch {
                SystemLogging.logitechHID.error(
                    "Unable to open selected Logitech HID interface: \(String(describing: error), privacy: .public)"
                )
                continue
            }

            let interface = LogitechHIDInterface(
                descriptor: descriptor,
                transport: transport
            )
            openedByID[descriptor.id] = OpenedInterface(device: io, interface: interface)
            interfaces.append(interface)
        }

        return interfaces
    }

    private func currentDevices() -> [IOHIDDevice] {
        guard let deviceSet = IOHIDManagerCopyDevices(manager) else { return [] }
        return (deviceSet as NSSet).allObjects.map { $0 as! IOHIDDevice }
    }

    private static func descriptor(for device: IOHIDDevice) -> LogitechHIDInterfaceDescriptor? {
        guard let vendorID = integerProperty(kIOHIDVendorIDKey, on: device),
              let productID = integerProperty(kIOHIDProductIDKey, on: device) else {
            return nil
        }

        var inputReportIDs: Set<UInt8> = []
        var outputReportIDs: Set<UInt8> = []
        if let copiedElements = IOHIDDeviceCopyMatchingElements(
            device,
            nil,
            IOOptionBits(kIOHIDOptionsTypeNone)
        ) {
            let elements = (copiedElements as NSArray).map { $0 as! IOHIDElement }
            for element in elements {
                let reportID = IOHIDElementGetReportID(element)
                guard reportID <= UInt8.max else { continue }

                switch IOHIDElementGetType(element) {
                case kIOHIDElementTypeInput_Misc,
                     kIOHIDElementTypeInput_Button,
                     kIOHIDElementTypeInput_Axis,
                     kIOHIDElementTypeInput_ScanCodes:
                    inputReportIDs.insert(UInt8(reportID))
                case kIOHIDElementTypeOutput:
                    outputReportIDs.insert(UInt8(reportID))
                default:
                    break
                }
            }
        }

        let serialNumber = stringProperty(kIOHIDSerialNumberKey, on: device)?.nilIfEmpty
        let locationID = integerProperty(kIOHIDLocationIDKey, on: device)
        let transport = stringProperty(kIOHIDTransportKey, on: device)?.nilIfEmpty
        let registryID = registryEntryID(for: device)
        let fallbackLocation = locationID.map(String.init) ?? "registry-\(registryID)"
        let physicalKey = [
            transport?.lowercased() ?? "unknown",
            String(format: "%04x", vendorID),
            String(format: "%04x", productID),
            serialNumber ?? "no-serial",
            fallbackLocation
        ].joined(separator: "|")

        return LogitechHIDInterfaceDescriptor(
            id: "iohid:\(registryID)",
            physicalKey: physicalKey,
            vendorID: vendorID,
            productID: productID,
            serialNumber: serialNumber,
            locationID: locationID,
            transport: transport,
            productName: stringProperty(kIOHIDProductKey, on: device),
            primaryUsagePage: integerProperty(kIOHIDPrimaryUsagePageKey, on: device),
            primaryUsage: integerProperty(kIOHIDPrimaryUsageKey, on: device),
            inputReportIDs: inputReportIDs,
            outputReportIDs: outputReportIDs
        )
    }

    private static func registryEntryID(for device: IOHIDDevice) -> UInt64 {
        var registryID: UInt64 = 0
        let service = IOHIDDeviceGetService(device)
        guard service != 0,
              IORegistryEntryGetRegistryEntryID(service, &registryID) == kIOReturnSuccess else {
            return UInt64(bitPattern: Int64(CFHash(device)))
        }
        return registryID
    }

    private static func integerProperty(_ key: String, on device: IOHIDDevice) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }

    private static func stringProperty(_ key: String, on device: IOHIDDevice) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
