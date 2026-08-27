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

final class IOKitHIDLifecycle: @unchecked Sendable {
    enum Phase: Equatable {
        case idle
        case opening
        case open
        case cancelling
        case cancelled
    }

    private let lock = NSLock()
    private var storedPhase: Phase = .idle

    var phase: Phase {
        lock.lock()
        defer { lock.unlock() }
        return storedPhase
    }

    func performOpen(_ setupAndActivation: () throws -> Void) throws {
        lock.lock()
        guard storedPhase == .idle else {
            lock.unlock()
            throw IOKitHIDDeviceError.alreadyOpen
        }
        storedPhase = .opening

        do {
            try setupAndActivation()
            storedPhase = .open
            lock.unlock()
        } catch {
            storedPhase = .cancelled
            lock.unlock()
            throw error
        }
    }

    func synchronizeWithOpening() {
        lock.lock()
        lock.unlock()
    }

    func withOpen<T>(_ body: () -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard storedPhase == .open else { return nil }
        return body()
    }

    func beginCancellation() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard storedPhase == .open else { return false }
        storedPhase = .cancelling
        return true
    }

    func finishCancellation() {
        lock.lock()
        if storedPhase == .cancelling {
            storedPhase = .cancelled
        }
        lock.unlock()
    }
}

enum IOKitHIDCancellationReason {
    case explicitClose
    case physicalRemoval
}

final class IOKitHIDCancellationCoordinator: @unchecked Sendable {
    private let lifecycle: IOKitHIDLifecycle
    private let notifyTransport: @Sendable () -> Void
    private let notifyOwnerRemoval: @Sendable () -> Void
    private let cancelNativeDevice: @Sendable () -> Void

    init(
        lifecycle: IOKitHIDLifecycle,
        notifyTransport: @escaping @Sendable () -> Void,
        notifyOwnerRemoval: @escaping @Sendable () -> Void,
        cancelNativeDevice: @escaping @Sendable () -> Void
    ) {
        self.lifecycle = lifecycle
        self.notifyTransport = notifyTransport
        self.notifyOwnerRemoval = notifyOwnerRemoval
        self.cancelNativeDevice = cancelNativeDevice
    }

    @discardableResult
    func cancel(reason: IOKitHIDCancellationReason) -> Bool {
        guard lifecycle.beginCancellation() else { return false }

        notifyTransport()
        if reason == .physicalRemoval {
            notifyOwnerRemoval()
        }
        cancelNativeDevice()
        return true
    }
}

enum IOKitHIDRetainedContext {
    static func retain<T: AnyObject>(_ value: T) -> UnsafeMutableRawPointer {
        Unmanaged.passRetained(value).toOpaque()
    }

    static func borrow<T: AnyObject>(
        _ context: UnsafeMutableRawPointer,
        as type: T.Type
    ) -> T {
        Unmanaged<T>.fromOpaque(context).takeUnretainedValue()
    }

    static func consume<T: AnyObject>(
        _ context: UnsafeMutableRawPointer,
        as type: T.Type
    ) -> T {
        Unmanaged<T>.fromOpaque(context).takeRetainedValue()
    }
}

final class IOKitHIDDevice: HIDPPDeviceIO, @unchecked Sendable {
    private final class CallbackState: @unchecked Sendable {
        let device: IOHIDDevice
        let buffer: UnsafeMutablePointer<UInt8>
        let bufferSize: Int

        private let lifecycle: IOKitHIDLifecycle
        private weak var transport: HIDPPTransport?
        private let cancellation: IOKitHIDCancellationCoordinator

        init(
            device: IOHIDDevice,
            bufferSize: Int,
            transport: HIDPPTransport,
            lifecycle: IOKitHIDLifecycle,
            onRemoval: @escaping @Sendable () -> Void
        ) {
            self.device = device
            self.bufferSize = bufferSize
            self.buffer = .allocate(capacity: bufferSize)
            self.buffer.initialize(repeating: 0, count: bufferSize)
            self.lifecycle = lifecycle
            self.transport = transport
            self.cancellation = IOKitHIDCancellationCoordinator(
                lifecycle: lifecycle,
                notifyTransport: { [weak transport] in
                    guard let transport else { return }
                    Task { await transport.interfaceRemoved() }
                },
                notifyOwnerRemoval: onRemoval,
                cancelNativeDevice: {
                    IOHIDDeviceCancel(device)
                }
            )
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
            let activeTransport: HIDPPTransport? = lifecycle.withOpen {
                self.transport
            } ?? nil

            guard let activeTransport else { return }
            Task { await activeTransport.receive(bytes) }
        }

        func cancel(reason: IOKitHIDCancellationReason) {
            cancellation.cancel(reason: reason)
        }

        func finishCancellation() {
            lifecycle.finishCancellation()
        }
    }

    private let device: IOHIDDevice
    private let maxInputReportSize: Int
    private let callbackQueue = DispatchQueue(label: "com.batteriesincluded.logitech-hid.callback")
    private let lifecycle = IOKitHIDLifecycle()
    private weak var callbackState: CallbackState?

    init(device: IOHIDDevice, maxInputReportSize: Int) {
        self.device = device
        self.maxInputReportSize = maxInputReportSize
    }

    deinit {
        close()
    }

    func open(
        transport: HIDPPTransport,
        onRemoval: @escaping @Sendable () -> Void
    ) throws {
        try lifecycle.performOpen {
            let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            guard result == kIOReturnSuccess else {
                throw IOKitHIDDeviceError.openFailed(result)
            }

            let state = CallbackState(
                device: device,
                bufferSize: maxInputReportSize,
                transport: transport,
                lifecycle: lifecycle,
                onRemoval: onRemoval
            )
            callbackState = state
            let context = IOKitHIDRetainedContext.retain(state)

            IOHIDDeviceSetDispatchQueue(device, callbackQueue)
            IOHIDDeviceRegisterInputReportCallback(
                device,
                state.buffer,
                state.bufferSize,
                { context, result, _, _, _, report, reportLength in
                    guard result == kIOReturnSuccess, let context else { return }
                    IOKitHIDRetainedContext
                        .borrow(context, as: CallbackState.self)
                        .receive(report: report, length: reportLength)
                },
                context
            )
            IOHIDDeviceRegisterRemovalCallback(
                device,
                { context, _, _ in
                    guard let context else { return }
                    IOKitHIDRetainedContext
                        .borrow(context, as: CallbackState.self)
                        .cancel(reason: .physicalRemoval)
                },
                context
            )
            IOHIDDeviceSetCancelHandler(device) {
                let state = IOKitHIDRetainedContext.consume(
                    context,
                    as: CallbackState.self
                )
                _ = IOHIDDeviceClose(state.device, IOOptionBits(kIOHIDOptionsTypeNone))
                state.finishCancellation()
            }
            IOHIDDeviceActivate(device)
        }
    }

    func write(_ report: [UInt8]) throws {
        guard let reportID = report.first else {
            throw HIDPPError.invalidPacket
        }

        let result = lifecycle.withOpen {
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
        lifecycle.synchronizeWithOpening()
        callbackState?.cancel(reason: .explicitClose)
    }
}
