import Foundation

public enum AnthropicAPIKeyUpstream {
    public static let defaultBaseURL = "https://api.anthropic.com"
    private static let unsupportedThinkingHistoryHosts = [
        "dashscope.aliyuncs.com",
        "dashscope-intl.aliyuncs.com",
    ]
    private static let validationProbePrompt = "你好"

    public static func normalizeBaseURL(_ value: String) throws -> String {
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
        if path == "/v1" {
            path = ""
        } else if path.hasSuffix("/v1") {
            path = String(path.dropLast(3))
        }
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

    public static func modelsURL(from baseURL: String) throws -> String {
        try self.v1URL(from: baseURL).appendingPathComponent("models").absoluteString
    }

    public static func messagesURL(from baseURL: String) throws -> String {
        try self.v1URL(from: baseURL).appendingPathComponent("messages").absoluteString
    }

    public static func countTokensURL(from baseURL: String) throws -> String {
        try self.v1URL(from: baseURL).appendingPathComponent("messages/count_tokens").absoluteString
    }

    public static func requestHeaders(
        apiKey: String,
        accept: String,
        anthropicVersion: String = AnthropicTranscoder.defaultAnthropicVersion,
        anthropicBeta: String? = nil
    ) -> [String: String] {
        var headers = [
            "x-api-key": apiKey,
            "Content-Type": "application/json",
            "Accept": accept,
            "anthropic-version": anthropicVersion,
            "User-Agent": RuntimeInfo.daemonServerToken,
        ]
        if let anthropicBeta, anthropicBeta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            headers["anthropic-beta"] = anthropicBeta
        }
        return headers
    }

    public static func validateConnection(
        config: AppConfig,
        baseURL: String,
        apiKey: String,
        validationProbeModels: [String] = []
    ) async throws {
        let response = try await HTTPClientFactory.request(
            config: config,
            url: try self.modelsURL(from: baseURL),
            method: .GET,
            headers: self.requestHeaders(
                apiKey: apiKey,
                accept: "application/json"
            )
        )
        if (200..<300).contains(response.statusCode) {
            return
        }

        if response.statusCode == 404 || response.statusCode == 405 {
            try await self.validateConnectionViaMessages(
                config: config,
                baseURL: baseURL,
                apiKey: apiKey,
                candidateModels: validationProbeModels
            )
            return
        }

        throw ProxyError.message(self.httpErrorMessage(from: response.body, statusCode: response.statusCode))
    }

    public static func defaultAccountLabel(baseURL: String, apiKey: String) -> String {
        let host = (try? self.rootURL(from: baseURL).host).flatMap { host in
            host?.trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? "Anthropic"
        let suffix = String(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).suffix(6))
        return suffix.isEmpty ? host : "\(host) \(suffix)"
    }

    public static func syntheticAccountID(apiKey: String, baseURL: String) -> String {
        let identity = "\(tryOrDefault(baseURL))|\(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))"
        return "anthropic-api-" + String(Helpers.sha256(identity).prefix(16))
    }

    public static func supportsThinkingContentBlocks(baseURL: String) -> Bool {
        !self.isDashScopeAnthropicCompatibilityRoot(baseURL)
    }

    public static func isDashScopeAnthropicCompatibilityRoot(_ value: String) -> Bool {
        guard let host = (try? self.rootURL(from: value).host)?.lowercased() else {
            return false
        }
        return self.unsupportedThinkingHistoryHosts.contains(where: {
            host == $0 || host.hasPrefix("\($0).")
        })
    }

    public static func sanitizedRequestForUnsupportedThinkingContentBlocks(
        _ rawPayload: [String: Any],
        baseURL: String
    ) -> [String: Any] {
        guard self.supportsThinkingContentBlocks(baseURL: baseURL) == false else {
            return rawPayload
        }

        var payload = rawPayload
        guard let rawMessages = payload["messages"] as? [Any] else {
            return payload
        }

        var sanitizedMessages: [Any] = []
        for rawMessage in rawMessages {
            guard var message = rawMessage as? [String: Any] else {
                sanitizedMessages.append(rawMessage)
                continue
            }

            let role = ((message["role"] as? String) ?? "").lowercased()
            guard role == "assistant",
                  let blocks = message["content"] as? [Any]
            else {
                sanitizedMessages.append(message)
                continue
            }

            let sanitizedBlocks = blocks.filter { rawBlock in
                guard let block = rawBlock as? [String: Any] else {
                    return true
                }
                let type = (block["type"] as? String) ?? ""
                return type != "thinking" && type != "redacted_thinking"
            }

            guard sanitizedBlocks.isEmpty == false else {
                continue
            }

            message["content"] = sanitizedBlocks
            sanitizedMessages.append(message)
        }

        payload["messages"] = sanitizedMessages
        return payload
    }

    private static func rootURL(from baseURL: String) throws -> URL {
        let normalized = try self.normalizeBaseURL(baseURL)
        guard let url = URL(string: normalized) else {
            throw ProxyError.message("根地址格式无效")
        }
        return url
    }

    private static func v1URL(from baseURL: String) throws -> URL {
        try self.rootURL(from: baseURL).appendingPathComponent("v1")
    }

    private static func tryOrDefault(_ baseURL: String) -> String {
        (try? self.normalizeBaseURL(baseURL)) ?? self.defaultBaseURL
    }

    private static func httpErrorMessage(from data: Data, statusCode: Int) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any],
               let message = error["message"] as? String,
               message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            {
                return message
            }
            if let message = object["error"] as? String,
               message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            {
                return message
            }
        }

        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty == false {
            return text
        }
        return "HTTP \(statusCode)"
    }

    private static func validateConnectionViaMessages(
        config: AppConfig,
        baseURL: String,
        apiKey: String,
        candidateModels: [String]
    ) async throws {
        var lastModelError: String?

        for model in candidateModels {
            let payload: [String: Any] = [
                "model": model,
                "messages": [
                    [
                        "role": "user",
                        "content": [
                            [
                                "type": "text",
                                "text": Self.validationProbePrompt,
                            ]
                        ]
                    ]
                ],
                "max_tokens": 1,
            ]
            let body = try JSONSerialization.data(withJSONObject: payload)
            let response = try await HTTPClientFactory.request(
                config: config,
                url: try self.messagesURL(from: baseURL),
                method: .POST,
                headers: self.requestHeaders(
                    apiKey: apiKey,
                    accept: "application/json"
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
        throw ProxyError.message("Anthropic validation failed.")
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
}
