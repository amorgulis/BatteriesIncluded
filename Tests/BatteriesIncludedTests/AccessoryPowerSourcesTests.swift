import XCTest
@testable import BatteriesIncluded

final class AccessoryPowerSourcesTests: XCTestCase {
    private let device = SystemDeviceReading(address: "AA:BB:CC:DD:EE:FF", name: "Buds", isConnected: true, category: .headphones, percentages: [.left: 70])
    private func source(_ fields: [String: Any]) -> [String: Any] {
        ["Type": "Accessory Source", "Transport Type": "Bluetooth", "Name": "Buds", "Is Present": true].merging(fields) { _, new in new }
    }
    func testMatchesAddressAndPreservesIndependentPartStatesAndLevels() {
        let descriptions = [
            source(["Group Identifier": "aa-bb-cc-dd-ee-ff", "Part Identifier": "Left", "Is Charging": true]),
            source(["Group Identifier": "aa-bb-cc-dd-ee-ff", "Part Identifier": "Right", "Is Charged": true, "Current Capacity": 200, "Max Capacity": 200]),
            source(["Group Identifier": "aa-bb-cc-dd-ee-ff", "Part Identifier": "Case", "Power Source State": "Battery Power", "Current Capacity": 50, "Max Capacity": 200])
        ]
        let readings = AccessoryPowerSources.enrich([device], descriptions: descriptions)
        let result = SystemBluetoothCollector.map(readings[0], now: .distantPast)
        XCTAssertEqual(result.map(\.component), [.left, .right, .case])
        XCTAssertEqual(result.map(\.percentage), [70, 100, 25])
        XCTAssertEqual(result.map(\.chargingState), [.charging, .full, .discharging])
    }
    func testUnknownStatusDoesNotInventDischargingOrFull() {
        for fields: [String: Any] in [["Is Charging": 2], ["Is Charged": -1], ["Is Charging": false], ["Is Charging": false, "Power Source State": "AC Power"], ["Current Capacity": 100, "Max Capacity": 100]] {
            let reading = AccessoryPowerSources.enrich([device], descriptions: [source(fields)])[0]
            XCTAssertTrue(reading.chargingStates[.whole] == nil || reading.chargingStates[.whole] == .unknown)
        }
    }
    func testRejectsAmbiguousNamesAndDisconnectedOrUnrelatedSources() {
        let duplicate = SystemDeviceReading(address: "11:22:33:44:55:66", name: "Buds", isConnected: true, category: .headphones, percentages: [:])
        XCTAssertTrue(AccessoryPowerSources.enrich([device, duplicate], descriptions: [source(["Is Charging": true])]).allSatisfy { $0.chargingStates.isEmpty })
        for fields: [String: Any] in [["Is Present": false], ["Transport Type": "USB"], ["Type": "InternalBattery"], ["Accessory Identifier": "11:22:33:44:55:66"]] {
            XCTAssertTrue(AccessoryPowerSources.enrich([device], descriptions: [source(fields.merging(["Is Charging": true]) { _, new in new })])[0].chargingStates.isEmpty)
        }
    }
    func testRejectsMultipleAccessoryGroupsWithSameName() {
        let descriptions = [source(["Group Identifier": "group1", "Is Charging": true]), source(["Group Identifier": "group2", "Is Charging": true])]
        XCTAssertTrue(AccessoryPowerSources.enrich([device], descriptions: descriptions)[0].chargingStates.isEmpty)
    }
    func testGroupSharesAddressMatchAcrossPartsDespiteDuplicateNames() {
        let duplicate = SystemDeviceReading(address: "11:22:33:44:55:66", name: "Buds", isConnected: true, category: .headphones, percentages: [:])
        let descriptions = [
            source(["Group Identifier": "group1", "Accessory Identifier": "AA:BB:CC:DD:EE:FF", "Part Identifier": "Left", "Is Charging": true]),
            source(["Group Identifier": "group1", "Accessory Identifier": "part-right", "Part Identifier": "Right", "Is Charged": true])
        ]
        let result = AccessoryPowerSources.enrich([device, duplicate], descriptions: descriptions)
        XCTAssertEqual(result[0].chargingStates[.right], .full)
        XCTAssertTrue(result[1].chargingStates.isEmpty)
    }

    func testNativeZeroPartLevelIsPreservedAsExplicitUnknownState() {
        let result = AccessoryPowerSources.enrich([device], descriptions: [source(["Part Identifier": "Case", "Current Capacity": 0, "Max Capacity": 100])])
        XCTAssertEqual(result[0].chargingStates[.case], .unknown)
    }

    func testCombinedPartsKeepIndividualStatusesWithoutInheritingSummaryState() {
        let descriptions = [source(["Group Identifier": "AA:BB:CC:DD:EE:FF", "Part Identifier": "Combined", "Is Charging": true,
            "Combined Parts": [["Part Identifier": "Left", "Is Charged": true], ["Part Identifier": "Right", "Current Capacity": 0, "Max Capacity": 100]]])]
        let result = AccessoryPowerSources.enrich([device], descriptions: descriptions)[0]
        XCTAssertEqual(result.chargingStates[.whole], .charging)
        XCTAssertEqual(result.chargingStates[.left], .full)
        XCTAssertEqual(result.chargingStates[.right], .unknown)
    }

    func testChargingWithoutLevelStillProducesPartObservation() {
        let reading = AccessoryPowerSources.enrich([device], descriptions: [source(["Part Identifier": "Case", "Is Charging": true])])[0]
        let result = SystemBluetoothCollector.map(reading, now: .distantPast)
        XCTAssertEqual(result.map(\.component), [.left, .case])
        XCTAssertEqual(result.last?.chargingState, .charging)
        XCTAssertNil(result.last?.percentage)
    }
}
