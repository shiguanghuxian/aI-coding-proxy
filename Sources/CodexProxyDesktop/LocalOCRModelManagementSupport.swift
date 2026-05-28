#if os(macOS)
import CodexProxyCore
import Foundation

@MainActor
extension DesktopAppModel {
    var selectedLocalOCRModelStatus: LocalOCRModelStatus? {
        self.localOCRModelsResponse.models.first {
            $0.descriptor.id == self.settings.ocrModel.localMLX.selectedModelID
        }
    }

    func refreshLocalOCRModels() async {
        self.localOCRModelsIsRefreshing = true
        defer { self.localOCRModelsIsRefreshing = false }
        do {
            self.localOCRModelsResponse = try await self.admin.getLocalOCRModels()
            self.reconcileLocalOCRModelProgressRefresh()
        } catch {
            self.present(error: error, context: .loadOCRCache)
        }
    }

    func selectLocalOCRModel(_ descriptor: LocalOCRModelDescriptor) {
        self.settings.ocrModel.localMLX.selectedModelID = descriptor.id
    }

    func applyLowResourceLocalOCRPreset() {
        self.settings.ocrModel.localMLX.selectedModelID = "mlx-community/Qwen2.5-VL-3B-Instruct-4bit"
        self.settings.ocrModel.localMLX.maxTokens = LocalMLXOCRConfig.defaultMaxTokens
        self.settings.ocrModel.localMLX.maxConcurrentRecognitions = LocalMLXOCRConfig.defaultMaxConcurrentRecognitions
        self.settings.ocrModel.localMLX.idleShutdownSeconds = LocalMLXOCRConfig.defaultIdleShutdownSeconds
        self.settings.ocrModel.maxImageSize = 2 * 1024 * 1024
    }

    func downloadLocalOCRModel(_ descriptor: LocalOCRModelDescriptor) async {
        await self.performLocalOCRModelAction(id: descriptor.id) {
            try await self.admin.downloadLocalOCRModel(id: descriptor.id)
        }
        self.reconcileLocalOCRModelProgressRefresh()
    }

    func verifyLocalOCRModel(_ descriptor: LocalOCRModelDescriptor) async {
        await self.performLocalOCRModelAction(id: descriptor.id) {
            try await self.admin.verifyLocalOCRModel(id: descriptor.id)
        }
    }

    func deleteLocalOCRModel(_ descriptor: LocalOCRModelDescriptor) async {
        await self.performLocalOCRModelAction(id: descriptor.id) {
            try await self.admin.deleteLocalOCRModel(id: descriptor.id)
        }
        self.reconcileLocalOCRModelProgressRefresh()
    }

    func stopLocalOCRModelProgressRefresh() {
        self.localOCRModelProgressRefreshTask?.cancel()
        self.localOCRModelProgressRefreshTask = nil
    }

    func stopLocalOCRRuntime() async {
        self.localOCRRuntimeIsStopping = true
        defer { self.localOCRRuntimeIsStopping = false }
        do {
            let status = try await self.admin.stopLocalOCRRuntime()
            self.localOCRModelsResponse.runtime = status
        } catch {
            self.present(error: error, context: .loadOCRCache)
        }
    }

    func localOCRModelPhaseText(_ phase: LocalOCRModelInstallPhase) -> String {
        switch phase {
        case .notInstalled:
            return self.text(.statusLocalOCRNotInstalled)
        case .downloading:
            return self.text(.statusLocalOCRDownloading)
        case .installed:
            return self.text(.statusLocalOCRInstalled)
        case .failed:
            return self.text(.statusOCRFailed)
        }
    }

    func localOCRModelOperationInProgress(_ descriptor: LocalOCRModelDescriptor) -> Bool {
        self.localOCRModelOperationIDs.contains(descriptor.id)
    }

    private func performLocalOCRModelAction(
        id: String,
        operation: () async throws -> LocalOCRModelActionResult
    ) async {
        self.localOCRModelOperationIDs.insert(id)
        defer { self.localOCRModelOperationIDs.remove(id) }
        do {
            let result = try await operation()
            self.localOCRModelsResponse = result.models
        } catch {
            self.present(error: error, context: .loadOCRCache)
            await self.refreshLocalOCRModels()
        }
    }

    private var hasDownloadingLocalOCRModels: Bool {
        self.localOCRModelsResponse.models.contains { $0.phase == .downloading }
    }

    private func reconcileLocalOCRModelProgressRefresh() {
        if self.hasDownloadingLocalOCRModels {
            self.startLocalOCRModelProgressRefreshIfNeeded()
        } else {
            self.stopLocalOCRModelProgressRefresh()
        }
    }

    private func startLocalOCRModelProgressRefreshIfNeeded() {
        guard self.localOCRModelProgressRefreshTask == nil else {
            return
        }
        self.localOCRModelProgressRefreshTask = Task { [weak self] in
            while Task.isCancelled == false {
                try? await Task.sleep(for: .seconds(1))
                guard Task.isCancelled == false, let self else {
                    break
                }
                await self.refreshLocalOCRModelsForProgress()
                let shouldContinue = self.hasDownloadingLocalOCRModels
                if shouldContinue == false {
                    break
                }
            }
            self?.clearLocalOCRModelProgressRefreshTask()
        }
    }

    private func refreshLocalOCRModelsForProgress() async {
        do {
            self.localOCRModelsResponse = try await self.admin.getLocalOCRModels()
        } catch {
            self.stopLocalOCRModelProgressRefresh()
            self.present(error: error, context: .loadOCRCache)
        }
    }

    private func clearLocalOCRModelProgressRefreshTask() {
        self.localOCRModelProgressRefreshTask = nil
    }
}
#endif
