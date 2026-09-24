import AppKit
import SwiftUI
import XCTest
@testable import BatteriesIncluded

@MainActor
final class DebugMenuVisibilityTests: XCTestCase {
    func testRefreshKeepsOpeningVisibilityWhenItemsChangeOrAreReplaced() {
        _ = NSApplication.shared
        for openingFlags: NSEvent.ModifierFlags in [[], [.option]] {
            var flags = openingFlags
            let visibility = DebugMenuVisibility(modifierFlags: { flags })
            let menu = NSMenu()
            let item = NSMenuItem(title: "Export Debug Snapshot…", action: nil, keyEquivalent: "")
            menu.addItem(item)
            withExtendedLifetime(visibility) {
                NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
                flags = openingFlags.isEmpty ? [.option] : []
                item.isHidden = false
                menu.itemChanged(item)
                XCTAssertEqual(item.isHidden, openingFlags.isEmpty)
                menu.removeItem(item)
                let replacement = NSMenuItem(title: "Export Debug Snapshot…", action: nil, keyEquivalent: "")
                menu.addItem(replacement)
                XCTAssertEqual(replacement.isHidden, openingFlags.isEmpty)
            }
        }
    }

    func testNativeMenuRechecksOptionEachTimeTrackingBegins() throws {
        guard #available(macOS 14.4, *) else { throw XCTSkip("Requires NSHostingMenu") }
        _ = NSApplication.shared
        var flags: NSEvent.ModifierFlags = []
        let visibility = DebugMenuVisibility(modifierFlags: { flags })
        let menu = NSHostingMenu(rootView: BatteryMenuView(monitor: DeviceMonitor(collectors: [])))
        menu.update()
        let item = try XCTUnwrap(menu.items.first { $0.title == "Export Debug Snapshot…" })
        withExtendedLifetime(visibility) {
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
            XCTAssertTrue(item.isHidden)
            flags = [.option]
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
            XCTAssertFalse(item.isHidden)
            flags = [.command]
            NotificationCenter.default.post(name: NSMenu.didBeginTrackingNotification, object: menu)
            XCTAssertTrue(item.isHidden)
        }
    }
}
