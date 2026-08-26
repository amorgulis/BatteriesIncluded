import Foundation
import XCTest
@testable import BatteriesIncluded

final class HIDPPTransportTests: XCTestCase {
    func testMatchingResponseCompletesRequestAndClearsPendingWork() async throws {
        let io = FakeHIDPPDeviceIO()
        let transport = HIDPPTransport(io: io, timeout: .seconds(1))
        let request = try packet(featureIndex: 7)

        let task = Task { try await transport.send(request) }
        let writtenRequest = await io.waitForWrite()
        XCTAssertEqual(writtenRequest, request.bytes)

        let response = [UInt8(0x11), 1, 7, 0x1D, 73] + .init(repeating: 0, count: 15)
        await transport.receive(response)

        let receivedResponse = try await task.value
        XCTAssertEqual(receivedResponse[4], 73)
        let pendingRequestCount = await transport.pendingRequestCount
        XCTAssertEqual(pendingRequestCount, 0)
    }

    func testMismatchedReportLeavesRequestPending() async throws {
        let io = FakeHIDPPDeviceIO()
        let transport = HIDPPTransport(io: io, timeout: .seconds(1))
        let request = try packet(featureIndex: 7)

        let task = Task { try await transport.send(request) }
        _ = await io.waitForWrite()

        await transport.receive([0x11, 1, 8, 0x1D, 99] + .init(repeating: 0, count: 15))
        let pendingAfterMismatch = await transport.pendingRequestCount
        XCTAssertEqual(pendingAfterMismatch, 1)

        let response = [UInt8(0x11), 1, 7, 0x1D, 73] + .init(repeating: 0, count: 15)
        await transport.receive(response)
        let receivedResponse = try await task.value
        XCTAssertEqual(receivedResponse, response)
    }

    func testProtocolErrorFailsMatchingRequest() async throws {
        let io = FakeHIDPPDeviceIO()
        let transport = HIDPPTransport(io: io, timeout: .seconds(1))
        let request = try packet(featureIndex: 7)

        let task = Task { try await transport.send(request) }
        _ = await io.waitForWrite()
        await transport.receive(
            [0x11, 1, 0xFF, 0x1D, 7, 0x06] + .init(repeating: 0, count: 14)
        )

        await assertTask(task, throws: HIDPPError.invalidFeatureIndex)
        let pendingRequestCount = await transport.pendingRequestCount
        XCTAssertEqual(pendingRequestCount, 0)
    }

    func testTimeoutFailsRequestAndClearsPendingWork() async throws {
        let io = FakeHIDPPDeviceIO()
        let transport = HIDPPTransport(io: io, timeout: .milliseconds(10))
        let request = try packet(featureIndex: 7)

        let task = Task { try await transport.send(request) }
        _ = await io.waitForWrite()

        await assertTask(task, throws: HIDPPError.timeout)
        let pendingRequestCount = await transport.pendingRequestCount
        XCTAssertEqual(pendingRequestCount, 0)
    }

    func testCancellationResumesOnceAndStartsNextQueuedRequest() async throws {
        let io = FakeHIDPPDeviceIO()
        let transport = HIDPPTransport(io: io, timeout: .seconds(1))
        let firstRequest = try packet(featureIndex: 7)
        let secondRequest = try packet(featureIndex: 8)

        let firstTask = Task { try await transport.send(firstRequest) }
        _ = await io.waitForWrite(number: 1)
        let secondTask = Task { try await transport.send(secondRequest) }
        await waitForPendingRequestCount(2, in: transport)

        firstTask.cancel()
        await assertTaskIsCancelled(firstTask)
        let secondWrite = await io.waitForWrite(number: 2)
        XCTAssertEqual(secondWrite, secondRequest.bytes)

        await transport.receive([0x11, 1, 7, 0x1D, 10] + .init(repeating: 0, count: 15))
        let pendingAfterLateResponse = await transport.pendingRequestCount
        XCTAssertEqual(pendingAfterLateResponse, 1)
        let secondResponse = [UInt8(0x11), 1, 8, 0x1D, 80] + .init(repeating: 0, count: 15)
        await transport.receive(secondResponse)

        let receivedSecondResponse = try await secondTask.value
        XCTAssertEqual(receivedSecondResponse, secondResponse)
        let pendingRequestCount = await transport.pendingRequestCount
        XCTAssertEqual(pendingRequestCount, 0)
    }

    func testInterfaceRemovalFailsActiveAndQueuedRequests() async throws {
        let io = FakeHIDPPDeviceIO()
        let transport = HIDPPTransport(io: io, timeout: .seconds(1))
        let firstRequest = try packet(featureIndex: 7)
        let secondRequest = try packet(featureIndex: 8)

        let firstTask = Task { try await transport.send(firstRequest) }
        _ = await io.waitForWrite()
        let secondTask = Task { try await transport.send(secondRequest) }
        await waitForPendingRequestCount(2, in: transport)

        await transport.interfaceRemoved()

        await assertTask(firstTask, throws: HIDPPError.disconnected)
        await assertTask(secondTask, throws: HIDPPError.disconnected)
        let pendingRequestCount = await transport.pendingRequestCount
        XCTAssertEqual(pendingRequestCount, 0)
        XCTAssertEqual(io.writeCount, 1)
    }

    func testRequestsSerializeOnOneTransport() async throws {
        let io = FakeHIDPPDeviceIO()
        let transport = HIDPPTransport(io: io, timeout: .seconds(1))
        let firstRequest = try packet(featureIndex: 7)
        let secondRequest = try packet(featureIndex: 8)

        let firstTask = Task { try await transport.send(firstRequest) }
        _ = await io.waitForWrite()
        let secondTask = Task { try await transport.send(secondRequest) }
        await waitForPendingRequestCount(2, in: transport)

        XCTAssertEqual(io.writeCount, 1)
        let firstResponse = [UInt8(0x11), 1, 7, 0x1D, 70] + .init(repeating: 0, count: 15)
        await transport.receive(firstResponse)
        let secondWrite = await io.waitForWrite(number: 2)
        XCTAssertEqual(secondWrite, secondRequest.bytes)

        let secondResponse = [UInt8(0x11), 1, 8, 0x1D, 80] + .init(repeating: 0, count: 15)
        await transport.receive(secondResponse)

        let receivedFirstResponse = try await firstTask.value
        let receivedSecondResponse = try await secondTask.value
        XCTAssertEqual(receivedFirstResponse, firstResponse)
        XCTAssertEqual(receivedSecondResponse, secondResponse)
    }

    func testIndependentTransportsCanProgressConcurrently() async throws {
        let firstIO = FakeHIDPPDeviceIO()
        let secondIO = FakeHIDPPDeviceIO()
        let firstTransport = HIDPPTransport(io: firstIO, timeout: .seconds(1))
        let secondTransport = HIDPPTransport(io: secondIO, timeout: .seconds(1))
        let firstRequest = try packet(featureIndex: 7)
        let secondRequest = try packet(featureIndex: 8)

        let firstTask = Task { try await firstTransport.send(firstRequest) }
        let secondTask = Task { try await secondTransport.send(secondRequest) }

        async let firstWrite = firstIO.waitForWrite()
        async let secondWrite = secondIO.waitForWrite()
        let writes = await (firstWrite, secondWrite)
        XCTAssertEqual(writes.0, firstRequest.bytes)
        XCTAssertEqual(writes.1, secondRequest.bytes)

        let firstResponse = [UInt8(0x11), 1, 7, 0x1D, 70] + .init(repeating: 0, count: 15)
        let secondResponse = [UInt8(0x11), 1, 8, 0x1D, 80] + .init(repeating: 0, count: 15)
        await firstTransport.receive(firstResponse)
        await secondTransport.receive(secondResponse)

        let receivedFirstResponse = try await firstTask.value
        let receivedSecondResponse = try await secondTask.value
        XCTAssertEqual(receivedFirstResponse, firstResponse)
        XCTAssertEqual(receivedSecondResponse, secondResponse)
    }

    private func packet(featureIndex: UInt8) throws -> HIDPPPacket {
        try HIDPPPacket.request(
            kind: .long,
            deviceIndex: 1,
            featureIndex: featureIndex,
            functionID: 1,
            softwareID: 0x0D,
            parameters: []
        )
    }

    private func waitForPendingRequestCount(
        _ expectedCount: Int,
        in transport: HIDPPTransport,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if await transport.pendingRequestCount == expectedCount {
                return
            }
            await Task.yield()
        }
        XCTFail(
            "Transport never reached \(expectedCount) pending requests",
            file: file,
            line: line
        )
    }

    private func assertTask(
        _ task: Task<[UInt8], Error>,
        throws expectedError: HIDPPError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("Expected task to throw \(expectedError)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? HIDPPError, expectedError, file: file, line: line)
        }
    }

    private func assertTaskIsCancelled(
        _ task: Task<[UInt8], Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("Expected task cancellation", file: file, line: line)
        } catch {
            XCTAssertTrue(error is CancellationError, file: file, line: line)
        }
    }
}

private final class FakeHIDPPDeviceIO: HIDPPDeviceIO, @unchecked Sendable {
    private struct WriteWaiter {
        let number: Int
        let continuation: CheckedContinuation<[UInt8], Never>
    }

    private let lock = NSLock()
    private var writes: [[UInt8]] = []
    private var waiters: [WriteWaiter] = []

    var writeCount: Int {
        lock.withLock { writes.count }
    }

    func write(_ report: [UInt8]) throws {
        let readyWaiters: [(CheckedContinuation<[UInt8], Never>, [UInt8])] = lock.withLock {
            writes.append(report)
            var ready: [(CheckedContinuation<[UInt8], Never>, [UInt8])] = []
            waiters.removeAll { waiter in
                guard writes.count >= waiter.number else { return false }
                ready.append((waiter.continuation, writes[waiter.number - 1]))
                return true
            }
            return ready
        }
        for (continuation, writtenReport) in readyWaiters {
            continuation.resume(returning: writtenReport)
        }
    }

    func waitForWrite(number: Int = 1) async -> [UInt8] {
        await withCheckedContinuation { continuation in
            let writtenReport: [UInt8]? = lock.withLock {
                guard writes.count < number else { return writes[number - 1] }
                waiters.append(WriteWaiter(number: number, continuation: continuation))
                return nil
            }
            if let writtenReport {
                continuation.resume(returning: writtenReport)
            }
        }
    }
}
