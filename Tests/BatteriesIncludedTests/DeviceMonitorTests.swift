import XCTest
@testable import BatteriesIncluded

private actor FixtureCollector: BatteryCollecting {
    let snapshot: CollectorSnapshot

    init(_ snapshot: CollectorSnapshot) {
        self.snapshot = snapshot
    }

    func collect() async -> CollectorSnapshot {
        snapshot
    }
}

private actor BlockingCollector: BatteryCollecting {
    private var invocationCount = 0
    private var invocationWaiters: [(after: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var resultWaiters: [CheckedContinuation<CollectorSnapshot, Never>] = []

    func collect() async -> CollectorSnapshot {
        invocationCount += 1
        let readyWaiters = invocationWaiters.filter { $0.after < invocationCount }
        invocationWaiters.removeAll { $0.after < invocationCount }
        readyWaiters.forEach { $0.continuation.resume() }

        return await withCheckedContinuation { continuation in
            resultWaiters.append(continuation)
        }
    }

    func waitForInvocation(after previousCount: Int = 0) async {
        guard invocationCount <= previousCount else { return }
        await withCheckedContinuation { continuation in
            invocationWaiters.append((previousCount, continuation))
        }
    }

    func count() -> Int {
        invocationCount
    }

    func finish(with snapshot: CollectorSnapshot = .init(availability: .available, observations: [])) {
        let waiters = resultWaiters
        resultWaiters.removeAll()
        waiters.forEach { $0.resume(returning: snapshot) }
    }
}

private actor ConcurrentCollectionProbe {
    private var activeCount = 0
    private var observedOverlap = false

    func enter() async {
        activeCount += 1
        if activeCount > 1 {
            observedOverlap = true
        }
        for _ in 0..<1_000 where !observedOverlap {
            await Task.yield()
        }
    }

    func leave() {
        activeCount -= 1
    }

    func didObserveOverlap() -> Bool {
        observedOverlap
    }
}

private actor ProbedCollector: BatteryCollecting {
    let probe: ConcurrentCollectionProbe

    init(probe: ConcurrentCollectionProbe) {
        self.probe = probe
    }

    func collect() async -> CollectorSnapshot {
        await probe.enter()
        await probe.leave()
        return .init(availability: .available, observations: [])
    }
}

@MainActor
final class DeviceMonitorTests: XCTestCase {
    func testRefreshCombinesCollectorsAndPublishesDevices() async {
        let now = Date()
        let device = BatteryObservation(
            sourceID: "one", stableID: "one", name: "Mouse", isConnected: true,
            category: .mouse, component: .whole, percentage: 84,
            source: .system, observedAt: now
        )
        let monitor = DeviceMonitor(
            collectors: [
                FixtureCollector(.init(availability: .available, observations: [device])),
                FixtureCollector(.init(availability: .permissionDenied, observations: []))
            ],
            now: { now }
        )

        await monitor.refresh()

        guard case .devices(let devices) = monitor.state else {
            return XCTFail("Expected devices")
        }
        XCTAssertEqual(devices.first?.levels.first?.percentage, 84)
    }

    func testRefreshCollectsSourcesConcurrently() async {
        let probe = ConcurrentCollectionProbe()
        let monitor = DeviceMonitor(collectors: [
            ProbedCollector(probe: probe),
            ProbedCollector(probe: probe)
        ])

        await monitor.refresh()

        let observedOverlap = await probe.didObserveOverlap()
        XCTAssertTrue(observedOverlap)
    }

    func testRefreshPreservesCollectorDeclarationOrderWhenCollectorsCompleteInReverse() async {
        let now = Date()
        let declaredFirst = BatteryObservation(
            sourceID: "first", stableID: "shared", name: "Declared First", isConnected: true,
            category: .mouse, component: .whole, percentage: 31,
            source: .system, observedAt: now
        )
        let completedFirst = BatteryObservation(
            sourceID: "second", stableID: "shared", name: "Completed First", isConnected: true,
            category: .keyboard, component: .whole, percentage: 92,
            source: .system, observedAt: now
        )
        let firstCollector = BlockingCollector()
        let secondCollector = BlockingCollector()
        let monitor = DeviceMonitor(
            collectors: [firstCollector, secondCollector],
            now: { now }
        )

        let refresh = Task { await monitor.refresh() }
        await firstCollector.waitForInvocation()
        await secondCollector.waitForInvocation()
        await secondCollector.finish(
            with: .init(availability: .available, observations: [completedFirst])
        )
        try? await Task.sleep(for: .milliseconds(10))
        await firstCollector.finish(
            with: .init(availability: .available, observations: [declaredFirst])
        )
        await refresh.value

        guard case .devices(let devices) = monitor.state, let device = devices.first else {
            return XCTFail("Expected one normalized device")
        }
        XCTAssertEqual(device.name, "Declared First")
        XCTAssertEqual(device.category, .mouse)
        XCTAssertEqual(device.levels.first?.percentage, 31)
    }

    func testPermissionDenialWinsWhenNoDevicesAreReadable() async {
        let monitor = DeviceMonitor(
            collectors: [
                FixtureCollector(.init(availability: .unavailable, observations: [])),
                FixtureCollector(.init(availability: .poweredOff, observations: [])),
                FixtureCollector(.init(availability: .permissionDenied, observations: []))
            ]
        )

        await monitor.refresh()

        XCTAssertEqual(monitor.state, .permissionDenied)
    }

    func testBluetoothOffWinsOverGenericEmptyState() async {
        let monitor = DeviceMonitor(
            collectors: [
                FixtureCollector(.init(availability: .unavailable, observations: [])),
                FixtureCollector(.init(availability: .poweredOff, observations: []))
            ]
        )

        await monitor.refresh()

        XCTAssertEqual(monitor.state, .bluetoothOff)
    }

    func testUnavailableWinsOverNoDevicesWhenNoDevicesAreReadable() async {
        let monitor = DeviceMonitor(
            collectors: [
                FixtureCollector(.init(availability: .available, observations: [])),
                FixtureCollector(.init(availability: .unavailable, observations: []))
            ]
        )

        await monitor.refresh()

        XCTAssertEqual(monitor.state, .unavailable)
    }

    func testAvailableCollectorsWithoutDevicesPublishNoDevices() async {
        let monitor = DeviceMonitor(
            collectors: [FixtureCollector(.init(availability: .available, observations: []))]
        )

        await monitor.refresh()

        XCTAssertEqual(monitor.state, .noDevices)
    }

    func testStartRefreshesImmediatelyWithoutOverlappingManualOrScheduledCycles() async {
        let collector = BlockingCollector()
        let monitor = DeviceMonitor(collectors: [collector], refreshInterval: .milliseconds(10))

        monitor.start()
        await collector.waitForInvocation()
        let initialCount = await collector.count()
        XCTAssertEqual(initialCount, 1)

        await monitor.refresh()
        let manualRefreshCount = await collector.count()
        XCTAssertEqual(manualRefreshCount, 1)

        monitor.stop()
        await collector.finish()
        try? await Task.sleep(for: .milliseconds(30))
        let stoppedCount = await collector.count()
        XCTAssertEqual(stoppedCount, 1)
    }

    func testStartSchedulesPeriodicRefreshAndStopPreventsAnotherCycle() async {
        let collector = BlockingCollector()
        let monitor = DeviceMonitor(collectors: [collector], refreshInterval: .milliseconds(10))

        monitor.start()
        await collector.waitForInvocation()
        await collector.finish()
        await collector.waitForInvocation(after: 1)
        let periodicCount = await collector.count()
        XCTAssertEqual(periodicCount, 2)

        monitor.stop()
        await collector.finish()
        try? await Task.sleep(for: .milliseconds(30))
        let stoppedCount = await collector.count()
        XCTAssertEqual(stoppedCount, 2)
    }

    func testStartedMonitorCanDeinitializeWhilePeriodicTaskIsSleeping() async {
        let collector = BlockingCollector()
        var monitor: DeviceMonitor? = DeviceMonitor(
            collectors: [collector],
            refreshInterval: .seconds(60)
        )
        weak let weakMonitor = monitor

        monitor?.start()
        await collector.waitForInvocation()
        await collector.finish()
        while monitor?.isRefreshing == true {
            await Task.yield()
        }

        monitor = nil
        await Task.yield()

        XCTAssertNil(weakMonitor)
    }

    func testRefreshPreservesDevicesWhileCollectionIsInFlight() async {
        let now = Date()
        let first = BatteryObservation(
            sourceID: "one", stableID: "one", name: "Mouse", isConnected: true,
            category: .mouse, component: .whole, percentage: 84,
            source: .system, observedAt: now
        )
        let collector = BlockingCollector()
        let monitor = DeviceMonitor(collectors: [collector], now: { now })

        let initialRefresh = Task { await monitor.refresh() }
        await collector.waitForInvocation()
        await collector.finish(with: .init(availability: .available, observations: [first]))
        await initialRefresh.value

        let secondRefresh = Task { await monitor.refresh() }
        await collector.waitForInvocation(after: 1)
        XCTAssertTrue(monitor.isRefreshing)
        guard case .devices = monitor.state else {
            return XCTFail("Expected existing devices during refresh")
        }
        await collector.finish()
        await secondRefresh.value
    }
}
