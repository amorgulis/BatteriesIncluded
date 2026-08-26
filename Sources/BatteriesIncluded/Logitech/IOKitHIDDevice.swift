import Dispatch
import Foundation
import IOKit.hid

enum IOKitHIDDeviceError: Error, CustomStringConvertible {
    case alreadyOpen
    case openFailed(IOReturn)
    case writeFailed(IOReturn)

    var description: String {
        switch self {
        case .alreadyOpen:
            "interface already open"
        case .openFailed(let result):
            "open failed (IOKit result \(result))"
        case .writeFailed(let result):
            "write failed (IOKit result \(result))"
        }
    }
}

final class IOKitHIDDevice: HIDPPDeviceIO, @unchecked Sendable {
    private final class CallbackState: @unchecked Sendable {
        let device: IOHIDDevice
        let buffer: UnsafeMutablePointer<UInt8>
        let bufferSize: Int

        private let lock = NSLock()
        private weak var transport: HIDPPTransport?
        private var isActive = true

        init(device: IOHIDDevice, bufferSize: Int, transport: HIDPPTransport) {
            self.device = device
            self.bufferSize = bufferSize
            self.buffer = .allocate(capacity: bufferSize)
            self.buffer.initialize(repeating: 0, count: bufferSize)
            self.transport = transport
        }

        deinit {
            buffer.deinitialize(count: bufferSize)
            buffer.deallocate()
        }

        func receive(report: UnsafeMutablePointer<UInt8>, length: Int) {
            guard length > 0, length <= bufferSize else { return }

            // IOHIDReportCallback's buffer is the complete raw report. Its
            // reportID argument is metadata, so prepending it would duplicate
            // the leading HID++ report-ID byte.
            let bytes = Array(UnsafeBufferPointer(start: report, count: length))
            lock.lock()
            let transport = isActive ? transport : nil
            lock.unlock()

            guard let transport else { return }
            Task { await transport.receive(bytes) }
        }

        func remove() {
            lock.lock()
            guard isActive else {
                lock.unlock()
                return
            }
            isActive = false
            let transport = transport
            lock.unlock()

            guard let transport else { return }
            Task { await transport.interfaceRemoved() }
        }

        func withActiveDevice<T>(_ body: (IOHIDDevice) -> T) -> T? {
            lock.lock()
            defer { lock.unlock() }
            guard isActive else { return nil }
            return body(device)
        }
    }

    private let device: IOHIDDevice
    private let maxInputReportSize: Int
    private let callbackQueue = DispatchQueue(label: "com.batteriesincluded.logitech-hid.callback")
    private let lock = NSLock()
    private var callbackState: CallbackState?
    private var isClosing = false

    init(device: IOHIDDevice, maxInputReportSize: Int) {
        self.device = device
        self.maxInputReportSize = maxInputReportSize
    }

    deinit {
        close()
    }

    func open(transport: HIDPPTransport) throws {
        lock.lock()
        guard callbackState == nil, !isClosing else {
            lock.unlock()
            throw IOKitHIDDeviceError.alreadyOpen
        }

        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            lock.unlock()
            throw IOKitHIDDeviceError.openFailed(result)
        }

        let state = CallbackState(
            device: device,
            bufferSize: maxInputReportSize,
            transport: transport
        )
        callbackState = state
        let context = Unmanaged.passRetained(state).toOpaque()
        lock.unlock()

        IOHIDDeviceSetDispatchQueue(device, callbackQueue)
        IOHIDDeviceRegisterInputReportCallback(
            device,
            state.buffer,
            state.bufferSize,
            { context, result, _, _, _, report, reportLength in
                guard result == kIOReturnSuccess, let context else { return }
                Unmanaged<CallbackState>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                    .receive(report: report, length: reportLength)
            },
            context
        )
        IOHIDDeviceRegisterRemovalCallback(
            device,
            { context, _, _ in
                guard let context else { return }
                Unmanaged<CallbackState>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                    .remove()
            },
            context
        )
        IOHIDDeviceSetCancelHandler(device) {
            let state = Unmanaged<CallbackState>.fromOpaque(context).takeRetainedValue()
            _ = IOHIDDeviceClose(state.device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        IOHIDDeviceActivate(device)
    }

    func write(_ report: [UInt8]) throws {
        guard let reportID = report.first else {
            throw HIDPPError.invalidPacket
        }

        lock.lock()
        let state = isClosing ? nil : callbackState
        lock.unlock()
        guard let state else {
            throw HIDPPError.disconnected
        }

        let result = state.withActiveDevice { device in
            report.withUnsafeBufferPointer { buffer in
                IOHIDDeviceSetReport(
                    device,
                    kIOHIDReportTypeOutput,
                    Int(reportID),
                    buffer.baseAddress!,
                    buffer.count
                )
            }
        }
        guard let result else {
            throw HIDPPError.disconnected
        }
        guard result == kIOReturnSuccess else {
            throw IOKitHIDDeviceError.writeFailed(result)
        }
    }

    func close() {
        lock.lock()
        guard !isClosing, let state = callbackState else {
            lock.unlock()
            return
        }
        isClosing = true
        lock.unlock()

        state.remove()
        IOHIDDeviceCancel(device)
    }
}
