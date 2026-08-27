import XCTest
@testable import BatteriesIncluded

final class IOKitHIDDeviceLifecycleTests: XCTestCase {
    func testManagerUsesIndependentDevicesForCreateOpenAndClose() {
        XCTAssertEqual(LogitechHIDNativeConfiguration.managerCreateOptions, 0x08)
        XCTAssertEqual(LogitechHIDNativeConfiguration.managerOpenOptions, 0x08)
        XCTAssertEqual(LogitechHIDNativeConfiguration.managerCloseOptions, 0x08)
    }

    func testPhysicalRemovalCancelsOnceAndNotifiesTransportAndOwner() throws {
        let lifecycle = IOKitHIDLifecycle()
        try lifecycle.performOpen {}
        let events = LockedEvents()
        let cancellation = IOKitHIDCancellationCoordinator(
            lifecycle: lifecycle,
            notifyTransport: { events.append("transport") },
            notifyOwnerRemoval: { events.append("owner") },
            cancelNativeDevice: { events.append("native-cancel") }
        )

        XCTAssertTrue(cancellation.cancel(reason: .physicalRemoval))
        XCTAssertFalse(cancellation.cancel(reason: .explicitClose))
        XCTAssertEqual(events.values, ["transport", "owner", "native-cancel"])
    }

    func testCloseWaitsUntilOpenSetupAndActivationCriticalSectionFinishes() throws {
        let lifecycle = IOKitHIDLifecycle()
        let setupEntered = DispatchSemaphore(value: 0)
        let allowActivation = DispatchSemaphore(value: 0)
        let openFinished = DispatchSemaphore(value: 0)
        let cancellationAttempted = DispatchSemaphore(value: 0)
        let cancellationFinished = DispatchSemaphore(value: 0)
        let cancellationResult = LockedBoolean()

        DispatchQueue.global().async {
            try? lifecycle.performOpen {
                setupEntered.signal()
                _ = allowActivation.wait(timeout: .now() + 2)
            }
            openFinished.signal()
        }

        XCTAssertEqual(setupEntered.wait(timeout: .now() + 2), .success)
        DispatchQueue.global().async {
            cancellationAttempted.signal()
            cancellationResult.value = lifecycle.beginCancellation()
            cancellationFinished.signal()
        }

        XCTAssertEqual(cancellationAttempted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(cancellationFinished.wait(timeout: .now() + 0.05), .timedOut)

        allowActivation.signal()
        XCTAssertEqual(openFinished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(cancellationFinished.wait(timeout: .now() + 2), .success)
        XCTAssertTrue(cancellationResult.value)
        XCTAssertEqual(lifecycle.phase, .cancelling)

        lifecycle.finishCancellation()
        XCTAssertEqual(lifecycle.phase, .cancelled)
    }

    func testRetainedCallbackContextLivesUntilCancelHandlerConsumesIt() {
        final class Token {}

        var token: Token? = Token()
        weak let weakToken = token
        let context = IOKitHIDRetainedContext.retain(token!)
        token = nil

        XCTAssertNotNil(weakToken)
        XCTAssertTrue(
            IOKitHIDRetainedContext.borrow(context, as: Token.self) === weakToken
        )

        var consumed: Token? = IOKitHIDRetainedContext.consume(context, as: Token.self)
        XCTAssertNotNil(consumed)
        consumed = nil
        XCTAssertNil(weakToken)
    }
}

private final class LockedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ value: String) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }
}

private final class LockedBoolean: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
