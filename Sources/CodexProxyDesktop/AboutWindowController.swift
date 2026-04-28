#if os(macOS)
import AppKit
import SwiftUI

@MainActor
protocol AboutWindowControlling: AnyObject {
    func showWindow()
    func closeWindow()
    func refreshWindow()
}

@MainActor
final class AboutWindowController: NSObject, NSWindowDelegate, AboutWindowControlling {
    private weak var model: DesktopAppModel?
    private var hostingController: NSHostingController<AnyView>?
    private var window: NSWindow?

    init(model: DesktopAppModel) {
        self.model = model
        super.init()
    }

    func showWindow() {
        guard let model else { return }

        if let window {
            self.refreshWindow()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let rootView = self.makeRootView(model: model)
        let hostingController = NSHostingController(rootView: rootView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = model.aboutWindowTitle
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.minSize = NSSize(width: 780, height: 600)
        window.setContentSize(NSSize(width: 920, height: 680))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        AppearanceStore.applyWindowAppearance(window, for: model.preferences.themeMode)

        self.hostingController = hostingController
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func closeWindow() {
        self.window?.close()
    }

    func refreshWindow() {
        guard let model else { return }
        self.hostingController?.rootView = self.makeRootView(model: model)
        self.window?.title = model.aboutWindowTitle
        if let window = self.window {
            AppearanceStore.applyWindowAppearance(window, for: model.preferences.themeMode)
        }
    }

    func windowWillClose(_ notification: Notification) {
        self.model?.aboutWindowDidClose()
    }

    private func makeRootView(model: DesktopAppModel) -> AnyView {
        AnyView(
            AboutView(model: model)
                .preferredColorScheme(AppearanceStore.preferredColorScheme(for: model.preferences.themeMode))
        )
    }
}
#endif
