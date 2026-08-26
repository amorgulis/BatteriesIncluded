import XCTest
@testable import BatteriesIncluded

final class LogitechHIDDiscoveryTests: XCTestCase {
    func testSelectKeepsOnlyLogitechInterfacesWithBidirectionalHIDPPReports() {
        let candidates = [
            fixture(input: [0x11], output: [0x11]),
            fixture(id: "wrong-vendor", vendorID: 0x1234, input: [0x11], output: [0x11]),
            fixture(id: "input-only", input: [0x11], output: []),
            fixture(id: "output-only", input: [], output: [0x11]),
            fixture(id: "ordinary-hid", input: [0x01], output: [0x01])
        ]

        XCTAssertEqual(LogitechHIDDiscoveryPolicy.select(candidates).map(\.id), ["fixture"])
    }

    func testSelectRequiresTheSameHIDPPReportIDInBothDirections() {
        let candidate = fixture(input: [0x10], output: [0x11])

        XCTAssertTrue(LogitechHIDDiscoveryPolicy.select([candidate]).isEmpty)
    }

    func testSelectDeduplicatesPhysicalCollectionsPreferringLongReportSupport() {
        let short = fixture(id: "short", input: [0x10], output: [0x10])
        let long = fixture(id: "long", input: [0x11], output: [0x11])
        let other = fixture(
            id: "other",
            input: [0x10],
            output: [0x10],
            physicalKey: "usb:046d:c548:other"
        )

        XCTAssertEqual(
            LogitechHIDDiscoveryPolicy.select([short, other, long]).map(\.id),
            ["long", "other"]
        )
    }

    func testDirectIdentityUsesSerialNumber() {
        let descriptor = fixture(serialNumber: "unit-serial", locationID: 42, transport: "USB")

        XCTAssertEqual(
            descriptor.identity(deviceIndex: 0xFF).stableID,
            "logitech-hid:usb:046d:c548:serial:unit-serial"
        )
    }

    func testDirectIdentityFallsBackToTransportProductAndLocation() {
        let descriptor = fixture(serialNumber: nil, locationID: 42, transport: "USB")

        XCTAssertEqual(
            descriptor.identity(deviceIndex: 0xFF).stableID,
            "logitech-hid:usb:046d:c548:location:0000002a"
        )
    }

    func testReceiverChildrenHaveDistinctStableIDs() {
        let descriptor = fixture(serialNumber: "receiver")

        XCTAssertNotEqual(
            descriptor.identity(deviceIndex: 1).stableID,
            descriptor.identity(deviceIndex: 2).stableID
        )
    }

    func testDirectIdentityFallsBackToProductName() {
        let descriptor = fixture(productName: "MX Fixture")

        XCTAssertEqual(descriptor.identity(deviceIndex: 0xFF).name, "MX Fixture")
        XCTAssertFalse(descriptor.identity(deviceIndex: 0xFF).isReceiverChild)
    }

    func testReceiverChildDoesNotUseReceiverProductName() {
        let descriptor = fixture(productName: "USB Receiver")

        XCTAssertNil(descriptor.identity(deviceIndex: 1).name)
        XCTAssertTrue(descriptor.identity(deviceIndex: 1).isReceiverChild)
    }

    func testIdentityMapsMouseUsageToMouseCategory() {
        let descriptor = fixture(primaryUsagePage: 0x01, primaryUsage: 0x02)

        XCTAssertEqual(descriptor.identity(deviceIndex: 0xFF).category, .mouse)
    }

    func testIdentityMapsKeyboardUsageToKeyboardCategory() {
        let descriptor = fixture(primaryUsagePage: 0x01, primaryUsage: 0x06)

        XCTAssertEqual(descriptor.identity(deviceIndex: 0xFF).category, .keyboard)
    }

    private func fixture(
        id: String = "fixture",
        vendorID: Int = 0x046D,
        input: Set<UInt8> = [0x11],
        output: Set<UInt8> = [0x11],
        physicalKey: String = "usb:046d:c548:serial",
        serialNumber: String? = "serial",
        locationID: Int? = 1,
        transport: String? = "USB",
        productName: String? = "MX Fixture",
        primaryUsagePage: Int? = 1,
        primaryUsage: Int? = 2
    ) -> LogitechHIDInterfaceDescriptor {
        .init(
            id: id,
            physicalKey: physicalKey,
            vendorID: vendorID,
            productID: 0xC548,
            serialNumber: serialNumber,
            locationID: locationID,
            transport: transport,
            productName: productName,
            primaryUsagePage: primaryUsagePage,
            primaryUsage: primaryUsage,
            inputReportIDs: input,
            outputReportIDs: output
        )
    }
}
