#if os(macOS)
import Foundation

extension DesktopAppModel {
    func openOCRModelManagerWindow() {
        if self.ocrModelManagerWindowController == nil {
            self.ocrModelManagerWindowController = self.ocrModelManagerWindowFactory(self)
        }
        self.isOCRModelManagerPresented = true
        self.ocrModelManagerWindowController?.showWindow()
        Task { await self.refreshLocalOCRModels() }
    }

    func dismissOCRModelManagerWindow() {
        self.ocrModelManagerWindowController?.closeWindow()
    }

    func handleOCRModelManagerWindowDidClose() {
        self.isOCRModelManagerPresented = false
        self.ocrModelTestDraft = nil
    }
}
#endif
