import Foundation

public enum OpenAICompatibleUpstream {
    public static let defaultBaseURL = "https://api.openai.com"
    public static let defaultGeminiBaseURL = "https://generativelanguage.googleapis.com/v1beta/openai"
    private static let validationProbePrompt = "你好"
    public static let geminiCompatibilityRootRequiresGeminiPresetMessage =
        "检测到 Google Gemini OpenAI-compatible 根地址，请将 Provider 切换为 `Google Gemini Compatible`，不要使用 `Generic OpenAI Compatible`。"
    public static let googleGeminiAPIKeyOnlyMessage =
        "手动 `Google Gemini Compatible` preset 目前只支持 Gemini API key。Google / Gemini 登录态不能作为这个兼容 preset 的账号导入。若你想使用 Google OAuth 登录，请到账号页使用新的 `Google / Gemini Login`；若你想继续走 OpenAI-compatible 兼容链路，请改用 Google AI Studio 生成的 Gemini API key。"

    public static func normalizedManualProviderPreset(
        baseURL: String,
        providerPreset: OpenAICompatibleProviderPreset
    ) -> OpenAICompatibleProviderPreset {
        guard providerPreset == .genericOpenAICompatible,
              self.isOfficialGeminiCompatibilityRoot(baseURL)
        else {
            return providerPreset
        }
        return .googleGeminiCompatible
    }

    public static func isOfficialGeminiCompatibilityRoot(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(),
              host == "generativelanguage.googleapis.com"
        else {
            return false
        }

        components.query = nil
        components.fragment = nil

        var path = components.path.lowercased()
        while path.hasSuffix("/") && path.count > 1 {
            path.removeLast()
        }
        if path == "/" {
            path = ""
        }
        return path == "/v1beta/openai"
    }

    public static func manualConfigurationError(
        baseURL: String,
        providerPreset: OpenAICompatibleProviderPreset,
        explicitSelection: Bool = true
    ) -> String? {
        guard explicitSelection,
              self.normalizedManualProviderPreset(
                baseURL: baseURL,
                providerPreset: providerPreset
              ) != providerPreset
        else {
            return nil
        }
        return self.geminiCompatibilityRootRequiresGeminiPresetMessage
    }

    public static func isLikelyGoogleAIOAuthLikeCredential(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return false
        }
        let lower = trimmed.lowercased()
        let prefixes = [
            "aq.",
            "ya29.",
            "1//",
        ]
        return prefixes.contains(where: { lower.hasPrefix($0) })
    }

    public static func googleGeminiCredentialConfigurationError(
        providerPreset: OpenAICompatibleProviderPreset,
        apiKey: String?
    ) -> String? {
        guard providerPreset == .googleGeminiCompatible,
              let apiKey,
              self.isLikelyGoogleAIOAuthLikeCredential(apiKey)
        else {
            return nil
        }
        return self.googleGeminiAPIKeyOnlyMessage
    }

    public static func configurationError(
        baseURL: String,
        providerPreset: OpenAICompatibleProviderPreset,
        apiKey: String? = nil,
        explicitSelection: Bool = true
    ) -> String? {
        if let rootMismatch = self.manualConfigurationError(
            baseURL: baseURL,
            providerPreset: providerPreset,
            explicitSelection: explicitSelection
        ) {
            return rootMismatch
        }
        return self.googleGeminiCredentialConfigurationError(
            providerPreset: providerPreset,
            apiKey: apiKey
        )
    }

    public static func storedConfigurationError(
        baseURL: String,
        providerPreset: OpenAICompatibleProviderPreset,
        apiKey: String? = nil
    ) -> String? {
        if self.normalizedManualProviderPreset(
            baseURL: baseURL,
            providerPreset: providerPreset
        ) != providerPreset {
            return self.geminiCompatibilityRootRequiresGeminiPresetMessage
        }
        return self.googleGeminiCredentialConfigurationError(
            providerPreset: providerPreset,
            apiKey: apiKey
        )
    }

    public static func humanizedUpstreamErrorMessage(
        _ message: String,
        providerPreset: OpenAICompatibleProviderPreset,
        apiKey: String? = nil
    ) -> String {
        let lower = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if providerPreset == .googleGeminiCompatible,
           lower.contains("multiple authentication credentials received")
        {
            return self.googleGeminiAPIKeyOnlyMessage
        }
        if let configurationError = self.googleGeminiCredentialConfigurationError(
            providerPreset: providerPreset,
            apiKey: apiKey
        ) {
            return configurationError
        }
        return message
    }

    public static func normalizeBaseURL(
        _ value: String,
        providerPreset: OpenAICompatibleProviderPreset = .genericOpenAICompatible
    ) throws -> String {
        switch providerPreset {
        case .genericOpenAICompatible:
            return try self.normalizeOpenAICompatibleBaseURL(value)
        case .aliyunQwenCodingPlan:
            return try self.normalizeVersionedOpenAICompatibleBaseURL(value)
        case .googleGeminiCompatible:
            return try self.normalizeGeminiCompatibleBaseURL(value)
        case .anthropicAPICompatible:
            return try AnthropicAPIKeyUpstream.normalizeBaseURL(value)
        }
    }

    public static func modelsURL(
        from baseURL: String,
        providerPreset: OpenAICompatibleProviderPreset = .genericOpenAICompatible,
        baseURLMode: ManualAPIKeyBaseURLMode? = nil
    ) throws -> String {
        switch providerPreset {
        case .anthropicAPICompatible:
            return try AnthropicAPIKeyUpstream.modelsURL(from: baseURL)
        case .genericOpenAICompatible, .aliyunQwenCodingPlan, .googleGeminiCompatible:
            return try self.baseAPIURL(
                from: baseURL,
                providerPreset: providerPreset,
                baseURLMode: baseURLMode
            )
                .appendingPathComponent("models")
                .absoluteString
        }
    }

    public static func responsesURL(
        from baseURL: String,
        providerPreset: OpenAICompatibleProviderPreset = .genericOpenAICompatible,
        baseURLMode: ManualAPIKeyBaseURLMode? = nil
    ) throws -> String {
        try self.baseAPIURL(
            from: baseURL,
            providerPreset: providerPreset,
            baseURLMode: baseURLMode
        )
            .appendingPathComponent("responses")
            .absoluteString
    }

    public static func chatCompletionsURL(
        from baseURL: String,
        providerPreset: OpenAICompatibleProviderPreset = .genericOpenAICompatible,
        baseURLMode: ManualAPIKeyBaseURLMode? = nil
    ) throws -> String {
        try self.baseAPIURL(
            from: baseURL,
            providerPreset: providerPreset,
            baseURLMode: baseURLMode
        )
            .appendingPathComponent("chat/completions")
            .absoluteString
    }

    public static func apiBaseURL(
        from baseURL: String,
        providerPreset: OpenAICompatibleProviderPreset = .genericOpenAICompatible,
        baseURLMode: ManualAPIKeyBaseURLMode? = nil
    ) throws -> String {
        try self.baseAPIURL(
            from: baseURL,
            providerPreset: providerPreset,
            baseURLMode: baseURLMode
        ).absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    public static func defaultAccountLabel(
        baseURL: String,
        apiKey: String,
        providerPreset: OpenAICompatibleProviderPreset = .genericOpenAICompatible
    ) -> String {
        switch providerPreset {
        case .anthropicAPICompatible:
            return AnthropicAPIKeyUpstream.defaultAccountLabel(baseURL: baseURL, apiKey: apiKey)
        case .genericOpenAICompatible, .aliyunQwenCodingPlan, .googleGeminiCompatible:
            let host = (try? self.rootURL(from: baseURL, providerPreset: providerPreset).host).flatMap { host in
                host?.trimmingCharacters(in: .whitespacesAndNewlines)
            } ?? "API"
            let suffix = String(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).suffix(6))
            return suffix.isEmpty ? host : "\(host) \(suffix)"
        }
    }

    public static func probeModels(
        config: AppConfig,
        baseURL: String,
        apiKey: String,
        providerPreset: OpenAICompatibleProviderPreset = .genericOpenAICompatible,
        baseURLMode: ManualAPIKeyBaseURLMode? = nil
    ) async throws -> [String] {
        let response = try await self.requestModelsResponse(
            config: config,
            baseURL: baseURL,
            apiKey: apiKey,
            providerPreset: providerPreset,
            baseURLMode: baseURLMode
        )
        guard (200..<300).contains(response.statusCode) else {
            let rawMessage = self.httpErrorMessage(from: response.body, statusCode: response.statusCode)
            throw ProxyError.message(
                self.humanizedUpstreamErrorMessage(
                    rawMessage,
                    providerPreset: providerPreset,
                    apiKey: apiKey
                )
            )
        }
        return try self.decodeModelsResponse(
            response,
            providerPreset: providerPreset
        )
    }

    public static func validateConnection(
        config: AppConfig,
        baseURL: String,
        apiKey: String,
        providerPreset: OpenAICompatibleProviderPreset,
        baseURLMode: ManualAPIKeyBaseURLMode? = nil,
        upstreamAdapter: ManualAPIKeyUpstreamAdapter? = nil,
        validationProbeModels: [String] = []
    ) async throws {
        switch providerPreset {
        case .genericOpenAICompatible, .googleGeminiCompatible:
            let probeModels = self.normalizedValidationProbeModels(
                providerPreset: providerPreset,
                requested: validationProbeModels
            )
            switch try await self.validateModelsEndpoint(
                config: config,
                baseURL: baseURL,
                apiKey: apiKey,
                providerPreset: providerPreset,
                baseURLMode: baseURLMode
            ) {
            case .validated:
                if providerPreset == .genericOpenAICompatible {
                    try await self.validateGenericRuntimeProbe(
                        config: config,
                        baseURL: baseURL,
                        apiKey: apiKey,
                        baseURLMode: baseURLMode,
                        upstreamAdapter: upstreamAdapter,
                        candidateModels: probeModels
                    )
                }
                return
            case .requiresRuntimeProbe:
                if providerPreset == .genericOpenAICompatible {
                    try await self.validateGenericRuntimeProbe(
                        config: config,
                        baseURL: baseURL,
                        apiKey: apiKey,
                        baseURLMode: baseURLMode,
                        upstreamAdapter: upstreamAdapter,
                        candidateModels: probeModels
                    )
                } else {
                    try await self.validateConnectionViaChatCompletions(
                        config: config,
                        baseURL: baseURL,
                        apiKey: apiKey,
                        providerPreset: providerPreset,
                        baseURLMode: baseURLMode,
                        candidateModels: probeModels
                    )
                }
            }
        case .aliyunQwenCodingPlan:
            try await self.probeAliyunCodingPlan(
                config: config,
                baseURL: baseURL,
                apiKey: apiKey,
                candidateModels: self.normalizedValidationProbeModels(
                    providerPreset: providerPreset,
                    requested: validationProbeModels
                )
            )
        case .anthropicAPICompatible:
            try await AnthropicAPIKeyUpstream.validateConnection(
                config: config,
                baseURL: baseURL,
                apiKey: apiKey,
                validationProbeModels: validationProbeModels
            )
        }
    }

    private static func validateGenericRuntimeProbe(
        config: AppConfig,
        baseURL: String,
        apiKey: String,
        baseURLMode: ManualAPIKeyBaseURLMode?,
        upstreamAdapter: ManualAPIKeyUpstreamAdapter?,
        candidateModels: [String]
    ) async throws {
        switch upstreamAdapter ?? .responses {
        case .responses:
            try await self.validateConnectionViaResponses(
                config: config,
                baseURL: baseURL,
                apiKey: apiKey,
                baseURLMode: baseURLMode,
                candidateModels: candidateModels
            )
        case .chatCompletions:
            try await self.validateConnectionViaChatCompletions(
                config: config,
                baseURL: baseURL,
                apiKey: apiKey,
                providerPreset: .genericOpenAICompatible,
                baseURLMode: baseURLMode,
                candidateModels: candidateModels
            )
        }
    }

    private enum ModelsEndpointValidation {
        case validated
        case requiresRuntimeProbe
    }

    private static func requestModelsResponse(
        config: AppConfig,
        baseURL: String,
        apiKey: String,
        providerPreset: OpenAICompatibleProviderPreset,
        baseURLMode: ManualAPIKeyBaseURLMode?
    ) async throws -> SimpleHTTPResponse {
        try await HTTPClientFactory.request(
            config: config,
            url: try self.modelsURL(
                from: baseURL,
                providerPreset: providerPreset,
                baseURLMode: baseURLMode
            ),
            method: .GET,
            headers: self.requestHeaders(
                apiKey: apiKey,
                accept: "application/json",
                providerPreset: providerPreset
            )
        )
    }

    private static func decodeModelsResponse(
        _ response: SimpleHTTPResponse,
        providerPreset: OpenAICompatibleProviderPreset
    ) throws -> [String] {
        let payload: ModelListPayload
        do {
            payload = try Helpers.readJSON(ModelListPayload.self, from: response.body)
        } catch {
            if let detail = DecodingDiagnostics.describe(
                error,
                endpoint: providerPreset == .googleGeminiCompatible ? "/models" : "/v1/models",
                method: "GET",
                targetType: ModelListPayload.self,
                responseBody: response.body
            ) {
                throw ProxyError.message(detail)
            }
            throw error
        }
        let models = Array(Set(payload.data.map(\.id))).sorted()
        return models.isEmpty ? ProxyTranscoder.supportedModels : models
    }

    private static func validateModelsEndpoint(
        config: AppConfig,
        baseURL: String,
        apiKey: String,
        providerPreset: OpenAICompatibleProviderPreset,
        baseURLMode: ManualAPIKeyBaseURLMode?
    ) async throws -> ModelsEndpointValidation {
        let response = try await self.requestModelsResponse(
            config: config,
            baseURL: baseURL,
            apiKey: apiKey,
            providerPreset: providerPreset,
            baseURLMode: baseURLMode
        )
        if (200..<300).contains(response.statusCode) {
            _ = try self.decodeModelsResponse(response, providerPreset: providerPreset)
            return .validated
        }
        if response.statusCode == 404 || response.statusCode == 405 {
            return .requiresRuntimeProbe
        }
        let rawMessage = self.httpErrorMessage(from: response.body, statusCode: response.statusCode)
        throw ProxyError.message(
            self.humanizedUpstreamErrorMessage(
                rawMessage,
                providerPreset: providerPreset,
                apiKey: apiKey
            )
        )
    }

    public static func requestHeaders(
        apiKey: String,
        accept: String,
        providerPreset: OpenAICompatibleProviderPreset
    ) -> [String: String] {
        switch providerPreset {
        case .anthropicAPICompatible:
            return AnthropicAPIKeyUpstream.requestHeaders(apiKey: apiKey, accept: accept)
        case .genericOpenAICompatible, .aliyunQwenCodingPlan, .googleGeminiCompatible:
            return [
                "Authorization": "Bearer \(apiKey)",
                "Content-Type": "application/json",
                "Accept": accept,
                "User-Agent": providerPreset.providerUserAgent,
            ]
        }
    }

    public static func syntheticAccountID(apiKey: String, baseURL: String) -> String {
        let identity = "\(tryOrDefault(baseURL))|\(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))"
        return "api-key-" + String(Helpers.sha256(identity).prefix(16))
    }

    private static func normalizeOpenAICompatibleBaseURL(_ value: String) throws -> String {
        try self.normalizeOpenAICompatibleBaseURL(value, preserveVersionSuffix: true)
    }

    private static func normalizeVersionedOpenAICompatibleBaseURL(_ value: String) throws -> String {
        try self.normalizeOpenAICompatibleBaseURL(value, preserveVersionSuffix: false)
    }

    private static func normalizeOpenAICompatibleBaseURL(
        _ value: String,
        preserveVersionSuffix: Bool
    ) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw ProxyError.message("根地址不能为空")
        }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host?.isEmpty == false
        else {
            throw ProxyError.message("根地址格式无效")
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ProxyError.message("根地址格式无效")
        }

        components.query = nil
        components.fragment = nil

        var path = components.path
        while path.hasSuffix("/") && path.count > 1 {
            path.removeLast()
        }
        if preserveVersionSuffix == false {
            if path == "/v1" {
                path = ""
            } else if path.hasSuffix("/v1") {
                path = String(path.dropLast(3))
            }
            while path.hasSuffix("/") && path.count > 1 {
                path.removeLast()
            }
        }
        components.path = path == "/" ? "" : path

        guard let normalized = components.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
              normalized.isEmpty == false
        else {
            throw ProxyError.message("根地址格式无效")
        }
        return normalized
    }

    private static func normalizeGeminiCompatibleBaseURL(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw ProxyError.message("根地址不能为空")
        }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host?.isEmpty == false
        else {
            throw ProxyError.message("根地址格式无效")
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ProxyError.message("根地址格式无效")
        }
        components.query = nil
        components.fragment = nil

        var path = components.path
        while path.hasSuffix("/") && path.count > 1 {
            path.removeLast()
        }
        components.path = path == "/" ? "" : path

        guard let normalized = components.url?.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
              normalized.isEmpty == false
        else {
            throw ProxyError.message("根地址格式无效")
        }
        return normalized
    }

    private static func rootURL(
        from baseURL: String,
        providerPreset: OpenAICompatibleProviderPreset = .genericOpenAICompatible
    ) throws -> URL {
        let normalized = try self.normalizeBaseURL(baseURL, providerPreset: providerPreset)
        guard let url = URL(string: normalized) else {
            throw ProxyError.message("根地址格式无效")
        }
        return url
    }

    private static func baseAPIURL(
        from baseURL: String,
        providerPreset: OpenAICompatibleProviderPreset,
        baseURLMode: ManualAPIKeyBaseURLMode?
    ) throws -> URL {
        let root = try self.rootURL(from: baseURL, providerPreset: providerPreset)
        switch providerPreset {
        case .genericOpenAICompatible:
            switch baseURLMode ?? .exactAPIPrefix {
            case .legacyAppendV1:
                return root.appendingPathComponent("v1")
            case .exactAPIPrefix:
                return root
            }
        case .aliyunQwenCodingPlan:
            return root.appendingPathComponent("v1")
        case .googleGeminiCompatible:
            return root
        case .anthropicAPICompatible:
            return root.appendingPathComponent("v1")
        }
    }

    private static func probeAliyunCodingPlan(
        config: AppConfig,
        baseURL: String,
        apiKey: String,
        candidateModels: [String]
    ) async throws {
        let url = try self.chatCompletionsURL(from: baseURL, providerPreset: .aliyunQwenCodingPlan)
        var lastModelError: String?

        for model in candidateModels {
            let payload: [String: Any] = [
                "model": model,
                "messages": [
                    [
                        "role": "user",
                        "content": Self.validationProbePrompt,
                    ],
                ],
                "stream": false,
                "max_tokens": 1,
                "temperature": 0,
            ]
            let body = try JSONSerialization.data(withJSONObject: payload)
            let response = try await HTTPClientFactory.request(
                config: config,
                url: url,
                method: .POST,
                headers: self.requestHeaders(
                    apiKey: apiKey,
                    accept: "application/json",
                    providerPreset: .aliyunQwenCodingPlan
                ),
                body: body
            )
            guard (200..<300).contains(response.statusCode) == false else {
                return
            }

            let message = self.httpErrorMessage(from: response.body, statusCode: response.statusCode)
            if self.isRetryableValidationModelError(message) {
                lastModelError = message
                continue
            }
            throw ProxyError.message(self.aliyunCodingPlanCompatibilityMessage(message))
        }

        if let lastModelError {
            throw ProxyError.message(self.aliyunCodingPlanCompatibilityMessage(lastModelError))
        }
        throw ProxyError.message("Aliyun Coding Plan validation failed.")
    }

    private static func validateConnectionViaResponses(
        config: AppConfig,
        baseURL: String,
        apiKey: String,
        baseURLMode: ManualAPIKeyBaseURLMode?,
        candidateModels: [String]
    ) async throws {
        let url = try self.responsesURL(
            from: baseURL,
            providerPreset: .genericOpenAICompatible,
            baseURLMode: baseURLMode
        )
        var lastModelError: String?

        for model in candidateModels {
            let payload: [String: Any] = [
                "model": model,
                "input": Self.validationProbePrompt,
                "stream": false,
                "max_output_tokens": 1,
            ]
            let body = try JSONSerialization.data(withJSONObject: payload)
            let response = try await HTTPClientFactory.request(
                config: config,
                url: url,
                method: .POST,
                headers: self.requestHeaders(
                    apiKey: apiKey,
                    accept: "application/json",
                    providerPreset: .genericOpenAICompatible
                ),
                body: body
            )
            if (200..<300).contains(response.statusCode) {
                return
            }

            let message = self.httpErrorMessage(from: response.body, statusCode: response.statusCode)
            if self.isRetryableValidationModelError(message) {
                lastModelError = message
                continue
            }
            throw ProxyError.message(message)
        }

        if let lastModelError {
            throw ProxyError.message(lastModelError)
        }
        throw ProxyError.message("OpenAI-compatible validation failed.")
    }

    private static func validateConnectionViaChatCompletions(
        config: AppConfig,
        baseURL: String,
        apiKey: String,
        providerPreset: OpenAICompatibleProviderPreset,
        baseURLMode: ManualAPIKeyBaseURLMode?,
        candidateModels: [String]
    ) async throws {
        let url = try self.chatCompletionsURL(
            from: baseURL,
            providerPreset: providerPreset,
            baseURLMode: baseURLMode
        )
        var lastModelError: String?

        for model in candidateModels {
            let payload: [String: Any] = [
                "model": model,
                "messages": [
                    [
                        "role": "user",
                        "content": Self.validationProbePrompt,
                    ],
                ],
                "stream": false,
                "max_tokens": 1,
                "temperature": 0,
            ]
            let body = try JSONSerialization.data(withJSONObject: payload)
            let response = try await HTTPClientFactory.request(
                config: config,
                url: url,
                method: .POST,
                headers: self.requestHeaders(
                    apiKey: apiKey,
                    accept: "application/json",
                    providerPreset: providerPreset
                ),
                body: body
            )
            if (200..<300).contains(response.statusCode) {
                return
            }

            let message = self.httpErrorMessage(from: response.body, statusCode: response.statusCode)
            if self.isRetryableValidationModelError(message) {
                lastModelError = message
                continue
            }
            throw ProxyError.message(
                self.humanizedUpstreamErrorMessage(
                    message,
                    providerPreset: providerPreset,
                    apiKey: apiKey
                )
            )
        }

        if let lastModelError {
            throw ProxyError.message(
                self.humanizedUpstreamErrorMessage(
                    lastModelError,
                    providerPreset: providerPreset,
                    apiKey: apiKey
                )
            )
        }
        throw ProxyError.message("OpenAI-compatible chat validation failed.")
    }

    private static func httpErrorMessage(from data: Data, statusCode: Int) -> String {
        if
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let error = object["error"] as? [String: Any],
            let message = error["message"] as? String,
            message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        {
            return message
        }

        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty == false {
            return text
        }
        return "HTTP \(statusCode)"
    }

    private static func tryOrDefault(_ baseURL: String) -> String {
        (try? self.normalizeBaseURL(baseURL)) ?? self.defaultBaseURL
    }

    private static func normalizedValidationProbeModels(
        providerPreset: OpenAICompatibleProviderPreset,
        requested: [String]
    ) -> [String] {
        var models: [String] = []
        func append(_ candidate: String?) {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard trimmed.isEmpty == false else { return }
            guard models.contains(trimmed) == false else { return }
            models.append(trimmed)
        }

        for candidate in requested {
            append(candidate)
        }

        if models.isEmpty {
            switch providerPreset {
            case .genericOpenAICompatible:
                append(ProxyTranscoder.defaultModel)
                for model in ProxyTranscoder.supportedModels {
                    append(model)
                }
            case .aliyunQwenCodingPlan, .googleGeminiCompatible:
                for model in providerPreset.defaultValidationModelCandidates {
                    append(model)
                }
            case .anthropicAPICompatible:
                break
            }
        }

        return models
    }

    private static func isRetryableValidationModelError(_ message: String) -> Bool {
        let lower = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let patterns = [
            "model not found",
            "invalid model",
            "unknown model",
            "unsupported model",
            "model is not supported",
            "is not supported",
            "specified model",
            "does not exist",
        ]
        return patterns.contains(where: { lower.contains($0) })
    }

    private static func aliyunCodingPlanCompatibilityMessage(_ upstreamMessage: String) -> String {
        let trimmed = upstreamMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return "Aliyun Coding Plan validation failed."
        }
        let lower = trimmed.lowercased()
        if lower.contains("coding plan is currently only available for coding agents") {
            return "\(trimmed) (AI Coding Proxy already retried this account in Aliyun Coding Plan compatibility mode via /v1/chat/completions. If this still happens, the current key or base URL is likely not hitting an accepted Coding Plan entrypoint.)"
        }
        return trimmed
    }
}

private struct ModelListPayload: Decodable, Sendable {
    struct Item: Decodable, Sendable {
        var id: String
    }

    var data: [Item]
}
