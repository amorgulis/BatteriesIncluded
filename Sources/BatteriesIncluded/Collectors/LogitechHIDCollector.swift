import Foundation

actor LogitechHIDCollector: BatteryCollecting {
    private struct CachedReader {
        let transport: HIDPPTransport
        let reader: any HIDPPBatteryReading
    }

    private struct InterfaceReader: Sendable {
        let interfaceID: String
        let descriptor: LogitechHIDInterfaceDescriptor
        let reader: any HIDPPBatteryReading
    }

    private let discovery: any LogitechHIDDiscovering
    private let readerFactory: @Sendable (HIDPPTransport) -> any HIDPPBatteryReading
    private let now: @Sendable () -> Date
    private var cachedReaders: [String: CachedReader] = [:]

    init(
        discovery: any LogitechHIDDiscovering = LogitechHIDDiscovery(),
        readerFactory: @escaping @Sendable (HIDPPTransport) -> any HIDPPBatteryReading = {
            HIDPPBatteryReader(requester: $0)
        },
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.discovery = discovery
        self.readerFactory = readerFactory
        self.now = now
    }

    func collect() async -> CollectorSnapshot {
        let interfaces = await discovery.interfaces()
        let interfaceReaders = readers(for: interfaces)
        let observedAt = now()

        let batches = await withTaskGroup(
            of: (interfaceID: String, readings: [HIDPPDeviceReading]).self,
            returning: [(interfaceID: String, readings: [HIDPPDeviceReading])].self
        ) { group in
            for interfaceReader in interfaceReaders {
                group.addTask {
                    let readings = await Self.readTargets(
                        descriptor: interfaceReader.descriptor,
                        reader: interfaceReader.reader
                    )
                    return (interfaceReader.interfaceID, readings)
                }
            }

            var batches: [(interfaceID: String, readings: [HIDPPDeviceReading])] = []
            for await batch in group {
                batches.append(batch)
            }
            return batches
        }

        var seenStableIDs: Set<String> = []
        var observations: [BatteryObservation] = []
        for batch in batches.sorted(by: { $0.interfaceID < $1.interfaceID }) {
            for reading in batch.readings where seenStableIDs.insert(reading.stableID).inserted {
                observations.append(BatteryObservation(
                    sourceID: reading.stableID,
                    stableID: reading.stableID,
                    name: reading.name,
                    isConnected: true,
                    category: reading.category,
                    component: .whole,
                    percentage: reading.percentage,
                    source: .logitechHID,
                    observedAt: observedAt
                ))
            }
        }

        observations.sort {
            let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return ($0.stableID ?? $0.sourceID) < ($1.stableID ?? $1.sourceID)
        }

        return CollectorSnapshot(availability: .available, observations: observations)
    }

    private func readers(for interfaces: [LogitechHIDInterface]) -> [InterfaceReader] {
        let activeIDs = Set(interfaces.map { $0.descriptor.id })
        cachedReaders = cachedReaders.filter { activeIDs.contains($0.key) }

        return interfaces.sorted { $0.descriptor.id < $1.descriptor.id }.map { interface in
            let interfaceID = interface.descriptor.id
            let reader: any HIDPPBatteryReading
            if let cached = cachedReaders[interfaceID], cached.transport === interface.transport {
                reader = cached.reader
            } else {
                reader = readerFactory(interface.transport)
                cachedReaders[interfaceID] = CachedReader(
                    transport: interface.transport,
                    reader: reader
                )
            }
            return InterfaceReader(
                interfaceID: interfaceID,
                descriptor: interface.descriptor,
                reader: reader
            )
        }
    }

    private static func readTargets(
        descriptor: LogitechHIDInterfaceDescriptor,
        reader: any HIDPPBatteryReading
    ) async -> [HIDPPDeviceReading] {
        var readings: [HIDPPDeviceReading] = []
        for deviceIndex in [UInt8(0xFF), 1, 2, 3, 4, 5, 6] {
            do {
                if let reading = try await reader.read(
                    deviceIndex: deviceIndex,
                    fallbackIdentity: descriptor.identity(deviceIndex: deviceIndex)
                ) {
                    if deviceIndex == 0xFF,
                       descriptor.isReceiverInterface,
                       reading.percentage == nil {
                        continue
                    }
                    readings.append(reading)
                }
            } catch {
                await reader.invalidate(deviceIndex: deviceIndex)
                continue
            }
        }
        return readings
    }
}
