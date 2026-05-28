#if os(macOS)
import AppKit
import SwiftUI

@MainActor
protocol OCRModelManagerWindowControlling: AnyObject {
    func showWindow()
    func closeWindow()
    func refreshWindow()
}

@MainActor
final class OCRModelManagerWindowController: NSObject, NSWindowDelegate, OCRModelManagerWindowControlling {
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
        window.title = model.text(.ocrModelManagerWindowTitle)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.minSize = NSSize(width: 980, height: 720)
        window.setContentSize(NSSize(width: 1180, height: 820))
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
            self.model?.handleOCRModelManagerWindowDidClose()
        }
    }

    func refreshWindow() {
        guard let model else { return }
        self.hostingController?.rootView = self.makeRootView(model: model)
        self.window?.title = model.text(.ocrModelManagerWindowTitle)
        if let window = self.window {
            AppearanceStore.applyWindowAppearance(window, for: model.preferences.themeMode)
        }
    }

    func windowWillClose(_ notification: Notification) {
        self.model?.handleOCRModelManagerWindowDidClose()
        self.hostingController = nil
        self.window = nil
    }

    private func makeRootView(model: DesktopAppModel) -> AnyView {
        AnyView(
            OCRModelManagerView(model: model)
                .preferredColorScheme(model.resolvedPreferredColorScheme)
        )
    }
}
#endif
