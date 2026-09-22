import AppKit
import SwiftUI
import XCTest
@testable import BatteriesIncluded

@MainActor
final class DeviceRowMenuTests: XCTestCase {
    func testDeviceRowUsesUndimmedNativeMenuItem() throws {
        guard #available(macOS 14.4, *) else {
            throw XCTSkip("NSHostingMenu requires macOS 14.4")
        }
        _ = NSApplication.shared
        let device = DeviceBattery(id: "mouse", name: "Mouse", category: .mouse,
                                   levels: [(.whole, 42)], chargingState: .charging)
        let menu = NSHostingMenu(rootView: DeviceRowView(device: device))
        menu.update()
        let item = try XCTUnwrap(menu.items.first)
        XCTAssertTrue(item.title.contains("Mouse"))
        XCTAssertTrue(item.isEnabled, "Disabled native menu items dim their text regardless of SwiftUI foreground color")
    }
}
