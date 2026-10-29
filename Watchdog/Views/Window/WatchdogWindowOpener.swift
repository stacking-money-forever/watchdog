import AppKit
import SwiftUI

/// Opens the named SwiftUI `Window` and brings Watchdog to the front.
/// Accessory (`LSUIElement`) launches otherwise leave the window behind.
@MainActor
enum WatchdogWindowOpener {
    static var pendingOpen = false
    static var openWindowAction: ((String) -> Void)? {
        didSet {
            guard pendingOpen, openWindowAction != nil else { return }
            openMainWindow()
        }
    }

    static func openMainWindow() {
        if openWindowAction == nil {
            pendingOpen = true
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }
        pendingOpen = false
        openWindowAction?("main")
        NSApplication.shared.activate(ignoringOtherApps: true)
        Task { @MainActor in
            bringMainWindowForward()
        }
    }

    static func bringMainWindowForward() {
        let match = NSApplication.shared.windows.first { window in
            window.identifier?.rawValue == "main" || window.title == "Watchdog"
        }
        match?.identifier = NSUserInterfaceItemIdentifier("main")
        match?.setAccessibilityIdentifier("watchdog.window")
        match?.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

struct WatchdogWindowOpenInstaller: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            WatchdogWindowOpener.openWindowAction = { id in
                openWindow(id: id)
            }
        }
    }
}
