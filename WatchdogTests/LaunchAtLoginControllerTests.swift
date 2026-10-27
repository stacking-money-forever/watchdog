import XCTest
@testable import Watchdog

@MainActor
final class LaunchAtLoginControllerTests: XCTestCase {
    func testFirstLaunchRegistersAutomatically() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = FakeLaunchAtLoginService(status: .notRegistered)

        let controller = LaunchAtLoginController(defaults: defaults, service: service)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertFalse(controller.requiresApproval)
    }

    func testFreshInstallReportingNotFoundRegistersOnce() {
        // SMAppService.mainApp reports .notFound for an app Background Task
        // Management has never seen; that is the real first-launch state.
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = FakeLaunchAtLoginService(status: .notFound)

        let controller = LaunchAtLoginController(defaults: defaults, service: service)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(defaults.string(forKey: "launchAtLogin.lastStatus"), "enabled")
    }

    func testNotFoundAfterUserRemovedLoginItemDoesNotReregister() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "launchAtLogin.didAutoRegister")
        defaults.set("0.2.5 (10)", forKey: "launchAtLogin.registeredBuild")
        let service = FakeLaunchAtLoginService(status: .notFound)

        _ = LaunchAtLoginController(defaults: defaults, service: service, currentBuild: "0.2.5 (10)")

        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertEqual(defaults.string(forKey: "launchAtLogin.lastStatus"), "notFound")
    }

    func testUpdateToANewBuildReregistersAfterNotFound() {
        // An ad-hoc signed update has a new code identity, which Background
        // Task Management reports as .notFound even though it was registered.
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        _ = LaunchAtLoginController(
            defaults: defaults,
            service: FakeLaunchAtLoginService(status: .notFound),
            currentBuild: "0.2.4 (9)"
        )

        let updated = FakeLaunchAtLoginService(status: .notFound)
        let controller = LaunchAtLoginController(defaults: defaults, service: updated, currentBuild: "0.2.5 (10)")

        XCTAssertEqual(updated.registerCallCount, 1)
        XCTAssertTrue(controller.isEnabled)
    }

    func testUpdateFromBuildWithoutRecordReregisters() {
        // 0.2.4 set didAutoRegister but did not record the build.
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "launchAtLogin.didAutoRegister")
        let service = FakeLaunchAtLoginService(status: .notFound)

        _ = LaunchAtLoginController(defaults: defaults, service: service, currentBuild: "0.2.5 (10)")

        XCTAssertEqual(service.registerCallCount, 1)
    }

    func testUpdateDoesNotOverrideOptOut() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "launchAtLogin.didAutoRegister")
        defaults.set(true, forKey: "launchAtLogin.userOptedOut")
        let service = FakeLaunchAtLoginService(status: .notFound)

        _ = LaunchAtLoginController(defaults: defaults, service: service, currentBuild: "0.2.5 (10)")

        XCTAssertEqual(service.registerCallCount, 0)
    }

    func testNotFoundWithOptOutDoesNotRegister() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "launchAtLogin.userOptedOut")
        let service = FakeLaunchAtLoginService(status: .notFound)

        _ = LaunchAtLoginController(defaults: defaults, service: service)

        XCTAssertEqual(service.registerCallCount, 0)
    }

    func testApprovalStateIsShownWithoutRepeatedRegistration() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = FakeLaunchAtLoginService(status: .requiresApproval)

        let controller = LaunchAtLoginController(defaults: defaults, service: service)

        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertTrue(controller.requiresApproval)
    }

    func testUnknownStateDoesNotAttemptRegistration() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let service = FakeLaunchAtLoginService(status: .unknown)

        let controller = LaunchAtLoginController(defaults: defaults, service: service)

        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertFalse(controller.requiresApproval)
    }

    func testExplicitOptOutSurvivesTheNextLaunch() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstService = FakeLaunchAtLoginService(status: .enabled)
        let firstController = LaunchAtLoginController(defaults: defaults, service: firstService)
        firstController.setEnabled(false)

        let secondService = FakeLaunchAtLoginService(status: .notRegistered)
        _ = LaunchAtLoginController(defaults: defaults, service: secondService)

        XCTAssertEqual(secondService.registerCallCount, 0)
    }

    func testReenablingClearsExplicitOptOut() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "launchAtLogin.userOptedOut")
        let service = FakeLaunchAtLoginService(status: .notRegistered)
        let controller = LaunchAtLoginController(defaults: defaults, service: service)

        controller.setEnabled(true)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertFalse(defaults.bool(forKey: "launchAtLogin.userOptedOut"))
    }

    func testRemovalInSystemSettingsIsNotUndoneOnNextLaunch() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstService = FakeLaunchAtLoginService(status: .notRegistered)
        _ = LaunchAtLoginController(defaults: defaults, service: firstService)
        XCTAssertEqual(firstService.registerCallCount, 1)

        // The user removed Watchdog under System Settings → Login Items.
        let secondService = FakeLaunchAtLoginService(status: .notRegistered)
        let controller = LaunchAtLoginController(defaults: defaults, service: secondService)

        XCTAssertEqual(secondService.registerCallCount, 0)
        XCTAssertFalse(controller.isEnabled)
    }

    func testAlreadyEnabledInstallIsRememberedAsRegistered() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        _ = LaunchAtLoginController(defaults: defaults, service: FakeLaunchAtLoginService(status: .enabled))

        let removed = FakeLaunchAtLoginService(status: .notRegistered)
        _ = LaunchAtLoginController(defaults: defaults, service: removed)

        XCTAssertEqual(removed.registerCallCount, 0)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "dev.justn.watchdog.launch-at-login-tests"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}

@MainActor
private final class FakeLaunchAtLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0

    init(status: LaunchAtLoginStatus) {
        self.status = status
    }

    func register() throws {
        registerCallCount += 1
        status = .enabled
    }

    func unregister() throws {
        unregisterCallCount += 1
        status = .notRegistered
    }
}
