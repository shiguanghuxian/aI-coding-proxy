#if os(macOS)
import AppKit
import CodexProxyCore
import CodexProxyDeploy
import SwiftUI

@MainActor
protocol RemoteAdminWindowControlling: AnyObject {
    var hostID: String { get }
    func showWindow()
    func closeWindow()
    func refreshWindow(preferences: DesktopPreferences)
}

@MainActor
final class RemoteAdminWindowController: NSObject, NSWindowDelegate, RemoteAdminWindowControlling {
    let hostID: String

    private let model: RemoteAdminWindowModel
    private let onClose: @Sendable () -> Void
    private var hostingController: NSHostingController<AnyView>?
    private var window: NSWindow?

    init(
        host: RemoteHostConfig,
        preferences: DesktopPreferences,
        remoteDeploy: any RemoteDeploying,
        onClose: @escaping @Sendable () -> Void,
        discoveredAdminPortHandler: @escaping RemoteAdminDiscoveredPortHandler
    ) {
        self.hostID = host.id
        self.model = RemoteAdminWindowModel(
            host: host,
            preferences: preferences,
            remoteDeploy: remoteDeploy,
            discoveredAdminPortHandler: discoveredAdminPortHandler
        )
        self.onClose = onClose
        super.init()
    }

    func showWindow() {
        if let window {
            self.refreshWindow(preferences: self.model.appModel.preferences)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            self.model.activate()
            return
        }

        let hostingController = NSHostingController(rootView: self.makeRootView())
        let window = NSWindow(contentViewController: hostingController)
        window.title = self.windowTitle
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.minSize = NSSize(width: 1320, height: 860)
        window.setContentSize(NSSize(width: 1520, height: 980))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        AppearanceStore.applyWindowAppearance(window, for: self.model.appModel.preferences.themeMode)

        self.hostingController = hostingController
        self.window = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        self.model.activate()
    }

    func closeWindow() {
        if let window {
            window.close()
        } else {
            Task { await self.model.close() }
            self.onClose()
        }
    }

    func refreshWindow(preferences: DesktopPreferences) {
        self.model.applyPreferences(preferences)
        self.hostingController?.rootView = self.makeRootView()
        self.window?.title = self.windowTitle
        if let window = self.window {
            AppearanceStore.applyWindowAppearance(window, for: preferences.themeMode)
        }
    }

    func windowWillClose(_ notification: Notification) {
        Task { await self.model.close() }
        self.hostingController = nil
        self.window = nil
        self.onClose()
    }

    private var windowTitle: String {
        "\(self.model.localized(zh: "远端管理台", en: "Remote Admin")) · \(self.model.hostDisplayName)"
    }

    private func makeRootView() -> AnyView {
        AnyView(
            RemoteAdminWindowView(model: self.model) { [weak self] in
                self?.closeWindow()
            }
            .preferredColorScheme(AppearanceStore.preferredColorScheme(for: self.model.appModel.preferences.themeMode))
        )
    }
}
#endif
