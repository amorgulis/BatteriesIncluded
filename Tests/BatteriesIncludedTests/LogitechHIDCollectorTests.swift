import Foundation
import XCTest
@testable import BatteriesIncluded

final class LogitechHIDCollectorTests: XCTestCase {
    func testCollectProbesDirectAndReceiverTargetsInOrderAndIsolatesTargetFailures() async {
        let now = Date(timeIntervalSince1970: 1_725_000_000)
        let transport = makeTransport()
        let interface = makeInterface(id: "receiver", transport: transport)
        let reader = ScriptedBatteryReader(results: [
            0xFF: .success(reading(index: 0xFF, stableID: "direct", name: "A Direct", percentage: 85)),
            1: .failure(FakeError.unresponsive),
            2: .success(reading(index: 2, stableID: "receiver:2", name: "B Mouse", percentage: 42)),
            3: .success(nil),
            4: .success(reading(index: 4, stableID: "receiver:4", name: "G Headset", percentage: nil)),
            5: .success(nil),
            6: .success(nil)
        ])
        let collector = LogitechHIDCollector(
            discovery: FakeLogitechHIDDiscovery(snapshots: [[interface]]),
            readerFactory: { _ in reader },
            now: { now }
        )

        let snapshot = await collector.collect()
        let requestedIndexes = await reader.requestedIndexes

        XCTAssertEqual(snapshot.availability, .available)
        XCTAssertEqual(requestedIndexes, [0xFF, 1, 2, 3, 4, 5, 6])
        XCTAssertEqual(snapshot.observations.map(\.name), ["A Direct", "B Mouse", "G Headset"])
        XCTAssertEqual(
            Set(snapshot.observations.compactMap(\.stableID)),
            ["direct", "receiver:2", "receiver:4"]
        )
        XCTAssertEqual(snapshot.observations.map(\.sourceID), ["direct", "receiver:2", "receiver:4"])
        XCTAssertTrue(snapshot.observations.allSatisfy(\.isConnected))
        XCTAssertTrue(snapshot.observations.allSatisfy { $0.component == .whole })
        XCTAssertTrue(snapshot.observations.allSatisfy { $0.source == .logitechHID })
        XCTAssertTrue(snapshot.observations.allSatisfy { $0.observedAt == now })
        XCTAssertNil(snapshot.observations.first { $0.name == "G Headset" }?.percentage)
    }

    func testCollectRunsInterfacesConcurrentlyAndDeduplicatesByStableID() async {
        let firstTransport = makeTransport()
        let secondTransport = makeTransport()
        let firstInterface = makeInterface(id: "a", transport: firstTransport)
        let secondInterface = makeInterface(id: "b", transport: secondTransport)
        let gate = AsyncGate(expectedArrivals: 2)
        let firstStarted = expectation(description: "first interface started")
        let secondStarted = expectation(description: "second interface started")
        let firstReader = ScriptedBatteryReader(
            results: [
                0xFF: .success(reading(index: 0xFF, stableID: "shared", name: "Shared Device", percentage: 80))
            ],
            firstRead: {
                firstStarted.fulfill()
                await gate.arriveAndWait()
            }
        )
        let secondReader = ScriptedBatteryReader(
            results: [
                0xFF: .success(reading(index: 0xFF, stableID: "shared", name: "Shared Device", percentage: 80)),
                1: .success(reading(index: 1, stableID: "unique", name: "Unique Device", percentage: 55))
            ],
            firstRead: {
                secondStarted.fulfill()
                await gate.arriveAndWait()
            }
        )
        let readers = ReaderLookup([
            ObjectIdentifier(firstTransport): firstReader,
            ObjectIdentifier(secondTransport): secondReader
        ])
        let collector = LogitechHIDCollector(
            discovery: FakeLogitechHIDDiscovery(snapshots: [[firstInterface, secondInterface]]),
            readerFactory: { readers.reader(for: $0) }
        )

        let collection = Task { await collector.collect() }
        await fulfillment(of: [firstStarted, secondStarted], timeout: 1)
        let arrivalCount = await gate.arrivalCount
        XCTAssertEqual(arrivalCount, 2)
        await gate.open()
        let snapshot = await collection.value

        XCTAssertEqual(snapshot.observations.map(\.stableID), ["shared", "unique"])
    }

    func testCollectReturnsAvailableEmptySnapshotWhenDiscoveryFindsNoInterfaces() async {
        let collector = LogitechHIDCollector(
            discovery: FakeLogitechHIDDiscovery(snapshots: [[]]),
            readerFactory: { _ in XCTFail("No reader should be created"); return ScriptedBatteryReader() }
        )

        let snapshot = await collector.collect()

        XCTAssertEqual(snapshot.availability, .available)
        XCTAssertTrue(snapshot.observations.isEmpty)
    }

    func testCollectReusesReadersForUnchangedInterfacesAndEvictsRemovedOrReplacedInterfaces() async {
        let firstTransport = makeTransport()
        let replacementTransport = makeTransport()
        let descriptor = makeDescriptor(id: "stable-interface")
        let original = LogitechHIDInterface(descriptor: descriptor, transport: firstTransport)
        let replacement = LogitechHIDInterface(descriptor: descriptor, transport: replacementTransport)
        let discovery = FakeLogitechHIDDiscovery(snapshots: [
            [original],
            [original],
            [replacement],
            [],
            [replacement]
        ])
        let factory = ReaderFactoryRecorder()
        let collector = LogitechHIDCollector(
            discovery: discovery,
            readerFactory: { factory.makeReader(for: $0) }
        )

        _ = await collector.collect()
        XCTAssertEqual(factory.creationCount, 1)
        _ = await collector.collect()
        XCTAssertEqual(factory.creationCount, 1)
        _ = await collector.collect()
        XCTAssertEqual(factory.creationCount, 2)
        _ = await collector.collect()
        XCTAssertEqual(factory.creationCount, 2)
        _ = await collector.collect()
        XCTAssertEqual(factory.creationCount, 3)
    }

    private func makeTransport() -> HIDPPTransport {
        HIDPPTransport(io: NoopHIDPPDeviceIO())
    }

    private func makeInterface(id: String, transport: HIDPPTransport) -> LogitechHIDInterface {
        LogitechHIDInterface(descriptor: makeDescriptor(id: id), transport: transport)
    }

    private func makeDescriptor(id: String) -> LogitechHIDInterfaceDescriptor {
        LogitechHIDInterfaceDescriptor(
            id: id,
            physicalKey: "physical-\(id)",
            vendorID: 0x046D,
            productID: 0xC548,
            serialNumber: id,
            locationID: nil,
            transport: "USB",
            productName: "Receiver \(id)",
            primaryUsagePage: 1,
            primaryUsage: 2,
            inputReportIDs: [0x11],
            outputReportIDs: [0x11]
        )
    }

    private func reading(
        index: UInt8,
        stableID: String,
        name: String,
        percentage: Int?
    ) -> HIDPPDeviceReading {
        HIDPPDeviceReading(
            deviceIndex: index,
            stableID: stableID,
            name: name,
            category: .mouse,
            percentage: percentage
        )
    }
}

private enum FakeError: Error {
    case unresponsive
}

private actor FakeLogitechHIDDiscovery: LogitechHIDDiscovering {
    private var snapshots: [[LogitechHIDInterface]]

    init(snapshots: [[LogitechHIDInterface]]) {
        self.snapshots = snapshots
    }

    func interfaces() -> [LogitechHIDInterface] {
        guard snapshots.count > 1 else { return snapshots.first ?? [] }
        return snapshots.removeFirst()
    }
}

private actor ScriptedBatteryReader: HIDPPBatteryReading {
    typealias Result = Swift.Result<HIDPPDeviceReading?, Error>

    private let results: [UInt8: Result]
    private let firstRead: (@Sendable () async -> Void)?
    private var indexes: [UInt8] = []

    init(
        results: [UInt8: Result] = [:],
        firstRead: (@Sendable () async -> Void)? = nil
    ) {
        self.results = results
        self.firstRead = firstRead
    }

    var requestedIndexes: [UInt8] { indexes }

    func read(
        deviceIndex: UInt8,
        fallbackIdentity: HIDPPFallbackIdentity
    ) async throws -> HIDPPDeviceReading? {
        indexes.append(deviceIndex)
        if indexes.count == 1 {
            await firstRead?()
        }
        return try results[deviceIndex, default: .success(nil)].get()
    }
}

private actor AsyncGate {
    private let expectedArrivals: Int
    private var arrivals = 0
    private var isOpen = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    init(expectedArrivals: Int) {
        self.expectedArrivals = expectedArrivals
    }

    var arrivalCount: Int { arrivals }

    func arriveAndWait() async {
        arrivals += 1
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func open() {
        XCTAssertEqual(arrivals, expectedArrivals)
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting {
            continuation.resume()
        }
    }
}

private final class ReaderLookup: @unchecked Sendable {
    private let readers: [ObjectIdentifier: any HIDPPBatteryReading]

    init(_ readers: [ObjectIdentifier: any HIDPPBatteryReading]) {
        self.readers = readers
    }

    func reader(for transport: HIDPPTransport) -> any HIDPPBatteryReading {
        readers[ObjectIdentifier(transport)]!
    }
}

private final class ReaderFactoryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var creationCount: Int {
        lock.withLock { count }
    }

    func makeReader(for transport: HIDPPTransport) -> any HIDPPBatteryReading {
        lock.withLock { count += 1 }
        return ScriptedBatteryReader()
    }
}

private struct NoopHIDPPDeviceIO: HIDPPDeviceIO {
    func write(_ report: [UInt8]) throws {}
}
