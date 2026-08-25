import Foundation
import IOKit
import IOKit.hid

struct HIDDeviceDescriptor {
    let path: String
    let productID: UInt16
    let interfaceNumber: Int32
    let productName: String
    let registryEntryID: UInt64
}

final class HIDDeviceHandle: HIDPPTransport {
    private let context: HIDReadContext
    private let readThread: Thread

    init(device: IOHIDDevice) {
        let context = HIDReadContext(device: device)
        self.context = context
        readThread = Thread {
            context.run()
        }
        readThread.name = "BatteriesIncluded-HID-Read"
        readThread.start()
        context.waitUntilReady()
    }

    deinit {
        context.stop()
        readThread.cancel()
        context.waitUntilFinished()
        context.closeDevice()
    }

    func read(maxLength: Int, timeoutMilliseconds: Int32) -> [UInt8]? {
        if let report = context.reports.dequeue() { return Array(report.prefix(maxLength)) }
        let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1_000)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
            if let report = context.reports.dequeue() {
                return Array(report.prefix(maxLength))
            }
        }
        return nil
    }

    func write(_ data: [UInt8]) -> Int32 {
        guard !data.isEmpty else { return -1 }
        let reportID = CFIndex(data[0])
        let result = data.withUnsafeBufferPointer { buffer in
            IOHIDDeviceSetReport(
                context.device, kIOHIDReportTypeOutput, reportID,
                buffer.baseAddress!, buffer.count
            )
        }
        return result == kIOReturnSuccess ? Int32(data.count) : -1
    }
}

private final class HIDReadContext {
    let device: IOHIDDevice
    let reports = HIDReportQueue()
    private let inputBufferSize = 64
    private let inputBuffer: UnsafeMutablePointer<UInt8>
    private let ready = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private var stopping = false
    private var deviceClosed = false

    init(device: IOHIDDevice) {
        self.device = device
        inputBuffer = .allocate(capacity: inputBufferSize)
        inputBuffer.initialize(repeating: 0, count: inputBufferSize)
    }

    deinit {
        inputBuffer.deallocate()
    }

    func run() {
        guard let currentRunLoop = CFRunLoopGetCurrent() else {
            ready.signal()
            finished.signal()
            return
        }
        lock.lock()
        runLoop = currentRunLoop
        lock.unlock()
        IOHIDDeviceRegisterInputReportCallback(
            device, inputBuffer, inputBufferSize, hidInputReportCallback,
            Unmanaged.passUnretained(reports).toOpaque()
        )
        IOHIDDeviceScheduleWithRunLoop(
            device, currentRunLoop, CFRunLoopMode.defaultMode!.rawValue
        )
        ready.signal()

        while !shouldStop {
            let result = CFRunLoopRunInMode(CFRunLoopMode.defaultMode, 1, true)
            if result == .finished || result == .stopped { break }
        }

        IOHIDDeviceUnscheduleFromRunLoop(
            device, currentRunLoop, CFRunLoopMode.defaultMode!.rawValue
        )
        IOHIDDeviceRegisterInputReportCallback(
            device, inputBuffer, inputBufferSize, nil, nil
        )
        finished.signal()
    }

    func waitUntilReady() {
        ready.wait()
    }

    func stop() {
        lock.lock()
        stopping = true
        let runLoop = runLoop
        lock.unlock()
        if let runLoop { CFRunLoopStop(runLoop) }
    }

    func waitUntilFinished() {
        finished.wait()
    }

    func closeDevice() {
        lock.lock()
        guard !deviceClosed else {
            lock.unlock()
            return
        }
        deviceClosed = true
        lock.unlock()
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    private var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopping
    }
}

private final class HIDReportQueue {
    private var queue: [[UInt8]] = []
    private let lock = NSLock()

    func enqueue(_ report: [UInt8]) {
        lock.lock()
        queue.append(report)
        lock.unlock()
    }

    func dequeue() -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        return queue.isEmpty ? nil : queue.removeFirst()
    }
}

private func hidInputReportCallback(
    context: UnsafeMutableRawPointer?, result: IOReturn,
    sender: UnsafeMutableRawPointer?, type: IOHIDReportType,
    reportID: UInt32, report: UnsafeMutablePointer<UInt8>, reportLength: CFIndex
) {
    guard let context, result == kIOReturnSuccess else { return }
    let bytes = Array(UnsafeBufferPointer(start: report, count: reportLength))
    Unmanaged<HIDReportQueue>.fromOpaque(context).takeUnretainedValue().enqueue(bytes)
}

final class HIDManager {
    private let manager: IOHIDManager

    init?() {
        manager = IOHIDManagerCreate(
            kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone)
        )
        IOHIDManagerSetDeviceMatching(manager, nil)
        IOHIDManagerScheduleWithRunLoop(
            manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode!.rawValue
        )
        guard IOHIDManagerOpen(
            manager, IOOptionBits(kIOHIDOptionsTypeNone)
        ) == kIOReturnSuccess else { return nil }
    }

    deinit {
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func enumerate(vendorID: UInt16) -> [HIDDeviceDescriptor] {
        IOHIDManagerSetDeviceMatching(
            manager, [kIOHIDVendorIDKey as String: Int(vendorID)] as CFDictionary
        )
        defer { IOHIDManagerSetDeviceMatching(manager, nil) }
        guard let deviceSet = IOHIDManagerCopyDevices(manager) else { return [] }

        return (deviceSet as! Set<IOHIDDevice>).compactMap { device in
            let vendor = property(device, kIOHIDVendorIDKey) as? Int ?? 0
            guard vendor == Int(vendorID) else { return nil }
            let productID = property(device, kIOHIDProductIDKey) as? Int ?? 0
            let productName = property(device, kIOHIDProductKey) as? String ?? "Logitech Device"
            let locationID = property(device, kIOHIDLocationIDKey) as? Int ?? 0
            let usagePage = property(device, kIOHIDPrimaryUsagePageKey) as? Int ?? 0
            let usage = property(device, kIOHIDPrimaryUsageKey) as? Int ?? 0
            let interfaceNumber: Int32 = usagePage >= 0xFF00 ? (usage == 1 ? 2 : 1) : -1
            let path = String(
                format: "IOHIDDevice_%08X_%04X_%04X", locationID, usagePage, usage
            )
            var entryID: UInt64 = 0
            let service = IOHIDDeviceGetService(device)
            if service != MACH_PORT_NULL {
                IORegistryEntryGetRegistryEntryID(service, &entryID)
            }
            return HIDDeviceDescriptor(
                path: path, productID: UInt16(productID),
                interfaceNumber: interfaceNumber, productName: productName,
                registryEntryID: entryID
            )
        }
    }

    func open(_ descriptor: HIDDeviceDescriptor) -> HIDDeviceHandle? {
        guard descriptor.registryEntryID != 0 else { return nil }
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IORegistryEntryIDMatching(descriptor.registryEntryID)
        )
        guard service != MACH_PORT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, service),
              IOHIDDeviceOpen(
                device, IOOptionBits(kIOHIDOptionsTypeNone)
              ) == kIOReturnSuccess else { return nil }
        return HIDDeviceHandle(device: device)
    }

    private func property(_ device: IOHIDDevice, _ key: String) -> Any? {
        IOHIDDeviceGetProperty(device, key as CFString)
    }
}
