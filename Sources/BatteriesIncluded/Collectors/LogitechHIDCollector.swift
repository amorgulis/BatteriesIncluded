import Foundation

protocol HIDPPTransport: Sendable {
    func request(_ report: [UInt8]) async -> [UInt8]?
    func prepare(deviceIndex: UInt8) async
}

extension HIDPPTransport {
    func prepare(deviceIndex: UInt8) async {}
}

struct LogitechHIDEndpoint: Sendable {
    let id: String
    let name: String
    let category: DeviceCategory
    let deviceIndices: [UInt8]
    let transport: any HIDPPTransport
}

protocol LogitechHIDDiscovering: Sendable {
    func discover() async -> [LogitechHIDEndpoint]
}

actor LogitechHIDCollector: BatteryCollecting {
    private let discovery: any LogitechHIDDiscovering
    private let now: @Sendable () -> Date
    private var nextSoftwareID: UInt8 = 8

    init(
        discovery: any LogitechHIDDiscovering = IOKitLogitechHIDDiscovery(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.discovery = discovery
        self.now = now
    }

    func collect() async -> CollectorSnapshot {
        let endpoints = await discovery.discover()
        var observations: [BatteryObservation] = []

        for endpoint in endpoints {
            for deviceIndex in endpoint.deviceIndices {
                await endpoint.transport.prepare(deviceIndex: deviceIndex)
                guard let battery = await readBattery(
                    deviceIndex: deviceIndex,
                    transport: endpoint.transport
                ) else { continue }

                let isReceiverSlot = deviceIndex != 0xFF
                let name = isReceiverSlot
                    ? await readName(deviceIndex: deviceIndex, transport: endpoint.transport) ?? "Logitech Device \(deviceIndex)"
                    : endpoint.name
                let sourceID = "\(endpoint.id):\(deviceIndex)"
                observations.append(BatteryObservation(
                    sourceID: sourceID,
                    stableID: "logitech:\(sourceID)",
                    name: name,
                    isConnected: true,
                    category: endpoint.category,
                    component: .whole,
                    percentage: battery.percentage,
                    source: .logitechHID,
                    observedAt: now(),
                    coarseLevel: battery.coarseLevel
                ))
            }
        }

        return CollectorSnapshot(availability: .available, observations: observations)
    }

    private func readBattery(
        deviceIndex: UInt8,
        transport: any HIDPPTransport
    ) async -> HIDPPBatteryValue? {
        let features: [(UInt16, UInt8, ([UInt8]) -> HIDPPBatteryValue?)] = [
            (0x1004, 0x10, HIDPPProtocol.parseUnifiedBattery),
            (0x1000, 0x00, HIDPPProtocol.parseBatteryStatus),
            (0x1001, 0x00, HIDPPProtocol.parseBatteryVoltage)
        ]

        for (feature, function, parser) in features {
            let featureRequest = makeRequest(
                deviceIndex: deviceIndex,
                command: 0,
                address: 0,
                parameters: [UInt8(feature >> 8), UInt8(feature & 0xFF)]
            )
            guard let featureReply = await transport.request(featureRequest),
                  featureReply.count >= 5, featureReply[4] != 0 else { continue }
            let request = makeRequest(
                deviceIndex: deviceIndex,
                command: featureReply[4],
                address: function
            )
            if let reply = await transport.request(request), let value = parser(reply) {
                return value
            }
        }

        if let reply = await transport.request(HIDPPProtocol.registerRead(
            deviceIndex: deviceIndex, register: 0x0D
        )), let value = HIDPPProtocol.parseBatteryCharge(reply) {
            return value
        }
        if let reply = await transport.request(HIDPPProtocol.registerRead(
            deviceIndex: deviceIndex, register: 0x07
        )) {
            return HIDPPProtocol.parseBatteryStatusRegister(reply)
        }
        return nil
    }

    private func readName(
        deviceIndex: UInt8,
        transport: any HIDPPTransport
    ) async -> String? {
        let featureRequest = makeRequest(
            deviceIndex: deviceIndex, command: 0, address: 0, parameters: [0x00, 0x05]
        )
        guard let featureReply = await transport.request(featureRequest),
              featureReply.count >= 5, featureReply[4] != 0 else { return nil }
        let featureIndex = featureReply[4]
        let lengthRequest = makeRequest(deviceIndex: deviceIndex, command: featureIndex, address: 0)
        guard let lengthReply = await transport.request(lengthRequest), lengthReply.count >= 5 else { return nil }
        let expectedLength = Int(lengthReply[4])
        guard expectedLength > 0 else { return nil }

        var nameBytes: [UInt8] = []
        while nameBytes.count < expectedLength {
            let request = makeRequest(
                deviceIndex: deviceIndex, command: featureIndex, address: 0x10,
                parameters: [UInt8(nameBytes.count)]
            )
            guard let reply = await transport.request(request), reply.count > 4 else { return nil }
            let fragment = reply.dropFirst(4).prefix(expectedLength - nameBytes.count)
            guard !fragment.isEmpty else { return nil }
            nameBytes.append(contentsOf: fragment)
        }
        return String(bytes: nameBytes, encoding: .utf8)
    }

    private func makeRequest(
        deviceIndex: UInt8,
        command: UInt8,
        address: UInt8,
        parameters: [UInt8] = []
    ) -> [UInt8] {
        let softwareID = nextSoftwareID
        nextSoftwareID = softwareID == 15 ? 8 : softwareID + 1
        return HIDPPProtocol.shortRequest(
            deviceIndex: deviceIndex,
            command: command,
            address: address,
            parameters: parameters,
            softwareID: softwareID
        )
    }
}

private extension HIDPPBatteryValue {
    var percentage: Int? {
        if case .percentage(let value) = self { return value }
        return nil
    }

    var coarseLevel: CoarseBatteryLevel? {
        if case .coarse(let value) = self { return value }
        return nil
    }
}
