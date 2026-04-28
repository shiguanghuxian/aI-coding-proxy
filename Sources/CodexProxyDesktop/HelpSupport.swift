#if os(macOS)
import AppKit
import Foundation

@MainActor
extension DesktopAppModel {
    var shouldAutoPresentHelpWindow: Bool {
        self.preferences.hasSeenHelpWindow == false
    }

    func openHelpWindow(markAsSeen: Bool = true) {
        if markAsSeen {
            self.markHelpWindowSeenIfNeeded()
        }

        if self.helpWindowController == nil {
            self.helpWindowController = self.helpWindowFactory(self)
        }

        self.isHelpPresented = true
        self.helpWindowController?.showWindow()
    }

    func presentHelpWindowIfNeededOnFirstLaunch() {
        guard self.shouldAutoPresentHelpWindow else { return }
        self.openHelpWindow(markAsSeen: true)
    }

    func dismissHelpWindow(shouldAutoOpenOnboarding: Bool = true) {
        self.helpWindowDidClose(shouldAutoOpenOnboarding: shouldAutoOpenOnboarding)
        self.helpWindowController?.closeWindow()
    }

    func helpWindowDidClose(shouldAutoOpenOnboarding: Bool = true) {
        guard self.isHelpPresented else { return }
        self.isHelpPresented = false
        if shouldAutoOpenOnboarding {
            self.presentOnboardingAfterHelpDismissIfNeeded()
        }
    }

    func openHelpAction(_ target: HelpActionTarget) {
        switch target {
        case .page(let page):
            self.openDashboard(page)
        case .proxyAccess:
            self.openProxyAccessPage()
        case .settingsProxy:
            self.openSettingsProxyPage()
        case .requestLogs:
            self.openDashboard(.proxy)
            guard self.preferences.interfaceMode == .full else { return }
            self.openRequestLogsWindow()
        case .proxyTestConsole:
            self.openDashboard(.proxy)
            guard self.preferences.interfaceMode == .full else { return }
            self.openProxyTestConsole()
        case .managedProxyManager:
            self.openDashboard(.settings)
            guard self.preferences.interfaceMode == .full else { return }
            self.openManagedProxyManagerWindow()
        case .onboarding:
            self.dismissHelpWindow(shouldAutoOpenOnboarding: false)
            self.startOnboarding()
        }
    }

    private func markHelpWindowSeenIfNeeded() {
        guard self.preferences.hasSeenHelpWindow == false else { return }
        self.updatePreferences(showSuccessNotice: false) { preferences in
            preferences.hasSeenHelpWindow = true
        }
    }
}
#endif
