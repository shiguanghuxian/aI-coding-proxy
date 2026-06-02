#if os(macOS)
import Foundation

@MainActor
extension DesktopAppModel {
    var codexProjectRoutesWindowTitle: String {
        self.text(.codexProjectRoutesTitle)
    }

    var codexProjectRoutesWindowSubtitle: String {
        self.text(.codexProjectRoutesSubtitle)
    }

    func openCodexProjectRoutesWindow() {
        if self.codexProjectRoutesWindowController == nil {
            self.codexProjectRoutesWindowController = self.codexProjectRoutesWindowFactory(self)
        }
        self.isCodexProjectRoutesPresented = true
        self.codexProjectRoutesWindowController?.showWindow()
        Task {
            await self.refreshClientConfigManagerState(showLoading: true, target: .codex, force: false)
            await self.refreshClientConfigManagerState(showLoading: true, target: .claudeCode, force: false)
            await self.loadClientConfigManagerBackupsIfNeeded(target: .codex, force: false)
            await self.loadClientConfigManagerBackupsIfNeeded(target: .claudeCode, force: false)
        }
    }

    func dismissCodexProjectRoutesWindow() {
        self.isCodexProjectRoutesPresented = false
        self.codexProjectRoutesWindowController?.closeWindow()
    }

    func handleCodexProjectRoutesWindowDidClose() {
        self.isCodexProjectRoutesPresented = false
        self.codexProjectRouteDraft = nil
    }
}
#endif
