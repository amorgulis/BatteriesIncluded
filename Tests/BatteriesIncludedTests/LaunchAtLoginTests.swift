import ServiceManagement
import XCTest
@testable import BatteriesIncluded

@MainActor
final class LaunchAtLoginTests: XCTestCase {
    func testRefreshReflectsExternalChanges() {
        var status = SMAppService.Status.notRegistered
        let setting = LaunchAtLogin(status: { status }, register: {}, unregister: {})
        XCTAssertFalse(setting.isEnabled)
        status = .enabled
        setting.refresh()
        XCTAssertTrue(setting.isEnabled)
        status = .requiresApproval
        setting.refresh()
        XCTAssertFalse(setting.isEnabled)
        XCTAssertTrue(setting.requiresApproval)
    }

    func testFailedChangeKeepsSystemStateAndPropagatesError() {
        struct RegistrationError: Error {}
        let setting = LaunchAtLogin(status: { .notRegistered }, register: {
            throw RegistrationError()
        }, unregister: {})
        XCTAssertThrowsError(try setting.setEnabled(true))
        XCTAssertFalse(setting.isEnabled)
    }

    func testEnableAndDisableReflectServiceResult() throws {
        var status = SMAppService.Status.notRegistered
        let setting = LaunchAtLogin(status: { status }, register: {
            status = .enabled
        }, unregister: {
            status = .notRegistered
        })
        try setting.setEnabled(true)
        XCTAssertTrue(setting.isEnabled)
        try setting.setEnabled(false)
        XCTAssertFalse(setting.isEnabled)
    }
}
