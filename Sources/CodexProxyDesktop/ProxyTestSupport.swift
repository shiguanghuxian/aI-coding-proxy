#if os(macOS)
import CodexProxyCore
import Foundation
import SwiftUI

enum ProxyTestEndpoint: String, CaseIterable, Identifiable, Sendable {
    case chatCompletions
    case responses
    case imageGenerations
    case imageEdits
    case anthropicMessages
    case geminiGenerateContent

    var id: String { self.rawValue }

    var pathComponent: String {
        switch self {
        case .chatCompletions:
            return "chat/completions"
        case .responses:
            return "responses"
        case .imageGenerations:
            return "images/generations"
        case .imageEdits:
            return "images/edits"
        case .anthropicMessages:
            return "messages"
        case .geminiGenerateContent:
            return ""
        }
    }

    var prefersAnthropicRootBaseURL: Bool {
        self == .anthropicMessages
    }

    var prefersGeminiRootBaseURL: Bool {
        self == .geminiGenerateContent
    }

    var supportsCustomModelEntry: Bool {
        true
    }

    var supportsStreaming: Bool {
        self != .imageGenerations && self != .imageEdits
    }

    var supportsSystemPrompt: Bool {
        self != .imageGenerations && self != .imageEdits
    }

    var supportsToolsJSON: Bool {
        self == .anthropicMessages || self == .geminiGenerateContent
    }

    var modelFamily: ProxyTestModelFamily {
        switch self {
        case .imageGenerations, .imageEdits:
            return .image
        case .anthropicMessages:
            return .anthropic
        case .geminiGenerateContent:
            return .gemini
        case .chatCompletions, .responses:
            return .gpt
        }
    }

    func modelGroup(in catalog: ProxyTestModelCatalog) -> ProxyTestModelGroup {
        switch self {
        case .anthropicMessages:
            return catalog.anthropicMessages
        case .chatCompletions:
            return catalog.chatCompletions
        case .responses:
            return catalog.responses
        case .imageGenerations, .imageEdits:
            return catalog.imageGenerations
        case .geminiGenerateContent:
            return catalog.geminiGenerateContent
        }
    }

    func defaultModel(in catalog: ProxyTestModelCatalog) -> String {
        let group = self.modelGroup(in: catalog)
        let trimmed = group.defaultModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? self.fallbackDefaultModel : trimmed
    }

    func availableModels(in catalog: ProxyTestModelCatalog) -> [String] {
        let models = self.modelGroup(in: catalog).models
        return Self.mergeModels(models)
    }

    func acceptsModelFamily(_ model: String, catalog: ProxyTestModelCatalog) -> Bool {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if self.availableModels(in: catalog).contains(trimmed) {
            return true
        }
        if self == .imageGenerations || self == .imageEdits {
            return true
        }
        return Self.inferredFamily(for: trimmed) == self.modelFamily
    }

    private var fallbackDefaultModel: String {
        switch self {
        case .anthropicMessages:
            return ProxyTestDraft.defaultAnthropicModel
        case .geminiGenerateContent:
            return ProxyTestDraft.defaultGeminiModel
        case .imageGenerations, .imageEdits:
            return ProxyTestDraft.defaultImageModel
        case .chatCompletions, .responses:
            return ProxyTestDraft.defaultOpenAIModel
        }
    }

    fileprivate static func inferredFamily(for model: String) -> ProxyTestModelFamily? {
        let lower = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !lower.isEmpty else { return nil }
        if lower.contains("image") {
            return .image
        }
        if lower.contains("claude") || lower.contains("sonnet") || lower.contains("opus") || lower.contains("haiku") {
            return .anthropic
        }
        if lower.contains("gemini") {
            return .gemini
        }
        if lower.contains("gpt") {
            return .gpt
        }
        return nil
    }

    private static func mergeModels(_ models: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for model in models {
            let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
            ordered.append(trimmed)
        }
        return ordered
    }
}

enum ProxyTestRunState: Equatable, Sendable {
    case idle
    case loadingModels
    case running
    case completed
    case failed
    case cancelled
}

struct ProxyTestUsage: Equatable, Sendable {
    var inputTokens: Int64
    var outputTokens: Int64
    var totalTokens: Int64

    init(inputTokens: Int64 = 0, outputTokens: Int64 = 0, totalTokens: Int64 = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
    }
}

struct ProxyTestImageOutput: Equatable, Sendable {
    var imageData: Data?
    var url: String?
    var revisedPrompt: String?

    init(imageData: Data? = nil, url: String? = nil, revisedPrompt: String? = nil) {
        self.imageData = imageData
        self.url = url
        self.revisedPrompt = revisedPrompt
    }
}

struct ProxyTestResult: Equatable, Sendable {
    var assistantText: String
    var rawResponseJSON: String
    var rawSSETranscript: String
    var latencyMilliseconds: Int?
    var httpStatus: Int?
    var usage: ProxyTestUsage?
    var imageOutputs: [ProxyTestImageOutput]
    var errorSummary: String?
    var rawError: String?

    init(
        assistantText: String = "",
        rawResponseJSON: String = "",
        rawSSETranscript: String = "",
        latencyMilliseconds: Int? = nil,
        httpStatus: Int? = nil,
        usage: ProxyTestUsage? = nil,
        imageOutputs: [ProxyTestImageOutput] = [],
        errorSummary: String? = nil,
        rawError: String? = nil
    ) {
        self.assistantText = assistantText
        self.rawResponseJSON = rawResponseJSON
        self.rawSSETranscript = rawSSETranscript
        self.latencyMilliseconds = latencyMilliseconds
        self.httpStatus = httpStatus
        self.usage = usage
        self.imageOutputs = imageOutputs
        self.errorSummary = errorSummary
        self.rawError = rawError
    }
}

struct ProxyTestDraft: Equatable, Sendable {
    static let defaultOpenAIModel: String = ProxyTranscoder.defaultModel
    static let defaultImageModel = "codex-gpt-image-2"
    static let defaultAnthropicModel = "claude-sonnet-4-5"
    static let defaultGeminiModel = "gemini-2.5-flash"

    var endpoint: ProxyTestEndpoint
    var model: String
    var systemPrompt: String
    var userPrompt: String
    var toolsJSON: String
    var stream: Bool
    var endpointURL: String
    var apiKey: String
    var selectedAccountKey: String
    var imageEditFileURLs: [URL]

    init(
        endpoint: ProxyTestEndpoint = .chatCompletions,
        model: String = Self.defaultOpenAIModel,
        systemPrompt: String = "",
        userPrompt: String = "",
        toolsJSON: String = "",
        stream: Bool = false,
        endpointURL: String = "",
        apiKey: String = "",
        selectedAccountKey: String = "",
        imageEditFileURLs: [URL] = []
    ) {
        self.endpoint = endpoint
        self.model = (endpoint == .imageGenerations || endpoint == .imageEdits) && model == Self.defaultOpenAIModel
            ? Self.defaultImageModel
            : model
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.toolsJSON = toolsJSON
        self.stream = stream
        self.endpointURL = endpointURL
        self.apiKey = apiKey
        self.selectedAccountKey = selectedAccountKey
        self.imageEditFileURLs = imageEditFileURLs
    }

    var hasPrompt: Bool {
        !self.userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var selectedAccountKeyValue: String? {
        let trimmed = self.selectedAccountKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var hasImageEditInputs: Bool {
        self.imageEditFileURLs.isEmpty == false
    }

    var requiresImageEditInputs: Bool {
        self.endpoint == .imageEdits
    }

    func requestPayload() throws -> [String: Any] {
        switch self.endpoint {
        case .chatCompletions:
            var messages: [[String: Any]] = []
            let system = self.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !system.isEmpty {
                messages.append([
                    "role": "system",
                    "content": system,
                ])
            }
            messages.append([
                "role": "user",
                "content": self.userPrompt,
            ])
            return [
                "model": self.model,
                "messages": messages,
                "stream": self.stream,
            ]
        case .responses:
            var payload: [String: Any] = [
                "model": self.model,
                "input": self.userPrompt,
                "stream": self.stream,
            ]
            let system = self.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !system.isEmpty {
                payload["instructions"] = system
            }
            return payload
        case .imageGenerations:
            return [
                "model": self.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? ProxyTestDraft.defaultImageModel
                    : self.model,
                "prompt": self.userPrompt,
                "n": 1,
                "size": "1024x1024",
            ]
        case .imageEdits:
            return self.imageEditsPreviewPayload()
        case .anthropicMessages:
            var payload: [String: Any] = [
                "model": self.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? ProxyTestDraft.defaultAnthropicModel : self.model,
                "messages": [
                    [
                        "role": "user",
                        "content": [
                            [
                                "type": "text",
                                "text": self.userPrompt,
                            ],
                        ],
                    ],
                ],
                "stream": self.stream,
            ]
            let system = self.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !system.isEmpty {
                payload["system"] = system
            }

            let toolsText = self.toolsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
            if !toolsText.isEmpty {
                guard let data = toolsText.data(using: .utf8) else {
                    throw ProxyError.message("Anthropic tools JSON is not valid UTF-8.")
                }
                let object = try JSONSerialization.jsonObject(with: data)
                guard let array = object as? [Any] else {
                    throw ProxyError.message("Anthropic `tools` must be a JSON array.")
                }
                payload["tools"] = array
            }
            return payload
        case .geminiGenerateContent:
            var payload: [String: Any] = [
                "contents": [
                    [
                        "role": "user",
                        "parts": [
                            [
                                "text": self.userPrompt,
                            ],
                        ],
                    ],
                ],
            ]
            let system = self.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !system.isEmpty {
                payload["systemInstruction"] = [
                    "parts": [
                        ["text": system],
                    ],
                ]
            }

            let toolsText = self.toolsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
            if !toolsText.isEmpty {
                guard let data = toolsText.data(using: .utf8) else {
                    throw ProxyError.message("Gemini tools JSON is not valid UTF-8.")
                }
                let object = try JSONSerialization.jsonObject(with: data)
                guard let array = object as? [[String: Any]] else {
                    throw ProxyError.message("Gemini `tools` must be a JSON array.")
                }
                payload["tools"] = array
            }
            return payload
        }
    }

    func requestData(pretty: Bool = false) throws -> Data {
        if self.endpoint == .imageEdits {
            return try self.multipartImageEditBody().data
        }
        let options: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try JSONSerialization.data(withJSONObject: self.requestPayload(), options: options)
    }

    func requestBody() throws -> ProxyTestRequestBody {
        if self.endpoint == .imageEdits {
            return try self.multipartImageEditBody()
        }
        return ProxyTestRequestBody(
            data: try self.requestData(),
            contentType: "application/json"
        )
    }

    func requestPreview() -> String {
        do {
            if self.endpoint == .imageEdits {
                let payload = self.imageEditsPreviewPayload()
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
                return String(decoding: data, as: UTF8.self)
            }
            return String(decoding: try self.requestData(pretty: true), as: UTF8.self)
        } catch {
            let payload = ["error": error.localizedDescription]
            guard
                let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            else {
                return "{}"
            }
            return String(decoding: data, as: UTF8.self)
        }
    }

    private func imageEditsPreviewPayload() -> [String: Any] {
        [
            "content_type": self.multipartImageEditsContentType(),
            "model": self.resolvedImageModel,
            "prompt": self.userPrompt,
            "n": 1,
            "size": "1024x1024",
            "response_format": "b64_json",
            "images": self.imageEditFileURLs.map { url in
                [
                    "filename": url.lastPathComponent,
                    "size_bytes": Self.fileSize(at: url) ?? 0,
                    "content_type": Self.imageContentType(for: url),
                ] as [String: Any]
            },
        ]
    }

    private var resolvedImageModel: String {
        let trimmed = self.model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? ProxyTestDraft.defaultImageModel : trimmed
    }

    private func multipartImageEditBody() throws -> ProxyTestRequestBody {
        guard self.imageEditFileURLs.isEmpty == false else {
            throw ProxyError.message("Images edits test requires at least one selected image.")
        }
        let boundary = self.multipartImageEditsBoundary()
        var body = Data()
        func appendTextField(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data(value.utf8))
            body.append(Data("\r\n".utf8))
        }
        appendTextField("model", self.resolvedImageModel)
        appendTextField("prompt", self.userPrompt)
        appendTextField("n", "1")
        appendTextField("size", "1024x1024")
        appendTextField("response_format", "b64_json")

        for url in self.imageEditFileURLs {
            let data = try Data(contentsOf: url)
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(
                Data(
                    "Content-Disposition: form-data; name=\"image\"; filename=\"\(Self.multipartEscapedFilename(url.lastPathComponent))\"\r\n".utf8
                )
            )
            body.append(Data("Content-Type: \(Self.imageContentType(for: url))\r\n\r\n".utf8))
            body.append(data)
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return ProxyTestRequestBody(
            data: body,
            contentType: self.multipartImageEditsContentType(boundary: boundary)
        )
    }

    private func multipartImageEditsContentType(boundary: String? = nil) -> String {
        "multipart/form-data; boundary=\(boundary ?? self.multipartImageEditsBoundary())"
    }

    private func multipartImageEditsBoundary() -> String {
        let seed = [
            self.endpoint.rawValue,
            self.resolvedImageModel,
            self.userPrompt,
            self.imageEditFileURLs.map(\.path).joined(separator: "|"),
        ].joined(separator: "\u{1F}")
        return "CodexProxyImageEdit-\(Helpers.sha256(seed).prefix(24))"
    }

    private static func imageContentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "webp":
            return "image/webp"
        case "gif":
            return "image/gif"
        default:
            return "image/png"
        }
    }

    private static func fileSize(at url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else {
            return nil
        }
        return size.int64Value
    }

    private static func multipartEscapedFilename(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

struct ProxyTestRequestBody: Equatable, Sendable {
    var data: Data
    var contentType: String
}

struct ProxyPublicRequestFailure: Error, LocalizedError, Sendable {
    let statusCode: Int
    let message: String
    let rawBody: String

    var errorDescription: String? {
        let trimmed = self.rawBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return self.message
    }
}

private struct ProxyHealthPayload: Decodable, Sendable {
    var status: String
    var service: String
    var version: String?
    var publicBaseURL: String?
}

private struct ProxyModelListPayload: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        var id: String
    }

    var data: [Item]
}

actor ProxyPublicAPIClient {
    typealias HealthHandler = @Sendable (String) async throws -> Void
    typealias ModelsHandler = @Sendable (String, String) async throws -> [String]
    typealias ExecuteNonStreamHandler = @Sendable (ProxyTestDraft) async throws -> SimpleHTTPResponse
    typealias ExecuteStreamHandler = @Sendable (ProxyTestDraft) async throws -> StreamingHTTPResponse

    private let session: URLSession
    private let healthHandler: HealthHandler?
    private let modelsHandler: ModelsHandler?
    private let executeNonStreamHandler: ExecuteNonStreamHandler?
    private let executeStreamHandler: ExecuteStreamHandler?

    init(
        session: URLSession = ProxyPublicAPIClient.makeSession(),
        healthHandler: HealthHandler? = nil,
        modelsHandler: ModelsHandler? = nil,
        executeNonStreamHandler: ExecuteNonStreamHandler? = nil,
        executeStreamHandler: ExecuteStreamHandler? = nil
    ) {
        self.session = session
        self.healthHandler = healthHandler
        self.modelsHandler = modelsHandler
        self.executeNonStreamHandler = executeNonStreamHandler
        self.executeStreamHandler = executeStreamHandler
    }

    func health(baseURL: String) async throws {
        if let healthHandler {
            try await healthHandler(baseURL)
            return
        }
        let url = try Self.healthURL(from: baseURL)
        _ = try await self.dataRequest(url: url, apiKey: nil, method: "GET", body: nil)
    }

    func models(baseURL: String, apiKey: String) async throws -> [String] {
        if let modelsHandler {
            return try await modelsHandler(baseURL, apiKey)
        }
        let url = try Self.openAIAPIBaseURL(from: baseURL).appendingPathComponent("models")
        let response = try await self.dataRequest(url: url, apiKey: apiKey, method: "GET", body: nil)
        let payload: ProxyModelListPayload
        do {
            payload = try Helpers.readJSON(ProxyModelListPayload.self, from: response.body)
        } catch {
            if let detail = DecodingDiagnostics.describe(
                error,
                endpoint: "/v1/models",
                method: "GET",
                targetType: ProxyModelListPayload.self,
                responseBody: response.body
            ) {
                throw ProxyError.message(detail)
            }
            throw error
        }
        let models = Array(Set(payload.data.map(\.id))).sorted()
        return models.isEmpty ? ProxyTranscoder.supportedModels : models
    }

    func executeNonStream(draft: ProxyTestDraft) async throws -> SimpleHTTPResponse {
        if let executeNonStreamHandler {
            return try await executeNonStreamHandler(draft)
        }
        let url = try Self.requestURL(for: draft, stream: false)
        let requestBody = try draft.requestBody()
        return try await self.dataRequest(
            url: url,
            apiKey: nil,
            method: "POST",
            body: requestBody.data,
            bodyContentType: requestBody.contentType,
            additionalHeaders: self.additionalHeaders(for: draft)
                .merging(self.authenticationHeaders(for: draft), uniquingKeysWith: { _, new in new })
        )
    }

    func executeStream(draft: ProxyTestDraft) async throws -> StreamingHTTPResponse {
        if let executeStreamHandler {
            return try await executeStreamHandler(draft)
        }
        let url = try Self.requestURL(for: draft, stream: true)
        let requestBody = try draft.requestBody()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = requestBody.data
        request.timeoutInterval = 1_800
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(requestBody.contentType, forHTTPHeaderField: "Content-Type")
        for (name, value) in self.authenticationHeaders(for: draft)
            .merging(self.additionalHeaders(for: draft), uniquingKeysWith: { _, new in new })
        {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (bytes, response) = try await self.session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProxyError.message("Invalid HTTP response")
        }

        if !(200..<300).contains(httpResponse.statusCode) {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
            }
            throw ProxyPublicRequestFailure(
                statusCode: httpResponse.statusCode,
                message: Self.httpErrorMessage(from: data, statusCode: httpResponse.statusCode),
                rawBody: Self.prettyResponseBody(from: data)
            )
        }

        let stream = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                var iterator = bytes.makeAsyncIterator()
                var buffer = Data()
                buffer.reserveCapacity(2_048)

                do {
                    while let byte = try await iterator.next() {
                        try Task.checkCancellation()
                        buffer.append(byte)
                        if buffer.count >= 2_048 {
                            continuation.yield(buffer)
                            buffer.removeAll(keepingCapacity: true)
                        }
                    }
                    if !buffer.isEmpty {
                        continuation.yield(buffer)
                    }
                    continuation.finish()
                } catch {
                    if error is CancellationError {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }

        return StreamingHTTPResponse(
            statusCode: httpResponse.statusCode,
            headers: Self.responseHeaders(from: httpResponse),
            body: stream
        )
    }

    private func dataRequest(
        url: URL,
        apiKey: String?,
        method: String,
        body: Data?,
        bodyContentType: String = "application/json",
        additionalHeaders: [String: String] = [:]
    ) async throws -> SimpleHTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 1_800
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue(bodyContentType, forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in additionalHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await self.session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProxyError.message("Invalid HTTP response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ProxyPublicRequestFailure(
                statusCode: httpResponse.statusCode,
                message: Self.httpErrorMessage(from: data, statusCode: httpResponse.statusCode),
                rawBody: Self.prettyResponseBody(from: data)
            )
        }
        return SimpleHTTPResponse(
            statusCode: httpResponse.statusCode,
            headers: Self.responseHeaders(from: httpResponse),
            body: data
        )
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1_800
        configuration.timeoutIntervalForResource = 1_800
        return URLSession(configuration: configuration)
    }

    private func additionalHeaders(for draft: ProxyTestDraft) -> [String: String] {
        var headers = [
            ProxyHeaderName.proxyTestConsole: "1",
        ]
        if let selectedAccountKey = draft.selectedAccountKeyValue {
            headers[ProxyHeaderName.testAccountKey] = selectedAccountKey
        }
        return headers
    }

    private func authenticationHeaders(for draft: ProxyTestDraft) -> [String: String] {
        switch draft.endpoint {
        case .geminiGenerateContent:
            return ["x-goog-api-key": draft.apiKey]
        case .chatCompletions, .responses, .imageGenerations, .imageEdits, .anthropicMessages:
            return ["Authorization": "Bearer \(draft.apiKey)"]
        }
    }

    private static func normalizedURL(from baseURL: String) throws -> URL {
        guard let url = URL(string: try OpenAICompatibleUpstream.normalizeBaseURL(baseURL)) else {
            throw ProxyError.message("Invalid URL: \(baseURL)")
        }
        return url
    }

    private static func rootURL(from baseURL: String) throws -> URL {
        try self.normalizedURL(from: baseURL)
    }

    private static func openAIAPIBaseURL(from baseURL: String) throws -> URL {
        try self.rootURL(from: baseURL)
    }

    private static func v1BaseURL(from baseURL: String) throws -> URL {
        let root = try self.rootURL(from: baseURL)
        return root.appendingPathComponent("v1")
    }

    private static func proxyRootURL(from baseURL: String) throws -> URL {
        let url = try self.rootURL(from: baseURL)
        if url.pathComponents.last == "v1" {
            return url.deletingLastPathComponent()
        }
        return url
    }

    private static func requestURL(for draft: ProxyTestDraft, stream: Bool) throws -> URL {
        switch draft.endpoint {
        case .chatCompletions, .responses, .imageGenerations, .imageEdits:
            return try self.openAIAPIBaseURL(from: draft.endpointURL).appendingPathComponent(draft.endpoint.pathComponent)
        case .anthropicMessages:
            return try self.v1BaseURL(from: draft.endpointURL).appendingPathComponent(draft.endpoint.pathComponent)
        case .geminiGenerateContent:
            let model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? ProxyTestDraft.defaultGeminiModel
                : draft.model
            let operation = stream ? "streamGenerateContent" : "generateContent"
            return try self.rootURL(from: draft.endpointURL)
                .appendingPathComponent("v1beta")
                .appendingPathComponent("models")
                .appendingPathComponent("\(model):\(operation)")
        }
    }

    private static func healthURL(from baseURL: String) throws -> URL {
        try self.proxyRootURL(from: baseURL).appendingPathComponent("health")
    }

    private static func responseHeaders(from response: HTTPURLResponse) -> [String: String] {
        response.allHeaderFields.reduce(into: [:]) { partialResult, entry in
            guard let key = entry.key as? String else { return }
            partialResult[key.lowercased()] = "\(entry.value)"
        }
    }

    private static func httpErrorMessage(from data: Data, statusCode: Int) -> String {
        if
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = object["error"] as? [String: Any],
            let message = error["message"] as? String,
            !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return message
        }

        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            return text
        }
        return "HTTP \(statusCode)"
    }

    private static func prettyResponseBody(from data: Data) -> String {
        if
            let object = try? JSONSerialization.jsonObject(with: data),
            let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        {
            return String(decoding: pretty, as: UTF8.self)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

extension DesktopAppModel {
    var proxyTestSelectedAccountKey: String {
        self.proxyTestDraft.selectedAccountKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var proxyTestAccountOptions: [RequestLogAccountOption] {
        let sortedAccounts = self.orderedAccountsBySelection
        let duplicateLabels = self.accountSelectionDuplicateLabels(in: sortedAccounts)
        var options = [
            RequestLogAccountOption(
                accountKey: "",
                title: self.text(.optionAutoSelectByOrder)
            ),
        ]
        options.append(
            contentsOf: sortedAccounts.map { account in
                RequestLogAccountOption(
                    accountKey: account.accountKey,
                    title: self.accountSelectionOptionTitle(for: account, duplicateLabels: duplicateLabels)
                )
            }
        )

        let selectedAccountKey = self.proxyTestSelectedAccountKey
        if !selectedAccountKey.isEmpty, options.contains(where: { $0.accountKey == selectedAccountKey }) == false {
            options.insert(RequestLogAccountOption(accountKey: selectedAccountKey, title: selectedAccountKey), at: 1)
        }
        return options
    }

    var proxyTestSelectedAccount: AccountSummary? {
        let selectedAccountKey = self.proxyTestSelectedAccountKey
        guard !selectedAccountKey.isEmpty else { return nil }
        return self.accounts.first(where: { $0.accountKey == selectedAccountKey })
    }

    var proxyTestSelectedDataSource: ProxyDataSource? {
        self.proxyTestSelectedAccount?.authMode.primaryPinnedProxyTestDataSource
    }

    private func proxyTestSelectedAccount(for draft: ProxyTestDraft) -> AccountSummary? {
        guard let selectedAccountKey = draft.selectedAccountKeyValue else {
            return nil
        }
        return self.accounts.first(where: { $0.accountKey == selectedAccountKey })
    }

    private func proxyTestUsesAdminOnlyGeminiExecution(for draft: ProxyTestDraft) -> Bool {
        guard draft.endpoint == .geminiGenerateContent,
              let account = self.proxyTestSelectedAccount(for: draft)
        else {
            return false
        }
        return account.authMode == .geminiOAuth
    }

    private func proxyTestSelectedAccountEndpointCompatibilityIssue(
        for draft: ProxyTestDraft
    ) -> String? {
        guard let account = self.proxyTestSelectedAccount(for: draft),
              (
                (account.authMode == .geminiOAuth && draft.endpoint != .geminiGenerateContent)
                    || ((draft.endpoint == .imageGenerations || draft.endpoint == .imageEdits) && account.authMode.providerFamily != .openAI)
              )
        else {
            return nil
        }
        if draft.endpoint == .imageGenerations || draft.endpoint == .imageEdits {
            return self.localized(
                zh: "Images 图片测试只支持 OpenAI 授权登录账号和 OpenAI API Key 类型账号。",
                en: "Images tests only support OpenAI authorized login accounts and OpenAI API key accounts."
            )
        }
        return self.localized(
            zh: "`Google / Gemini Login` 账号现在只支持 Gemini CLI / Gemini endpoint。测试台里选中这类账号时，只能测试 Gemini endpoint。",
            en: "`Google / Gemini Login` accounts are now Gemini CLI only. In the test console, they can only be used with the Gemini endpoint."
        )
    }

    var proxyTestCanSend: Bool {
        self.proxyTestConnectionHealthy
            && self.proxyTestDraft.hasPrompt
            && self.proxyTestCompatibilityIssueText == nil
            && self.proxyTestSelectedAccountEndpointCompatibilityIssue(for: self.proxyTestDraft) == nil
            && (!self.proxyTestDraft.requiresImageEditInputs || self.proxyTestDraft.hasImageEditInputs)
            && (
                self.proxyTestUsesAdminOnlyGeminiExecution(for: self.proxyTestDraft)
                    || !self.proxyTestDraft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            && self.proxyTestRunState != .running
            && self.proxyTestRunState != .loadingModels
    }

    var proxyTestSubtitleText: String {
        guard self.proxyTestUsesRemoteAdminTransport else {
            return self.text(.proxyTestSubtitle)
        }
        return self.localized(
            zh: "通过当前远端管理隧道发起代理测试，验证远端 `/v1` 接入是否可用，并在同一个控制台里查看返回细节。",
            en: "Send proxy test requests through the current remote admin tunnel, verify the remote `/v1` access path, and inspect the response details in one console."
        )
    }

    var proxyTestHealthHintText: String {
        guard self.proxyTestUsesRemoteAdminTransport else {
            return self.text(.proxyTestHealthHint)
        }
        return self.localized(
            zh: "控制台会先检查远端管理隧道和服务状态，再加载桌面端模型目录。远端测试链路不可用时会禁用发送。",
            en: "The console first checks the remote admin tunnel and service health, then loads the desktop model catalog. Sending stays disabled when the remote test path is unavailable."
        )
    }

    var proxyTestResultHintText: String {
        guard self.proxyTestUsesRemoteAdminTransport else {
            return self.text(.proxyTestResultHint)
        }
        return self.localized(
            zh: "这里会展示经当前远端管理链路返回的文本结果、用量、耗时、HTTP 状态和原始响应。",
            en: "Review the assistant output, usage, latency, HTTP status, and raw response details returned through the current remote admin path."
        )
    }

    var proxyTestCompatibilityIssueText: String? {
        self.proxyTestTransportCompatibilityIssue(for: self.proxyTestDraft)
    }

    var proxyTestRequestPreview: String {
        self.proxyTestDraft.requestPreview()
    }

    func proxyTestSelectedAccountStatusText() -> String {
        guard let account = self.proxyTestSelectedAccount else {
            return self.text(.statusUnavailable)
        }
        if !account.enabled {
            return self.text(.statusDisabled)
        }
        if self.proxyTestCompatibilityIssueText != nil {
            return self.text(.statusUnavailable)
        }
        if self.proxyTestSelectedAccountEndpointCompatibilityIssue(for: self.proxyTestDraft) != nil {
            return self.text(.statusUnavailable)
        }
        if self.proxyTestSelectedAccountProxyAPIKeyIssueTextKey != nil {
            return self.text(.statusUnavailable)
        }
        return self.accountRuntimeStatusText(account)
    }

    func proxyTestSelectedAccountStatusTone() -> StatusPill.Tone {
        guard let account = self.proxyTestSelectedAccount else {
            return .warning
        }
        if !account.enabled {
            return .danger
        }
        if self.proxyTestCompatibilityIssueText != nil {
            return .warning
        }
        if self.proxyTestSelectedAccountEndpointCompatibilityIssue(for: self.proxyTestDraft) != nil {
            return .warning
        }
        if self.proxyTestSelectedAccountProxyAPIKeyIssueTextKey != nil {
            return .warning
        }
        if account.isCoolingDown() || self.accountRuntimeIssueText(account) != nil {
            return .warning
        }
        return .success
    }

    func proxyTestSelectedAccountIssueText() -> String? {
        let selectedAccountKey = self.proxyTestSelectedAccountKey
        guard !selectedAccountKey.isEmpty else { return nil }
        guard let account = self.proxyTestSelectedAccount else {
            return self.localized(
                zh: "当前选择的账号已不在账号池中。发送测试时会直接返回错误，不会回退其他账号。",
                en: "The selected account is no longer in the account pool. Pinned tests will fail immediately without falling back."
            )
        }
        if !account.enabled {
            return self.localized(
                zh: "这个账号当前已停用。发送测试时会直接返回错误，不会回退其他账号。",
                en: "This account is disabled. Pinned tests will fail immediately without falling back."
            )
        }
        if let issue = self.proxyTestCompatibilityIssueText {
            return issue
        }
        if let issue = self.proxyTestSelectedAccountEndpointCompatibilityIssue(for: self.proxyTestDraft) {
            return issue
        }
        if let textKey = self.proxyTestSelectedAccountProxyAPIKeyIssueTextKey {
            return self.text(textKey)
        }
        return self.accountRuntimeIssueText(account)
    }

    func proxyTestSelectedAccountDetailText() -> String {
        if self.proxyTestUsesAdminOnlyGeminiExecution(for: self.proxyTestDraft) {
            if self.proxyTestUsesRemoteAdminTransport {
                return self.localized(
                    zh: "这个 Gemini endpoint 测试会通过远端管理隧道上的 admin-only 执行链路直接调用所选 `Google / Gemini Login` 账号，不依赖公开代理 API Key，也不会回退其他账号。",
                    en: "This Gemini endpoint test uses the remote admin-only execution path for the selected `Google / Gemini Login` account. It does not require a public proxy API key and will not fall back to other accounts."
                )
            }
            return self.localized(
                zh: "这个 Gemini endpoint 测试会通过本地 admin-only 执行链路直接调用所选 `Google / Gemini Login` 账号，不依赖公开代理 API Key，也不会回退其他账号。",
                en: "This Gemini endpoint test uses the local admin-only execution path for the selected `Google / Gemini Login` account. It does not require a public proxy API key and will not fall back to other accounts."
            )
        }
        if let issue = self.proxyTestCompatibilityIssueText {
            return issue
        }
        if let issue = self.proxyTestSelectedAccountIssueText() {
            return issue
        }
        return self.localized(
            zh: "本次测试会锁定到这个账号；如果请求失败，不会自动切换到其他账号。",
            en: "This test stays pinned to the selected account and will not fall back automatically if it fails."
        )
    }

    func label(for endpoint: ProxyTestEndpoint) -> String {
        switch endpoint {
        case .chatCompletions:
            return self.text(.optionChatCompletions)
        case .responses:
            return self.text(.optionResponses)
        case .imageGenerations:
            return self.text(.optionImageGenerations)
        case .imageEdits:
            return self.text(.optionImageEdits)
        case .anthropicMessages:
            return self.text(.optionAnthropicMessages)
        case .geminiGenerateContent:
            return self.text(.optionGeminiGenerateContent)
        }
    }

    func proxyTestStatusText() -> String {
        switch self.proxyTestRunState {
        case .loadingModels:
            return self.text(.statusLoadingModels)
        case .running:
            return self.text(.statusTesting)
        case .completed:
            return self.text(.statusCompleted)
        case .failed:
            return self.text(.statusFailed)
        case .cancelled:
            return self.text(.statusCancelled)
        case .idle:
            return self.proxyTestConnectionHealthy ? self.text(.statusReady) : self.text(.statusOffline)
        }
    }

    func proxyTestStatusTone() -> StatusPill.Tone {
        switch self.proxyTestRunState {
        case .completed:
            return .success
        case .failed:
            return .danger
        case .cancelled:
            return .warning
        case .loadingModels, .running:
            return .accent
        case .idle:
            return self.proxyTestConnectionHealthy ? .success : .warning
        }
    }

    func openProxyTestConsole() {
        guard self.adminSupportsProxyTesting else {
            self.publishBanner(
                .warning,
                title: self.localized(zh: "当前目标不支持代理测试", en: "Proxy testing is unavailable for this target"),
                detail: nil
            )
            return
        }
        if self.proxyTestWindowController == nil {
            self.proxyTestWindowController = ProxyTestWindowController(model: self)
        }
        self.isProxyTestPresented = true
        self.proxyTestWindowController?.showWindow()
        Task { await self.refreshProxyTestConsole() }
    }

    func dismissProxyTestConsole() {
        self.cancelProxyTest(quiet: true)
        self.proxyTestModelCatalogTask?.cancel()
        self.proxyTestModelCatalogTask = nil
        self.isProxyTestPresented = false
        self.proxyTestWindowController?.closeWindow()
    }

    func clearProxyTestBanner() {
        withAnimation(.easeInOut(duration: 0.18)) {
            self.proxyTestBanners.removeAll()
        }
    }

    func dismissProxyTestBanner(id: BannerState.ID) {
        withAnimation(.easeInOut(duration: 0.18)) {
            self.proxyTestBanners.removeAll { $0.id == id }
        }
    }

    func updateProxyTestEndpoint(_ endpoint: ProxyTestEndpoint) {
        guard self.proxyTestDraft.endpoint != endpoint else { return }
        self.proxyTestDraft.endpoint = endpoint
        if !endpoint.supportsStreaming {
            self.proxyTestDraft.stream = false
        }
        self.applyProxyTestConnectionDefaults(
            resetModelIfNeeded: endpoint == .imageGenerations
                || endpoint == .imageEdits
                || !endpoint.acceptsModelFamily(self.proxyTestDraft.model, catalog: self.proxyTestModelCatalog)
        )
        self.syncProxyTestModelList()
    }

    func setProxyTestSelectedAccountKey(_ value: String) {
        let previousSelectedAccountKey = self.proxyTestDraft.selectedAccountKeyValue
        self.proxyTestDraft.selectedAccountKey = value
        self.applyProxyTestConnectionDefaults(resetModelIfNeeded: false)
        let selectedAccountKey = self.proxyTestDraft.selectedAccountKeyValue
        guard previousSelectedAccountKey != selectedAccountKey, self.isProxyTestPresented else {
            return
        }
        self.reloadProxyTestModelCatalogForSelectedAccount()
    }

    func refreshProxyTestConsole() async {
        self.cancelProxyTest(quiet: true)
        self.proxyTestModelCatalogTask?.cancel()
        self.proxyTestModelCatalogTask = nil
        self.clearProxyTestBanner()
        self.proxyTestResult = nil
        self.proxyTestRunState = .loadingModels
        self.proxyTestConnectionHealthy = false
        self.applyProxyTestConnectionDefaults(resetModelIfNeeded: false)
        self.syncProxyTestModelList()

        let apiKey = self.proxyTestDraft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowsMissingAPIKeyForPinnedAccount =
            self.proxyTestSelectedAccountProxyAPIKeyIssueTextKey != nil
            || self.proxyTestSelectedAccountEndpointCompatibilityIssue(for: self.proxyTestDraft) != nil
            || self.proxyTestUsesAdminOnlyGeminiExecution(for: self.proxyTestDraft)
        guard !apiKey.isEmpty || allowsMissingAPIKeyForPinnedAccount else {
            self.completeProxyTestFailure(
                ProxyError.message("Missing proxy api key."),
                context: .runProxyTest,
                markConnectionUnhealthy: true
            )
            return
        }

        do {
            if self.proxyTestUsesRemoteAdminTransport {
                self.status = try await self.admin.getStatus()
            } else {
                try await self.publicProxyClient.health(baseURL: self.proxyTestDraft.endpointURL)
            }
            self.proxyTestConnectionHealthy = true
        } catch {
            self.completeProxyTestFailure(
                error,
                context: .runProxyTest,
                markConnectionUnhealthy: true
            )
            return
        }

        await self.loadProxyTestModelCatalog(
            selectedAccountKey: self.proxyTestDraft.selectedAccountKeyValue,
            completionRunState: .idle
        )
    }

    func startProxyTest() {
        guard self.proxyTestRunState != .running else { return }
        guard self.proxyTestCanSend else { return }
        self.cancelProxyTest(quiet: true)

        let snapshot = self.proxyTestDraft
        self.proxyTestTask = Task { [weak self] in
            await self?.executeProxyTest(snapshot: snapshot)
        }
    }

    func cancelProxyTest(quiet: Bool = false) {
        self.proxyTestTask?.cancel()
        self.proxyTestTask = nil
        guard self.proxyTestRunState == .running else { return }
        self.proxyTestRunState = .cancelled
        if !quiet {
            self.publishProxyTestBanner(
                .warning,
                title: self.text(.statusCancelled),
                detail: nil
            )
        }
    }

    private func executeProxyTest(snapshot: ProxyTestDraft) async {
        let startedAt = Date()
        self.proxyTestRunState = .running
        self.proxyTestResult = ProxyTestResult()
        self.clearProxyTestBanner()
        if let warning = self.proxyTestModelFamilyWarning(for: snapshot) {
            self.publishProxyTestBanner(.warning, title: warning.title, detail: warning.detail)
        }
        defer { self.proxyTestTask = nil }

        do {
            if snapshot.endpoint.supportsStreaming && snapshot.stream {
                try await self.executeStreamingProxyTest(snapshot: snapshot, startedAt: startedAt)
            } else {
                let response: SimpleHTTPResponse
                if self.proxyTestUsesRemoteAdminTransport || self.proxyTestUsesAdminOnlyGeminiExecution(for: snapshot) {
                    response = try await self.admin.runProxyTestNonStream(self.adminProxyTestRunRequest(for: snapshot))
                } else {
                    response = try await self.publicProxyClient.executeNonStream(draft: snapshot)
                }
                var result = Self.parseNonStreamResult(response, endpoint: snapshot.endpoint)
                result.latencyMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
                self.proxyTestResult = result
                self.proxyTestRunState = .completed
                self.publishProxyTestBanner(.success, title: self.text(.successProxyTestCompleted), detail: nil)
            }
        } catch is CancellationError {
            if self.proxyTestRunState == .running {
                self.proxyTestRunState = .cancelled
            }
        } catch {
            self.completeProxyTestFailure(
                error,
                context: .runProxyTest,
                latencyMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000)
            )
        }
    }

    private func executeStreamingProxyTest(snapshot: ProxyTestDraft, startedAt: Date) async throws {
        let response: StreamingHTTPResponse
        if self.proxyTestUsesRemoteAdminTransport || self.proxyTestUsesAdminOnlyGeminiExecution(for: snapshot) {
            response = try await self.admin.runProxyTestStream(self.adminProxyTestRunRequest(for: snapshot))
        } else {
            response = try await self.publicProxyClient.executeStream(draft: snapshot)
        }
        var result = ProxyTestResult(httpStatus: response.statusCode)
        var decoder = SSEIncrementalDecoder()
        var sawCompletion = false

        for try await chunk in response.body {
            try Task.checkCancellation()
            let events = decoder.append(chunk)
            Self.consumeStreamEvents(events, endpoint: snapshot.endpoint, result: &result, sawCompletion: &sawCompletion)
            self.proxyTestResult = result
        }

        let tailEvents = decoder.finish()
        Self.consumeStreamEvents(tailEvents, endpoint: snapshot.endpoint, result: &result, sawCompletion: &sawCompletion)

        if let rawError = result.rawError,
           !rawError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            throw ProxyError.message(rawError)
        }

        if !sawCompletion {
            switch snapshot.endpoint {
            case .responses:
                throw ProxyError.message("上游未返回 response.completed")
            case .imageGenerations, .imageEdits:
                break
            case .anthropicMessages:
                throw ProxyError.message("Anthropic stream did not finish with `message_stop`.")
            case .geminiGenerateContent:
                throw ProxyError.message("Gemini stream did not finish with `finishReason`.")
            case .chatCompletions:
                break
            }
        }

        result.latencyMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
        self.proxyTestResult = result
        self.proxyTestRunState = .completed
        self.publishProxyTestBanner(.success, title: self.text(.successProxyTestCompleted), detail: nil)
    }

    private func applyProxyTestConnectionDefaults(resetModelIfNeeded: Bool = false) {
        self.proxyTestDraft.endpointURL = self.currentProxyTestBaseURL(for: self.proxyTestDraft.endpoint)
        self.proxyTestDraft.apiKey = self.resolvedProxyTestAPIKey()
        if !self.proxyTestDraft.endpoint.supportsStreaming {
            self.proxyTestDraft.stream = false
        }
        let trimmedModel = self.proxyTestDraft.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if resetModelIfNeeded || trimmedModel.isEmpty {
            self.proxyTestDraft.model = self.defaultProxyTestModel(for: self.proxyTestDraft.endpoint)
        }
    }

    private func reloadProxyTestModelCatalogForSelectedAccount() {
        self.proxyTestModelCatalogTask?.cancel()
        let selectedAccountKey = self.proxyTestDraft.selectedAccountKeyValue
        let restoreRunState = self.proxyTestRunState == .loadingModels ? ProxyTestRunState.idle : self.proxyTestRunState
        if self.proxyTestRunState != .running {
            self.proxyTestRunState = .loadingModels
        }
        self.proxyTestModelCatalogTask = Task { [weak self] in
            await self?.loadProxyTestModelCatalog(
                selectedAccountKey: selectedAccountKey,
                completionRunState: restoreRunState
            )
        }
    }

    private func loadProxyTestModelCatalog(
        selectedAccountKey: String?,
        completionRunState: ProxyTestRunState
    ) async {
        do {
            let catalog = try await self.admin.getProxyTestModels(selectedAccountKey: selectedAccountKey)
            guard !Task.isCancelled, self.proxyTestDraft.selectedAccountKeyValue == selectedAccountKey else {
                return
            }
            self.proxyTestModelCatalog = catalog
            self.syncProxyTestModelList(
                resetModelIfNeeded: !self.proxyTestDraft.endpoint.acceptsModelFamily(
                    self.proxyTestDraft.model,
                    catalog: catalog
                )
            )
            self.proxyTestRunState = completionRunState
        } catch {
            guard !Task.isCancelled, self.proxyTestDraft.selectedAccountKeyValue == selectedAccountKey else {
                return
            }
            self.proxyTestModelCatalog = .defaultCatalog
            self.syncProxyTestModelList(
                resetModelIfNeeded: !self.proxyTestDraft.endpoint.acceptsModelFamily(
                    self.proxyTestDraft.model,
                    catalog: self.proxyTestModelCatalog
                )
            )
            self.proxyTestRunState = completionRunState

            let rawDetail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            self.publishProxyTestBanner(
                .warning,
                title: self.text(.proxyTestFallbackModels),
                detail: self.localization.errorDetail(for: rawDetail, context: .loadProxyTestModels)
            )
        }
    }

    private func currentProxyTestBaseURL(for endpoint: ProxyTestEndpoint) -> String {
        if endpoint.prefersAnthropicRootBaseURL {
            return self.anthropicBaseURL
        }
        if endpoint.prefersGeminiRootBaseURL {
            return self.geminiBaseURL
        }
        return self.openAICompatibleBaseURL
    }

    private func syncProxyTestModelList(resetModelIfNeeded: Bool = false) {
        let models = self.proxyTestDraft.endpoint.availableModels(in: self.proxyTestModelCatalog)
        self.proxyTestAvailableModels = models
        let trimmedModel = self.proxyTestDraft.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if resetModelIfNeeded || trimmedModel.isEmpty {
            self.proxyTestDraft.model = self.defaultProxyTestModel(for: self.proxyTestDraft.endpoint)
        }
    }

    private func defaultProxyTestModel(for endpoint: ProxyTestEndpoint) -> String {
        let group = endpoint.modelGroup(in: self.proxyTestModelCatalog)
        let defaultModel = endpoint.defaultModel(in: self.proxyTestModelCatalog)
        if group.models.contains(defaultModel) {
            return defaultModel
        }
        return group.models.first ?? defaultModel
    }

    private func adminProxyTestRunRequest(for draft: ProxyTestDraft) throws -> AdminProxyTestRunRequest {
        let selectedAccountKey = draft.selectedAccountKeyValue
        let usesAdminOnlyGeminiExecution = self.proxyTestUsesAdminOnlyGeminiExecution(for: draft)
        if usesAdminOnlyGeminiExecution, selectedAccountKey == nil {
            throw ProxyError.message("Admin proxy test requires a selected account.")
        }
        let model = draft.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? self.defaultProxyTestModel(for: draft.endpoint)
            : draft.model
        let requestBody = try draft.requestBody()
        let payloadJSON = draft.endpoint == .imageEdits
            ? draft.requestPreview()
            : String(decoding: requestBody.data, as: UTF8.self)
        return AdminProxyTestRunRequest(
            endpoint: self.adminProxyTestEndpoint(for: draft.endpoint),
            model: model,
            payloadJSON: payloadJSON,
            stream: draft.endpoint.supportsStreaming && draft.stream,
            selectedAccountKey: selectedAccountKey,
            proxyAPIKey: usesAdminOnlyGeminiExecution
                ? nil
                : draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            anthropicVersion: draft.endpoint == .anthropicMessages ? AnthropicTranscoder.defaultAnthropicVersion : nil,
            contentType: draft.endpoint == .imageEdits ? requestBody.contentType : nil,
            bodyBase64: draft.endpoint == .imageEdits ? requestBody.data.base64EncodedString() : nil
        )
    }

    private var proxyTestUsesRemoteAdminTransport: Bool {
        self.adminCapabilities.allowsLocalFallback == false
    }

    private var proxyTestResolvedAdminTransportMode: ProxyStatus.ProxyTestAdminTransportMode {
        guard self.proxyTestUsesRemoteAdminTransport else {
            return .full
        }
        guard self.status != nil else {
            return .full
        }
        return self.status?.proxyTestAdminTransportMode ?? .legacyGeminiOnly
    }

    private func proxyTestTransportCompatibilityIssue(for draft: ProxyTestDraft) -> String? {
        guard self.proxyTestUsesRemoteAdminTransport else { return nil }
        guard self.proxyTestResolvedAdminTransportMode == .legacyGeminiOnly else { return nil }
        guard self.proxyTestUsesAdminOnlyGeminiExecution(for: draft) == false else { return nil }
        return self.localized(
            zh: "当前远端服务仍是旧版测试协议，只支持固定到 `Google / Gemini Login` 账号的 Gemini endpoint 测试。要测试 Chat / Responses / Images / Anthropic，请重新部署或升级远端 daemon。",
            en: "This remote service still uses the legacy proxy-test protocol. Only Gemini endpoint tests pinned to a `Google / Gemini Login` account are available. Redeploy or upgrade the remote daemon to test Chat, Responses, Images, or Anthropic routes."
        )
    }

    private func adminProxyTestEndpoint(for endpoint: ProxyTestEndpoint) -> AdminProxyTestEndpoint {
        switch endpoint {
        case .chatCompletions:
            return .chatCompletions
        case .responses:
            return .responses
        case .imageGenerations:
            return .imageGenerations
        case .imageEdits:
            return .imageEdits
        case .anthropicMessages:
            return .anthropicMessages
        case .geminiGenerateContent:
            return .geminiGenerateContent
        }
    }

    func copyCurrentProxyTestAPIKey() {
        self.copyToPasteboard(self.proxyTestDraft.apiKey, context: .copyAPIKey)
    }

    private var proxyTestSelectedAccountProxyAPIKeyIssueTextKey: LocalizedTextKey? {
        guard let account = self.proxyTestSelectedAccount, account.enabled else { return nil }
        guard self.accountRuntimeIssueText(account) == nil else { return nil }
        if self.proxyTestUsesAdminOnlyGeminiExecution(for: self.proxyTestDraft) {
            return nil
        }
        switch self.compatibleProxyTestAPIKeyResolution(for: account) {
        case .available:
            return nil
        case .restricted:
            return .proxyTestSelectedAccountOutsideAPIKeyAllowlist
        case .missing:
            return self.proxyTestMissingMatchingAPIKeyTextKey(for: account)
        }
    }

    private enum ProxyTestAPIKeyResolution {
        case available(ProxyAPIKeyRecord)
        case restricted
        case missing
    }

    private func proxyTestCandidateDataSources(for account: AccountSummary) -> [ProxyDataSource] {
        var ordered: [ProxyDataSource] = [account.authMode.primaryPinnedProxyTestDataSource, .all]
        for dataSource in account.authMode.fallbackPinnedProxyTestCompatibleDataSources where !ordered.contains(dataSource) {
            ordered.append(dataSource)
        }
        return ordered
    }

    private func proxyTestAPIKeyAllowsPinnedAccount(_ record: ProxyAPIKeyRecord, accountKey: String) -> Bool {
        let trimmedAccountKey = accountKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAccountKey.isEmpty else { return true }
        return record.allowedAccountKeys.isEmpty || record.allowedAccountKeys.contains(trimmedAccountKey)
    }

    private func matchingEnabledProxyAPIKeys(for dataSource: ProxyDataSource) -> [ProxyAPIKeyRecord] {
        self.configuredProxyAPIKeys.filter { $0.enabled && $0.dataSource == dataSource }
    }

    private func compatibleProxyTestAPIKeyResolution(for account: AccountSummary) -> ProxyTestAPIKeyResolution {
        var foundRestrictedCandidate = false
        for dataSource in self.proxyTestCandidateDataSources(for: account) {
            let records = self.matchingEnabledProxyAPIKeys(for: dataSource)
            if records.isEmpty {
                continue
            }
            if let record = records.first(where: { self.proxyTestAPIKeyAllowsPinnedAccount($0, accountKey: account.accountKey) }) {
                return .available(record)
            }
            foundRestrictedCandidate = true
        }
        return foundRestrictedCandidate ? .restricted : .missing
    }

    private func compatibleProxyTestAPIKey(for account: AccountSummary) -> ProxyAPIKeyRecord? {
        guard case let .available(record) = self.compatibleProxyTestAPIKeyResolution(for: account) else {
            return nil
        }
        return record
    }

    private func resolvedProxyTestAPIKey() -> String {
        guard let account = self.proxyTestSelectedAccount else {
            if self.proxyTestDraft.endpoint == .anthropicMessages {
                return self.anthropicAccessProxyAPIKeyValue ?? ""
            }
            if self.proxyTestDraft.endpoint == .imageGenerations || self.proxyTestDraft.endpoint == .imageEdits {
                return self.openAIProxyTestAPIKeyValue
            }
            return self.localProxyAPIKeyValue
        }
        return self.compatibleProxyTestAPIKey(for: account)?.key ?? ""
    }

    private var openAIProxyTestAPIKeyValue: String {
        let runtimeKey = self.status?.apiKey.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !runtimeKey.isEmpty {
            return runtimeKey
        }
        let matchingKeys = self.configuredProxyAPIKeys.filter { record in
            record.enabled && (record.dataSource == .openAI || record.dataSource == .all)
        }
        let record = matchingKeys.first(where: { $0.dataSource == .openAI && $0.allowedAccountKeys.isEmpty })
            ?? matchingKeys.first(where: { $0.dataSource == .all && $0.allowedAccountKeys.isEmpty })
            ?? matchingKeys.first
        let key = record?.key.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return key.isEmpty ? self.localProxyAPIKeyValue : key
    }

    private func proxyTestMissingMatchingAPIKeyTextKey(for account: AccountSummary) -> LocalizedTextKey {
        switch account.authMode {
        case .chatGPT, .openAIAPIKey:
            return .proxyTestMissingOpenAIDataSourceAPIKey
        case .anthropicAPIKey:
            return .proxyTestMissingAnthropicDataSourceAPIKey
        case .anthropicSubscriptionOAuth:
            return .proxyTestMissingAnthropicOAuthCompatibleAPIKey
        case .geminiOAuth:
            return .proxyTestMissingGeminiDataSourceAPIKey
        }
    }

    func proxyTestModelFamilyWarning(for draft: ProxyTestDraft) -> (title: String, detail: String)? {
        let inferredFamily = ProxyTestEndpoint.inferredFamily(for: draft.model)
        guard let inferredFamily, inferredFamily != draft.endpoint.modelFamily else {
            return nil
        }

        if self.localization.resolvedLanguage == .zhHans {
            switch draft.endpoint.modelFamily {
            case .gpt:
                return (
                    "当前模型与接口不匹配",
                    "当前 \(self.label(for: draft.endpoint)) 接口通常应使用 GPT 模型，`\((draft.model))` 看起来属于 Anthropic / Claude 模型族。请求仍会继续发送，但建议切换到 GPT 候选。"
                )
            case .image:
                return (
                    "当前模型与接口不匹配",
                    "当前 \(self.label(for: draft.endpoint)) 接口通常应使用图片生成模型，例如 `\(ProxyTestDraft.defaultImageModel)`。`\((draft.model))` 看起来属于其他模型族。请求仍会继续发送，但建议切换到图片生成模型。"
                )
            case .anthropic:
                return (
                    "当前模型与接口不匹配",
                    "当前 \(self.label(for: draft.endpoint)) 接口通常应使用 Anthropic / Claude 模型，`\((draft.model))` 看起来属于 GPT 模型族。请求仍会继续发送，但建议切换到 Claude 候选。"
                )
            case .gemini:
                return (
                    "当前模型与接口不匹配",
                    "当前 \(self.label(for: draft.endpoint)) 接口通常应使用 Gemini 模型，`\((draft.model))` 看起来属于其他模型族。请求仍会继续发送，但建议切换到 Gemini 候选。"
                )
            }
        }

        switch draft.endpoint.modelFamily {
        case .gpt:
            return (
                "The selected model may not match this endpoint",
                "The current \(self.label(for: draft.endpoint)) endpoint usually expects GPT-family models. `\(draft.model)` looks like an Anthropic / Claude model. The request will still be sent, but switching to a GPT candidate is recommended."
            )
        case .image:
            return (
                "The selected model may not match this endpoint",
                "The current \(self.label(for: draft.endpoint)) endpoint usually expects an image generation model such as `\(ProxyTestDraft.defaultImageModel)`. `\(draft.model)` looks like a different model family. The request will still be sent, but switching to an image model is recommended."
            )
        case .anthropic:
            return (
                "The selected model may not match this endpoint",
                "The current \(self.label(for: draft.endpoint)) endpoint usually expects Anthropic / Claude models. `\(draft.model)` looks like a GPT-family model. The request will still be sent, but switching to a Claude candidate is recommended."
            )
        case .gemini:
            return (
                "The selected model may not match this endpoint",
                "The current \(self.label(for: draft.endpoint)) endpoint usually expects Gemini-family models. `\(draft.model)` looks like a different model family. The request will still be sent, but switching to a Gemini candidate is recommended."
            )
        }
    }

    func publishProxyTestBanner(_ tone: BannerState.Tone, title: String, detail: String?) {
        let state = BannerState(tone: tone, title: title, detail: detail)
        withAnimation(.spring(response: 0.26, dampingFraction: 0.9)) {
            self.proxyTestBanners.insert(state, at: 0)
        }
        guard tone != .error else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.toastAutoDismissDuration ?? .seconds(3.5))
            guard self?.proxyTestBanners.contains(where: { $0.id == state.id }) == true else { return }
            self?.dismissProxyTestBanner(id: state.id)
        }
    }

    private func completeProxyTestFailure(
        _ error: Error,
        context: OperationContext,
        markConnectionUnhealthy: Bool = false,
        latencyMilliseconds: Int? = nil
    ) {
        let rawDetail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = self.localization.errorTitle(for: rawDetail, context: context)
        let detail = self.localization.errorDetail(for: rawDetail, context: context)

        self.proxyTestRunState = .failed
        if markConnectionUnhealthy {
            self.proxyTestConnectionHealthy = false
        }
        self.proxyTestResult = ProxyTestResult(
            latencyMilliseconds: latencyMilliseconds,
            httpStatus: (error as? ProxyPublicRequestFailure)?.statusCode,
            errorSummary: detail ?? title,
            rawError: rawDetail
        )
        self.publishProxyTestBanner(.error, title: title, detail: detail)
    }

    private static func consumeStreamEvents(
        _ events: [SSEEvent],
        endpoint: ProxyTestEndpoint,
        result: inout ProxyTestResult,
        sawCompletion: inout Bool
    ) {
        for event in events {
            result.rawSSETranscript.append(self.transcriptText(for: event))

            if event.data == "[DONE]" {
                sawCompletion = true
                continue
            }

            guard
                let data = event.data.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                continue
            }

            switch endpoint {
            case .chatCompletions:
                if let delta = self.extractChatCompletionDelta(from: object), !delta.isEmpty {
                    result.assistantText.append(delta)
                }
                if let usage = self.extractChatUsage(from: object["usage"]) {
                    result.usage = usage
                }
                if self.chatCompletionFinished(object) {
                    sawCompletion = true
                }
            case .responses:
                let type = object["type"] as? String ?? ""
                switch type {
                case "response.output_text.delta":
                    result.assistantText.append(object["delta"] as? String ?? "")
                case "response.failed":
                    sawCompletion = true
                    let response = object["response"] as? [String: Any] ?? [:]
                    if let error = response["error"] as? [String: Any] {
                        result.rawError = error["message"] as? String ?? self.prettyString(from: error)
                    } else if let error = object["error"] as? [String: Any] {
                        result.rawError = error["message"] as? String ?? self.prettyString(from: error)
                    } else {
                        result.rawError = self.prettyString(from: object)
                    }
                case "response.completed":
                    sawCompletion = true
                    let response = object["response"] as? [String: Any] ?? [:]
                    result.rawResponseJSON = self.prettyString(from: response)
                    if result.assistantText.isEmpty {
                        result.assistantText = ProxyTranscoder.extractAssistantText(from: response)
                    }
                    if let usage = self.extractResponsesUsage(from: response["usage"]) {
                        result.usage = usage
                    }
                default:
                    continue
                }
            case .imageGenerations, .imageEdits:
                continue
            case .anthropicMessages:
                let type = (object["type"] as? String) ?? event.event ?? ""
                switch type {
                case "ping":
                    continue
                case "message_start":
                    if let message = object["message"] as? [String: Any],
                       let usage = self.extractAnthropicUsage(from: message["usage"])
                    {
                        result.usage = usage
                    }
                case "content_block_start":
                    if let block = object["content_block"] as? [String: Any],
                       (block["type"] as? String) == "tool_use"
                    {
                        let name = block["name"] as? String ?? "tool"
                        if !result.assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            result.assistantText.append("\n")
                        }
                        result.assistantText.append("[tool_use] \(name)")
                    }
                case "content_block_delta":
                    if let delta = object["delta"] as? [String: Any] {
                        switch delta["type"] as? String ?? "" {
                        case "text_delta":
                            result.assistantText.append(delta["text"] as? String ?? "")
                        case "input_json_delta":
                            continue
                        default:
                            continue
                        }
                    }
                case "message_delta":
                    if let usage = self.extractAnthropicDeltaUsage(from: object["usage"], existing: result.usage) {
                        result.usage = usage
                    }
                case "message_stop":
                    sawCompletion = true
                case "error":
                    if let error = object["error"] as? [String: Any] {
                        result.rawError = error["message"] as? String ?? self.prettyString(from: error)
                    } else {
                        result.rawError = self.prettyString(from: object)
                    }
                default:
                    continue
                }
            case .geminiGenerateContent:
                if let error = object["error"] as? [String: Any] {
                    result.rawError = error["message"] as? String ?? self.prettyString(from: error)
                    continue
                }
                let candidates = object["candidates"] as? [[String: Any]] ?? []
                if let candidate = candidates.first {
                    let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
                    for part in parts {
                        if let text = part["text"] as? String, !text.isEmpty {
                            result.assistantText.append(text)
                            continue
                        }
                        if let functionCall = part["functionCall"] as? [String: Any],
                           let name = functionCall["name"] as? String,
                           !name.isEmpty
                        {
                            if !result.assistantText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                result.assistantText.append("\n")
                            }
                            result.assistantText.append("[functionCall] \(name)")
                        }
                    }
                    if candidate["finishReason"] != nil {
                        sawCompletion = true
                    }
                }
                if let usage = self.extractGeminiUsage(from: object["usageMetadata"]) {
                    result.usage = usage
                }
            }
        }
    }

    private static func transcriptText(for event: SSEEvent) -> String {
        var lines: [String] = []
        if let name = event.event, !name.isEmpty {
            lines.append("event: \(name)")
        }
        let dataLines = event.data.split(separator: "\n", omittingEmptySubsequences: false)
        if dataLines.isEmpty {
            lines.append("data:")
        } else {
            for line in dataLines {
                lines.append("data: \(line)")
            }
        }
        return lines.joined(separator: "\n") + "\n\n"
    }

    private static func parseNonStreamResult(_ response: SimpleHTTPResponse, endpoint: ProxyTestEndpoint) -> ProxyTestResult {
        let rawString = prettyResponseString(from: response.body)
        guard
            let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        else {
            return ProxyTestResult(rawResponseJSON: rawString, httpStatus: response.statusCode)
        }

        switch endpoint {
        case .chatCompletions:
            return ProxyTestResult(
                assistantText: extractChatCompletionText(from: object),
                rawResponseJSON: rawString,
                httpStatus: response.statusCode,
                usage: extractChatUsage(from: object["usage"])
            )
        case .responses:
            return ProxyTestResult(
                assistantText: ProxyTranscoder.extractAssistantText(from: object),
                rawResponseJSON: rawString,
                httpStatus: response.statusCode,
                usage: extractResponsesUsage(from: object["usage"])
            )
        case .imageGenerations, .imageEdits:
            let outputs = self.extractImageOutputs(from: object["data"])
            return ProxyTestResult(
                assistantText: self.imageSummaryText(for: outputs),
                rawResponseJSON: rawString,
                httpStatus: response.statusCode,
                imageOutputs: outputs
            )
        case .anthropicMessages:
            return ProxyTestResult(
                assistantText: AnthropicTranscoder.extractText(from: object),
                rawResponseJSON: rawString,
                httpStatus: response.statusCode,
                usage: extractAnthropicUsage(from: object["usage"])
            )
        case .geminiGenerateContent:
            return ProxyTestResult(
                assistantText: GeminiTranscoder.extractText(from: object),
                rawResponseJSON: rawString,
                httpStatus: response.statusCode,
                usage: extractGeminiUsage(from: object["usageMetadata"])
            )
        }
    }

    private static func extractImageOutputs(from value: Any?) -> [ProxyTestImageOutput] {
        guard let items = value as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            let imageData = self.imageData(fromBase64Value: item["b64_json"] as? String)
            let url = self.trimmed(item["url"] as? String)
            let revisedPrompt = self.trimmed(item["revised_prompt"] as? String)
            guard imageData != nil || url != nil else { return nil }
            return ProxyTestImageOutput(imageData: imageData, url: url, revisedPrompt: revisedPrompt)
        }
    }

    private static func imageData(fromBase64Value value: String?) -> Data? {
        guard var raw = self.trimmed(value) else { return nil }
        if raw.lowercased().hasPrefix("data:image/"),
           let comma = raw.firstIndex(of: ",")
        {
            raw = String(raw[raw.index(after: comma)...])
        }
        return Data(base64Encoded: raw)
    }

    private static func imageSummaryText(for outputs: [ProxyTestImageOutput]) -> String {
        let urls = outputs.compactMap(\.url)
        if urls.isEmpty == false {
            return urls.joined(separator: "\n")
        }
        guard outputs.isEmpty == false else {
            return ""
        }
        return outputs.count == 1 ? "Generated 1 image." : "Generated \(outputs.count) images."
    }

    private static func extractChatCompletionText(from object: [String: Any]) -> String {
        guard
            let choices = object["choices"] as? [[String: Any]],
            let first = choices.first
        else {
            return ""
        }

        if let message = first["message"] as? [String: Any] {
            return self.extractMessageText(from: message["content"])
        }
        if let delta = first["delta"] as? [String: Any] {
            return self.extractMessageText(from: delta["content"])
        }
        return ""
    }

    private static func extractChatCompletionDelta(from object: [String: Any]) -> String? {
        guard
            let choices = object["choices"] as? [[String: Any]],
            let first = choices.first,
            let delta = first["delta"] as? [String: Any]
        else {
            return nil
        }
        return self.extractMessageText(from: delta["content"])
    }

    private static func extractMessageText(from value: Any?) -> String {
        if let text = value as? String {
            return text
        }
        if let items = value as? [[String: Any]] {
            return items.compactMap { item in
                if let text = item["text"] as? String {
                    return text
                }
                if let value = item["content"] as? String {
                    return value
                }
                return nil
            }
            .joined()
        }
        return ""
    }

    private static func chatCompletionFinished(_ object: [String: Any]) -> Bool {
        guard
            let choices = object["choices"] as? [[String: Any]],
            let first = choices.first
        else {
            return false
        }
        let finishReason = first["finish_reason"]
        if finishReason is NSNull {
            return false
        }
        return finishReason != nil
    }

    private static func extractChatUsage(from value: Any?) -> ProxyTestUsage? {
        guard let usage = value as? [String: Any] else { return nil }
        return ProxyTestUsage(
            inputTokens: self.int64(from: usage["prompt_tokens"]),
            outputTokens: self.int64(from: usage["completion_tokens"]),
            totalTokens: self.int64(from: usage["total_tokens"])
        )
    }

    private static func extractResponsesUsage(from value: Any?) -> ProxyTestUsage? {
        guard let usage = value as? [String: Any] else { return nil }
        return ProxyTestUsage(
            inputTokens: self.int64(from: usage["input_tokens"]),
            outputTokens: self.int64(from: usage["output_tokens"]),
            totalTokens: self.int64(from: usage["total_tokens"])
        )
    }

    private static func extractAnthropicUsage(from value: Any?) -> ProxyTestUsage? {
        guard let usage = value as? [String: Any] else { return nil }
        let input = self.int64(from: usage["input_tokens"])
        let output = self.int64(from: usage["output_tokens"])
        return ProxyTestUsage(
            inputTokens: input,
            outputTokens: output,
            totalTokens: input + output
        )
    }

    private static func extractAnthropicDeltaUsage(from value: Any?, existing: ProxyTestUsage?) -> ProxyTestUsage? {
        guard let usage = value as? [String: Any] else { return existing }
        let current = existing ?? ProxyTestUsage()
        let output = self.int64(from: usage["output_tokens"])
        return ProxyTestUsage(
            inputTokens: current.inputTokens,
            outputTokens: output,
            totalTokens: current.inputTokens + output
        )
    }

    private static func extractGeminiUsage(from value: Any?) -> ProxyTestUsage? {
        guard let usage = value as? [String: Any] else { return nil }
        return ProxyTestUsage(
            inputTokens: self.int64(from: usage["promptTokenCount"]),
            outputTokens: self.int64(from: usage["candidatesTokenCount"]),
            totalTokens: self.int64(from: usage["totalTokenCount"])
        )
    }

    private static func int64(from value: Any?) -> Int64 {
        if let number = value as? Int64 {
            return number
        }
        if let number = value as? Int {
            return Int64(number)
        }
        if let string = value as? String, let number = Int64(string) {
            return number
        }
        return 0
    }

    private static func trimmed(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func prettyResponseString(from data: Data) -> String {
        guard !data.isEmpty else { return "" }
        if
            let object = try? JSONSerialization.jsonObject(with: data),
            let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        {
            return String(decoding: pretty, as: UTF8.self)
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func prettyString(from object: [String: Any]) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else {
            return ""
        }
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
