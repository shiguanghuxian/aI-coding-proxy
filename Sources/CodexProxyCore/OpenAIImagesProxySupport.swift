import Foundation

public enum OpenAIImagesEndpoint: String, Sendable, Equatable, CaseIterable {
    case generations = "/v1/images/generations"
    case edits = "/v1/images/edits"
    case variations = "/v1/images/variations"

    public init?(path: String) {
        self.init(rawValue: path)
    }

    public var upstreamPath: String {
        switch self {
        case .generations:
            return "images/generations"
        case .edits:
            return "images/edits"
        case .variations:
            return "images/variations"
        }
    }

    var canBridgeViaResponses: Bool {
        switch self {
        case .generations, .edits:
            return true
        case .variations:
            return false
        }
    }
}

public struct OpenAIImagesRequestInfo: Sendable, Equatable {
    public var endpoint: OpenAIImagesEndpoint
    public var contentType: String?
    public var fields: [String: String]
    public var inputImageDataURIs: [String]
    public var maskImageDataURIs: [String]
    public var isMultipart: Bool

    public init(
        endpoint: OpenAIImagesEndpoint,
        contentType: String?,
        fields: [String: String],
        inputImageDataURIs: [String],
        maskImageDataURIs: [String] = [],
        isMultipart: Bool
    ) {
        self.endpoint = endpoint
        self.contentType = contentType
        self.fields = fields
        self.inputImageDataURIs = inputImageDataURIs
        self.maskImageDataURIs = maskImageDataURIs
        self.isMultipart = isMultipart
    }

    public var model: String {
        Self.trimmed(self.fields["model"]) ?? OpenAIImagesProxySupport.defaultImageModel
    }

    public var prompt: String? {
        Self.trimmed(self.fields["prompt"])
    }

    public var responseFormat: String? {
        Self.trimmed(self.fields["response_format"])?.lowercased()
    }

    public var stream: Bool {
        Self.boolValue(self.fields["stream"]) ?? false
    }

    public var n: Int? {
        guard let raw = Self.trimmed(self.fields["n"]) else { return nil }
        return Int(raw)
    }

    public var redactedPayloadForPromptCache: [String: Any] {
        var payload: [String: Any] = [
            "model": self.model,
            "endpoint": self.endpoint.rawValue,
        ]
        if let prompt {
            payload["prompt"] = prompt
        }
        if let responseFormat {
            payload["response_format"] = responseFormat
        }
        return payload
    }

    private static func trimmed(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func boolValue(_ value: String?) -> Bool? {
        guard let trimmed = self.trimmed(value)?.lowercased() else { return nil }
        if ["1", "true", "yes"].contains(trimmed) {
            return true
        }
        if ["0", "false", "no"].contains(trimmed) {
            return false
        }
        return nil
    }
}

public struct ChatGPTWebImageRequirements: Sendable, Equatable {
    public var token: String
    public var proofToken: String
    public var turnstileToken: String
    public var soToken: String

    public init(
        token: String,
        proofToken: String = "",
        turnstileToken: String = "",
        soToken: String = ""
    ) {
        self.token = token
        self.proofToken = proofToken
        self.turnstileToken = turnstileToken
        self.soToken = soToken
    }
}

public struct ChatGPTWebPOWResources: Sendable, Equatable {
    public var scriptSources: [String]
    public var dataBuild: String

    public init(scriptSources: [String], dataBuild: String) {
        self.scriptSources = scriptSources
        self.dataBuild = dataBuild
    }
}

public struct ChatGPTWebImageConversationState: Sendable, Equatable {
    public var conversationID: String?
    public var fileIDs: [String]
    public var sedimentIDs: [String]
    public var message: String?
    public var blocked: Bool
    public var toolInvoked: Bool?
    public var turnUseCase: String?

    public init(
        conversationID: String? = nil,
        fileIDs: [String] = [],
        sedimentIDs: [String] = [],
        message: String? = nil,
        blocked: Bool = false,
        toolInvoked: Bool? = nil,
        turnUseCase: String? = nil
    ) {
        self.conversationID = conversationID
        self.fileIDs = fileIDs
        self.sedimentIDs = sedimentIDs
        self.message = message
        self.blocked = blocked
        self.toolInvoked = toolInvoked
        self.turnUseCase = turnUseCase
    }

    public var hasImageReferences: Bool {
        self.fileIDs.isEmpty == false || self.sedimentIDs.isEmpty == false
    }

    public mutating func merge(_ other: ChatGPTWebImageConversationState) {
        if let conversationID = other.conversationID, conversationID.isEmpty == false {
            self.conversationID = conversationID
        }
        Self.appendUnique(other.fileIDs, to: &self.fileIDs)
        Self.appendUnique(other.sedimentIDs, to: &self.sedimentIDs)
        if let message = other.message?.trimmingCharacters(in: .whitespacesAndNewlines),
           message.isEmpty == false
        {
            self.message = message
        }
        self.blocked = self.blocked || other.blocked
        self.toolInvoked = other.toolInvoked ?? self.toolInvoked
        if let turnUseCase = other.turnUseCase, turnUseCase.isEmpty == false {
            self.turnUseCase = turnUseCase
        }
    }

    private static func appendUnique(_ values: [String], to target: inout [String]) {
        for value in values where value.isEmpty == false && target.contains(value) == false {
            target.append(value)
        }
    }
}

public enum OpenAIImagesProxySupport {
    public static let defaultImageModel = "gpt-image-2"
    public static let defaultChatGPTWebImageModel = "codex-gpt-image-2"
    public static let chatGPTWebImageModels = ["codex-gpt-image-2", "gpt-image-2"]
    public static let chatGPTWebDefaultClientVersion = "prod-be885abbfcfe7b1f511e88b3003d9ee44757fbad"
    public static let chatGPTWebDefaultClientBuildNumber = "5955942"
    public static let chatGPTWebDefaultPOWScript = "https://chatgpt.com/backend-api/sentinel/sdk.js"
    public static let chatGPTWebDefaultUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0"

    public static func requestInfo(
        body: Data,
        headers: [String: String],
        endpoint: OpenAIImagesEndpoint
    ) -> OpenAIImagesRequestInfo {
        let contentType = self.header("content-type", in: headers)
        if let contentType,
           contentType.lowercased().contains("multipart/form-data"),
           let parsed = self.parseMultipart(body: body, contentType: contentType)
        {
            return OpenAIImagesRequestInfo(
                endpoint: endpoint,
                contentType: contentType,
                fields: parsed.textFields,
                inputImageDataURIs: parsed.inputImageDataURIs,
                maskImageDataURIs: parsed.maskImageDataURIs,
                isMultipart: true
            )
        }

        var fields: [String: String] = [:]
        var images: [String] = []
        var masks: [String] = []
        if let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
            fields = self.textFields(fromJSONObject: object)
            images = self.imageDataURIs(fromJSONObject: object, keys: ["image", "images"])
            masks = self.imageDataURIs(fromJSONObject: object, keys: ["mask", "masks"])
        }
        return OpenAIImagesRequestInfo(
            endpoint: endpoint,
            contentType: contentType,
            fields: fields,
            inputImageDataURIs: images,
            maskImageDataURIs: masks,
            isMultipart: false
        )
    }

    public static func upstreamHeaders(
        apiKey: String,
        inboundHeaders: [String: String],
        providerPreset: OpenAICompatibleProviderPreset = .genericOpenAICompatible,
        defaultAccept: String = "application/json"
    ) -> [String: String] {
        var headers = OpenAICompatibleUpstream.requestHeaders(
            apiKey: apiKey,
            accept: self.header("accept", in: inboundHeaders) ?? defaultAccept,
            providerPreset: providerPreset
        )
        if let contentType = self.header("content-type", in: inboundHeaders) {
            headers["Content-Type"] = contentType
        }
        for name in ["openai-organization", "openai-project", "idempotency-key", "openai-beta"] {
            if let value = self.header(name, in: inboundHeaders) {
                headers[name] = value
            }
        }
        return headers
    }

    public static func bodyByApplyingModel(
        _ model: String,
        to body: Data,
        headers: [String: String],
        info: OpenAIImagesRequestInfo
    ) -> Data {
        guard model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              model != info.model
        else {
            return body
        }

        if info.isMultipart,
           let contentType = info.contentType,
           let parsed = self.parseMultipart(body: body, contentType: contentType)
        {
            return parsed.bodyBySettingTextField(name: "model", value: model) ?? body
        }

        guard var object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return body
        }
        object["model"] = model
        return (try? JSONSerialization.data(withJSONObject: object)) ?? body
    }

    public static func responsesBridgeRequest(
        info: OpenAIImagesRequestInfo,
        resolvedModel: String
    ) -> [String: Any]? {
        guard info.endpoint.canBridgeViaResponses else {
            return nil
        }
        if info.responseFormat == "url" {
            return nil
        }
        if let n = info.n, n > 1 {
            return nil
        }
        guard let prompt = info.prompt else {
            return nil
        }
        if info.endpoint == .edits, info.inputImageDataURIs.isEmpty {
            return nil
        }

        var content: [[String: Any]] = [
            [
                "type": "input_text",
                "text": prompt,
            ],
        ]
        for imageURL in info.inputImageDataURIs {
            content.append([
                "type": "input_image",
                "image_url": imageURL,
            ])
        }

        var tool: [String: Any] = [
            "type": "image_generation",
        ]
        for key in ["size", "quality", "background", "output_format", "moderation"] {
            if let value = info.fields[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
                tool[key] = value
            }
        }

        return [
            "model": resolvedModel,
            "input": [
                [
                    "type": "message",
                    "role": "user",
                    "content": content,
                ],
            ],
            "tools": [tool],
            "tool_choice": [
                "type": "image_generation",
            ],
            "stream": false,
            "store": false,
        ]
    }

    public static func imagesAPIResponse(
        fromResponsesBody body: Data,
        requestedModel: String
    ) throws -> [String: Any] {
        let completed = try self.completedResponseObject(from: body)
        var imagePayloads: [String] = []
        self.collectBase64Images(from: completed, into: &imagePayloads)
        imagePayloads = Array(NSOrderedSet(array: imagePayloads).compactMap { $0 as? String })

        guard imagePayloads.isEmpty == false else {
            throw ProxyError.message("ChatGPT image generation response did not contain image data.")
        }

        let created = (completed["created_at"] as? Int)
            ?? (completed["created"] as? Int)
            ?? Int(Helpers.now())
        return [
            "created": created,
            "data": imagePayloads.map { ["b64_json": $0] },
        ]
    }

    public static func isResponsesBridgeCompatibilityFailure(statusCode: Int, bodyText: String) -> Bool {
        if [401, 402, 403, 429].contains(statusCode) {
            return false
        }
        if HTTPErrorClassifier.containsAuthSignal(bodyText)
            || HTTPErrorClassifier.containsQuotaSignal(bodyText)
            || HTTPErrorClassifier.containsRateLimitSignal(bodyText)
        {
            return false
        }
        if [400, 404, 405, 501].contains(statusCode) {
            return true
        }

        let lower = bodyText.lowercased()
        let patterns = [
            "unsupported endpoint",
            "not implemented",
            "not found",
            "no route",
            "route not found",
            "image_generation",
            "unsupported tool",
            "tool not supported",
            "unsupported parameter",
            "unsupported model",
        ]
        return patterns.contains(where: { lower.contains($0) })
    }

    public static func chatGPTWebImageModelSlug(for model: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "gpt-image-2" {
            return "gpt-5-3"
        }
        if trimmed == "codex-gpt-image-2" {
            return trimmed
        }
        return "auto"
    }

    public static func chatGPTWebImageCount(_ value: Int?) -> Int {
        min(max(value ?? 1, 1), 4)
    }

    public static func chatGPTWebPreparePayload(
        prompt: String,
        model: String,
        timezone: String = "Asia/Shanghai",
        timezoneOffsetMinutes: Int = -480
    ) -> [String: Any] {
        return [
            "action": "next",
            "fork_from_shared_post": false,
            "parent_message_id": self.uuid(),
            "model": self.chatGPTWebImageModelSlug(for: model),
            "client_prepare_state": "success",
            "timezone_offset_min": timezoneOffsetMinutes,
            "timezone": timezone,
            "conversation_mode": ["kind": "primary_assistant"],
            "system_hints": ["picture_v2"],
            "partial_query": [
                "id": self.uuid(),
                "author": ["role": "user"],
                "content": [
                    "content_type": "text",
                    "parts": [prompt],
                ],
            ],
            "supports_buffering": true,
            "supported_encodings": ["v1"],
            "client_contextual_info": ["app_name": "chatgpt.com"],
        ]
    }

    public static func chatGPTWebConversationPayload(
        prompt: String,
        model: String,
        imageReferences: [[String: Any]] = [],
        timezone: String = "Asia/Shanghai",
        timezoneOffsetMinutes: Int = -480
    ) -> [String: Any] {
        let content: [String: Any]
        var metadata: [String: Any] = [
            "selected_all_github_repos": false,
            "system_hints": ["picture_v2"],
            "serialization_metadata": ["custom_symbol_offsets": []],
        ]
        if imageReferences.isEmpty {
            content = [
                "content_type": "text",
                "parts": [prompt],
            ]
        } else {
            var parts: [Any] = imageReferences.map { reference -> [String: Any] in
                [
                    "content_type": "image_asset_pointer",
                    "asset_pointer": "file-service://\(self.nonEmptyString(reference["file_id"]) ?? "")",
                    "width": reference["width"] ?? 0,
                    "height": reference["height"] ?? 0,
                    "size_bytes": reference["file_size"] ?? 0,
                ]
            }
            parts.append(prompt)
            content = [
                "content_type": "multimodal_text",
                "parts": parts,
            ]
            metadata["attachments"] = imageReferences.map { reference in
                [
                    "id": self.nonEmptyString(reference["file_id"]) ?? "",
                    "mimeType": self.nonEmptyString(reference["mime_type"]) ?? "image/png",
                    "name": self.nonEmptyString(reference["file_name"]) ?? "image.png",
                    "size": reference["file_size"] ?? 0,
                    "width": reference["width"] ?? 0,
                    "height": reference["height"] ?? 0,
                ]
            }
        }
        return [
            "action": "next",
            "messages": [
                [
                    "id": self.uuid(),
                    "author": ["role": "user"],
                    "create_time": Double(Helpers.nowMilliseconds()) / 1_000,
                    "content": content,
                    "metadata": metadata,
                ],
            ],
            "parent_message_id": self.uuid(),
            "model": self.chatGPTWebImageModelSlug(for: model),
            "client_prepare_state": "sent",
            "timezone_offset_min": timezoneOffsetMinutes,
            "timezone": timezone,
            "conversation_mode": ["kind": "primary_assistant"],
            "enable_message_followups": true,
            "system_hints": ["picture_v2"],
            "supports_buffering": true,
            "supported_encodings": ["v1"],
            "client_contextual_info": [
                "is_dark_mode": false,
                "time_since_loaded": 1200,
                "page_height": 1072,
                "page_width": 1724,
                "pixel_ratio": 1.2,
                "screen_height": 1440,
                "screen_width": 2560,
                "app_name": "chatgpt.com",
            ],
            "paragen_cot_summary_display_override": "allow",
            "force_parallel_switch": "auto",
        ]
    }

    public static func chatGPTWebConversationState(from events: [SSEEvent]) -> ChatGPTWebImageConversationState {
        var state = ChatGPTWebImageConversationState()
        for event in events {
            var eventState = self.chatGPTWebConversationState(fromText: event.data)
            if let object = ProxyTranscoder.jsonObject(from: event) {
                eventState.merge(self.chatGPTWebConversationState(fromJSONObject: object))
            }
            state.merge(eventState)
        }
        return state
    }

    public static func chatGPTWebConversationState(fromConversationDocument body: Data) -> ChatGPTWebImageConversationState {
        var state = self.chatGPTWebConversationState(fromText: String(decoding: body, as: UTF8.self))
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return state
        }
        state.merge(self.chatGPTWebConversationState(fromJSONObject: object))
        return state
    }

    public static func chatGPTWebDownloadURL(from body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        return self.nonEmptyString(object["download_url"])
            ?? self.nonEmptyString(object["url"])
    }

    public static func chatGPTWebImagesAPIResponse(
        imageData: [Data],
        created: Int = Int(Helpers.now())
    ) -> [String: Any] {
        [
            "created": created,
            "data": imageData.map { ["b64_json": $0.base64EncodedString()] },
        ]
    }

    public static func chatGPTWebPOWResources(fromHTML html: String) -> ChatGPTWebPOWResources {
        var sources: [String] = []
        let scriptPattern = #"<script\b[^>]*\bsrc\s*=\s*["']([^"']+)["'][^>]*>"#
        for source in self.matches(pattern: scriptPattern, in: html) where source.isEmpty == false {
            if sources.contains(source) == false {
                sources.append(source)
            }
        }
        var dataBuild = ""
        for source in sources {
            if let match = self.firstMatch(pattern: #"(c/[^/]*/_)"#, in: source) {
                dataBuild = match
                break
            }
        }
        if dataBuild.isEmpty,
           let htmlBuild = self.firstMatch(pattern: #"<html[^>]*\bdata-build\s*=\s*["']([^"']*)["']"#, in: html)
        {
            dataBuild = htmlBuild
        }
        if sources.isEmpty {
            sources = [Self.chatGPTWebDefaultPOWScript]
        }
        return ChatGPTWebPOWResources(scriptSources: sources, dataBuild: dataBuild)
    }

    public static func chatGPTWebLegacyRequirementsToken(
        userAgent: String = Self.chatGPTWebDefaultUserAgent,
        scriptSources: [String] = [Self.chatGPTWebDefaultPOWScript],
        dataBuild: String = ""
    ) -> String {
        let config = self.chatGPTWebPOWConfig(
            userAgent: userAgent,
            scriptSources: scriptSources,
            dataBuild: dataBuild
        )
        let seed = "\(Double.random(in: 0..<1))"
        let answer = self.chatGPTWebPOWGenerate(seed: seed, difficulty: "0fffff", config: config).answer
        return "gAAAAAC\(answer)"
    }

    public static func chatGPTWebProofToken(
        seed: String,
        difficulty: String,
        userAgent: String = Self.chatGPTWebDefaultUserAgent,
        scriptSources: [String] = [Self.chatGPTWebDefaultPOWScript],
        dataBuild: String = ""
    ) throws -> String {
        let config = self.chatGPTWebPOWConfig(
            userAgent: userAgent,
            scriptSources: scriptSources,
            dataBuild: dataBuild
        )
        let result = self.chatGPTWebPOWGenerate(seed: seed, difficulty: difficulty, config: config)
        guard result.solved else {
            throw ProxyError.message("failed to solve ChatGPT proof token: difficulty=\(difficulty)")
        }
        return "gAAAAAB\(result.answer)"
    }

    public static func chatGPTWebTurnstileToken(dx: String, sourceP: String) -> String? {
        guard let decodedData = Data.base64EncodedWithOptionalPadding(dx),
              let encodedProgram = String(data: decodedData, encoding: .utf8)
        else {
            return nil
        }
        let program = self.turnstileXOR(encodedProgram, key: sourceP)
        guard let data = program.data(using: .utf8),
              let instructions = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else {
            return nil
        }
        var runner = ChatGPTWebTurnstileRunner(instructions: instructions, sourceP: sourceP)
        return runner.run()
    }

    public static func header(_ name: String, in headers: [String: String]) -> String? {
        let lowerName = name.lowercased()
        return headers[name]
            ?? headers[lowerName]
            ?? headers.first(where: { $0.key.lowercased() == lowerName })?.value
    }

    private static func textFields(fromJSONObject object: [String: Any]) -> [String: String] {
        var fields: [String: String] = [:]
        for (key, value) in object {
            switch value {
            case let string as String:
                fields[key] = string
            case let number as NSNumber:
                fields[key] = number.stringValue
            case let bool as Bool:
                fields[key] = bool ? "true" : "false"
            default:
                continue
            }
        }
        return fields
    }

    private static func imageDataURIs(fromJSONObject object: [String: Any], keys: [String]) -> [String] {
        var values: [String] = []
        for key in keys {
            self.collectImageStrings(from: object[key], into: &values)
        }
        return values.compactMap(self.normalizedImageDataURI)
    }

    private static func collectImageStrings(from value: Any?, into values: inout [String]) {
        if let string = value as? String {
            values.append(string)
            return
        }
        if let array = value as? [Any] {
            for item in array {
                self.collectImageStrings(from: item, into: &values)
            }
            return
        }
        if let object = value as? [String: Any] {
            self.collectImageStrings(from: object["b64_json"], into: &values)
            self.collectImageStrings(from: object["image_url"], into: &values)
            self.collectImageStrings(from: object["url"], into: &values)
        }
    }

    private static func normalizedImageDataURI(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        if trimmed.lowercased().hasPrefix("data:image/") {
            return trimmed
        }
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            return trimmed
        }
        return "data:image/png;base64,\(trimmed)"
    }

    private static func completedResponseObject(from body: Data) throws -> [String: Any] {
        let text = String(decoding: body, as: UTF8.self)
        if text.contains("data:") {
            for line in text.components(separatedBy: .newlines).reversed() {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard trimmed.hasPrefix("data:") else { continue }
                let payload = trimmed.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                guard payload != "[DONE]",
                      let data = payload.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    continue
                }
                if (object["type"] as? String) == "response.completed",
                   let response = object["response"] as? [String: Any]
                {
                    return response
                }
                if let response = object["response"] as? [String: Any] {
                    return response
                }
            }
        }

        guard let object = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw ProxyError.message("ChatGPT image generation response was not valid JSON.")
        }
        if let response = object["response"] as? [String: Any] {
            return response
        }
        return object
    }

    private static func collectBase64Images(from value: Any?, into results: inout [String]) {
        if let array = value as? [Any] {
            for item in array {
                self.collectBase64Images(from: item, into: &results)
            }
            return
        }

        guard let object = value as? [String: Any] else {
            return
        }

        if let result = object["result"] as? String,
           let normalized = self.base64Payload(fromImageValue: result)
        {
            results.append(normalized)
        }
        if let b64 = object["b64_json"] as? String,
           let normalized = self.base64Payload(fromImageValue: b64)
        {
            results.append(normalized)
        }
        if let imageURL = object["image_url"] as? String,
           let normalized = self.base64Payload(fromImageValue: imageURL)
        {
            results.append(normalized)
        }
        if let url = object["url"] as? String,
           let normalized = self.base64Payload(fromImageValue: url)
        {
            results.append(normalized)
        }

        for nested in object.values {
            self.collectBase64Images(from: nested, into: &results)
        }
    }

    private static func base64Payload(fromImageValue value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return nil }
        if trimmed.lowercased().hasPrefix("data:image/"),
           let comma = trimmed.firstIndex(of: ",")
        {
            return String(trimmed[trimmed.index(after: comma)...])
        }
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            return nil
        }
        return trimmed
    }

    private static func chatGPTWebConversationState(fromText text: String) -> ChatGPTWebImageConversationState {
        var state = ChatGPTWebImageConversationState()
        if let conversationID = self.firstMatch(pattern: #""conversation_id"\s*:\s*"([^"]+)""#, in: text) {
            state.conversationID = conversationID
        }
        state.fileIDs = self.matches(pattern: #"file-service://([A-Za-z0-9_-]+)"#, in: text)
        state.sedimentIDs = self.matches(pattern: #"sediment://([A-Za-z0-9_-]+)"#, in: text)
        return state
    }

    private static func chatGPTWebConversationState(fromJSONObject object: [String: Any]) -> ChatGPTWebImageConversationState {
        var state = ChatGPTWebImageConversationState()
        self.walkChatGPTWebJSONObject(object, state: &state, isAssistantMessage: false)
        return state
    }

    private static func walkChatGPTWebJSONObject(
        _ value: Any?,
        state: inout ChatGPTWebImageConversationState,
        isAssistantMessage: Bool
    ) {
        if let string = value as? String {
            state.merge(self.chatGPTWebConversationState(fromText: string))
            if isAssistantMessage {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty == false,
                   trimmed.lowercased().hasPrefix("file-service://") == false,
                   trimmed.lowercased().hasPrefix("sediment://") == false
                {
                    state.message = trimmed
                }
            }
            return
        }

        if let array = value as? [Any] {
            for item in array {
                self.walkChatGPTWebJSONObject(item, state: &state, isAssistantMessage: isAssistantMessage)
            }
            return
        }

        guard let object = value as? [String: Any] else {
            return
        }

        if let conversationID = self.nonEmptyString(object["conversation_id"]) {
            state.conversationID = conversationID
        }
        if let blocked = object["blocked"] as? Bool {
            state.blocked = state.blocked || blocked
        }
        if let toolInvoked = object["tool_invoked"] as? Bool {
            state.toolInvoked = toolInvoked
        }
        if let metadata = object["metadata"] as? [String: Any] {
            if let toolInvoked = metadata["tool_invoked"] as? Bool {
                state.toolInvoked = toolInvoked
            }
            if let turnUseCase = self.nonEmptyString(metadata["turn_use_case"]) {
                state.turnUseCase = turnUseCase
            }
            if self.nonEmptyString(metadata["async_task_type"]) == "image_gen" {
                state.toolInvoked = true
            }
        }

        let author = object["author"] as? [String: Any]
        let role = self.nonEmptyString(author?["role"])
        let nextAssistant = isAssistantMessage || role == "assistant"

        if let content = object["content"] as? [String: Any],
           let parts = content["parts"]
        {
            self.walkChatGPTWebJSONObject(parts, state: &state, isAssistantMessage: nextAssistant)
        }

        for nested in object.values {
            self.walkChatGPTWebJSONObject(nested, state: &state, isAssistantMessage: nextAssistant)
        }
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        let trimmed = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func matches(pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text)
            else {
                return nil
            }
            return String(text[range])
        }
    }

    private static func firstMatch(pattern: String, in text: String) -> String? {
        self.matches(pattern: pattern, in: text).first
    }

    private static func uuid() -> String {
        UUID().uuidString.lowercased()
    }

    fileprivate static func turnstileXOR(_ text: String, key: String) -> String {
        guard key.isEmpty == false else { return text }
        let textScalars = Array(text.unicodeScalars)
        let keyScalars = Array(key.unicodeScalars)
        var scalars = String.UnicodeScalarView()
        for (index, scalar) in textScalars.enumerated() {
            let value = scalar.value ^ keyScalars[index % keyScalars.count].value
            scalars.append(UnicodeScalar(value) ?? "\u{FFFD}")
        }
        return String(scalars)
    }

    private static func chatGPTWebPOWConfig(
        userAgent: String,
        scriptSources: [String],
        dataBuild: String
    ) -> [Any] {
        let navigatorKeys = [
            "registerProtocolHandler\u{2212}function registerProtocolHandler() { [native code] }",
            "storage\u{2212}[object StorageManager]",
            "locks\u{2212}[object LockManager]",
            "appCodeName\u{2212}Mozilla",
            "permissions\u{2212}[object Permissions]",
            "share\u{2212}function share() { [native code] }",
            "webdriver\u{2212}false",
            "managed\u{2212}[object NavigatorManagedData]",
            "canShare\u{2212}function canShare() { [native code] }",
            "vendor\u{2212}Google Inc.",
            "mediaDevices\u{2212}[object MediaDevices]",
            "vibrate\u{2212}function vibrate() { [native code] }",
            "storageBuckets\u{2212}[object StorageBucketManager]",
            "mediaCapabilities\u{2212}[object MediaCapabilities]",
            "cookieEnabled\u{2212}true",
            "virtualKeyboard\u{2212}[object VirtualKeyboard]",
            "product\u{2212}Gecko",
            "presentation\u{2212}[object Presentation]",
            "onLine\u{2212}true",
            "mimeTypes\u{2212}[object MimeTypeArray]",
            "credentials\u{2212}[object CredentialsContainer]",
            "serviceWorker\u{2212}[object ServiceWorkerContainer]",
            "keyboard\u{2212}[object Keyboard]",
            "gpu\u{2212}[object GPU]",
            "doNotTrack",
            "serial\u{2212}[object Serial]",
            "pdfViewerEnabled\u{2212}true",
            "language\u{2212}zh-CN",
            "geolocation\u{2212}[object Geolocation]",
            "userAgentData\u{2212}[object NavigatorUAData]",
            "getUserMedia\u{2212}function getUserMedia() { [native code] }",
            "sendBeacon\u{2212}function sendBeacon() { [native code] }",
            "hardwareConcurrency\u{2212}32",
            "windowControlsOverlay\u{2212}[object WindowControlsOverlay]",
        ]
        let windowKeys = [
            "0", "window", "self", "document", "name", "location", "customElements", "history",
            "navigation", "innerWidth", "innerHeight", "scrollX", "scrollY", "visualViewport",
            "screenX", "screenY", "outerWidth", "outerHeight", "devicePixelRatio", "screen",
            "chrome", "navigator", "onresize", "performance", "crypto", "indexedDB",
            "sessionStorage", "localStorage", "scheduler", "alert", "atob", "btoa", "fetch",
            "matchMedia", "postMessage", "queueMicrotask", "requestAnimationFrame",
            "setInterval", "setTimeout", "caches", "__NEXT_DATA__", "__BUILD_MANIFEST",
            "__NEXT_PRELOADREADY",
        ]
        let perfMS = ProcessInfo.processInfo.systemUptime * 1_000
        let epochMS = Date().timeIntervalSince1970 * 1_000
        return [
            [3_000, 4_000, 5_000].randomElement() ?? 3_000,
            self.chatGPTWebLegacyDateString(),
            4_294_705_152,
            0,
            userAgent,
            scriptSources.randomElement() ?? Self.chatGPTWebDefaultPOWScript,
            dataBuild,
            "en-US",
            "en-US,es-US,en,es",
            0,
            navigatorKeys.randomElement() ?? "webdriver-false",
            ["_reactListeningo743lnnpvdg", "location"].randomElement() ?? "location",
            windowKeys.randomElement() ?? "window",
            perfMS,
            self.uuid(),
            "",
            [8, 16, 24, 32].randomElement() ?? 16,
            epochMS - perfMS,
        ]
    }

    private static func chatGPTWebLegacyDateString() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: -5 * 60 * 60)
        formatter.dateFormat = "EEE MMM dd yyyy HH:mm:ss"
        return "\(formatter.string(from: Date())) GMT-0500 (Eastern Standard Time)"
    }

    private static func chatGPTWebPOWGenerate(
        seed: String,
        difficulty: String,
        config: [Any],
        limit: Int = 500_000
    ) -> (answer: String, solved: Bool) {
        guard let target = self.hexData(difficulty),
              target.isEmpty == false,
              let static1 = self.jsonData(Array(config.prefix(3))).dropLastByteAndAppend(","),
              let static2 = self.jsonData(Array(config[4..<9])).dropFirstAndLastAndWrap(prefix: ",", suffix: ","),
              let static3 = self.jsonData(Array(config[10...])).dropFirstAndWrap(prefix: ",")
        else {
            let fallback = "wQ8Lk5FbGpA2NcR9dShT6gYjU7VxZ4D"
                + Data("\"\(seed)\"".utf8).base64EncodedString()
            return (fallback, false)
        }
        let seedData = Data(seed.utf8)
        for index in 0..<limit {
            var payload = Data()
            payload.append(static1)
            payload.append(Data("\(index)".utf8))
            payload.append(static2)
            payload.append(Data("\(index >> 1)".utf8))
            payload.append(static3)
            let encoded = payload.base64EncodedString()
            var hashInput = seedData
            hashInput.append(Data(encoded.utf8))
            let digest = self.sha3_512(hashInput)
            if self.lexicographicPrefix(digest, count: target.count, isLessThanOrEqualTo: target) {
                return (encoded, true)
            }
        }
        let fallback = "wQ8Lk5FbGpA2NcR9dShT6gYjU7VxZ4D"
            + Data("\"\(seed)\"".utf8).base64EncodedString()
        return (fallback, false)
    }

    private static func jsonData(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: value)) ?? Data("[]".utf8)
    }

    private static func hexData(_ value: String) -> Data? {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count.isMultiple(of: 2) else { return nil }
        var data = Data()
        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let next = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    private static func lexicographicPrefix(
        _ data: Data,
        count: Int,
        isLessThanOrEqualTo target: Data
    ) -> Bool {
        guard data.count >= count, target.count >= count else {
            return false
        }
        for offset in 0..<count {
            let lhs = data[data.index(data.startIndex, offsetBy: offset)]
            let rhs = target[target.index(target.startIndex, offsetBy: offset)]
            if lhs < rhs { return true }
            if lhs > rhs { return false }
        }
        return true
    }

    private static func sha3_512(_ data: Data) -> Data {
        let rate = 72
        var state = [UInt64](repeating: 0, count: 25)
        var offset = 0
        while offset + rate <= data.count {
            self.keccakAbsorb(block: data[offset..<(offset + rate)], into: &state)
            self.keccakF1600(&state)
            offset += rate
        }

        var finalBlock = [UInt8](repeating: 0, count: rate)
        let remainder = data.count - offset
        if remainder > 0 {
            finalBlock[0..<remainder] = ArraySlice(Array(data[offset..<data.count]))
        }
        finalBlock[remainder] ^= 0x06
        finalBlock[rate - 1] ^= 0x80
        self.keccakAbsorb(block: Data(finalBlock), into: &state)
        self.keccakF1600(&state)

        var output = Data()
        output.reserveCapacity(64)
        while output.count < 64 {
            for lane in 0..<(rate / 8) {
                var value = state[lane].littleEndian
                withUnsafeBytes(of: &value) { bytes in
                    let remaining = 64 - output.count
                    output.append(contentsOf: bytes.prefix(remaining))
                }
                if output.count == 64 {
                    break
                }
            }
            if output.count < 64 {
                self.keccakF1600(&state)
            }
        }
        return output
    }

    private static func keccakAbsorb(block: Data, into state: inout [UInt64]) {
        let bytes = [UInt8](block)
        for lane in 0..<(bytes.count / 8) {
            var value: UInt64 = 0
            for byteOffset in 0..<8 {
                value |= UInt64(bytes[lane * 8 + byteOffset]) << UInt64(byteOffset * 8)
            }
            state[lane] ^= value
        }
    }

    private static func keccakF1600(_ state: inout [UInt64]) {
        let rotationOffsets: [UInt64] = [
            0, 1, 62, 28, 27,
            36, 44, 6, 55, 20,
            3, 10, 43, 25, 39,
            41, 45, 15, 21, 8,
            18, 2, 61, 56, 14,
        ]
        let roundConstants: [UInt64] = [
            0x0000_0000_0000_0001, 0x0000_0000_0000_8082,
            0x8000_0000_0000_808A, 0x8000_0000_8000_8000,
            0x0000_0000_0000_808B, 0x0000_0000_8000_0001,
            0x8000_0000_8000_8081, 0x8000_0000_0000_8009,
            0x0000_0000_0000_008A, 0x0000_0000_0000_0088,
            0x0000_0000_8000_8009, 0x0000_0000_8000_000A,
            0x0000_0000_8000_808B, 0x8000_0000_0000_008B,
            0x8000_0000_0000_8089, 0x8000_0000_0000_8003,
            0x8000_0000_0000_8002, 0x8000_0000_0000_0080,
            0x0000_0000_0000_800A, 0x8000_0000_8000_000A,
            0x8000_0000_8000_8081, 0x8000_0000_0000_8080,
            0x0000_0000_8000_0001, 0x8000_0000_8000_8008,
        ]

        for round in 0..<24 {
            var c = [UInt64](repeating: 0, count: 5)
            for x in 0..<5 {
                c[x] = state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20]
            }
            var d = [UInt64](repeating: 0, count: 5)
            for x in 0..<5 {
                d[x] = c[(x + 4) % 5] ^ self.rotateLeft(c[(x + 1) % 5], by: 1)
            }
            for y in 0..<5 {
                for x in 0..<5 {
                    state[x + 5 * y] ^= d[x]
                }
            }

            var b = [UInt64](repeating: 0, count: 25)
            for y in 0..<5 {
                for x in 0..<5 {
                    let source = x + 5 * y
                    let destination = y + 5 * ((2 * x + 3 * y) % 5)
                    b[destination] = self.rotateLeft(state[source], by: rotationOffsets[source])
                }
            }

            for y in 0..<5 {
                for x in 0..<5 {
                    state[x + 5 * y] = b[x + 5 * y] ^ ((~b[((x + 1) % 5) + 5 * y]) & b[((x + 2) % 5) + 5 * y])
                }
            }

            state[0] ^= roundConstants[round]
        }
    }

    private static func rotateLeft(_ value: UInt64, by shift: UInt64) -> UInt64 {
        let normalized = shift & 63
        guard normalized != 0 else { return value }
        return (value << normalized) | (value >> (64 - normalized))
    }

    private static func parseMultipart(body: Data, contentType: String) -> ParsedMultipart? {
        guard let boundary = self.multipartBoundary(from: contentType) else {
            return nil
        }
        let delimiter = Data("--\(boundary)".utf8)
        let segments = body.components(separatedBy: delimiter)
        var parts: [MultipartPart] = []
        for var segment in segments {
            if segment.isEmpty {
                continue
            }
            if segment.starts(with: Data("--".utf8)) {
                continue
            }
            segment = segment.trimmingLeadingCRLF()
            segment = segment.trimmingTrailingCRLF()
            guard let headerRange = segment.range(of: Data("\r\n\r\n".utf8)) else {
                continue
            }
            let headerData = segment[..<headerRange.lowerBound]
            let contentStart = headerRange.upperBound
            let content = Data(segment[contentStart...])
            let rawHeaders = String(decoding: headerData, as: UTF8.self)
            let headers = self.multipartHeaders(from: rawHeaders)
            let disposition = headers["content-disposition"] ?? ""
            let name = self.dispositionParameter("name", in: disposition)
            let filename = self.dispositionParameter("filename", in: disposition)
            let contentType = headers["content-type"]
            parts.append(
                MultipartPart(
                    rawHeaders: rawHeaders,
                    headers: headers,
                    name: name,
                    filename: filename,
                    contentType: contentType,
                    body: content
                )
            )
        }
        return ParsedMultipart(boundary: boundary, parts: parts)
    }

    private static func multipartBoundary(from contentType: String) -> String? {
        for component in contentType.components(separatedBy: ";") {
            let trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("boundary=") else { continue }
            var value = String(trimmed.dropFirst("boundary=".count))
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value.removeFirst()
                value.removeLast()
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func multipartHeaders(from rawHeaders: String) -> [String: String] {
        var headers: [String: String] = [:]
        for line in rawHeaders.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }
        return headers
    }

    private static func dispositionParameter(_ name: String, in value: String) -> String? {
        let pattern = "\(name)=\""
        guard let start = value.range(of: pattern) else { return nil }
        let rest = value[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let result = rest[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : String(result)
    }
}

private struct ParsedMultipart {
    var boundary: String
    var parts: [MultipartPart]

    var textFields: [String: String] {
        var fields: [String: String] = [:]
        for part in self.parts where part.filename == nil {
            guard let name = part.name else { continue }
            let value = String(decoding: part.body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            fields[name] = value
        }
        return fields
    }

    var inputImageDataURIs: [String] {
        self.parts.compactMap { part -> String? in
            guard part.filename != nil,
                  let name = part.name,
                  name == "image" || name == "image[]",
                  part.body.isEmpty == false
            else {
                return nil
            }
            let mimeType = part.contentType?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedMimeType = (mimeType?.isEmpty == false ? mimeType! : "image/png")
            return "data:\(resolvedMimeType);base64,\(part.body.base64EncodedString())"
        }
    }

    var maskImageDataURIs: [String] {
        self.parts.compactMap { part -> String? in
            guard part.filename != nil,
                  let name = part.name,
                  name == "mask" || name == "mask[]",
                  part.body.isEmpty == false
            else {
                return nil
            }
            let mimeType = part.contentType?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedMimeType = (mimeType?.isEmpty == false ? mimeType! : "image/png")
            return "data:\(resolvedMimeType);base64,\(part.body.base64EncodedString())"
        }
    }

    func bodyBySettingTextField(name: String, value: String) -> Data? {
        var updatedParts = self.parts
        if let index = updatedParts.firstIndex(where: { $0.name == name && $0.filename == nil }) {
            updatedParts[index].body = Data(value.utf8)
        } else {
            updatedParts.append(
                MultipartPart(
                    rawHeaders: #"Content-Disposition: form-data; name="\#(name)""#,
                    headers: ["content-disposition": #"form-data; name="\#(name)""#],
                    name: name,
                    filename: nil,
                    contentType: nil,
                    body: Data(value.utf8)
                )
            )
        }

        var data = Data()
        for part in updatedParts {
            data.append(Data("--\(self.boundary)\r\n".utf8))
            data.append(Data(part.rawHeaders.utf8))
            data.append(Data("\r\n\r\n".utf8))
            data.append(part.body)
            data.append(Data("\r\n".utf8))
        }
        data.append(Data("--\(self.boundary)--\r\n".utf8))
        return data
    }
}

private struct MultipartPart {
    var rawHeaders: String
    var headers: [String: String]
    var name: String?
    var filename: String?
    var contentType: String?
    var body: Data
}

private struct ChatGPTWebTurnstileOrderedMap {
    var keys: [String] = []
    var values: [String: ChatGPTWebTurnstileValue] = [:]

    mutating func add(key: String, value: ChatGPTWebTurnstileValue) {
        if self.values[key] == nil {
            self.keys.append(key)
        }
        self.values[key] = value
    }
}

private indirect enum ChatGPTWebTurnstileValue: Equatable {
    case undefined
    case null
    case bool(Bool)
    case int(Int)
    case number(Double)
    case string(String)
    case array([ChatGPTWebTurnstileValue])
    case orderedMap(ChatGPTWebTurnstileOrderedMap)
    case function(Int)

    static func == (lhs: ChatGPTWebTurnstileValue, rhs: ChatGPTWebTurnstileValue) -> Bool {
        switch (lhs, rhs) {
        case (.undefined, .undefined), (.null, .null):
            return true
        case let (.bool(lhs), .bool(rhs)):
            return lhs == rhs
        case let (.int(lhs), .int(rhs)):
            return lhs == rhs
        case let (.number(lhs), .number(rhs)):
            return lhs == rhs
        case let (.int(lhs), .number(rhs)):
            return Double(lhs) == rhs
        case let (.number(lhs), .int(rhs)):
            return lhs == Double(rhs)
        case let (.string(lhs), .string(rhs)):
            return lhs == rhs
        case let (.array(lhs), .array(rhs)):
            return lhs == rhs
        case let (.function(lhs), .function(rhs)):
            return lhs == rhs
        case let (.orderedMap(lhs), .orderedMap(rhs)):
            return lhs.keys == rhs.keys && lhs.values == rhs.values
        default:
            return false
        }
    }

    var isTruthyObject: Bool {
        switch self {
        case .undefined, .null:
            return false
        default:
            return true
        }
    }

    var stringValue: String {
        switch self {
        case .undefined, .null:
            return "undefined"
        case let .bool(value):
            return value ? "true" : "false"
        case let .int(value):
            return "\(value)"
        case let .number(value):
            if value.isFinite == false {
                return "NaN"
            }
            return "\(value)"
        case let .string(value):
            return Self.specialStringValue(value)
        case let .array(values):
            if values.allSatisfy({ value in
                if case .string = value { return true }
                return false
            }) {
                return values.map(\.stringValue).joined(separator: ",")
            }
            return "[\(values.map(\.stringValue).joined(separator: ", "))]"
        case let .orderedMap(map):
            return map.keys.map { "\($0):\(map.values[$0]?.stringValue ?? "undefined")" }
                .joined(separator: ",")
        case let .function(identifier):
            return "function \(identifier)"
        }
    }

    var jsonString: String {
        switch self {
        case .undefined, .null, .function:
            return "null"
        case let .bool(value):
            return value ? "true" : "false"
        case let .int(value):
            return "\(value)"
        case let .number(value):
            if value.isFinite == false {
                return "null"
            }
            return "\(value)"
        case let .string(value):
            return Self.quotedJSONString(value)
        case let .array(values):
            return "[\(values.map(\.jsonString).joined(separator: ", "))]"
        case let .orderedMap(map):
            let pairs = map.keys.map { key in
                "\(Self.quotedJSONString(key)): \(map.values[key]?.jsonString ?? "null")"
            }
            return "{\(pairs.joined(separator: ", "))}"
        }
    }

    static func fromJSONValue(_ value: Any) -> ChatGPTWebTurnstileValue {
        switch value {
        case _ as NSNull:
            return .null
        case let bool as Bool:
            return .bool(bool)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            let type = CFNumberGetType(number)
            switch type {
            case .floatType, .float32Type, .float64Type, .doubleType, .cgFloatType:
                return .number(number.doubleValue)
            default:
                return .int(number.intValue)
            }
        case let string as String:
            return .string(string)
        case let array as [Any]:
            return .array(array.map(Self.fromJSONValue))
        case let object as [String: Any]:
            var map = ChatGPTWebTurnstileOrderedMap()
            for key in object.keys.sorted() {
                map.add(key: key, value: Self.fromJSONValue(object[key] ?? NSNull()))
            }
            return .orderedMap(map)
        default:
            return .undefined
        }
    }

    private static func specialStringValue(_ value: String) -> String {
        let special = [
            "window.Math": "[object Math]",
            "window.Reflect": "[object Reflect]",
            "window.performance": "[object Performance]",
            "window.localStorage": "[object Storage]",
            "window.Object": "function Object() { [native code] }",
            "window.Reflect.set": "function set() { [native code] }",
            "window.performance.now": "function () { [native code] }",
            "window.Object.create": "function create() { [native code] }",
            "window.Object.keys": "function keys() { [native code] }",
            "window.Math.random": "function random() { [native code] }",
        ]
        return special[value] ?? value
    }

    private static func quotedJSONString(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"":
                result += "\\\""
            case "\\":
                result += "\\\\"
            case "\n":
                result += "\\n"
            case "\r":
                result += "\\r"
            case "\t":
                result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04X", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        result += "\""
        return result
    }
}

private struct ChatGPTWebTurnstileRunner {
    private var instructions: [Any]
    private var sourceP: String
    private var values: [Int: ChatGPTWebTurnstileValue] = [:]
    private var result = ""
    private var startNanoseconds = DispatchTime.now().uptimeNanoseconds

    init(instructions: [Any], sourceP: String) {
        self.instructions = instructions
        self.sourceP = sourceP
        for identifier in [1, 2, 3, 5, 6, 7, 8, 14, 15, 17, 18, 19, 20, 21, 23, 24] {
            self.values[identifier] = .function(identifier)
        }
        self.values[9] = .array(instructions.map(ChatGPTWebTurnstileValue.fromJSONValue))
        self.values[10] = .string("window")
        self.values[16] = .string(sourceP)
    }

    mutating func run() -> String? {
        for instruction in self.instructions {
            guard let parts = instruction as? [Any],
                  let opcode = Self.intValue(parts.first)
            else {
                continue
            }
            do {
                try self.execute(opcode: opcode, args: Array(parts.dropFirst()))
            } catch {
                continue
            }
        }
        return self.result.isEmpty ? nil : self.result
    }

    private mutating func execute(opcode: Int, args: [Any]) throws {
        switch opcode {
        case 1:
            try self.requireArgCount(args, 2)
            let first = try self.value(for: args[0]).stringValue
            let second = try self.value(for: args[1]).stringValue
            try self.set(OpenAIImagesProxySupport.turnstileXOR(first, key: second), for: args[0])
        case 2:
            try self.requireArgCount(args, 2)
            try self.set(ChatGPTWebTurnstileValue.fromJSONValue(args[1]), for: args[0])
        case 3:
            guard let first = args.first else { throw TurnstileError.invalidInstruction }
            guard let text = first as? String else {
                throw TurnstileError.invalidInstruction
            }
            self.result = Data(text.utf8).base64EncodedString()
        case 5:
            try self.requireArgCount(args, 2)
            let current = try self.value(for: args[0])
            let incoming = try self.value(for: args[1])
            if case var .array(values) = current {
                values.append(incoming)
                try self.set(.array(values), for: args[0])
                return
            }
            if current.isStringLike || incoming.isStringLike {
                try self.set(current.stringValue + incoming.stringValue, for: args[0])
                return
            }
            try self.set("NaN", for: args[0])
        case 6:
            try self.requireArgCount(args, 3)
            let first = try self.value(for: args[1])
            let second = try self.value(for: args[2])
            guard case let .string(firstString) = first,
                  case let .string(secondString) = second
            else {
                return
            }
            let joined = "\(firstString).\(secondString)"
            try self.set(joined == "window.document.location" ? "https://chatgpt.com/" : joined, for: args[0])
        case 7:
            try self.requireArgCount(args, 1)
            let target = try self.value(for: args[0])
            if case let .string(name) = target, name == "window.Reflect.set" {
                try self.reflectSet(args: Array(args.dropFirst()))
                return
            }
            if case let .function(identifier) = target {
                try self.callFunction(identifier, values: try args.dropFirst().map { try self.value(for: $0) })
            }
        case 8:
            try self.requireArgCount(args, 2)
            try self.set(try self.value(for: args[1]), for: args[0])
        case 14:
            try self.requireArgCount(args, 2)
            let text = try self.value(for: args[1]).stringValue
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data)
            else {
                throw TurnstileError.invalidInstruction
            }
            try self.set(ChatGPTWebTurnstileValue.fromJSONValue(object), for: args[0])
        case 15:
            try self.requireArgCount(args, 2)
            try self.set(try self.value(for: args[1]).jsonString, for: args[0])
        case 17:
            try self.requireArgCount(args, 2)
            try self.callNativeFunction(output: args[0], target: self.value(for: args[1]), args: Array(args.dropFirst(2)))
        case 18:
            try self.requireArgCount(args, 1)
            let text = try self.value(for: args[0]).stringValue
            guard let decoded = Data.base64EncodedWithOptionalPadding(text),
                  let decodedText = String(data: decoded, encoding: .utf8)
            else {
                throw TurnstileError.invalidInstruction
            }
            try self.set(decodedText, for: args[0])
        case 19:
            try self.requireArgCount(args, 1)
            let text = try self.value(for: args[0]).stringValue
            try self.set(Data(text.utf8).base64EncodedString(), for: args[0])
        case 20:
            try self.requireArgCount(args, 3)
            guard try self.value(for: args[0]) == self.value(for: args[1]) else {
                return
            }
            if case let .function(identifier) = try self.value(for: args[2]) {
                try self.callFunction(identifier, values: try args.dropFirst(3).map { try self.value(for: $0) })
            }
        case 21:
            return
        case 23:
            try self.requireArgCount(args, 2)
            guard try self.value(for: args[0]).isTruthyObject,
                  case let .function(identifier) = try self.value(for: args[1])
            else {
                return
            }
            try self.callRawFunction(identifier, args: Array(args.dropFirst(2)))
        case 24:
            try self.requireArgCount(args, 3)
            let first = try self.value(for: args[1])
            let second = try self.value(for: args[2])
            guard case let .string(firstString) = first,
                  case let .string(secondString) = second
            else {
                return
            }
            try self.set("\(firstString).\(secondString)", for: args[0])
        default:
            return
        }
    }

    private mutating func callFunction(_ identifier: Int, values: [ChatGPTWebTurnstileValue]) throws {
        switch identifier {
        case 3:
            guard let first = values.first else { return }
            self.result = Data(first.stringValue.utf8).base64EncodedString()
        case 21:
            return
        default:
            return
        }
    }

    private mutating func callRawFunction(_ identifier: Int, args: [Any]) throws {
        switch identifier {
        case 3:
            guard let first = args.first as? String else { return }
            self.result = Data(first.utf8).base64EncodedString()
        case 21:
            return
        default:
            return
        }
    }

    private mutating func callNativeFunction(
        output: Any,
        target: ChatGPTWebTurnstileValue,
        args: [Any]
    ) throws {
        if case let .function(identifier) = target {
            try self.callFunction(identifier, values: try args.map { try self.value(for: $0) })
            try self.set(.null, for: output)
            return
        }
        guard case let .string(name) = target else { return }
        switch name {
        case "window.performance.now":
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - self.startNanoseconds) / 1_000_000
            try self.set(elapsed + Double.random(in: 0..<1), for: output)
        case "window.Object.create":
            try self.set(.orderedMap(ChatGPTWebTurnstileOrderedMap()), for: output)
        case "window.Object.keys":
            let values = try args.map { try self.value(for: $0) }
            if values.first == .string("window.localStorage") {
                try self.set(
                    .array([
                        .string("STATSIG_LOCAL_STORAGE_INTERNAL_STORE_V4"),
                        .string("STATSIG_LOCAL_STORAGE_STABLE_ID"),
                        .string("client-correlated-secret"),
                        .string("oai/apps/capExpiresAt"),
                        .string("oai-did"),
                        .string("STATSIG_LOCAL_STORAGE_LOGGING_REQUEST"),
                        .string("UiState.isNavigationCollapsed.1"),
                    ]),
                    for: output
                )
            }
        case "window.Math.random":
            try self.set(Double.random(in: 0..<1), for: output)
        default:
            return
        }
    }

    private mutating func reflectSet(args: [Any]) throws {
        try self.requireArgCount(args, 3)
        let objectKey = try Self.key(from: args[0])
        guard case var .orderedMap(map) = self.values[objectKey] else {
            return
        }
        let key = try self.value(for: args[1]).stringValue
        let value = try self.value(for: args[2])
        map.add(key: key, value: value)
        self.values[objectKey] = .orderedMap(map)
    }

    private func value(for raw: Any) throws -> ChatGPTWebTurnstileValue {
        let key = try Self.key(from: raw)
        guard let value = self.values[key] else {
            throw TurnstileError.missingValue
        }
        return value
    }

    private mutating func set(_ string: String, for raw: Any) throws {
        try self.set(.string(string), for: raw)
    }

    private mutating func set(_ number: Double, for raw: Any) throws {
        try self.set(.number(number), for: raw)
    }

    private mutating func set(_ value: ChatGPTWebTurnstileValue, for raw: Any) throws {
        self.values[try Self.key(from: raw)] = value
    }

    private func requireArgCount(_ args: [Any], _ count: Int) throws {
        if args.count < count {
            throw TurnstileError.invalidInstruction
        }
    }

    private static func key(from raw: Any) throws -> Int {
        guard let value = self.intValue(raw) else {
            throw TurnstileError.invalidInstruction
        }
        return value
    }

    private static func intValue(_ raw: Any?) -> Int? {
        switch raw {
        case let value as Int:
            return value
        case let value as NSNumber:
            return value.intValue
        case let value as Double:
            return Int(value)
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }

    private static func rawString(_ raw: Any) -> String {
        ChatGPTWebTurnstileValue.fromJSONValue(raw).stringValue
    }

    private enum TurnstileError: Error {
        case invalidInstruction
        case missingValue
    }
}

private extension ChatGPTWebTurnstileValue {
    var isStringLike: Bool {
        switch self {
        case .string, .int, .number:
            return true
        default:
            return false
        }
    }
}

private extension Data {
    static func base64EncodedWithOptionalPadding(_ value: String) -> Data? {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder = cleaned.count % 4
        let padded = remainder == 0
            ? cleaned
            : cleaned + String(repeating: "=", count: 4 - remainder)
        return Data(base64Encoded: padded)
    }

    func components(separatedBy separator: Data) -> [Data] {
        guard separator.isEmpty == false else { return [self] }
        var parts: [Data] = []
        var searchStart = self.startIndex
        while searchStart < self.endIndex,
              let range = self.range(of: separator, options: [], in: searchStart..<self.endIndex)
        {
            parts.append(Data(self[searchStart..<range.lowerBound]))
            searchStart = range.upperBound
        }
        parts.append(Data(self[searchStart..<self.endIndex]))
        return parts
    }

    func starts(with prefix: Data) -> Bool {
        guard self.count >= prefix.count else { return false }
        return self[self.startIndex..<self.index(self.startIndex, offsetBy: prefix.count)].elementsEqual(prefix)
    }

    func trimmingLeadingCRLF() -> Data {
        var data = self
        while data.starts(with: Data("\r\n".utf8)) {
            data = Data(data.dropFirst(2))
        }
        return data
    }

    func trimmingTrailingCRLF() -> Data {
        var data = self
        while data.count >= 2 && data.suffix(2).elementsEqual(Data("\r\n".utf8)) {
            data = Data(data.dropLast(2))
        }
        return data
    }

    func dropLastByteAndAppend(_ suffix: String) -> Data? {
        guard self.isEmpty == false else { return nil }
        var data = Data(self.dropLast())
        data.append(Data(suffix.utf8))
        return data
    }

    func dropFirstAndLastAndWrap(prefix: String, suffix: String) -> Data? {
        guard self.count >= 2 else { return nil }
        var data = Data(prefix.utf8)
        data.append(Data(self.dropFirst().dropLast()))
        data.append(Data(suffix.utf8))
        return data
    }

    func dropFirstAndWrap(prefix: String) -> Data? {
        guard self.isEmpty == false else { return nil }
        var data = Data(prefix.utf8)
        data.append(Data(self.dropFirst()))
        return data
    }
}
