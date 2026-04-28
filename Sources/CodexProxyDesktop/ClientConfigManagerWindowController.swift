#if os(macOS)
import AppKit
import SwiftUI

@MainActor
protocol ClientConfigManagerWindowControlling: AnyObject {
    func showWindow()
    func closeWindow()
    func refreshWindow()
}

@MainActor
final class ClientConfigManagerWindowController: NSObject, NSWindowDelegate, ClientConfigManagerWindowControlling {
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
        window.title = model.clientConfigManagerWindowTitle
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.minSize = NSSize(width: 980, height: 700)
        window.setContentSize(NSSize(width: 1140, height: 860))
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
            self.model?.handleClientConfigManagerWindowDidClose()
        }
    }

    func refreshWindow() {
        guard let model else { return }
        self.hostingController?.rootView = self.makeRootView(model: model)
        self.window?.title = model.clientConfigManagerWindowTitle
        if let window = self.window {
            AppearanceStore.applyWindowAppearance(window, for: model.preferences.themeMode)
        }
    }

    func windowWillClose(_ notification: Notification) {
        self.model?.handleClientConfigManagerWindowDidClose()
        self.hostingController = nil
        self.window = nil
    }

    private func makeRootView(model: DesktopAppModel) -> AnyView {
        AnyView(
            ClientConfigManagerView(model: model)
                .preferredColorScheme(AppearanceStore.preferredColorScheme(for: model.preferences.themeMode))
        )
    }
}
#endif
