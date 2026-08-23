import Foundation
@preconcurrency import CoreBluetooth

struct BLEDeviceReading: Sendable {
    let identifier: UUID
    let name: String
    let isConnected: Bool
    let batteryLevel: Int?
}

actor CoreBluetoothCollector: BatteryCollecting {
    private let state: CoreBluetoothCollectionState
    private let bridge: CoreBluetoothDelegateBridge

    init() {
        let state = CoreBluetoothCollectionState()
        self.state = state
        self.bridge = CoreBluetoothDelegateBridge(state: state)
    }

    func collect() async -> CollectorSnapshot {
        await state.collect(using: bridge)
    }

    nonisolated static func map(_ reading: BLEDeviceReading, now: Date) -> [BatteryObservation] {
        guard reading.isConnected else { return [] }

        let identifier = reading.identifier.uuidString
        return [
            BatteryObservation(
                sourceID: identifier,
                stableID: identifier,
                name: reading.name,
                isConnected: true,
                category: nil,
                component: .whole,
                percentage: reading.batteryLevel,
                source: .coreBluetooth,
                observedAt: now
            )
        ]
    }
}

private actor CoreBluetoothCollectionState {
    private static let timeoutNanoseconds: UInt64 = 2_000_000_000

    private struct PendingCollection {
        let continuation: CheckedContinuation<CollectorSnapshot, Never>
        let bridge: CoreBluetoothDelegateBridge
        var availability: BluetoothAvailability?
        var devices: [UUID: BLEDeviceReading] = [:]
        var awaiting: Set<UUID> = []
        var finishedBeforeResolution: Set<UUID> = []
        var timeoutTask: Task<Void, Never>?
    }

    private var batteryLevels: [UUID: Int] = [:]
    private var pendingCollections: [UUID: PendingCollection] = [:]

    func collect(using bridge: CoreBluetoothDelegateBridge) async -> CollectorSnapshot {
        let requestID = UUID()

        return await withCheckedContinuation { continuation in
            pendingCollections[requestID] = PendingCollection(
                continuation: continuation,
                bridge: bridge
            )

            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: Self.timeoutNanoseconds)
                guard !Task.isCancelled else { return }
                await self?.timeOut(requestID)
            }

            if var pending = pendingCollections[requestID] {
                pending.timeoutTask = timeoutTask
                pendingCollections[requestID] = pending
                bridge.retrieveConnectedPeripherals(for: requestID)
            } else {
                timeoutTask.cancel()
            }
        }
    }

    func resolve(
        requestID: UUID,
        availability: BluetoothAvailability,
        devices: [BLEDeviceReading]
    ) {
        guard var pending = pendingCollections[requestID] else { return }

        pending.availability = availability
        guard availability == .available else {
            pendingCollections[requestID] = pending
            finish(requestID, availability: availability)
            return
        }

        pending.devices = Dictionary(uniqueKeysWithValues: devices.map { ($0.identifier, $0) })
        pending.awaiting = Set(pending.devices.keys)
        pending.awaiting.subtract(pending.finishedBeforeResolution)
        pendingCollections[requestID] = pending

        if pending.awaiting.isEmpty || pending.devices.keys.allSatisfy({ batteryLevels[$0] != nil }) {
            finish(requestID, availability: .available)
        }
    }

    func record(_ reading: BLEDeviceReading, for requestIDs: [UUID]) {
        if let level = reading.batteryLevel {
            batteryLevels[reading.identifier] = level
        }

        for requestID in requestIDs {
            guard var pending = pendingCollections[requestID] else { continue }

            pending.devices[reading.identifier] = reading
            if pending.availability == nil {
                pending.finishedBeforeResolution.insert(reading.identifier)
            } else {
                pending.awaiting.remove(reading.identifier)
            }
            pendingCollections[requestID] = pending

            if pending.availability == .available && pending.awaiting.isEmpty {
                finish(requestID, availability: .available)
            }
        }
    }

    func managerDidBecomeUnavailable(_ availability: BluetoothAvailability) {
        guard availability != .available else { return }
        for requestID in Array(pendingCollections.keys) {
            finish(requestID, availability: availability)
        }
    }

    private func timeOut(_ requestID: UUID) {
        guard let pending = pendingCollections[requestID] else { return }
        finish(requestID, availability: pending.availability ?? .unavailable)
    }

    private func finish(_ requestID: UUID, availability: BluetoothAvailability) {
        guard let pending = pendingCollections.removeValue(forKey: requestID) else { return }

        pending.timeoutTask?.cancel()
        pending.bridge.cancel(requestID: requestID)

        let observations: [BatteryObservation]
        if availability == .available {
            observations = pending.devices.values
                .sorted { $0.identifier.uuidString < $1.identifier.uuidString }
                .flatMap { device in
                    let reading = BLEDeviceReading(
                        identifier: device.identifier,
                        name: device.name,
                        isConnected: device.isConnected,
                        batteryLevel: batteryLevels[device.identifier] ?? device.batteryLevel
                    )
                    return CoreBluetoothCollector.map(reading, now: .now)
                }
        } else {
            observations = []
        }

        pending.continuation.resume(
            returning: CollectorSnapshot(
                availability: availability,
                observations: observations
            )
        )
    }
}

private final class CoreBluetoothDelegateBridge: NSObject, @unchecked Sendable {
    private static let batteryService = CBUUID(string: "180F")
    private static let batteryLevelCharacteristic = CBUUID(string: "2A19")

    private let queue = DispatchQueue(label: "BatteriesIncluded.CoreBluetoothCollector")
    private let state: CoreBluetoothCollectionState
    private var centralManager: CBCentralManager?
    private var waitingForManager: Set<UUID> = []
    private var requestIDsByPeripheral: [UUID: Set<UUID>] = [:]
    private var peripheralsByIdentifier: [UUID: CBPeripheral] = [:]

    init(state: CoreBluetoothCollectionState) {
        self.state = state
        super.init()

        queue.async { [self] in
            centralManager = CBCentralManager(delegate: self, queue: queue)
        }
    }

    func retrieveConnectedPeripherals(for requestID: UUID) {
        queue.async { [self] in
            guard let centralManager else {
                waitingForManager.insert(requestID)
                return
            }
            beginRequest(requestID, centralManager: centralManager)
        }
    }

    func cancel(requestID: UUID) {
        queue.async { [self] in
            waitingForManager.remove(requestID)
            for identifier in Array(requestIDsByPeripheral.keys) {
                requestIDsByPeripheral[identifier]?.remove(requestID)
                if requestIDsByPeripheral[identifier]?.isEmpty == true {
                    requestIDsByPeripheral.removeValue(forKey: identifier)
                }
            }
        }
    }

    private func beginRequest(_ requestID: UUID, centralManager: CBCentralManager) {
        guard let availability = availability(for: centralManager) else {
            waitingForManager.insert(requestID)
            return
        }

        guard availability == .available else {
            resolve(requestID: requestID, availability: availability, devices: [])
            return
        }

        let peripherals = centralManager
            .retrieveConnectedPeripherals(withServices: [Self.batteryService])
            .filter { $0.state == .connected }

        let devices = peripherals.map { peripheral in
            BLEDeviceReading(
                identifier: peripheral.identifier,
                name: peripheral.name ?? peripheral.identifier.uuidString,
                isConnected: true,
                batteryLevel: nil
            )
        }
        resolve(requestID: requestID, availability: .available, devices: devices)

        for peripheral in peripherals {
            peripheralsByIdentifier[peripheral.identifier] = peripheral
            requestIDsByPeripheral[peripheral.identifier, default: []].insert(requestID)
            peripheral.delegate = self
            discoverBatteryLevel(on: peripheral)
        }
    }

    private func discoverBatteryLevel(on peripheral: CBPeripheral) {
        if let service = peripheral.services?.first(where: { $0.uuid == Self.batteryService }) {
            discoverBatteryLevel(on: peripheral, service: service)
        } else {
            peripheral.discoverServices([Self.batteryService])
        }
    }

    private func discoverBatteryLevel(on peripheral: CBPeripheral, service: CBService) {
        if let characteristic = service.characteristics?.first(where: {
            $0.uuid == Self.batteryLevelCharacteristic
        }) {
            readBatteryLevel(on: peripheral, characteristic: characteristic)
        } else {
            peripheral.discoverCharacteristics([Self.batteryLevelCharacteristic], for: service)
        }
    }

    private func readBatteryLevel(on peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        let cachedLevel = characteristic.value.flatMap(Self.batteryLevel(from:))
        if let cachedLevel {
            completeRequests(for: peripheral, batteryLevel: cachedLevel)
        }

        if characteristic.properties.contains(.read) {
            peripheral.readValue(for: characteristic)
        } else if cachedLevel == nil {
            completeRequests(for: peripheral, batteryLevel: nil)
        }
    }

    private func completeRequests(for peripheral: CBPeripheral, batteryLevel: Int?) {
        let requestIDs = Array(requestIDsByPeripheral.removeValue(forKey: peripheral.identifier) ?? [])
        let reading = BLEDeviceReading(
            identifier: peripheral.identifier,
            name: peripheral.name ?? peripheral.identifier.uuidString,
            isConnected: peripheral.state == .connected,
            batteryLevel: batteryLevel
        )
        let state = state
        Task {
            await state.record(reading, for: requestIDs)
        }
    }

    private func resolve(
        requestID: UUID,
        availability: BluetoothAvailability,
        devices: [BLEDeviceReading]
    ) {
        let state = state
        Task {
            await state.resolve(
                requestID: requestID,
                availability: availability,
                devices: devices
            )
        }
    }

    private func availability(for centralManager: CBCentralManager) -> BluetoothAvailability? {
        switch CBManager.authorization {
        case .denied, .restricted:
            return .permissionDenied
        case .allowedAlways, .notDetermined:
            break
        @unknown default:
            return .unavailable
        }

        switch centralManager.state {
        case .unknown, .resetting:
            return nil
        case .unsupported:
            return .unavailable
        case .unauthorized:
            return .permissionDenied
        case .poweredOff:
            return .poweredOff
        case .poweredOn:
            return .available
        @unknown default:
            return .unavailable
        }
    }

    private static func batteryLevel(from data: Data) -> Int? {
        data.first.map(Int.init)
    }
}

extension CoreBluetoothDelegateBridge: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard let availability = availability(for: central) else { return }

        if availability == .available {
            let requestIDs = Array(waitingForManager)
            waitingForManager.removeAll()
            for requestID in requestIDs {
                beginRequest(requestID, centralManager: central)
            }
        } else {
            waitingForManager.removeAll()
            requestIDsByPeripheral.removeAll()
            peripheralsByIdentifier.removeAll()
            let state = state
            Task {
                await state.managerDidBecomeUnavailable(availability)
            }
        }
    }
}

extension CoreBluetoothDelegateBridge: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == Self.batteryService }) else {
            completeRequests(for: peripheral, batteryLevel: nil)
            return
        }

        discoverBatteryLevel(on: peripheral, service: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil,
              let characteristic = service.characteristics?.first(where: {
                  $0.uuid == Self.batteryLevelCharacteristic
              }) else {
            completeRequests(for: peripheral, batteryLevel: nil)
            return
        }

        readBatteryLevel(on: peripheral, characteristic: characteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == Self.batteryLevelCharacteristic else { return }
        let level = error == nil ? characteristic.value.flatMap(Self.batteryLevel(from:)) : nil
        completeRequests(for: peripheral, batteryLevel: level)
    }
}
