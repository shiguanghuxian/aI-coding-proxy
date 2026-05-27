#if os(macOS)
import CoreImage
import Foundation
import MLXHuggingFace
import MLXLLM
import MLXLMCommon
import MLXVLM
import Network
import Tokenizers

private struct ServerArguments {
    var modelDirectory: URL
    var host: String
    var port: UInt16

    static func parse(_ arguments: [String]) throws -> ServerArguments {
        var modelPath: String?
        var host = "127.0.0.1"
        var port: UInt16 = 19181
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--model":
                index += 1
                guard index < arguments.count else { throw ServerError.badArguments("--model 缺少路径。") }
                modelPath = arguments[index]
            case "--host":
                index += 1
                guard index < arguments.count else { throw ServerError.badArguments("--host 缺少地址。") }
                host = arguments[index]
            case "--port":
                index += 1
                guard index < arguments.count, let value = UInt16(arguments[index]) else {
                    throw ServerError.badArguments("--port 必须是 1-65535。")
                }
                port = value
            default:
                break
            }
            index += 1
        }
        guard let modelPath else {
            throw ServerError.badArguments("必须提供 --model <model-directory>。")
        }
        return ServerArguments(modelDirectory: URL(fileURLWithPath: modelPath), host: host, port: port)
    }
}

private enum ServerError: Error, LocalizedError {
    case badArguments(String)
    case invalidRequest
    case imageDecodeFailed(String)
    case multipleImagesUnsupported(Int)
    case metalLibraryMissing(String)
    case modelLoadFailed(String)

    var errorDescription: String? {
        switch self {
        case .badArguments(let message):
            return message
        case .invalidRequest:
            return "HTTP 请求无效。"
        case .imageDecodeFailed(let message):
            return message
        case .multipleImagesUnsupported(let count):
            return "Local MLX OCR 当前按单图推理，本次请求包含 \(count) 张图片。"
        case .metalLibraryMissing(let path):
            return "内置 MLX Metal 库缺失：\(path)。"
        case .modelLoadFailed(let message):
            return message
        }
    }
}

private struct ChatCompletionRequest: Decodable {
    struct Message: Decodable {
        var role: String
        var content: ChatContent

        var text: String { self.content.text }
        var imageCount: Int { self.content.imageCount }
        func images() throws -> [UserInput.Image] { try self.content.images() }
    }

    var messages: [Message]
    var maxTokens: Int?
    var temperature: Float?
    var stream: Bool?

    enum CodingKeys: String, CodingKey {
        case messages
        case maxTokens = "max_tokens"
        case temperature
        case stream
    }
}

private enum ChatContent: Decodable {
    case text(String)
    case parts([ChatContentPart])

    var text: String {
        switch self {
        case .text(let text):
            return text
        case .parts(let parts):
            return parts.compactMap(\.text).joined(separator: "\n")
        }
    }

    var imageCount: Int {
        switch self {
        case .text:
            return 0
        case .parts(let parts):
            return parts.filter(\.isImage).count
        }
    }

    init(from decoder: Swift.Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
        } else {
            self = .parts(try container.decode([ChatContentPart].self))
        }
    }

    func images() throws -> [UserInput.Image] {
        switch self {
        case .text:
            return []
        case .parts(let parts):
            return try parts.compactMap { try $0.image() }
        }
    }
}

private enum ChatContentPart: Decodable {
    struct ImageURL: Decodable {
        var url: String
    }

    case text(String)
    case imageURL(String)
    case unsupported

    enum CodingKeys: String, CodingKey {
        case type
        case text
        case imageURL = "image_url"
    }

    init(from decoder: Swift.Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decodeIfPresent(String.self, forKey: .type) {
        case "text":
            self = .text(try container.decodeIfPresent(String.self, forKey: .text) ?? "")
        case "image_url":
            if let object = try? container.decode(ImageURL.self, forKey: .imageURL) {
                self = .imageURL(object.url)
            } else {
                self = .imageURL(try container.decode(String.self, forKey: .imageURL))
            }
        default:
            self = .unsupported
        }
    }

    var text: String? {
        if case .text(let text) = self { return text }
        return nil
    }

    var isImage: Bool {
        if case .imageURL = self { return true }
        return false
    }

    func image() throws -> UserInput.Image? {
        guard case .imageURL(let value) = self else { return nil }
        if value.hasPrefix("data:") {
            guard let comma = value.firstIndex(of: ",") else {
                throw ServerError.imageDecodeFailed("图片 data URL 格式无效。")
            }
            let metadata = value[..<comma]
            guard metadata.localizedCaseInsensitiveContains(";base64") else {
                throw ServerError.imageDecodeFailed("图片 data URL 必须使用 base64。")
            }
            let encoded = String(value[value.index(after: comma)...])
            guard let data = Data(base64Encoded: encoded), let image = CIImage(data: data) else {
                throw ServerError.imageDecodeFailed("图片 base64 解码失败。")
            }
            return .ciImage(image)
        }
        guard let url = URL(string: value) else {
            throw ServerError.imageDecodeFailed("图片 URL 无效。")
        }
        return .url(url)
    }
}

private struct ChatCompletionResponse: Encodable {
    struct Choice: Encodable {
        struct Message: Encodable {
            var role: String
            var content: String
        }

        var index: Int
        var message: Message
        var finishReason: String

        enum CodingKeys: String, CodingKey {
            case index
            case message
            case finishReason = "finish_reason"
        }
    }

    struct Usage: Encodable {
        var promptTokens: Int
        var completionTokens: Int
        var totalTokens: Int

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case totalTokens = "total_tokens"
        }
    }

    var id: String
    var object: String
    var created: Int
    var model: String
    var choices: [Choice]
    var usage: Usage
}

private struct HealthResponse: Encodable {
    var status: String
    var runtime: String
    var model: String
}

private struct ErrorResponse: Encodable {
    var error: ErrorBody

    struct ErrorBody: Encodable {
        var message: String
        var type: String
    }

    init(message: String) {
        self.error = ErrorBody(message: message, type: "local_mlx_ocr_error")
    }
}

private actor MLXOCRRuntime {
    private let modelDirectory: URL
    private var container: ModelContainer?
    private var isGenerating = false
    private var generationWaiters: [CheckedContinuation<Void, Never>] = []

    init(modelDirectory: URL) {
        self.modelDirectory = modelDirectory
    }

    func load() async throws {
        _ = MLXLLM.TrampolineModelFactory.self
        _ = MLXVLM.TrampolineModelFactory.self
        if self.isGemma4ModelDirectory() {
            let tokenizerLoader = #huggingFaceTokenizerLoader()
            do {
                self.container = try await VLMModelFactory.shared.loadContainer(from: self.modelDirectory, using: tokenizerLoader)
                return
            } catch {
                let vlmError = error.localizedDescription
                do {
                    self.container = try await LLMModelFactory.shared.loadContainer(from: self.modelDirectory, using: tokenizerLoader)
                    return
                } catch {
                    throw ServerError.modelLoadFailed("Gemma4 模型加载失败。\n[VLM] \(vlmError)\n[LLM] \(error.localizedDescription)")
                }
            }
        }
        self.container = try await loadModelContainer(from: self.modelDirectory, using: #huggingFaceTokenizerLoader())
    }

    func health() -> HealthResponse {
        HealthResponse(status: "ok", runtime: "mlx-swift-lm", model: self.modelDirectory.path)
    }

    func chat(_ request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        try await self.withGenerationPermit {
            try await self.chatUnlocked(request)
        }
    }

    private func withGenerationPermit<T>(_ operation: () async throws -> T) async throws -> T {
        await self.enterGenerationPermit()
        defer { self.leaveGenerationPermit() }
        return try await operation()
    }

    private func enterGenerationPermit() async {
        if self.isGenerating == false {
            self.isGenerating = true
            return
        }
        await withCheckedContinuation { continuation in
            self.generationWaiters.append(continuation)
        }
    }

    private func leaveGenerationPermit() {
        if self.generationWaiters.isEmpty {
            self.isGenerating = false
        } else {
            self.generationWaiters.removeFirst().resume()
        }
    }

    private func chatUnlocked(_ request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
        guard let container else { throw ServerError.invalidRequest }
        let imageCount = request.messages.reduce(0) { $0 + $1.imageCount }
        if imageCount > 1 {
            throw ServerError.multipleImagesUnsupported(imageCount)
        }
        let chat = try request.messages.map { message -> Chat.Message in
            switch message.role {
            case "system":
                return .system(message.text)
            case "assistant":
                return .assistant(message.text)
            default:
                return .user(message.text, images: try message.images())
            }
        }
        let prepared = try await container.prepare(input: UserInput(chat: chat))
        let stream = try await container.generate(
            input: prepared,
            parameters: GenerateParameters(maxTokens: request.maxTokens ?? 2_048, temperature: request.temperature ?? 0)
        )
        var text = ""
        var promptTokens = 0
        var completionTokens = 0
        for await generation in stream {
            switch generation {
            case .chunk(let chunk):
                text += chunk
            case .info(let info):
                promptTokens = info.promptTokenCount
                completionTokens = info.generationTokenCount
            case .toolCall:
                break
            }
        }
        return ChatCompletionResponse(
            id: "chatcmpl-\(UUID().uuidString)",
            object: "chat.completion",
            created: Int(Date().timeIntervalSince1970),
            model: self.modelDirectory.lastPathComponent,
            choices: [.init(index: 0, message: .init(role: "assistant", content: text), finishReason: "stop")],
            usage: .init(
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                totalTokens: promptTokens + completionTokens
            )
        )
    }

    private func isGemma4ModelDirectory() -> Bool {
        let configURL = self.modelDirectory.appendingPathComponent("config.json")
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return (json["model_type"] as? String) == "gemma4"
    }
}

private final class HTTPServer: @unchecked Sendable {
    private let runtime: MLXOCRRuntime
    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.codexproxy.mlx-ocr-server")

    init(port: UInt16, runtime: MLXOCRRuntime) throws {
        self.runtime = runtime
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        self.listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
    }

    func start() async throws {
        let ready = ListenerReadyContinuation()
        self.listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receive(connection: connection, data: Data())
        }
        self.listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                ready.resume()
            case .failed(let error):
                ready.resume(throwing: error)
            case .cancelled:
                ready.resume(throwing: ServerError.modelLoadFailed("HTTP listener 已取消。"))
            default:
                break
            }
        }
        self.listener.start(queue: self.queue)
        try await ready.wait()
    }

    private func receive(connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.sendError(connection: connection, status: 500, message: error.localizedDescription)
                return
            }
            var buffer = data
            if let chunk {
                buffer.append(chunk)
            }
            if let request = HTTPRequest(data: buffer) {
                Task { await self.handle(request: request, connection: connection) }
            } else if isComplete {
                self.sendError(connection: connection, status: 400, message: "请求不完整。")
            } else {
                self.receive(connection: connection, data: buffer)
            }
        }
    }

    private func handle(request: HTTPRequest, connection: NWConnection) async {
        do {
            switch (request.method, request.path) {
            case ("GET", "/health"):
                self.send(connection: connection, status: 200, data: try JSONEncoder().encode(await self.runtime.health()))
            case ("POST", "/v1/chat/completions"):
                let decoded = try JSONDecoder().decode(ChatCompletionRequest.self, from: request.body)
                guard decoded.stream != true else {
                    self.sendError(connection: connection, status: 400, message: "Local MLX OCR helper 不支持 stream。")
                    return
                }
                self.send(connection: connection, status: 200, data: try JSONEncoder().encode(try await self.runtime.chat(decoded)))
            default:
                self.sendError(connection: connection, status: 404, message: "Not Found")
            }
        } catch {
            self.sendError(connection: connection, status: 500, message: error.localizedDescription)
        }
    }

    private func sendError(connection: NWConnection, status: Int, message: String) {
        let payload = (try? JSONEncoder().encode(ErrorResponse(message: message)))
            ?? Data(#"{"error":{"message":"Unknown error","type":"local_mlx_ocr_error"}}"#.utf8)
        self.send(connection: connection, status: status, data: payload)
    }

    private func send(connection: NWConnection, status: Int, data: Data) {
        let reason = status == 200 ? "OK" : "Error"
        var header = "HTTP/1.1 \(status) \(reason)\r\n"
        header += "content-type: application/json; charset=utf-8\r\n"
        header += "content-length: \(data.count)\r\n"
        header += "connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(data)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

private final class ListenerReadyContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func wait() async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.lock.lock()
            if let result {
                self.lock.unlock()
                continuation.resume(with: result)
            } else {
                self.continuation = continuation
                self.lock.unlock()
            }
        }
    }

    func resume() {
        self.resume(with: .success(()))
    }

    func resume(throwing error: Error) {
        self.resume(with: .failure(error))
    }

    private func resume(with result: Result<Void, Error>) {
        self.lock.lock()
        guard self.result == nil else {
            self.lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        self.lock.unlock()
        continuation?.resume(with: result)
    }
}

private struct HTTPRequest {
    var method: String
    var path: String
    var body: Data

    init?(data: Data) {
        guard let marker = data.range(of: Data("\r\n\r\n".utf8)),
              let headerText = String(data: data[..<marker.lowerBound], encoding: .utf8)
        else { return nil }
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var contentLength = 0
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1)
            if pair.count == 2, pair[0].lowercased() == "content-length" {
                contentLength = Int(pair[1].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            }
        }
        let bodyStart = marker.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }
        self.method = String(parts[0])
        self.path = String(parts[1].split(separator: "?").first ?? parts[1])
        self.body = data[bodyStart..<(bodyStart + contentLength)]
    }
}

@main
private enum CodexProxyMLXOCRServerMain {
    static func main() async {
        do {
            let arguments = try ServerArguments.parse(CommandLine.arguments)
            try self.validateBundledMetalLibrary()
            let runtime = MLXOCRRuntime(modelDirectory: arguments.modelDirectory)
            try await runtime.load()
            let server = try HTTPServer(port: arguments.port, runtime: runtime)
            try await server.start()
            FileHandle.standardError.write(Data("CodexProxyMLXOCRServer ready on \(arguments.host):\(arguments.port)\n".utf8))
            while Task.isCancelled == false {
                try await Task.sleep(for: .seconds(3_600))
            }
        } catch {
            FileHandle.standardError.write(Data("CodexProxyMLXOCRServer failed: \(error.localizedDescription)\n".utf8))
            Foundation.exit(2)
        }
    }

    private static func validateBundledMetalLibrary() throws {
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        let metalLibraryURL = executableURL.deletingLastPathComponent().appendingPathComponent("mlx.metallib")
        guard FileManager.default.fileExists(atPath: metalLibraryURL.path) else {
            throw ServerError.metalLibraryMissing(metalLibraryURL.path)
        }
    }
}
#else
import Foundation

@main
private enum CodexProxyMLXOCRServerMain {
    static func main() {
        FileHandle.standardError.write(Data("CodexProxyMLXOCRServer requires macOS.\n".utf8))
        Foundation.exit(2)
    }
}
#endif
