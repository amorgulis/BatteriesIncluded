import XCTest
@testable import BatteriesIncluded

final class BLEBatteryStatusTests: XCTestCase {
    func testExplicitPowerStateAndFaults() {
        XCTAssertEqual(BLEBatteryStatus.decode(Data([0, 0x21, 0])), .charging)
        XCTAssertEqual(BLEBatteryStatus.decode(Data([0, 0x41, 0])), .discharging)
        XCTAssertEqual(BLEBatteryStatus.decode(Data([0, 0x61, 0])), .discharging)
        XCTAssertEqual(BLEBatteryStatus.decode(Data([0, 1, 0])), .unknown)
        XCTAssertEqual(BLEBatteryStatus.decode(Data([0, 0x20, 0])), .unknown)
        XCTAssertEqual(BLEBatteryStatus.decode(Data([0, 0x21, 0x10])), .unknown)
        XCTAssertEqual(BLEBatteryStatus.decode(Data([0, 0x21, 0x20])), .unknown)
        XCTAssertEqual(BLEBatteryStatus.decode(Data([0, 0x21, 0x40])), .unknown)
        XCTAssertEqual(BLEBatteryStatus.decode(Data([4, 0x21, 0, 4])), .unknown)
    }

    func testOptionalFieldsAndTruncationNeverInferFull() {
        XCTAssertEqual(BLEBatteryStatus.decode(Data([7, 0x21, 0, 5, 0, 100, 0])), .charging)
        XCTAssertEqual(BLEBatteryStatus.decode(Data([2, 0x61, 0, 100])), .discharging)
        XCTAssertEqual(BLEBatteryStatus.decode(Data([4, 0x61, 0, 8])), .discharging)
        for bytes: [UInt8] in [[], [0], [0, 1], [1, 0x21, 0], [2, 0x21, 0], [4, 0x21, 0]] {
            XCTAssertEqual(BLEBatteryStatus.decode(Data(bytes)), .unknown)
        }
    }

    func testReadCoordinationWaitsForBothAndRetainsPartialLevel() {
        var read = BLEBatteryReadProgress(awaitingLevel: true, awaitingStatus: true)
        read.receiveLevel(72)
        XCTAssertFalse(read.isFinished)
        XCTAssertEqual(read.level, 72)
        read.receiveStatus(.unknown)
        XCTAssertTrue(read.isFinished)
        XCTAssertEqual(read.level, 72)
        XCTAssertEqual(read.chargingState, .unknown)
    }

    func testLevelOnlyAndStatusFirst() {
        var levelOnly = BLEBatteryReadProgress(awaitingLevel: true, awaitingStatus: false)
        levelOnly.receiveLevel(100)
        XCTAssertTrue(levelOnly.isFinished)
        XCTAssertNil(levelOnly.chargingState)
        var both = BLEBatteryReadProgress(awaitingLevel: true, awaitingStatus: true)
        both.receiveStatus(.charging)
        XCTAssertFalse(both.isFinished)
        both.receiveLevel(nil)
        XCTAssertTrue(both.isFinished)
        XCTAssertEqual(both.chargingState, .charging)
    }
}
