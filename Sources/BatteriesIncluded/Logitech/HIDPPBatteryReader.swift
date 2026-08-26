import Foundation

protocol HIDPPRequesting: Sendable {
    func send(_ packet: HIDPPPacket) async throws -> [UInt8]
}

struct HIDPPFallbackIdentity: Sendable, Equatable {
    let stableID: String
    let name: String?
    let category: DeviceCategory?
    let isReceiverChild: Bool
}

struct HIDPPDeviceReading: Sendable, Equatable {
    let deviceIndex: UInt8
    let stableID: String
    let name: String
    let category: DeviceCategory?
    let percentage: Int?
}

protocol HIDPPBatteryReading: Sendable {
    func read(
        deviceIndex: UInt8,
        fallbackIdentity: HIDPPFallbackIdentity
    ) async throws -> HIDPPDeviceReading?
}

actor HIDPPBatteryReader: HIDPPBatteryReading {
    private enum CachedName {
        case unresolved
        case value(String?)
    }

    private struct UnifiedBatteryFeature {
        let index: UInt8
        let supportsStateOfCharge: Bool
    }

    private struct DeviceCache {
        var name: CachedName = .unresolved
        var unifiedBattery: UnifiedBatteryFeature?
        var legacyBatteryIndex: UInt8?
    }

    private enum Feature {
        static let deviceName: UInt16 = 0x0005
        static let unifiedBattery: UInt16 = 0x1004
        static let legacyBattery: UInt16 = 0x1000
    }

    private let requester: any HIDPPRequesting
    private var caches: [UInt8: DeviceCache] = [:]

    init(requester: any HIDPPRequesting) {
        self.requester = requester
    }

    func read(
        deviceIndex: UInt8,
        fallbackIdentity: HIDPPFallbackIdentity
    ) async throws -> HIDPPDeviceReading? {
        guard let name = try await resolvedName(
            deviceIndex: deviceIndex,
            fallbackIdentity: fallbackIdentity
        ) else {
            return nil
        }

        let percentage: Int?
        if let unifiedPercentage = try await unifiedBatteryPercentage(deviceIndex: deviceIndex) {
            percentage = unifiedPercentage
        } else {
            percentage = try await legacyBatteryPercentage(deviceIndex: deviceIndex)
        }

        return HIDPPDeviceReading(
            deviceIndex: deviceIndex,
            stableID: fallbackIdentity.stableID,
            name: name,
            category: fallbackIdentity.category,
            percentage: percentage
        )
    }

    func invalidate(deviceIndex: UInt8) {
        caches.removeValue(forKey: deviceIndex)
    }

    func invalidateAll() {
        caches.removeAll()
    }

    private func resolvedName(
        deviceIndex: UInt8,
        fallbackIdentity: HIDPPFallbackIdentity
    ) async throws -> String? {
        if let name = fallbackIdentity.name, !name.isEmpty {
            return name
        }
        guard fallbackIdentity.isReceiverChild else {
            return nil
        }

        switch caches[deviceIndex, default: DeviceCache()].name {
        case .value(let name):
            return name
        case .unresolved:
            break
        }

        let name: String?
        do {
            guard let featureIndex = try await resolveFeature(Feature.deviceName, deviceIndex: deviceIndex) else {
                name = nil
                caches[deviceIndex, default: DeviceCache()].name = .value(nil)
                return nil
            }
            let parameters = try await send(
                deviceIndex: deviceIndex,
                featureIndex: featureIndex,
                functionID: 0
            )
            name = decodedName(from: parameters)
        } catch HIDPPError.invalidFeatureIndex {
            name = nil
        }

        caches[deviceIndex, default: DeviceCache()].name = .value(name)
        return name
    }

    private func unifiedBatteryPercentage(deviceIndex: UInt8) async throws -> Int? {
        let feature: UnifiedBatteryFeature
        if let cachedFeature = caches[deviceIndex]?.unifiedBattery {
            feature = cachedFeature
        } else {
            do {
                guard let featureIndex = try await resolveFeature(Feature.unifiedBattery, deviceIndex: deviceIndex) else {
                    return nil
                }
                let capabilities = try await send(
                    deviceIndex: deviceIndex,
                    featureIndex: featureIndex,
                    functionID: 0
                )
                guard capabilities.count >= 2 else {
                    return nil
                }
                feature = UnifiedBatteryFeature(
                    index: featureIndex,
                    supportsStateOfCharge: capabilities[1] & 0x02 != 0
                )
                caches[deviceIndex, default: DeviceCache()].unifiedBattery = feature
            } catch HIDPPError.invalidFeatureIndex {
                invalidate(deviceIndex: deviceIndex)
                return nil
            }
        }

        do {
            let status = try await send(
                deviceIndex: deviceIndex,
                featureIndex: feature.index,
                functionID: 1
            )
            guard let level = status.first else {
                return nil
            }
            if feature.supportsStateOfCharge {
                return level <= 100 ? Int(level) : nil
            }
            return switch level {
            case 1: 10
            case 2: 30
            case 4: 60
            case 8: 90
            default: nil
            }
        } catch HIDPPError.invalidFeatureIndex {
            invalidate(deviceIndex: deviceIndex)
            return nil
        }
    }

    private func legacyBatteryPercentage(deviceIndex: UInt8) async throws -> Int? {
        let featureIndex: UInt8
        if let cachedFeatureIndex = caches[deviceIndex]?.legacyBatteryIndex {
            featureIndex = cachedFeatureIndex
        } else {
            do {
                guard let resolvedFeatureIndex = try await resolveFeature(Feature.legacyBattery, deviceIndex: deviceIndex) else {
                    return nil
                }
                featureIndex = resolvedFeatureIndex
                caches[deviceIndex, default: DeviceCache()].legacyBatteryIndex = featureIndex
            } catch HIDPPError.invalidFeatureIndex {
                caches[deviceIndex, default: DeviceCache()].legacyBatteryIndex = nil
                return nil
            }
        }

        do {
            let status = try await send(
                deviceIndex: deviceIndex,
                featureIndex: featureIndex,
                functionID: 0
            )
            guard let percentage = status.first, (1...100).contains(percentage) else {
                return nil
            }
            return Int(percentage)
        } catch HIDPPError.invalidFeatureIndex {
            invalidate(deviceIndex: deviceIndex)
            return nil
        }
    }

    private func resolveFeature(_ featureID: UInt16, deviceIndex: UInt8) async throws -> UInt8? {
        let parameters = try await send(
            deviceIndex: deviceIndex,
            featureIndex: 0,
            functionID: 0,
            parameters: [UInt8(featureID >> 8), UInt8(featureID & 0xFF)]
        )
        guard let featureIndex = parameters.first, featureIndex != 0 else {
            return nil
        }
        return featureIndex
    }

    private func send(
        deviceIndex: UInt8,
        featureIndex: UInt8,
        functionID: UInt8,
        parameters: [UInt8] = []
    ) async throws -> [UInt8] {
        let packet = try HIDPPPacket.request(
            kind: .short,
            deviceIndex: deviceIndex,
            featureIndex: featureIndex,
            functionID: functionID,
            softwareID: 0x0D,
            parameters: parameters
        )
        let response = try await requester.send(packet)
        if let error = packet.protocolError(in: response) {
            throw error
        }
        guard packet.matchesResponse(response) else {
            throw HIDPPError.invalidPacket
        }
        return Array(response.dropFirst(4))
    }

    private func decodedName(from parameters: [UInt8]) -> String? {
        let bytes = parameters.prefix { $0 != 0 }
        guard let name = String(bytes: bytes, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return nil
        }
        return name
    }
}
