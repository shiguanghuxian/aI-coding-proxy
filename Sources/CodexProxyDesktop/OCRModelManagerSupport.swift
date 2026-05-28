#if os(macOS)
import AppKit
import CodexProxyCore
import Foundation
import UniformTypeIdentifiers

struct OCRModelTestImageSelection: Equatable {
    var data: Data
    var mimeType: String
    var filename: String
}

struct OCRModelTestDraft: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var ocrModel: OCRModelConfig
    var prompt: String
    var imageData: Data?
    var imageMIMEType = "image/png"
    var imageFilename = ""
    var result: OCRModelTestResult?
    var isRunning = false
}

private enum OCRModelTestImageFormat {
    case png
    case jpeg
    case webp
    case gif

    var mimeType: String {
        switch self {
        case .png:
            return "image/png"
        case .jpeg:
            return "image/jpeg"
        case .webp:
            return "image/webp"
        case .gif:
            return "image/gif"
        }
    }

    static func detect(data: Data, filename: String) -> Self {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return .png
        }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            return .jpeg
        }
        if bytes.starts(with: [0x47, 0x49, 0x46]) {
            return .gif
        }
        if bytes.count >= 12,
           Array(bytes[0...3]) == [0x52, 0x49, 0x46, 0x46],
           Array(bytes[8...11]) == [0x57, 0x45, 0x42, 0x50]
        {
            return .webp
        }

        switch filename.lowercased().split(separator: ".").last {
        case "jpg", "jpeg":
            return .jpeg
        case "webp":
            return .webp
        case "gif":
            return .gif
        default:
            return .png
        }
    }
}

@MainActor
extension DesktopAppModel {
    var selectedOnlineOCRProfile: OnlineOCRModelProfile? {
        self.settings.ocrModel.effectiveOnlineProfile
    }

    var selectedOCRModelDisplayText: String {
        switch self.settings.ocrModel.provider {
        case .openAICompatible:
            return self.settings.ocrModel.effectiveOnlineProfile?.displayLabel
                ?? self.localized(zh: "未选择在线模型", en: "No online model selected")
        case .localMLX:
            return self.settings.ocrModel.localMLX.effectiveModelID()
        }
    }

    static func defaultOCRModelTestImageSelection() throws -> OCRModelTestImageSelection? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .png,
            .jpeg,
            .gif,
            UTType(filenameExtension: "webp") ?? .image,
        ]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let data = try Data(contentsOf: url)
        let format = OCRModelTestImageFormat.detect(data: data, filename: url.lastPathComponent)
        return OCRModelTestImageSelection(data: data, mimeType: format.mimeType, filename: url.lastPathComponent)
    }

    func providerText(_ provider: OCRModelProvider) -> String {
        switch provider {
        case .openAICompatible:
            return self.localized(zh: "在线 OpenAI 兼容", en: "Online OpenAI Compatible")
        case .localMLX:
            return "Local MLX"
        }
    }

    func upsertOnlineOCRProfile(_ profile: OnlineOCRModelProfile, select: Bool = true) {
        var config = self.settings.ocrModel
        var profiles = config.onlineProfiles
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        config = self.normalizedOCRConfig(config, onlineProfiles: profiles, selectedOnlineProfileID: select ? profile.id : config.selectedOnlineProfileID)
        self.settings.ocrModel = config
    }

    func deleteOnlineOCRProfile(id: String) {
        var config = self.settings.ocrModel
        let profiles = config.onlineProfiles.filter { $0.id != id }
        let selectedID = config.selectedOnlineProfileID == id ? (profiles.first?.id ?? "") : config.selectedOnlineProfileID
        if profiles.isEmpty {
            config.model = ""
            config.apiKey = ""
            config.baseURL = OpenAICompatibleUpstream.defaultBaseURL
        }
        config = self.normalizedOCRConfig(config, onlineProfiles: profiles, selectedOnlineProfileID: selectedID)
        self.settings.ocrModel = config
    }

    func selectOnlineOCRProfile(id: String) {
        self.settings.ocrModel = self.normalizedOCRConfig(
            self.settings.ocrModel,
            onlineProfiles: self.settings.ocrModel.onlineProfiles,
            selectedOnlineProfileID: id
        )
    }

    func beginOnlineOCRModelTest(profileID: String) {
        var config = self.normalizedOCRConfig(
            self.settings.ocrModel,
            onlineProfiles: self.settings.ocrModel.onlineProfiles,
            selectedOnlineProfileID: profileID
        )
        config.provider = .openAICompatible
        config.enabled = true
        self.ocrModelTestDraft = OCRModelTestDraft(
            title: self.settings.ocrModel.onlineProfiles.first { $0.id == profileID }?.displayLabel ?? self.text(.sectionOnlineOCRModels),
            ocrModel: config,
            prompt: config.prompt
        )
    }

    func beginLocalOCRModelTest(modelID: String) {
        var config = self.settings.ocrModel
        config.provider = .localMLX
        config.enabled = true
        config.localMLX.selectedModelID = modelID
        self.ocrModelTestDraft = OCRModelTestDraft(
            title: "Local MLX · \(config.localMLX.effectiveModelID())",
            ocrModel: config,
            prompt: config.prompt
        )
    }

    func dismissOCRModelTest() {
        self.ocrModelTestDraft = nil
    }

    func chooseOCRModelTestImage() {
        do {
            guard let selection = try self.ocrModelTestImageSelectionHandler() else { return }
            guard var draft = self.ocrModelTestDraft else { return }
            draft.imageData = selection.data
            draft.imageMIMEType = selection.mimeType
            draft.imageFilename = selection.filename
            draft.result = nil
            self.ocrModelTestDraft = draft
        } catch {
            self.present(error: error, context: .generic)
        }
    }

    func runOCRModelTest() async {
        guard var draft = self.ocrModelTestDraft, draft.isRunning == false else { return }
        guard let imageData = draft.imageData, imageData.isEmpty == false else {
            self.publishBanner(
                .warning,
                title: self.text(.errorOCRModelTestFailed),
                detail: self.localized(zh: "请先选择一张图片。", en: "Choose an image first.")
            )
            return
        }

        draft.isRunning = true
        draft.result = nil
        self.ocrModelTestDraft = draft
        do {
            let request = OCRModelTestRequest(
                ocrModel: draft.ocrModel,
                imageBase64: imageData.base64EncodedString(),
                mimeType: draft.imageMIMEType,
                prompt: draft.prompt
            )
            let result = try await self.admin.testOCRModel(request)
            draft.result = result
            draft.isRunning = false
            self.ocrModelTestDraft = draft
            self.publishBanner(.success, title: self.text(.successOCRModelTest), detail: result.modelLabel)
        } catch {
            draft.isRunning = false
            self.ocrModelTestDraft = draft
            self.present(error: error, context: .generic)
        }
    }

    func openLocalOCRModelDirectory(_ status: LocalOCRModelStatus) {
        guard let localPath = status.localPath?.trimmingCharacters(in: .whitespacesAndNewlines), localPath.isEmpty == false else {
            self.publishBanner(
                .warning,
                title: self.text(.errorOperationFailed),
                detail: self.localized(zh: "这个模型还没有本地目录。", en: "This model does not have a local directory yet.")
            )
            return
        }
        self.openLocalOCRDirectory(URL(fileURLWithPath: localPath, isDirectory: true))
    }

    func openLocalOCRModelCacheDirectory() {
        let url = self.settings.ocrModel.localMLX.effectiveCacheDirectory(dataDirectory: Paths.defaultDataDirectory())
        self.openLocalOCRDirectory(url, createIfMissing: true)
    }

    private func openLocalOCRDirectory(_ url: URL, createIfMissing: Bool = false) {
        guard self.admin.canOpenLocalFilePaths else {
            self.publishBanner(
                .warning,
                title: self.text(.errorOperationFailed),
                detail: self.localized(zh: "当前连接的是远端管理端，不能在本机 Finder 打开远端模型目录。", en: "This is a remote admin target, so the remote model directory cannot be opened in local Finder.")
            )
            return
        }

        do {
            if createIfMissing {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw ProxyError.message(self.localized(zh: "目录不存在：\(url.path)", en: "Directory does not exist: \(url.path)"))
            }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            self.present(error: error, context: .generic)
        }
    }

    private func normalizedOCRConfig(
        _ source: OCRModelConfig,
        onlineProfiles: [OnlineOCRModelProfile],
        selectedOnlineProfileID: String
    ) -> OCRModelConfig {
        OCRModelConfig(
            provider: source.provider,
            model: source.model,
            apiKey: source.apiKey,
            baseURL: source.baseURL,
            prompt: source.prompt,
            timeout: source.timeout,
            maxImageSize: source.maxImageSize,
            enabled: source.enabled,
            debugMode: source.debugMode,
            localMLX: source.localMLX,
            onlineProfiles: onlineProfiles,
            selectedOnlineProfileID: selectedOnlineProfileID
        )
    }
}
#endif
