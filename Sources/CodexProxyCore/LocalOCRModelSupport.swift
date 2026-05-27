import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum LocalOCRModelError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedPlatform
    case modelNotSelected
    case modelNotInstalled(String)
    case downloadSourceUnavailable(String)
    case networkFailure(String)
    case invalidSnapshot(String)
    case runtimeExecutableMissing(String)
    case runtimeNotRunning
    case runtimeStartFailed(String)
    case inferenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "Local MLX OCR 仅支持 macOS Apple Silicon 本机运行。"
        case .modelNotSelected:
            return "Local MLX OCR 未选择模型。"
        case .modelNotInstalled(let id):
            return "Local MLX OCR 模型尚未下载：\(id)"
        case .downloadSourceUnavailable(let detail):
            return "Local MLX OCR 模型下载源不可用：\(detail)"
        case .networkFailure(let detail):
            return "Local MLX OCR 模型下载失败：\(detail)"
        case .invalidSnapshot(let detail):
            return "Local MLX OCR 模型目录无效：\(detail)"
        case .runtimeExecutableMissing(let path):
            return "找不到 Local MLX OCR 推理服务：\(path)"
        case .runtimeNotRunning:
            return "Local MLX OCR 推理服务未运行。"
        case .runtimeStartFailed(let detail):
            return "Local MLX OCR 推理服务启动失败：\(detail)"
        case .inferenceFailed(let detail):
            return "Local MLX OCR 推理失败：\(detail)"
        }
    }
}

public struct LocalMLXOCRRequest: Sendable, Equatable {
    public var prompt: String
    public var imageURL: String
    public var detail: String?
    public var modelID: String
    public var maxTokens: Int
    public var timeout: Int

    public init(prompt: String, imageURL: String, detail: String? = nil, modelID: String, maxTokens: Int, timeout: Int) {
        self.prompt = prompt
        self.imageURL = imageURL
        self.detail = detail
        self.modelID = modelID
        self.maxTokens = max(maxTokens, 128)
        self.timeout = max(timeout, 1)
    }
}

public protocol LocalMLXOCRServing: Sendable {
    func recognize(_ request: LocalMLXOCRRequest, config: OCRModelConfig, networkConfig: AppConfig) async throws -> String
    func status() async -> LocalMLXOCRRuntimeStatus
    func stop() async
}

public actor LocalOCRModelManager {
    private struct SnapshotFile: Codable, Equatable, Sendable {
        var path: String
        var sizeBytes: Int64?
    }

    private struct SnapshotManifest: Codable, Equatable, Sendable {
        var modelID: String
        var repo: String
        var source: String
        var files: [SnapshotFile]
        var downloadedAt: Int64
    }

    private struct HuggingFaceModelInfo: Decodable {
        struct Sibling: Decodable {
            var rfilename: String
            var size: Int64?
        }

        var siblings: [Sibling]
    }

    public static let snapshotManifestFilename = ".codex-proxy-ocr-snapshot.json"

    private let dataDirectory: URL
    private let session: URLSession
    private let fileManager: FileManager
    private var downloads: [String: Task<LocalOCRModelStatus, Error>] = [:]
    private var downloadProgress: [String: LocalOCRModelStatus] = [:]

    public init(
        dataDirectory: URL,
        session: URLSession = .shared,
        fileManager: FileManager = .default
    ) {
        self.dataDirectory = dataDirectory
        self.session = session
        self.fileManager = fileManager
    }

    public func models(config: OCRModelConfig, runtime: LocalMLXOCRRuntimeStatus = .init()) -> LocalOCRModelsResponse {
        let descriptors = self.descriptors(config: config.localMLX)
        let statuses = descriptors.map { self.installState(for: $0, config: config.localMLX) }
        return LocalOCRModelsResponse(
            selectedModelID: config.localMLX.selectedModelID,
            customHFRepo: config.localMLX.customHFRepo,
            models: statuses,
            runtime: runtime
        )
    }

    public func descriptor(for config: LocalMLXOCRConfig) throws -> LocalOCRModelDescriptor {
        guard let descriptor = LocalOCRModelDescriptor.descriptor(
            id: config.selectedModelID,
            customHFRepo: config.customHFRepo
        ) else {
            throw LocalOCRModelError.modelNotSelected
        }
        return descriptor
    }

    public func descriptor(id: String, config: LocalMLXOCRConfig) throws -> LocalOCRModelDescriptor {
        let decodedID = id.removingPercentEncoding ?? id
        guard let descriptor = LocalOCRModelDescriptor.descriptor(id: decodedID, customHFRepo: config.customHFRepo) else {
            throw LocalOCRModelError.modelNotSelected
        }
        return descriptor
    }

    public func modelDirectory(for descriptor: LocalOCRModelDescriptor, config: LocalMLXOCRConfig) -> URL {
        config.effectiveCacheDirectory(dataDirectory: self.dataDirectory)
            .appendingPathComponent(descriptor.snapshotDirectoryName, isDirectory: true)
    }

    public func installedModelDirectory(for descriptor: LocalOCRModelDescriptor, config: LocalMLXOCRConfig) throws -> URL {
        let directory = self.modelDirectory(for: descriptor, config: config)
        let status = self.installState(for: descriptor, config: config)
        guard status.phase == .installed else {
            throw LocalOCRModelError.modelNotInstalled(descriptor.id)
        }
        return directory
    }

    public func startDownload(id: String, config: OCRModelConfig) async throws -> LocalOCRModelActionResult {
        let descriptor = try self.descriptor(id: id, config: config.localMLX)
        let key = descriptor.huggingFaceRepo
        if let existing = self.downloads[key], existing.isCancelled == false {
            let status = self.downloadProgress[key] ?? self.downloadingStatus(for: descriptor, config: config.localMLX, progress: 0)
            return LocalOCRModelActionResult(
                status: status,
                models: self.models(config: config, runtime: .init())
            )
        }

        let task = Task {
            do {
                let status = try await self.download(descriptor: descriptor, config: config.localMLX)
                self.finishDownload(key: key, status: status)
                return status
            } catch {
                let status = self.failedStatus(for: descriptor, config: config.localMLX, error: error)
                self.finishDownload(key: key, status: status)
                throw error
            }
        }
        self.downloads[key] = task
        let status = self.downloadingStatus(for: descriptor, config: config.localMLX, progress: 0)
        self.downloadProgress[key] = status
        return LocalOCRModelActionResult(status: status, models: self.models(config: config, runtime: .init()))
    }

    public func verify(id: String, config: OCRModelConfig) throws -> LocalOCRModelActionResult {
        let descriptor = try self.descriptor(id: id, config: config.localMLX)
        let directory = self.modelDirectory(for: descriptor, config: config.localMLX)
        try Self.validateSnapshot(at: directory, fileManager: self.fileManager)
        let status = self.installState(for: descriptor, config: config.localMLX, successDetail: "模型目录校验通过。")
        return LocalOCRModelActionResult(status: status, models: self.models(config: config, runtime: .init()))
    }

    public func delete(id: String, config: OCRModelConfig) throws -> LocalOCRModelActionResult {
        let descriptor = try self.descriptor(id: id, config: config.localMLX)
        let key = descriptor.huggingFaceRepo
        self.downloads[key]?.cancel()
        self.downloads[key] = nil
        self.downloadProgress[key] = nil
        try? self.fileManager.removeItem(at: self.modelDirectory(for: descriptor, config: config.localMLX))
        try? self.fileManager.removeItem(at: self.partialDirectory(for: descriptor, config: config.localMLX))
        let status = self.installState(for: descriptor, config: config.localMLX)
        return LocalOCRModelActionResult(status: status, models: self.models(config: config, runtime: .init()))
    }

    private func descriptors(config: LocalMLXOCRConfig) -> [LocalOCRModelDescriptor] {
        var descriptors = LocalOCRModelDescriptor.recommendedModels
        if let custom = LocalOCRModelDescriptor.customDescriptor(repo: config.customHFRepo) {
            descriptors.append(custom)
        }
        return descriptors
    }

    private func installState(
        for descriptor: LocalOCRModelDescriptor,
        config: LocalMLXOCRConfig,
        successDetail: String = "模型已安装。"
    ) -> LocalOCRModelStatus {
        if let progress = self.downloadProgress[descriptor.huggingFaceRepo] {
            return progress
        }
        let directory = self.modelDirectory(for: descriptor, config: config)
        let partial = self.partialDirectory(for: descriptor, config: config)
        var isDirectory: ObjCBool = false
        guard self.fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            if self.fileManager.fileExists(atPath: partial.path) {
                return LocalOCRModelStatus(
                    descriptor: descriptor,
                    phase: .failed,
                    detail: "发现未完成的模型下载目录，请重新下载。",
                    localPath: directory.path,
                    compatibility: .incomplete
                )
            }
            return LocalOCRModelStatus(
                descriptor: descriptor,
                phase: .notInstalled,
                detail: "模型尚未下载。",
                localPath: directory.path,
                compatibility: .unknown
            )
        }
        do {
            try Self.validateSnapshot(at: directory, fileManager: self.fileManager)
            return LocalOCRModelStatus(
                descriptor: descriptor,
                phase: .installed,
                progress: 1,
                detail: successDetail,
                localPath: directory.path,
                compatibility: .compatible
            )
        } catch {
            return LocalOCRModelStatus(
                descriptor: descriptor,
                phase: .failed,
                progress: 1,
                detail: error.localizedDescription,
                localPath: directory.path,
                compatibility: .incomplete
            )
        }
    }

    private func download(descriptor: LocalOCRModelDescriptor, config: LocalMLXOCRConfig) async throws -> LocalOCRModelStatus {
        let target = self.modelDirectory(for: descriptor, config: config)
        let partial = self.partialDirectory(for: descriptor, config: config)
        try self.fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if self.fileManager.fileExists(atPath: partial.path) {
            try self.fileManager.removeItem(at: partial)
        }
        try self.fileManager.createDirectory(at: partial, withIntermediateDirectories: true)

        let files = try await self.snapshotFiles(for: descriptor, config: config)
        guard files.isEmpty == false else {
            throw LocalOCRModelError.downloadSourceUnavailable("Hugging Face 仓库没有可下载文件。")
        }
        let totalBytes = files.reduce(Int64(0)) { $0 + max($1.sizeBytes ?? 0, 0) }
        var completedBytes: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let destination = partial.appendingPathComponent(file.path)
            try self.fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let url = try self.downloadURL(for: file.path, descriptor: descriptor, config: config)
            let progress = totalBytes > 0 ? min(Double(completedBytes) / Double(totalBytes), 0.999) : 0
            self.downloadProgress[descriptor.huggingFaceRepo] = self.downloadingStatus(
                for: descriptor,
                config: config,
                progress: progress,
                detail: "下载 \(file.path)"
            )
            var request = URLRequest(url: url)
            request.timeoutInterval = 60
            request.setValue(RuntimeInfo.daemonServerToken, forHTTPHeaderField: "User-Agent")
            request.setValue("*/*", forHTTPHeaderField: "Accept")
            if config.hfToken.isEmpty == false {
                request.setValue("Bearer \(config.hfToken)", forHTTPHeaderField: "Authorization")
            }
            let (tempURL, response) = try await self.session.download(for: request)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) == false {
                throw LocalOCRModelError.networkFailure("\(url.absoluteString) 返回 HTTP \(http.statusCode)。")
            }
            if self.fileManager.fileExists(atPath: destination.path) {
                try self.fileManager.removeItem(at: destination)
            }
            try self.fileManager.moveItem(at: tempURL, to: destination)
            if let expected = file.sizeBytes {
                let actual = self.fileSize(destination)
                guard actual == expected else {
                    throw LocalOCRModelError.invalidSnapshot("\(file.path) 文件大小不匹配，期望 \(expected) bytes，实际 \(actual) bytes。")
                }
                completedBytes += expected
            } else {
                completedBytes += self.fileSize(destination)
            }
        }

        let manifest = SnapshotManifest(
            modelID: descriptor.id,
            repo: descriptor.huggingFaceRepo,
            source: config.hfBaseURL,
            files: files,
            downloadedAt: Helpers.now()
        )
        try Helpers.encodeJSON(manifest, pretty: true)
            .write(to: partial.appendingPathComponent(Self.snapshotManifestFilename), options: .atomic)
        try Self.validateSnapshot(at: partial, fileManager: self.fileManager)
        if self.fileManager.fileExists(atPath: target.path) {
            try self.fileManager.removeItem(at: target)
        }
        try self.fileManager.moveItem(at: partial, to: target)
        return LocalOCRModelStatus(
            descriptor: descriptor,
            phase: .installed,
            progress: 1,
            detail: "\(descriptor.displayName) 下载完成。",
            localPath: target.path,
            compatibility: .compatible
        )
    }

    private func snapshotFiles(for descriptor: LocalOCRModelDescriptor, config: LocalMLXOCRConfig) async throws -> [SnapshotFile] {
        let base = self.normalizedBaseURL(config.hfBaseURL)
        guard let apiURL = URL(string: "\(base)/api/models/\(descriptor.huggingFaceRepo)") else {
            throw LocalOCRModelError.downloadSourceUnavailable("Hugging Face API 地址无效。")
        }
        var request = URLRequest(url: apiURL)
        request.timeoutInterval = 30
        request.setValue(RuntimeInfo.daemonServerToken, forHTTPHeaderField: "User-Agent")
        if config.hfToken.isEmpty == false {
            request.setValue("Bearer \(config.hfToken)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await self.session.data(for: request)
        if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) == false {
            throw LocalOCRModelError.networkFailure("Hugging Face API 返回 HTTP \(http.statusCode)。")
        }
        let decoded = try JSONDecoder().decode(HuggingFaceModelInfo.self, from: data)
        return decoded.siblings
            .filter { Self.isAllowedSnapshotFile($0.rfilename) }
            .map { SnapshotFile(path: $0.rfilename, sizeBytes: $0.size) }
            .sorted { $0.path < $1.path }
    }

    private func downloadURL(for path: String, descriptor: LocalOCRModelDescriptor, config: LocalMLXOCRConfig) throws -> URL {
        let base = self.normalizedBaseURL(config.hfBaseURL)
        guard let url = URL(string: "\(base)/\(descriptor.huggingFaceRepo)/resolve/main/\(path)") else {
            throw LocalOCRModelError.downloadSourceUnavailable("下载 URL 无效。")
        }
        return url
    }

    private func partialDirectory(for descriptor: LocalOCRModelDescriptor, config: LocalMLXOCRConfig) -> URL {
        let target = self.modelDirectory(for: descriptor, config: config)
        return target.deletingLastPathComponent()
            .appendingPathComponent(target.lastPathComponent + ".part", isDirectory: true)
    }

    private func downloadingStatus(
        for descriptor: LocalOCRModelDescriptor,
        config: LocalMLXOCRConfig,
        progress: Double,
        detail: String = "模型下载已开始。"
    ) -> LocalOCRModelStatus {
        LocalOCRModelStatus(
            descriptor: descriptor,
            phase: .downloading,
            progress: progress,
            detail: detail,
            localPath: self.modelDirectory(for: descriptor, config: config).path,
            compatibility: .unknown
        )
    }

    private func failedStatus(
        for descriptor: LocalOCRModelDescriptor,
        config: LocalMLXOCRConfig,
        error: Error
    ) -> LocalOCRModelStatus {
        LocalOCRModelStatus(
            descriptor: descriptor,
            phase: .failed,
            detail: error.localizedDescription,
            localPath: self.modelDirectory(for: descriptor, config: config).path,
            compatibility: .unknown
        )
    }

    private func finishDownload(key: String, status: LocalOCRModelStatus) {
        self.downloads[key] = nil
        self.downloadProgress[key] = status
    }

    private func normalizedBaseURL(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "/ \n\r\t"))
        return trimmed.isEmpty ? "https://huggingface.co" : trimmed
    }

    private func fileSize(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    public static func validateSnapshot(at url: URL, fileManager: FileManager = .default) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LocalOCRModelError.invalidSnapshot("模型目录不存在：\(url.path)")
        }
        guard fileManager.fileExists(atPath: url.appendingPathComponent("config.json").path) else {
            throw LocalOCRModelError.invalidSnapshot("缺少 config.json。")
        }
        guard self.hasTokenizerFiles(at: url, fileManager: fileManager) else {
            throw LocalOCRModelError.invalidSnapshot("缺少 tokenizer_config.json 或 tokenizer 文件。")
        }
        let safetensors = try self.safetensorsFiles(at: url, fileManager: fileManager)
        guard safetensors.isEmpty == false else {
            throw LocalOCRModelError.invalidSnapshot("缺少 safetensors 权重。")
        }
        try self.validateSafetensorsIndex(at: url, safetensors: safetensors, fileManager: fileManager)
        let manifestURL = url.appendingPathComponent(Self.snapshotManifestFilename)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw LocalOCRModelError.invalidSnapshot("缺少下载清单 \(Self.snapshotManifestFilename)。")
        }
    }

    public static func isAllowedSnapshotFile(_ path: String) -> Bool {
        let blockedPrefixes = [".git/", "refs/", "logs/"]
        if blockedPrefixes.contains(where: { path.hasPrefix($0) }) {
            return false
        }
        let blockedNames = [".gitattributes", "README.md", "LICENSE", "LICENSE.txt"]
        if blockedNames.contains(path) {
            return false
        }
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return ["json", "safetensors", "model", "txt", "jinja", "tiktoken", "py"].contains(ext)
    }

    private static func hasTokenizerFiles(at url: URL, fileManager: FileManager) -> Bool {
        let configExists = fileManager.fileExists(atPath: url.appendingPathComponent("tokenizer_config.json").path)
        let payloads = ["tokenizer.json", "tokenizer.model", "tokenizer.tiktoken", "spiece.model"]
        return configExists && payloads.contains {
            fileManager.fileExists(atPath: url.appendingPathComponent($0).path)
        }
    }

    private static func safetensorsFiles(at url: URL, fileManager: FileManager) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var files: [URL] = []
        for case let fileURL as URL in enumerator where fileURL.pathExtension.lowercased() == "safetensors" {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true {
                files.append(fileURL)
            }
        }
        return files
    }

    private static func validateSafetensorsIndex(at url: URL, safetensors: [URL], fileManager: FileManager) throws {
        let shardedTotals = safetensors.compactMap { self.shardedTotal(from: $0.lastPathComponent) }
        let requiresIndex = shardedTotals.contains { $0 > 1 }
        guard requiresIndex else { return }
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw LocalOCRModelError.invalidSnapshot("缺少 safetensors index。")
        }
        let hasIndex = enumerator.contains { item in
            (item as? URL)?.lastPathComponent.hasSuffix(".safetensors.index.json") == true
        }
        if hasIndex == false {
            throw LocalOCRModelError.invalidSnapshot("分片权重缺少 safetensors index。")
        }
    }

    private static func shardedTotal(from filename: String) -> Int? {
        let parts = filename.split(separator: "-")
        guard parts.count >= 4, parts[0] == "model", parts[2] == "of" else { return nil }
        return Int(parts[3].split(separator: ".").first.map(String.init) ?? "")
    }
}

public actor LocalMLXOCRRuntimeService: LocalMLXOCRServing {
    private let dataDirectory: URL
    private let manager: LocalOCRModelManager
    private let session: URLSession
    private var process: Process?
    private var endpoint: URL?
    private var runningModelID: String?
    private var runningModelPath: URL?
    private var outputCapture: ProcessOutputCapture?
    private var outputPipes: [Pipe] = []
    private var nextPort: Int = 19181
    private var activeRecognitionCount = 0
    private var idleShutdownTask: Task<Void, Never>?

    public init(
        dataDirectory: URL,
        manager: LocalOCRModelManager,
        session: URLSession = URLSession(configuration: .ephemeral)
    ) {
        self.dataDirectory = dataDirectory
        self.manager = manager
        self.session = session
    }

    public func recognize(_ request: LocalMLXOCRRequest, config: OCRModelConfig, networkConfig: AppConfig) async throws -> String {
        #if os(macOS)
        self.beginRecognition()
        defer { self.finishRecognition(config: config.localMLX) }
        let descriptor = try await self.manager.descriptor(for: config.localMLX)
        let modelDirectory = try await self.manager.installedModelDirectory(for: descriptor, config: config.localMLX)
        let endpoint = try await self.ensureRunning(
            descriptor: descriptor,
            modelDirectory: modelDirectory,
            config: config.localMLX
        )
        let body = try Self.makeChatCompletionsBody(request: request)
        var urlRequest = URLRequest(url: endpoint.appendingPathComponent("v1/chat/completions"))
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = TimeInterval(max(request.timeout, 1))
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = body
        let (data, response) = try await self.session.data(for: urlRequest)
        if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) == false {
            throw LocalOCRModelError.inferenceFailed(Self.errorMessage(from: data, status: http.statusCode))
        }
        let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let text = Self.extractChatCompletionText(from: payload)
        guard text.isEmpty == false else {
            throw LocalOCRModelError.inferenceFailed("本地 MLX OCR 返回为空。")
        }
        return text
        #else
        throw LocalOCRModelError.unsupportedPlatform
        #endif
    }

    public func status() async -> LocalMLXOCRRuntimeStatus {
        guard let process, process.isRunning, let endpoint else {
            return LocalMLXOCRRuntimeStatus(running: false, modelID: self.runningModelID, endpoint: nil, detail: "Local MLX OCR 未启动。")
        }
        return LocalMLXOCRRuntimeStatus(
            running: true,
            modelID: self.runningModelID,
            endpoint: endpoint.absoluteString,
            detail: self.runningModelPath?.path ?? "Local MLX OCR 运行中。"
        )
    }

    public func stop() {
        self.stopProcess(resetActiveRecognitions: true)
    }

    #if os(macOS)
    private func ensureRunning(
        descriptor: LocalOCRModelDescriptor,
        modelDirectory: URL,
        config: LocalMLXOCRConfig
    ) async throws -> URL {
        if let process, process.isRunning, let endpoint, self.runningModelPath == modelDirectory {
            return endpoint
        }
        if config.autoStart == false {
            throw LocalOCRModelError.runtimeNotRunning
        }
        self.stopProcess(resetActiveRecognitions: false)
        guard let executableURL = Self.runtimeExecutableURL(config: config) else {
            throw LocalOCRModelError.runtimeExecutableMissing(config.runtimePath.isEmpty ? "CodexProxyMLXOCRServer" : config.runtimePath)
        }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw LocalOCRModelError.runtimeExecutableMissing(executableURL.path)
        }
        let metalLibrary = executableURL.deletingLastPathComponent().appendingPathComponent("mlx.metallib")
        guard FileManager.default.fileExists(atPath: metalLibrary.path) else {
            throw LocalOCRModelError.runtimeStartFailed("缺少 \(metalLibrary.path)。")
        }

        let port = self.allocatePort()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["--model", modelDirectory.path, "--host", "127.0.0.1", "--port", "\(port)"]
        process.qualityOfService = .utility
        let capture = ProcessOutputCapture()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        self.attachOutputHandler(to: stdout, label: "stdout", capture: capture)
        self.attachOutputHandler(to: stderr, label: "stderr", capture: capture)
        do {
            try process.run()
        } catch {
            self.clearOutputHandlers()
            throw LocalOCRModelError.runtimeStartFailed(error.localizedDescription)
        }
        self.process = process
        self.outputCapture = capture
        self.outputPipes = [stdout, stderr]
        self.endpoint = URL(string: "http://127.0.0.1:\(port)")
        self.runningModelID = descriptor.id
        self.runningModelPath = modelDirectory
        return try await self.waitUntilHealthy(process: process)
    }

    private func beginRecognition() {
        self.idleShutdownTask?.cancel()
        self.idleShutdownTask = nil
        self.activeRecognitionCount += 1
    }

    private func finishRecognition(config: LocalMLXOCRConfig) {
        self.activeRecognitionCount = max(0, self.activeRecognitionCount - 1)
        guard self.activeRecognitionCount == 0 else {
            return
        }
        self.scheduleIdleShutdown(after: config.idleShutdownSeconds)
    }

    private func scheduleIdleShutdown(after seconds: Int) {
        self.idleShutdownTask?.cancel()
        self.idleShutdownTask = nil
        guard seconds > 0 else {
            return
        }
        self.idleShutdownTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(Int64(seconds)))
            } catch {
                return
            }
            await self?.stopIfIdle()
        }
    }

    private func stopIfIdle() {
        guard self.activeRecognitionCount == 0 else {
            return
        }
        self.stopProcess(resetActiveRecognitions: false)
    }

    private func stopProcess(resetActiveRecognitions: Bool) {
        self.idleShutdownTask?.cancel()
        self.idleShutdownTask = nil
        if resetActiveRecognitions {
            self.activeRecognitionCount = 0
        }
        self.process?.terminate()
        self.process = nil
        self.endpoint = nil
        self.runningModelID = nil
        self.runningModelPath = nil
        self.clearOutputHandlers()
        self.outputCapture = nil
    }

    private func waitUntilHealthy(process: Process) async throws -> URL {
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if process.isRunning == false {
                let output = self.captureAndClearFailedRuntimeOutput(process: process)
                throw LocalOCRModelError.runtimeStartFailed(output.isEmpty ? "进程已退出。" : output)
            }
            if let endpoint = self.endpoint {
                do {
                    var request = URLRequest(url: endpoint.appendingPathComponent("health"))
                    request.timeoutInterval = 2
                    let (_, response) = try await self.session.data(for: request)
                    if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                        return endpoint
                    }
                } catch {
                    // Keep waiting while the helper loads the model.
                }
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        process.terminate()
        let output = self.captureAndClearFailedRuntimeOutput(process: process)
        throw LocalOCRModelError.runtimeStartFailed(output.isEmpty ? "启动超时。" : output)
    }

    private static func runtimeExecutableURL(config: LocalMLXOCRConfig) -> URL? {
        let override = config.runtimePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if override.isEmpty == false {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
        }
        let helperName = "CodexProxyMLXOCRServer"
        let bundleHelper = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent(helperName)
        if FileManager.default.isExecutableFile(atPath: bundleHelper.path) {
            return bundleHelper
        }
        let executableSibling = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .deletingLastPathComponent()
            .appendingPathComponent(helperName)
        if FileManager.default.isExecutableFile(atPath: executableSibling.path) {
            return executableSibling
        }
        return nil
    }

    private func allocatePort() -> Int {
        let port = self.nextPort
        self.nextPort += 1
        if self.nextPort > 19280 {
            self.nextPort = 19181
        }
        return port
    }

    private func attachOutputHandler(to pipe: Pipe, label: String, capture: ProcessOutputCapture) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty == false {
                _ = capture.append(data, label: label)
            }
        }
    }

    private func captureAndClearFailedRuntimeOutput(process: Process) -> String {
        let output = self.outputCapture?.snapshot() ?? ""
        if self.process === process {
            self.process = nil
            self.endpoint = nil
            self.runningModelID = nil
            self.runningModelPath = nil
            self.outputCapture = nil
        }
        self.clearOutputHandlers()
        return output
    }

    private func clearOutputHandlers() {
        for pipe in self.outputPipes {
            pipe.fileHandleForReading.readabilityHandler = nil
        }
        self.outputPipes = []
    }
    #endif

    public static func makeChatCompletionsBody(request: LocalMLXOCRRequest) throws -> Data {
        var imageURLObject: [String: Any] = ["url": request.imageURL]
        if let detail = request.detail, detail.isEmpty == false {
            imageURLObject["detail"] = detail
        }
        let body: [String: Any] = [
            "model": request.modelID,
            "stream": false,
            "messages": [
                [
                    "role": "system",
                    "content": request.prompt,
                ],
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "text",
                            "text": "请识别这张图片的全部关键信息，并按系统要求输出。",
                        ],
                        [
                            "type": "image_url",
                            "image_url": imageURLObject,
                        ],
                    ],
                ],
            ],
            "max_tokens": request.maxTokens,
            "temperature": 0,
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    private static func extractChatCompletionText(from payload: [String: Any]) -> String {
        let choices = payload["choices"] as? [[String: Any]] ?? []
        return choices.compactMap { choice -> String? in
            let message = choice["message"] as? [String: Any]
            if let text = message?["content"] as? String {
                return text
            }
            return nil
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func errorMessage(from data: Data, status: Int) -> String {
        if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = payload["error"] as? String {
                return error
            }
            if let error = payload["error"] as? [String: Any],
               let message = error["message"] as? String {
                return message
            }
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        return "HTTP \(status) \(Helpers.truncate(body, limit: 300))"
    }
}

private final class ProcessOutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var text = ""

    init(limit: Int = 16_384) {
        self.limit = limit
    }

    @discardableResult
    func append(_ data: Data, label: String) -> String? {
        guard let value = String(data: data, encoding: .utf8), value.isEmpty == false else {
            return nil
        }
        self.lock.lock()
        self.text += "[\(label)] \(value)"
        if self.text.utf8.count > self.limit {
            let start = self.text.index(self.text.endIndex, offsetBy: -min(self.text.count, self.limit))
            self.text = String(self.text[start...])
        }
        let snapshot = self.text
        self.lock.unlock()
        return snapshot
    }

    func snapshot() -> String {
        self.lock.lock()
        let value = self.text
        self.lock.unlock()
        return value
    }
}
