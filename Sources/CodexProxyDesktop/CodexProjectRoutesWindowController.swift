#if os(macOS)
import AppKit
import SwiftUI

@MainActor
protocol CodexProjectRoutesWindowControlling: AnyObject {
    func showWindow()
    func closeWindow()
    func refreshWindow()
}

@MainActor
final class CodexProjectRoutesWindowController: NSObject, NSWindowDelegate, CodexProjectRoutesWindowControlling {
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

        let hostingController = NSHostingController(rootView: self.makeRootView(model: model))
        let window = NSWindow(contentViewController: hostingController)
        window.title = model.codexProjectRoutesWindowTitle
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.minSize = NSSize(width: 980, height: 660)
        window.setContentSize(NSSize(width: 1120, height: 780))
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
        if let window {
            window.close()
        } else {
            self.model?.handleCodexProjectRoutesWindowDidClose()
        }
    }

    func refreshWindow() {
        guard let model else { return }
        self.hostingController?.rootView = self.makeRootView(model: model)
        self.window?.title = model.codexProjectRoutesWindowTitle
        if let window = self.window {
            AppearanceStore.applyWindowAppearance(window, for: model.preferences.themeMode)
        }
    }

    func windowWillClose(_ notification: Notification) {
        self.model?.handleCodexProjectRoutesWindowDidClose()
        self.hostingController = nil
        self.window = nil
    }

    private func makeRootView(model: DesktopAppModel) -> AnyView {
        AnyView(
            CodexProjectRoutesView(model: model)
                .preferredColorScheme(model.resolvedPreferredColorScheme)
        )
    }
}
#endif
