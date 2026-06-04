import Foundation

struct PromptCacheContext: Sendable, Equatable {
    var sourcePromptCacheKey: String?
    var sessionIdentifier: String?
    var metadataUserID: String?
    var claudeCodeSessionID: String?
    var seedMaterial: String?
    var geminiCLIStickySessionKey: String?
    var isGeminiCLISession: Bool
    var upstreamPromptCacheKey: String?
    var upstreamSessionID: String?
    var allowManualAPIKeyStickyBinding: Bool

    var stickySessionKey: String? {
        self.geminiCLIStickySessionKey ?? self.upstreamPromptCacheKey
    }
}

actor StickySessionBindingStore {
    struct Entry: Sendable, Equatable {
        var accountKey: String
        var expiresAt: Int64
    }

    private var entries: [String: Entry] = [:]

    func accountKey(for sessionKey: String, now: Int64 = Helpers.now()) -> String? {
        self.pruneExpired(now: now)
        return self.entries[sessionKey]?.accountKey
    }

    func bind(sessionKey: String, accountKey: String, ttlSeconds: Int64, now: Int64 = Helpers.now()) {
        guard sessionKey.isEmpty == false, accountKey.isEmpty == false, ttlSeconds > 0 else {
            return
        }
        self.entries[sessionKey] = Entry(accountKey: accountKey, expiresAt: now + ttlSeconds)
    }

    func clear(accountKey: String) {
        self.entries = self.entries.filter { $0.value.accountKey != accountKey }
    }

    private func pruneExpired(now: Int64) {
        self.entries = self.entries.filter { $0.value.expiresAt > now }
    }
}

enum PromptCacheSupport {
    static let stickySessionTTLSeconds: Int64 = 900
    static let chatCompletionsAPIKeyStickySessionTTLSeconds: Int64 = 7_200
    private static let geminiCLITmpDirectoryPattern = try! NSRegularExpression(
        pattern: #"/\.gemini/tmp/([A-Fa-f0-9]{64})"#
    )

    static func context(
        headers: [String: String],
        requestPayload: [String: Any],
        normalizedRequest: [String: Any],
        requestedModel: String,
        proxyKey: AuthenticatedProxyKeyContext,
        sourceAnthropicPayload: [String: Any]? = nil,
        preferGeminiCLIStickySession: Bool = false,
        allowManualAPIKeyStickyBinding: Bool = false
    ) -> PromptCacheContext {
        let explicitPromptCacheKey = self.trimmedString(requestPayload["prompt_cache_key"])
        let metadataUserID = self.extractMetadataUserID(from: requestPayload)
        let sessionIdentifier = self.sessionIdentifier(headers: headers, requestPayload: requestPayload)

        let explicitSeed = explicitPromptCacheKey ?? sessionIdentifier
        let generatedSeed = explicitSeed ?? self.generatedSeed(
            normalizedRequest: normalizedRequest,
            requestedModel: requestedModel,
            sourceAnthropicPayload: sourceAnthropicPayload
        )

        let upstreamPromptCacheKey = generatedSeed.map {
            self.isolatedPromptCacheKey(rawSeed: $0, proxyKey: proxyKey)
        }
        let upstreamSessionID = upstreamPromptCacheKey.map(self.deterministicSessionID)
        let hasGeminiCLIPrivilegedUserID = self.trimmedHeader("x-gemini-api-privileged-user-id", in: headers) != nil
        let geminiCLIStickySessionKey = preferGeminiCLIStickySession
            ? self.geminiCLIStickySessionKey(
                headers: headers,
                requestPayload: requestPayload,
                proxyKey: proxyKey
            )
            : nil

        return PromptCacheContext(
            sourcePromptCacheKey: explicitPromptCacheKey,
            sessionIdentifier: sessionIdentifier,
            metadataUserID: metadataUserID,
            claudeCodeSessionID: self.trimmedHeader("x-claude-code-session-id", in: headers),
            seedMaterial: generatedSeed,
            geminiCLIStickySessionKey: geminiCLIStickySessionKey,
            isGeminiCLISession: geminiCLIStickySessionKey != nil || hasGeminiCLIPrivilegedUserID,
            upstreamPromptCacheKey: upstreamPromptCacheKey,
            upstreamSessionID: upstreamSessionID,
            allowManualAPIKeyStickyBinding: allowManualAPIKeyStickyBinding
        )
    }

    static func sessionIdentifier(headers: [String: String], requestPayload: [String: Any]) -> String? {
        let metadataUserID = self.extractMetadataUserID(from: requestPayload)
        return self.trimmedHeader("session_id", in: headers)
            ?? self.trimmedHeader("conversation_id", in: headers)
            ?? self.parsedMetadataSessionID(metadataUserID)
            ?? self.trimmedHeader("x-claude-code-session-id", in: headers)
    }

    static func applyCodexPromptCache(
        to request: [String: Any],
        context: PromptCacheContext,
        auth: ExtractedAuth
    ) -> [String: Any] {
        guard auth.authMode == .chatGPT,
              let promptCacheKey = context.upstreamPromptCacheKey
        else {
            return request
        }

        var updated = request
        updated["prompt_cache_key"] = promptCacheKey
        return updated
    }

    static func applyAnthropicSessionHeader(
        to headers: [String: String],
        context: PromptCacheContext
    ) -> [String: String] {
        guard let sessionID = context.upstreamSessionID else {
            return headers
        }

        var updated = headers
        updated["X-Claude-Code-Session-Id"] = sessionID
        return updated
    }

    static func applyRawAnthropicRequest(
        _ rawPayload: [String: Any],
        upstreamModel: String,
        stream: Bool
    ) -> [String: Any] {
        var payload = rawPayload
        payload["model"] = upstreamModel
        payload["stream"] = stream
        return payload
    }

    private static func generatedSeed(
        normalizedRequest: [String: Any],
        requestedModel: String,
        sourceAnthropicPayload: [String: Any]?
    ) -> String? {
        let normalizedModel = requestedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedModel.isEmpty == false else {
            return nil
        }

        let cacheableText = sourceAnthropicPayload.flatMap(self.extractCacheableAnthropicText)
        let systemText = cacheableText ?? self.extractInstructions(from: normalizedRequest)
        let firstUserText = self.extractFirstUserText(from: normalizedRequest)
        let tools = self.serializedJSON(normalizedRequest["tools"])
        let toolChoice = self.serializedJSON(normalizedRequest["tool_choice"])
        let reasoning = self.serializedJSON(normalizedRequest["reasoning"])

        var parts = ["model=\(normalizedModel)"]
        if let systemText, systemText.isEmpty == false {
            parts.append("system=\(systemText)")
        }
        if cacheableText == nil, let firstUserText, firstUserText.isEmpty == false {
            parts.append("first_user=\(firstUserText)")
        }
        if let tools, tools.isEmpty == false {
            parts.append("tools=\(tools)")
        }
        if let toolChoice, toolChoice.isEmpty == false {
            parts.append("tool_choice=\(toolChoice)")
        }
        if let reasoning, reasoning.isEmpty == false {
            parts.append("reasoning=\(reasoning)")
        }

        let seed = parts.joined(separator: "|").trimmingCharacters(in: .whitespacesAndNewlines)
        return seed.isEmpty ? nil : seed
    }

    private static func extractMetadataUserID(from payload: [String: Any]) -> String? {
        guard let metadata = payload["metadata"] as? [String: Any] else {
            return nil
        }
        return self.trimmedString(metadata["user_id"])
    }

    private static func parsedMetadataSessionID(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false
        else {
            return nil
        }

        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let sessionID = self.trimmedString(object["session_id"])
        {
            return sessionID
        }

        return trimmed
    }

    private static func extractCacheableAnthropicText(from payload: [String: Any]) -> String? {
        if let system = payload["system"] as? [Any] {
            let systemText = system.enumerated().compactMap { _, rawBlock -> String? in
                guard let block = rawBlock as? [String: Any],
                      self.isEphemeralCacheControl(block["cache_control"]),
                      let text = self.trimmedString(block["text"])
                else {
                    return nil
                }
                return text
            }.joined(separator: "\n\n")
            if systemText.isEmpty == false {
                return systemText
            }
        }

        guard let messages = payload["messages"] as? [Any] else {
            return nil
        }
        for rawMessage in messages {
            guard let message = rawMessage as? [String: Any],
                  let content = message["content"] as? [Any]
            else {
                continue
            }
            let hasCacheableBlock = content.contains { rawBlock in
                guard let block = rawBlock as? [String: Any] else { return false }
                return self.isEphemeralCacheControl(block["cache_control"])
            }
            guard hasCacheableBlock else {
                continue
            }
            let text = content.compactMap { rawBlock -> String? in
                guard let block = rawBlock as? [String: Any],
                      (block["type"] as? String) == "text"
                else {
                    return nil
                }
                return self.trimmedString(block["text"])
            }.joined(separator: "\n\n")
            if text.isEmpty == false {
                return text
            }
        }
        return nil
    }

    private static func extractInstructions(from request: [String: Any]) -> String? {
        self.trimmedString(request["instructions"])
    }

    private static func extractFirstUserText(from request: [String: Any]) -> String? {
        guard let input = request["input"] as? [[String: Any]] else {
            return nil
        }
        for item in input {
            guard (item["type"] as? String) == "message",
                  ((item["role"] as? String) ?? "").lowercased() == "user"
            else {
                continue
            }
            if let content = item["content"] as? [[String: Any]] {
                let text = content.compactMap { block -> String? in
                    guard let type = block["type"] as? String else { return nil }
                    guard type == "input_text" || type == "text" else { return nil }
                    return self.trimmedString(block["text"])
                }.joined(separator: "\n\n")
                if text.isEmpty == false {
                    return text
                }
            }
            if let text = self.trimmedString(item["content"]) {
                return text
            }
        }
        return nil
    }

    private static func isolatedPromptCacheKey(
        rawSeed: String,
        proxyKey: AuthenticatedProxyKeyContext
    ) -> String {
        let trimmedSeed = rawSeed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedSeed.isEmpty == false else {
            return ""
        }
        let hash = Helpers.sha256("\(proxyKey.proxyKeyID)|\(trimmedSeed)")
        return "cpx_\(String(hash.prefix(40)))"
    }

    private static func deterministicSessionID(from promptCacheKey: String) -> String {
        let hash = Helpers.sha256(promptCacheKey)
        let chars = Array(hash)
        guard chars.count >= 32 else {
            return promptCacheKey
        }
        return [
            String(chars[0..<8]),
            String(chars[8..<12]),
            String(chars[12..<16]),
            String(chars[16..<20]),
            String(chars[20..<32]),
        ].joined(separator: "-")
    }

    private static func geminiCLIStickySessionKey(
        headers: [String: String],
        requestPayload: [String: Any],
        proxyKey: AuthenticatedProxyKeyContext
    ) -> String? {
        guard let tmpDirectoryHash = self.geminiCLITmpDirectoryHash(from: requestPayload) else {
            return nil
        }

        let privilegedUserID = self.trimmedHeader("x-gemini-api-privileged-user-id", in: headers)
        let seed = privilegedUserID.map { "\($0):\(tmpDirectoryHash)" } ?? tmpDirectoryHash
        return self.isolatedPromptCacheKey(rawSeed: "gemini-cli=\(seed)", proxyKey: proxyKey)
    }

    private static func geminiCLITmpDirectoryHash(from payload: [String: Any]) -> String? {
        guard let serialized = self.serializedJSON(payload) else {
            return nil
        }

        let normalizedSerialized = serialized.replacingOccurrences(of: #"\/"#, with: "/")
        let range = NSRange(normalizedSerialized.startIndex..<normalizedSerialized.endIndex, in: normalizedSerialized)
        guard let match = self.geminiCLITmpDirectoryPattern.firstMatch(
            in: normalizedSerialized,
            options: [],
            range: range
        ),
              match.numberOfRanges == 2,
              let hashRange = Range(match.range(at: 1), in: normalizedSerialized)
        else {
            return nil
        }

        return String(normalizedSerialized[hashRange]).lowercased()
    }

    private static func isEphemeralCacheControl(_ raw: Any?) -> Bool {
        guard let cacheControl = raw as? [String: Any],
              let type = cacheControl["type"] as? String
        else {
            return false
        }
        return type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "ephemeral"
    }

    private static func serializedJSON(_ value: Any?) -> String? {
        guard let value else { return nil }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return string
    }

    private static func trimmedHeader(_ name: String, in headers: [String: String]) -> String? {
        let alternateName = name.contains("_")
            ? name.replacingOccurrences(of: "_", with: "-")
            : name.replacingOccurrences(of: "-", with: "_")
        let value = headers[name]
            ?? headers[name.lowercased()]
            ?? headers[alternateName]
            ?? headers[alternateName.lowercased()]
            ?? headers.first(where: { $0.key.lowercased() == name.lowercased() || $0.key.lowercased() == alternateName.lowercased() })?.value
            ?? ""
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func trimmedString(_ value: Any?) -> String? {
        guard let value else { return nil }
        let string: String
        switch value {
        case let value as String:
            string = value
        case let value as NSString:
            string = value as String
        default:
            return nil
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

actor ChatCompletionsPrefixStabilityStore {
    struct Entry: Sendable, Equatable {
        var prefixHash: String
        var accountKey: String
        var messageHashes: [String]
        var providerShapeHash: String
        var touchedAt: Int64
    }

    private let ttlSeconds: Int64
    private var entries: [String: Entry] = [:]

    init(ttlSeconds: Int64 = PromptCacheSupport.chatCompletionsAPIKeyStickySessionTTLSeconds) {
        self.ttlSeconds = max(60, ttlSeconds)
    }

    func metadata(
        sessionKey: String?,
        model: String?,
        accountKey: String,
        prefixHash: String,
        messageHashes: [String] = [],
        providerShapeHash: String = "",
        now: Int64 = Helpers.now()
    ) -> [String: String] {
        self.pruneExpired(now: now)
        guard let sessionKey = self.trimmed(sessionKey),
              let model = self.trimmed(model),
              let accountKey = self.trimmed(accountKey),
              let prefixHash = self.trimmed(prefixHash)
        else {
            return [
                "chat_prefix_stability_tracked": "false",
            ]
        }

        let key = "\(sessionKey)\n\(model)"
        let previous = self.entries[key]
        self.entries[key] = Entry(
            prefixHash: prefixHash,
            accountKey: accountKey,
            messageHashes: messageHashes,
            providerShapeHash: providerShapeHash,
            touchedAt: now
        )

        guard let previous else {
            return [
                "chat_prefix_stability_tracked": "true",
                "chat_prefix_same_as_previous": "unknown",
                "chat_account_same_as_previous": "unknown",
                "chat_previous_messages_are_prefix_of_current": "unknown",
                "chat_common_message_prefix_count": "0",
                "chat_previous_message_count": "0",
                "chat_current_message_count": "\(messageHashes.count)",
                "chat_provider_shape_same_as_previous": "unknown",
            ]
        }

        let commonMessagePrefixCount = self.commonPrefixCount(
            previous.messageHashes,
            messageHashes
        )
        let hasMessageSequence = previous.messageHashes.isEmpty == false && messageHashes.isEmpty == false
        let previousMessagesArePrefix = hasMessageSequence
            && messageHashes.count >= previous.messageHashes.count
            && commonMessagePrefixCount == previous.messageHashes.count
        let providerShapeComparable = previous.providerShapeHash.isEmpty == false && providerShapeHash.isEmpty == false

        return [
            "chat_prefix_stability_tracked": "true",
            "chat_prefix_same_as_previous": previous.prefixHash == prefixHash ? "true" : "false",
            "chat_account_same_as_previous": previous.accountKey == accountKey ? "true" : "false",
            "chat_previous_messages_prefix_sha256": previous.prefixHash,
            "chat_previous_messages_are_prefix_of_current": hasMessageSequence
                ? (previousMessagesArePrefix ? "true" : "false")
                : "unknown",
            "chat_common_message_prefix_count": "\(commonMessagePrefixCount)",
            "chat_previous_message_count": "\(previous.messageHashes.count)",
            "chat_current_message_count": "\(messageHashes.count)",
            "chat_provider_shape_same_as_previous": providerShapeComparable
                ? (previous.providerShapeHash == providerShapeHash ? "true" : "false")
                : "unknown",
        ]
    }

    private func pruneExpired(now: Int64) {
        self.entries = self.entries.filter { now - $0.value.touchedAt < self.ttlSeconds }
    }

    private func trimmed(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func commonPrefixCount(_ lhs: [String], _ rhs: [String]) -> Int {
        var count = 0
        for (left, right) in zip(lhs, rhs) {
            guard left == right else { break }
            count += 1
        }
        return count
    }
}
