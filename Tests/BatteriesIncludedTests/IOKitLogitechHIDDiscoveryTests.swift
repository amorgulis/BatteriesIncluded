import IOKit
import XCTest
@testable import BatteriesIncluded

final class IOKitLogitechHIDDiscoveryTests: XCTestCase {
    func testManagerPermissionDenialDoesNotDiscardEnumeratedHIDPPInterfaces() {
        XCTAssertTrue(IOKitLogitechHIDDiscovery.canUseEnumeratedDevices(
            managerOpenResult: kIOReturnNotPermitted,
            deviceSetAvailable: true
        ))
    }

    func testMissingDeviceSetCannotBeEnumerated() {
        XCTAssertFalse(IOKitLogitechHIDDiscovery.canUseEnumeratedDevices(
            managerOpenResult: kIOReturnSuccess,
            deviceSetAvailable: false
        ))
    }
}
