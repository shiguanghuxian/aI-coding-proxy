#if os(macOS)
import AppKit
import SwiftUI

@MainActor
final class AssistantWindowController: NSObject, NSWindowDelegate, AssistantWindowControlling {
    private weak var model: DesktopAppModel?
    private var hostingController: NSHostingController<AnyView>?
    private var window: NSWindow?

    init(model: DesktopAppModel) {
        self.model = model
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
        window.title = model.localized(zh: "AI 助手", en: "Assistant")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.minSize = NSSize(width: 980, height: 720)
        window.setContentSize(NSSize(width: 1080, height: 780))
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
        self.window?.title = model.localized(zh: "AI 助手", en: "Assistant")
        if let window = self.window {
            AppearanceStore.applyWindowAppearance(window, for: model.preferences.themeMode)
        }
    }

    func windowWillClose(_ notification: Notification) {
        self.model?.assistantWindowDidClose()
    }

    private func makeRootView(model: DesktopAppModel) -> AnyView {
        AnyView(
            AssistantView(model: model)
                .preferredColorScheme(model.resolvedPreferredColorScheme)
        )
    }
}
#endif
