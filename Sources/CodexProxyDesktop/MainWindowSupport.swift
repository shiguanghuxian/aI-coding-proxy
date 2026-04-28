#if os(macOS)
import AppKit
import SwiftUI

@MainActor
enum DesktopMainWindow {
    static let sceneID = "desktop-main-window"
    static let identifier = NSUserInterfaceItemIdentifier("io.shiguanghuxian.codex-proxy.desktop.main-window")

    private static var openAction: (() -> Void)?

    static func configureOpenAction(_ action: @escaping () -> Void) {
        self.openAction = action
    }

    static func mark(_ window: NSWindow) {
        window.identifier = self.identifier
    }

    static func mainWindow(from windows: [NSWindow]) -> NSWindow? {
        windows.first(where: { $0.identifier == self.identifier })
    }

    static func find(in app: NSApplication = .shared) -> NSWindow? {
        self.mainWindow(from: app.windows)
    }

    static func activateOrOpen(in app: NSApplication = .shared) {
        app.activate(ignoringOtherApps: true)
        if let window = self.find(in: app) {
            window.makeKeyAndOrderFront(nil)
            return
        }

        self.openAction?()
        DispatchQueue.main.async {
            self.find(in: app)?.makeKeyAndOrderFront(nil)
        }
    }
}
#endif
