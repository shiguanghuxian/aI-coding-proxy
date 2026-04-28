#if os(macOS)
@MainActor
extension DesktopAppModel {
    func openAboutWindow() {
        if self.aboutWindowController == nil {
            self.aboutWindowController = self.aboutWindowFactory(self)
        }

        self.aboutWindowController?.showWindow()
    }

    func dismissAboutWindow() {
        self.aboutWindowController?.closeWindow()
    }

    func aboutWindowDidClose() {}
}
#endif
