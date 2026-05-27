#if os(macOS)
import Foundation

extension DesktopAppModel {
    func openOCRCacheLogsWindow() {
        if self.ocrCacheLogsWindowController == nil {
            self.ocrCacheLogsWindowController = self.ocrCacheLogsWindowFactory(self)
        }
        self.isOCRCacheLogsPresented = true
        self.ocrCacheLogsWindowController?.showWindow()
        Task { await self.refreshOCRCacheLogsWindowData() }
    }

    func dismissOCRCacheLogsWindow() {
        self.ocrCacheLogsWindowController?.closeWindow()
    }

    func handleOCRCacheLogsWindowDidClose() {
        self.isOCRCacheLogsPresented = false
        self.isOCRRecognitionResultPresented = false
        self.ocrRecognitionResult = nil
    }

    func refreshOCRCacheLogsWindowData() async {
        await self.loadOCRCacheSummary()
        await self.loadOCRRecognitionLogs()
    }
}
#endif
