import XCTest
@preconcurrency import CoreBluetooth
@testable import BatteriesIncluded

final class CoreBluetoothCollectorTests: XCTestCase {
    func testMapsStandardBatteryLevelCharacteristic() {
        let reading = BLEDeviceReading(
            identifier: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "Heart Rate Strap",
            isConnected: true,
            batteryLevel: 72
        )

        let result = CoreBluetoothCollector.map(reading, now: .distantPast)

        XCTAssertEqual(result.single?.component, .whole)
        XCTAssertEqual(result.single?.percentage, 72)
        XCTAssertEqual(result.single?.source, .coreBluetooth)
        XCTAssertEqual(result.single?.sourceID, "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        XCTAssertEqual(result.single?.stableID, "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        XCTAssertEqual(result.single?.name, "Heart Rate Strap")
        XCTAssertEqual(result.single?.observedAt, .distantPast)
    }

    func testPreservesUnavailableAndInvalidLevelsForNormalizer() {
        let identifier = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

        let unavailable = CoreBluetoothCollector.map(
            BLEDeviceReading(
                identifier: identifier,
                name: "Unavailable Sensor",
                isConnected: true,
                batteryLevel: nil
            ),
            now: .distantPast
        )
        let invalid = CoreBluetoothCollector.map(
            BLEDeviceReading(
                identifier: identifier,
                name: "Invalid Sensor",
                isConnected: true,
                batteryLevel: 101
            ),
            now: .distantPast
        )

        XCTAssertNil(unavailable.single?.percentage)
        XCTAssertEqual(invalid.single?.percentage, 101)
    }

    func testDoesNotReportDisconnectedPeripheral() {
        let reading = BLEDeviceReading(
            identifier: UUID(),
            name: "Sensor",
            isConnected: false,
            batteryLevel: 50
        )

        XCTAssertTrue(CoreBluetoothCollector.map(reading, now: .distantPast).isEmpty)
    }

    func testManagerStateDistinguishesInitialUnknownFromReset() {
        XCTAssertEqual(
            BLEManagerStateMapper.disposition(authorization: .allowedAlways, state: .unknown),
            .waitForInitialState
        )
        XCTAssertEqual(
            BLEManagerStateMapper.disposition(authorization: .allowedAlways, state: .resetting),
            .finish(.unavailable)
        )
        XCTAssertEqual(
            BLEManagerStateMapper.disposition(authorization: .allowedAlways, state: .poweredOff),
            .finish(.poweredOff)
        )
        XCTAssertEqual(
            BLEManagerStateMapper.disposition(authorization: .denied, state: .poweredOn),
            .finish(.permissionDenied)
        )
    }

    func testResetInvalidatesAvailableRequestAndIgnoresLateCallback() async {
        let state = CoreBluetoothCollectionState(timeoutNanoseconds: 60_000_000_000)
        let bridge = TestBLECollectionBridge()
        var requests = bridge.requestIDs.makeAsyncIterator()
        let device = reading(identifier: UUID(), level: nil)

        let collection = Task { await state.collect(using: bridge) }
        let requestID = await requests.next()!
        await state.resolve(requestID: requestID, availability: .available, devices: [device])
        await state.managerDidBecomeUnavailable(.unavailable, generation: 1)
        await state.record(
            reading(identifier: device.identifier, level: 90),
            for: [requestID],
            generation: 0
        )
        let snapshot = await collection.value

        XCTAssertEqual(snapshot.availability, .unavailable)
        XCTAssertTrue(snapshot.observations.isEmpty)
        XCTAssertEqual(bridge.cancelCount(for: requestID), 1)

        let collectionAfterReset = Task { await state.collect(using: bridge) }
        let requestAfterReset = await requests.next()!
        await state.resolve(
            requestID: requestAfterReset,
            availability: .available,
            devices: [device]
        )
        await state.timeOut(requestAfterReset)
        let snapshotAfterReset = await collectionAfterReset.value
        XCTAssertNil(snapshotAfterReset.observations.single?.percentage)
    }

    func testTimeoutAndCallbackRaceResolvesExactlyOnce() async {
        let state = CoreBluetoothCollectionState(timeoutNanoseconds: 60_000_000_000)
        let bridge = TestBLECollectionBridge()
        var requests = bridge.requestIDs.makeAsyncIterator()
        let device = reading(identifier: UUID(), level: nil)

        let collection = Task { await state.collect(using: bridge) }
        let requestID = await requests.next()!
        await state.resolve(requestID: requestID, availability: .available, devices: [device])
        let callbackReading = reading(identifier: device.identifier, level: 75)

        async let timeout: Void = state.timeOut(requestID)
        async let callback: Void = state.record(callbackReading, for: [requestID])
        _ = await (timeout, callback)
        let snapshot = await collection.value

        XCTAssertEqual(snapshot.availability, .available)
        XCTAssertEqual(snapshot.observations.count, 1)
        XCTAssertEqual(bridge.cancelCount(for: requestID), 1)
    }

    func testCallbackBeforeResolutionCompletesWithCachedLevel() async {
        let state = CoreBluetoothCollectionState(timeoutNanoseconds: 60_000_000_000)
        let bridge = TestBLECollectionBridge()
        var requests = bridge.requestIDs.makeAsyncIterator()
        let device = reading(identifier: UUID(), level: nil)

        let collection = Task { await state.collect(using: bridge) }
        let requestID = await requests.next()!
        await state.record(reading(identifier: device.identifier, level: 64), for: [requestID])
        await state.resolve(requestID: requestID, availability: .available, devices: [device])
        let snapshot = await collection.value

        XCTAssertEqual(snapshot.observations.single?.percentage, 64)
        XCTAssertEqual(bridge.cancelCount(for: requestID), 1)
    }

    func testOverlappingRequestsCompleteIndependentlyFromOneCallback() async {
        let state = CoreBluetoothCollectionState(timeoutNanoseconds: 60_000_000_000)
        let bridge = TestBLECollectionBridge()
        var requests = bridge.requestIDs.makeAsyncIterator()
        let device = reading(identifier: UUID(), level: nil)

        let firstCollection = Task { await state.collect(using: bridge) }
        let secondCollection = Task { await state.collect(using: bridge) }
        let firstID = await requests.next()!
        let secondID = await requests.next()!
        XCTAssertNotEqual(firstID, secondID)

        await state.resolve(requestID: firstID, availability: .available, devices: [device])
        await state.resolve(requestID: secondID, availability: .available, devices: [device])
        await state.record(
            reading(identifier: device.identifier, level: 88),
            for: [firstID, secondID]
        )
        let first = await firstCollection.value
        let second = await secondCollection.value

        XCTAssertEqual(first.observations.single?.percentage, 88)
        XCTAssertEqual(second.observations.single?.percentage, 88)
        XCTAssertEqual(Set(bridge.cancelledRequestIDs), Set([firstID, secondID]))
    }

    func testPoweredOffAndPermissionDeniedFinishPendingRequests() async {
        let state = CoreBluetoothCollectionState(timeoutNanoseconds: 60_000_000_000)
        let bridge = TestBLECollectionBridge()
        var requests = bridge.requestIDs.makeAsyncIterator()

        let firstCollection = Task { await state.collect(using: bridge) }
        let secondCollection = Task { await state.collect(using: bridge) }
        _ = await requests.next()!
        _ = await requests.next()!
        await state.managerDidBecomeUnavailable(.poweredOff)

        let first = await firstCollection.value
        let second = await secondCollection.value
        XCTAssertEqual(first.availability, .poweredOff)
        XCTAssertEqual(second.availability, .poweredOff)

        let deniedCollection = Task { await state.collect(using: bridge) }
        let deniedID = await requests.next()!
        await state.resolve(requestID: deniedID, availability: .permissionDenied, devices: [])
        let denied = await deniedCollection.value
        XCTAssertEqual(denied.availability, .permissionDenied)
    }

    func testCollectionRequestsConnectedRetrievalWithoutConnection() async {
        let state = CoreBluetoothCollectionState(timeoutNanoseconds: 60_000_000_000)
        let bridge = TestBLECollectionBridge()
        var requests = bridge.requestIDs.makeAsyncIterator()

        let collection = Task { await state.collect(using: bridge) }
        let requestID = await requests.next()!
        await state.resolve(requestID: requestID, availability: .available, devices: [])
        _ = await collection.value

        XCTAssertEqual(
            bridge.operations,
            [.retrieveConnected(requestID), .cancel(requestID)]
        )
    }

    func testNativeRetrievalUsesBatteryServiceWithoutConnectionRequest() {
        let central = TestBLECentralRetriever()

        let peripherals = BLEConnectedPeripheralRetriever.retrieve(from: central)

        XCTAssertTrue(peripherals.isEmpty)
        XCTAssertEqual(central.retrievedServiceUUIDs, [["180F"]])
        XCTAssertEqual(central.connectionRequestCount, 0)
    }

    func testPeripheralRegistryCoalescesOverlapAndReleasesWhenIdle() {
        var registry = BLEPeripheralOperationRegistry<String>()
        let peripheralID = UUID()
        let firstRequest = UUID()
        let secondRequest = UUID()

        XCTAssertTrue(
            registry.attach("Peripheral", identifier: peripheralID, requestID: firstRequest)
        )
        XCTAssertFalse(
            registry.attach("Peripheral", identifier: peripheralID, requestID: secondRequest)
        )
        registry.cancel(requestID: firstRequest)
        XCTAssertEqual(registry.retainedIdentifiers, [peripheralID])

        XCTAssertEqual(
            Set(registry.complete(identifier: peripheralID, operationFinished: true)!),
            [secondRequest]
        )
        XCTAssertTrue(registry.retainedIdentifiers.isEmpty)

        let resetRequest = UUID()
        XCTAssertTrue(
            registry.attach("Reset Peripheral", identifier: peripheralID, requestID: resetRequest)
        )
        registry.invalidateAll()
        XCTAssertNil(registry.complete(identifier: peripheralID, operationFinished: true))

        let disconnectRequest = UUID()
        XCTAssertTrue(
            registry.attach(
                "Disconnected Peripheral",
                identifier: peripheralID,
                requestID: disconnectRequest
            )
        )
        XCTAssertEqual(registry.invalidate(identifier: peripheralID), [disconnectRequest])
        XCTAssertTrue(registry.retainedIdentifiers.isEmpty)
    }

    private func reading(identifier: UUID, level: Int?) -> BLEDeviceReading {
        BLEDeviceReading(
            identifier: identifier,
            name: "Test Sensor",
            isConnected: true,
            batteryLevel: level
        )
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}

private final class TestBLECollectionBridge: BLECollectionBridging, @unchecked Sendable {
    enum Operation: Equatable {
        case retrieveConnected(UUID)
        case cancel(UUID)
    }

    let requestIDs: AsyncStream<UUID>
    private let requestContinuation: AsyncStream<UUID>.Continuation
    private let lock = NSLock()
    private var recordedOperations: [Operation] = []

    init() {
        let stream = AsyncStream.makeStream(of: UUID.self)
        requestIDs = stream.stream
        requestContinuation = stream.continuation
    }

    var operations: [Operation] {
        lock.withLock { recordedOperations }
    }

    var cancelledRequestIDs: [UUID] {
        operations.compactMap { operation in
            guard case .cancel(let requestID) = operation else { return nil }
            return requestID
        }
    }

    func cancelCount(for requestID: UUID) -> Int {
        cancelledRequestIDs.count(where: { $0 == requestID })
    }

    func retrieveConnectedPeripherals(for requestID: UUID) {
        lock.withLock {
            recordedOperations.append(.retrieveConnected(requestID))
        }
        requestContinuation.yield(requestID)
    }

    func cancel(requestID: UUID) {
        lock.withLock {
            recordedOperations.append(.cancel(requestID))
        }
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}

private final class TestBLECentralRetriever: BLEConnectedPeripheralRetrieving {
    private(set) var retrievedServiceUUIDs: [[String]] = []
    private(set) var connectionRequestCount = 0

    func retrieveConnectedPeripherals(withServices serviceUUIDs: [CBUUID]) -> [CBPeripheral] {
        retrievedServiceUUIDs.append(serviceUUIDs.map(\.uuidString))
        return []
    }
}
