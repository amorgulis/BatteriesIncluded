import Foundation
@preconcurrency import CoreBluetooth

struct BLEDeviceReading: Sendable {
    let identifier: UUID
    let name: String
    let isConnected: Bool
    let batteryLevel: Int?
}

enum BLEManagerDisposition: Sendable, Equatable {
    case waitForInitialState
    case collect
    case finish(BluetoothAvailability)
}

enum BLEManagerStateMapper {
    static func disposition(
        authorization: CBManagerAuthorization,
        state: CBManagerState
    ) -> BLEManagerDisposition {
        switch authorization {
        case .denied, .restricted:
            return .finish(.permissionDenied)
        case .allowedAlways, .notDetermined:
            break
        @unknown default:
            return .finish(.unavailable)
        }

        switch state {
        case .unknown:
            return .waitForInitialState
        case .resetting:
            return .finish(.unavailable)
        case .unsupported:
            return .finish(.unavailable)
        case .unauthorized:
            return .finish(.permissionDenied)
        case .poweredOff:
            return .finish(.poweredOff)
        case .poweredOn:
            return .collect
        @unknown default:
            return .finish(.unavailable)
        }
    }
}

protocol BLECollectionBridging: Sendable {
    func retrieveConnectedPeripherals(for requestID: UUID)
    func cancel(requestID: UUID)
}

protocol BLEConnectedPeripheralRetrieving: AnyObject {
    func retrieveConnectedPeripherals(withServices serviceUUIDs: [CBUUID]) -> [CBPeripheral]
}

extension CBCentralManager: BLEConnectedPeripheralRetrieving {}

enum BLEConnectedPeripheralRetriever {
    static let batteryService = CBUUID(string: "180F")

    static func retrieve(from centralManager: any BLEConnectedPeripheralRetrieving) -> [CBPeripheral] {
        centralManager
            .retrieveConnectedPeripherals(withServices: [batteryService])
            .filter { $0.state == .connected }
    }
}

struct BLEPeripheralOperationRegistry<Peripheral> {
    private var peripheralsByIdentifier: [UUID: Peripheral] = [:]
    private var requestIDsByPeripheral: [UUID: Set<UUID>] = [:]
    private var activeOperations: Set<UUID> = []

    var retainedIdentifiers: Set<UUID> {
        Set(peripheralsByIdentifier.keys)
    }

    func peripheral(for identifier: UUID) -> Peripheral? {
        peripheralsByIdentifier[identifier]
    }

    mutating func attach(
        _ peripheral: Peripheral,
        identifier: UUID,
        requestID: UUID
    ) -> Bool {
        requestIDsByPeripheral[identifier, default: []].insert(requestID)

        let shouldStartOperation = !activeOperations.contains(identifier)
        if shouldStartOperation {
            peripheralsByIdentifier[identifier] = peripheral
            activeOperations.insert(identifier)
        }
        return shouldStartOperation
    }

    mutating func cancel(requestID: UUID) {
        for identifier in Array(requestIDsByPeripheral.keys) {
            requestIDsByPeripheral[identifier]?.remove(requestID)
            if requestIDsByPeripheral[identifier]?.isEmpty == true {
                requestIDsByPeripheral.removeValue(forKey: identifier)
            }
            releaseIfIdle(identifier)
        }
    }

    mutating func complete(identifier: UUID, operationFinished: Bool) -> [UUID]? {
        guard peripheralsByIdentifier[identifier] != nil else { return nil }
        let requestIDs = Array(requestIDsByPeripheral.removeValue(forKey: identifier) ?? [])
        if operationFinished {
            activeOperations.remove(identifier)
        }
        releaseIfIdle(identifier)
        return requestIDs
    }

    mutating func invalidate(identifier: UUID) -> [UUID] {
        activeOperations.remove(identifier)
        peripheralsByIdentifier.removeValue(forKey: identifier)
        return Array(requestIDsByPeripheral.removeValue(forKey: identifier) ?? [])
    }

    mutating func invalidateAll() {
        activeOperations.removeAll()
        requestIDsByPeripheral.removeAll()
        peripheralsByIdentifier.removeAll()
    }

    private mutating func releaseIfIdle(_ identifier: UUID) {
        guard requestIDsByPeripheral[identifier] == nil,
              !activeOperations.contains(identifier) else { return }
        peripheralsByIdentifier.removeValue(forKey: identifier)
    }
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

actor CoreBluetoothCollectionState {
    private let timeoutNanoseconds: UInt64

    private struct PendingCollection {
        let continuation: CheckedContinuation<CollectorSnapshot, Never>
        let bridge: any BLECollectionBridging
        var availability: BluetoothAvailability?
        var devices: [UUID: BLEDeviceReading] = [:]
        var awaiting: Set<UUID> = []
        var finishedBeforeResolution: Set<UUID> = []
        var timeoutTask: Task<Void, Never>?
    }

    private var batteryLevels: [UUID: Int] = [:]
    private var pendingCollections: [UUID: PendingCollection] = [:]
    private var managerGeneration: UInt64 = 0

    init(timeoutNanoseconds: UInt64 = 2_000_000_000) {
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    func collect(using bridge: any BLECollectionBridging) async -> CollectorSnapshot {
        let requestID = UUID()

        return await withCheckedContinuation { continuation in
            pendingCollections[requestID] = PendingCollection(
                continuation: continuation,
                bridge: bridge
            )

            let timeoutNanoseconds = timeoutNanoseconds
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
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

    func record(
        _ reading: BLEDeviceReading,
        for requestIDs: [UUID],
        generation: UInt64? = nil
    ) {
        if let generation, generation != managerGeneration { return }

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

    func managerDidBecomeUnavailable(
        _ availability: BluetoothAvailability,
        generation: UInt64? = nil
    ) {
        guard availability != .available else { return }
        if let generation {
            guard generation >= managerGeneration else { return }
            managerGeneration = generation
        }
        batteryLevels.removeAll()
        for requestID in Array(pendingCollections.keys) {
            finish(requestID, availability: availability)
        }
    }

    func timeOut(_ requestID: UUID) {
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

private final class CoreBluetoothDelegateBridge: NSObject, BLECollectionBridging, @unchecked Sendable {
    private static let batteryLevelCharacteristic = CBUUID(string: "2A19")

    private let queue = DispatchQueue(label: "BatteriesIncluded.CoreBluetoothCollector")
    private let state: CoreBluetoothCollectionState
    private var centralManager: CBCentralManager?
    private var waitingForManager: Set<UUID> = []
    private var peripheralOperations = BLEPeripheralOperationRegistry<CBPeripheral>()
    private var managerGeneration: UInt64 = 0

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
            peripheralOperations.cancel(requestID: requestID)
        }
    }

    private func beginRequest(_ requestID: UUID, centralManager: CBCentralManager) {
        switch BLEManagerStateMapper.disposition(
            authorization: CBManager.authorization,
            state: centralManager.state
        ) {
        case .waitForInitialState:
            waitingForManager.insert(requestID)
            return
        case .finish(let availability):
            waitingForManager.removeAll()
            peripheralOperations.invalidateAll()
            managerGeneration &+= 1
            let generation = managerGeneration
            let state = state
            Task {
                await state.managerDidBecomeUnavailable(availability, generation: generation)
            }
            return
        case .collect:
            break
        }

        removeDisconnectedPeripherals()

        let peripherals = BLEConnectedPeripheralRetriever.retrieve(from: centralManager)

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
            let shouldStartOperation = peripheralOperations.attach(
                peripheral,
                identifier: peripheral.identifier,
                requestID: requestID
            )
            guard shouldStartOperation else { continue }
            peripheral.delegate = self
            discoverBatteryLevel(on: peripheral)
        }
    }

    private func discoverBatteryLevel(on peripheral: CBPeripheral) {
        if let service = peripheral.services?.first(where: {
            $0.uuid == BLEConnectedPeripheralRetriever.batteryService
        }) {
            discoverBatteryLevel(on: peripheral, service: service)
        } else {
            peripheral.discoverServices([BLEConnectedPeripheralRetriever.batteryService])
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
        let isReadable = characteristic.properties.contains(.read)
        if let cachedLevel {
            completeRequests(
                for: peripheral,
                batteryLevel: cachedLevel,
                operationFinished: !isReadable
            )
        }

        if isReadable {
            peripheral.readValue(for: characteristic)
        } else if cachedLevel == nil {
            completeRequests(for: peripheral, batteryLevel: nil)
        }
    }

    private func completeRequests(
        for peripheral: CBPeripheral,
        batteryLevel: Int?,
        operationFinished: Bool = true
    ) {
        guard peripheralOperations.peripheral(for: peripheral.identifier) === peripheral,
              let requestIDs = peripheralOperations.complete(
                  identifier: peripheral.identifier,
                  operationFinished: operationFinished
              ) else { return }
        let reading = BLEDeviceReading(
            identifier: peripheral.identifier,
            name: peripheral.name ?? peripheral.identifier.uuidString,
            isConnected: peripheral.state == .connected,
            batteryLevel: batteryLevel
        )
        let state = state
        let generation = managerGeneration
        Task {
            await state.record(reading, for: requestIDs, generation: generation)
        }
    }

    private func removeDisconnectedPeripherals() {
        for identifier in peripheralOperations.retainedIdentifiers {
            guard let peripheral = peripheralOperations.peripheral(for: identifier),
                  peripheral.state != .connected else { continue }
            let requestIDs = peripheralOperations.invalidate(identifier: identifier)
            let reading = BLEDeviceReading(
                identifier: identifier,
                name: peripheral.name ?? identifier.uuidString,
                isConnected: false,
                batteryLevel: nil
            )
            let state = state
            let generation = managerGeneration
            Task {
                await state.record(reading, for: requestIDs, generation: generation)
            }
        }
    }

    private func isCurrent(_ peripheral: CBPeripheral) -> Bool {
        peripheralOperations.peripheral(for: peripheral.identifier) === peripheral
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

    private static func batteryLevel(from data: Data) -> Int? {
        data.first.map(Int.init)
    }
}

extension CoreBluetoothDelegateBridge: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch BLEManagerStateMapper.disposition(
            authorization: CBManager.authorization,
            state: central.state
        ) {
        case .waitForInitialState:
            return
        case .collect:
            let requestIDs = Array(waitingForManager)
            waitingForManager.removeAll()
            for requestID in requestIDs {
                beginRequest(requestID, centralManager: central)
            }
        case .finish(let availability):
            waitingForManager.removeAll()
            peripheralOperations.invalidateAll()
            managerGeneration &+= 1
            let generation = managerGeneration
            let state = state
            Task {
                await state.managerDidBecomeUnavailable(availability, generation: generation)
            }
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard isCurrent(peripheral) else { return }
        let requestIDs = peripheralOperations.invalidate(identifier: peripheral.identifier)
        let reading = BLEDeviceReading(
            identifier: peripheral.identifier,
            name: peripheral.name ?? peripheral.identifier.uuidString,
            isConnected: false,
            batteryLevel: nil
        )
        let state = state
        let generation = managerGeneration
        Task {
            await state.record(reading, for: requestIDs, generation: generation)
        }
    }
}

extension CoreBluetoothDelegateBridge: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard isCurrent(peripheral) else { return }
        guard error == nil,
              let service = peripheral.services?.first(where: {
                  $0.uuid == BLEConnectedPeripheralRetriever.batteryService
              }) else {
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
        guard isCurrent(peripheral) else { return }
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
        guard isCurrent(peripheral) else { return }
        guard characteristic.uuid == Self.batteryLevelCharacteristic else { return }
        let level = error == nil ? characteristic.value.flatMap(Self.batteryLevel(from:)) : nil
        completeRequests(for: peripheral, batteryLevel: level)
    }
}
