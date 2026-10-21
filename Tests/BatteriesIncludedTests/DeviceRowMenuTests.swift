import AppKit
import SwiftUI
import XCTest
@testable import BatteriesIncluded

@MainActor
final class DeviceRowMenuTests: XCTestCase {
    func testBatteryColumnsShareTheSameTrailingEdge() throws {
        guard #available(macOS 14.4, *) else {
            throw XCTSkip("NSHostingMenu requires macOS 14.4")
        }
        _ = NSApplication.shared
        let devices = [
            DeviceBattery(id: "mouse", name: "Mouse", category: .mouse, levels: [(.whole, 9)]),
            DeviceBattery(id: "keyboard", name: "Long Keyboard Name", category: .keyboard,
                          levels: [(.whole, 100)]),
            DeviceBattery(id: "earbuds", name: "Earbuds", category: .headphones,
                          levels: [(.left, 42), (.right, 85)])
        ]
        let width = DeviceRowView.contentWidth(for: devices)
        let menu = NSHostingMenu(rootView: ForEach(devices) { device in
            DeviceRowView(device: device, contentWidth: width)
        })
        menu.update()
        XCTAssertEqual(menu.items.count, devices.count)
        let titles = try menu.items.map { item in
            let title = NSMutableAttributedString(attributedString: try XCTUnwrap(item.attributedTitle))
            title.addAttribute(.font, value: NSFont.menuFont(ofSize: 0),
                               range: NSRange(location: 0, length: title.length))
            return title
        }
        let firstWidth = try XCTUnwrap(titles.first).size().width
        for title in titles {
            XCTAssertEqual(title.size().width, firstWidth, accuracy: 1,
                           "Battery status should end at the same position for every device")
        }
    }

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
