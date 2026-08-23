import Foundation
import Observation

@MainActor
@Observable
final class DeviceMonitor {
    private(set) var state: MenuState = .loading
    private(set) var isRefreshing = false

    private let collectors: [any BatteryCollecting]
    private let normalizer: BatteryNormalizer
    private let refreshInterval: Duration
    private let now: @Sendable () -> Date
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(
        collectors: [any BatteryCollecting],
        normalizer: BatteryNormalizer = .init(),
        refreshInterval: Duration = .seconds(30),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.collectors = collectors
        self.normalizer = normalizer
        self.refreshInterval = refreshInterval
        self.now = now
    }

    func start() {
        guard refreshTask == nil else { return }
        let refreshInterval = refreshInterval

        refreshTask = Task { [weak self, refreshInterval] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.refresh()
                guard !Task.isCancelled, self != nil else { return }

                do {
                    try await Task.sleep(for: refreshInterval)
                } catch {
                    return
                }
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let collectors = collectors
        let snapshots = await withTaskGroup(
            of: (Int, CollectorSnapshot).self,
            returning: [CollectorSnapshot].self
        ) { group in
            for (index, collector) in collectors.enumerated() {
                group.addTask {
                    (index, await collector.collect())
                }
            }

            var indexedSnapshots: [(Int, CollectorSnapshot)] = []
            for await indexedSnapshot in group {
                indexedSnapshots.append(indexedSnapshot)
            }
            return indexedSnapshots.sorted { $0.0 < $1.0 }.map { $0.1 }
        }

        guard !Task.isCancelled else { return }

        let devices = normalizer.normalize(
            snapshots.flatMap(\.observations),
            now: now()
        )
        if !devices.isEmpty {
            state = .devices(devices)
        } else if snapshots.contains(where: { $0.availability == .permissionDenied }) {
            state = .permissionDenied
        } else if snapshots.contains(where: { $0.availability == .poweredOff }) {
            state = .bluetoothOff
        } else if snapshots.contains(where: { $0.availability == .unavailable }) {
            state = .unavailable
        } else {
            state = .noDevices
        }
    }

    deinit {
        refreshTask?.cancel()
    }
}
