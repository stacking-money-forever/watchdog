import Combine
import Foundation
import OSLog
import ServiceManagement

enum LaunchAtLoginStatus: Equatable {
    case enabled
    case requiresApproval
    case notFound
    case notRegistered
    case unknown
}

@MainActor
protocol LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus { get }
    func register() throws
    func unregister() throws
}

@MainActor
private struct SystemLaunchAtLoginService: LaunchAtLoginServicing {
    var status: LaunchAtLoginStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        case .notRegistered: return .notRegistered
        @unknown default: return .unknown
        }
    }

    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var requiresApproval = false
    @Published private(set) var errorMessage: String?

    private let defaults: UserDefaults
    private let service: any LaunchAtLoginServicing

    private enum Keys {
        static let userOptedOut = "launchAtLogin.userOptedOut"
        /// Set once Watchdog has been registered (by itself or the user).
        /// Removing the login item in System Settings afterwards is a user
        /// decision that a later launch must not silently undo.
        static let didAutoRegister = "launchAtLogin.didAutoRegister"
        /// Last observed status and registration error, kept so
        /// `watchdog-cli doctor` can explain a missing login item.
        static let lastStatus = "launchAtLogin.lastStatus"
        static let lastError = "launchAtLogin.lastError"
    }

    private static let log = Logger(subsystem: "dev.justn.watchdog", category: "login-item")

    init(
        defaults: UserDefaults = .standard,
        service: any LaunchAtLoginServicing = SystemLaunchAtLoginService(),
        automaticallyRegister: Bool = true
    ) {
        self.defaults = defaults
        self.service = service
        refresh()
        if automaticallyRegister {
            registerByDefaultIfNeeded()
        }
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try service.register()
                defaults.removeObject(forKey: Keys.userOptedOut)
            } else {
                try service.unregister()
                defaults.set(true, forKey: Keys.userOptedOut)
            }
            recordError(nil)
        } catch {
            recordError(error)
        }
        refresh()
    }

    func refresh() {
        let status = service.status
        defaults.set(status.diagnosticName, forKey: Keys.lastStatus)
        switch status {
        case .enabled:
            isEnabled = true
            requiresApproval = false
        case .requiresApproval:
            isEnabled = false
            requiresApproval = true
        case .notFound, .notRegistered, .unknown:
            isEnabled = false
            requiresApproval = false
        }
    }

    func registerByDefaultIfNeeded() {
        let status = service.status
        if status == .enabled || status == .requiresApproval {
            defaults.set(true, forKey: Keys.didAutoRegister)
        }
        // A main app that has never been registered reports `.notFound`, not
        // `.notRegistered`: Background Task Management has no record of it
        // yet. Accepting only `.notRegistered` silently skipped every fresh
        // install. `.unknown` stays excluded.
        guard !defaults.bool(forKey: Keys.userOptedOut),
              !defaults.bool(forKey: Keys.didAutoRegister),
              status == .notRegistered || status == .notFound
        else {
            Self.log.info("auto-register skipped: status=\(status.diagnosticName, privacy: .public) optedOut=\(self.defaults.bool(forKey: Keys.userOptedOut)) done=\(self.defaults.bool(forKey: Keys.didAutoRegister))")
            return
        }

        do {
            try service.register()
            defaults.set(true, forKey: Keys.didAutoRegister)
            recordError(nil)
            Self.log.info("auto-registered as login item (was \(status.diagnosticName, privacy: .public))")
        } catch {
            recordError(error)
            Self.log.error("auto-register failed: \(String(describing: error), privacy: .public)")
        }
        refresh()
    }

    private func recordError(_ error: Error?) {
        errorMessage = error?.localizedDescription
        if let error {
            let nsError = error as NSError
            defaults.set("\(nsError.domain) \(nsError.code): \(nsError.localizedDescription)", forKey: Keys.lastError)
        } else {
            defaults.removeObject(forKey: Keys.lastError)
        }
    }
}

extension LaunchAtLoginStatus {
    var diagnosticName: String {
        switch self {
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        case .notRegistered: "notRegistered"
        case .unknown: "unknown"
        }
    }
}
