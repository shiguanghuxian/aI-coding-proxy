#if os(macOS)
import AppKit
import CodexProxyCore

extension DesktopAppModel {
    func activateMainWindow() {
        DesktopMainWindow.activateOrOpen()
    }

    func openInterfaceModeWindow(target: DesktopInterfaceMode) {
        if self.preferences.interfaceMode == target {
            self.activateMainWindow()
            return
        }

        self.switchInterfaceMode(target: target)
        guard self.preferences.interfaceMode == target else { return }
        self.activateMainWindow()
    }

    func openRequestLogsFromMenu() {
        self.openRequestLogsWindow()
    }
}
#endif
