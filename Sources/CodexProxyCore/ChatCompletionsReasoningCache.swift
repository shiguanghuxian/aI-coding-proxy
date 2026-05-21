import Foundation

struct ChatCompletionsReasoningCacheEntry: Codable, Sendable, Equatable {
    var byToolCallID: [String: String]
    var byToolCallSignature: [String: String]
    var byAssistantFingerprint: [String: String]
    var byToolAssistantFingerprint: [String: String]
    var latestReasoningContent: String?
    var latestToolCallReasoningContent: String?
    var expiresAt: Int64
    var touchedAt: Int64
}

final class ChatCompletionsReasoningCache: @unchecked Sendable {
    private let lock = NSLock()
    private let ttlSeconds: Int64
    private let capacity: Int
    private let store: SQLiteStore?
    private var entries: [String: ChatCompletionsReasoningCacheEntry] = [:]

    init(ttlSeconds: Int64 = 604_800, capacity: Int = 2_048, store: SQLiteStore? = nil) {
        self.ttlSeconds = ttlSeconds
        self.capacity = max(1, capacity)
        self.store = store
    }

    func apply(
        to request: [String: Any],
        accountKey: String,
        sessionKey: String?,
        now: Int64 = Helpers.now()
    ) -> [String: Any] {
        guard let cacheKey = self.cacheKey(accountKey: accountKey, sessionKey: sessionKey) else {
            return request
        }

        let entry = self.entry(
            cacheKey: cacheKey,
            accountKey: accountKey,
            sessionKey: sessionKey ?? "",
            now: now
        )
        guard let entry, entry.expiresAt > now else {
            return request
        }
        guard var messages = request["messages"] as? [[String: Any]], messages.isEmpty == false else {
            return request
        }

        var changed = false
        for index in messages.indices {
            guard ((messages[index]["role"] as? String) ?? "").lowercased() == "assistant" else {
                continue
            }
            guard Self.trimmedString(messages[index]["reasoning_content"]) == nil else {
                continue
            }
            guard let reasoningContent = self.reasoningContent(for: messages[index], entry: entry) else {
                continue
            }
            messages[index]["reasoning_content"] = reasoningContent
            changed = true
        }

        guard changed else {
            return request
        }
        var updated = request
        updated["messages"] = messages
        return updated
    }

    func record(
        completedResponse: [String: Any],
        accountKey: String,
        sessionKey: String?,
        now: Int64 = Helpers.now()
    ) {
        guard let cacheKey = self.cacheKey(accountKey: accountKey, sessionKey: sessionKey),
              let reasoningContent = ProxyTranscoder.extractReasoningContent(from: completedResponse)
        else {
            return
        }

        let output = completedResponse["output"] as? [[String: Any]] ?? []
        let toolCalls = output.filter { ($0["type"] as? String) == "function_call" }
        let toolCallIDs = toolCalls.compactMap { item -> String? in
            guard (item["type"] as? String) == "function_call" else { return nil }
            return Self.trimmedString(item["call_id"]) ?? Self.trimmedString(item["id"])
        }
        let toolCallSignatures = toolCalls.compactMap(Self.toolCallSignature)
        let assistantText = ProxyTranscoder.extractAssistantText(from: completedResponse)
        let assistantFingerprint = Self.assistantFingerprint(forText: assistantText)

        self.lock.lock()
        self.pruneExpiredLocked(now: now)
        var entry = self.entries[cacheKey] ?? ChatCompletionsReasoningCacheEntry(
            byToolCallID: [:],
            byToolCallSignature: [:],
            byAssistantFingerprint: [:],
            byToolAssistantFingerprint: [:],
            latestReasoningContent: nil,
            latestToolCallReasoningContent: nil,
            expiresAt: now + self.ttlSeconds,
            touchedAt: now
        )
        for callID in toolCallIDs {
            entry.byToolCallID[callID] = reasoningContent
        }
        for signature in toolCallSignatures {
            entry.byToolCallSignature[signature] = reasoningContent
        }
        if let assistantFingerprint {
            entry.byAssistantFingerprint[assistantFingerprint] = reasoningContent
            if toolCalls.isEmpty == false {
                entry.byToolAssistantFingerprint[assistantFingerprint] = reasoningContent
            }
        }
        entry.latestReasoningContent = reasoningContent
        if toolCalls.isEmpty == false {
            entry.latestToolCallReasoningContent = reasoningContent
        }
        entry.expiresAt = now + self.ttlSeconds
        entry.touchedAt = now
        self.entries[cacheKey] = entry
        self.enforceCapacityLocked()
        self.lock.unlock()

        try? self.store?.upsertChatCompletionsReasoningCacheEntry(
            cacheKey: cacheKey,
            accountKey: accountKey,
            sessionKey: sessionKey ?? "",
            entry: entry,
            capacity: self.capacity
        )
    }

    func clear(accountKey: String) {
        self.lock.lock()
        self.entries = self.entries.filter { key, _ in
            !key.hasPrefix("\(accountKey)\n")
        }
        self.lock.unlock()
        _ = try? self.store?.clearChatCompletionsReasoningCache(accountKey: accountKey)
    }

    func pruneExpired(now: Int64 = Helpers.now()) {
        self.lock.lock()
        self.pruneExpiredLocked(now: now)
        self.lock.unlock()
        _ = try? self.store?.pruneExpiredChatCompletionsReasoningCache(now: now)
    }

    func summary(now: Int64 = Helpers.now()) throws -> ReasoningCacheSummary {
        try self.store?.chatCompletionsReasoningCacheSummary(now: now) ?? ReasoningCacheSummary()
    }

    func clear(_ request: ClearReasoningCacheRequest, now: Int64 = Helpers.now()) throws -> ClearReasoningCacheResult {
        let deleted = try self.store?.clearChatCompletionsReasoningCache(request, now: now) ?? 0
        self.lock.lock()
        if request.clearAll {
            self.entries.removeAll()
        } else {
            let accountKeys = Set(request.accountKeys)
            self.entries = self.entries.filter { key, entry in
                let accountMatches = accountKeys.isEmpty || accountKeys.contains(Self.accountKey(fromCacheKey: key))
                let expiredMatches = request.expiredOnly && entry.expiresAt <= now
                let olderMatches = request.olderThanSeconds.map { entry.touchedAt < now - $0 } ?? false
                let shouldDelete = accountMatches && (request.expiredOnly || request.olderThanSeconds != nil || !accountKeys.isEmpty)
                    && (!request.expiredOnly || expiredMatches)
                    && (request.olderThanSeconds == nil || olderMatches)
                return !shouldDelete
            }
        }
        self.lock.unlock()
        return ClearReasoningCacheResult(deletedCount: deleted, summary: try self.summary(now: now))
    }

    private func entry(
        cacheKey: String,
        accountKey: String,
        sessionKey: String,
        now: Int64
    ) -> ChatCompletionsReasoningCacheEntry? {
        self.lock.lock()
        self.pruneExpiredLocked(now: now)
        if var entry = self.entries[cacheKey] {
            entry.touchedAt = now
            self.entries[cacheKey] = entry
            self.lock.unlock()
            return entry
        }
        self.lock.unlock()

        guard let persistent = try? self.store?.loadChatCompletionsReasoningCacheEntry(
            accountKey: accountKey,
            sessionKey: sessionKey,
            now: now
        ), persistent.expiresAt > now else {
            return nil
        }

        self.lock.lock()
        self.entries[cacheKey] = persistent
        self.enforceCapacityLocked()
        self.lock.unlock()
        return persistent
    }

    private func reasoningContent(for message: [String: Any], entry: ChatCompletionsReasoningCacheEntry) -> String? {
        let toolCalls = message["tool_calls"] as? [[String: Any]] ?? []
        for toolCall in toolCalls {
            guard let callID = Self.trimmedString(toolCall["id"]) else { continue }
            if let reasoningContent = entry.byToolCallID[callID] {
                return reasoningContent
            }
        }
        for toolCall in toolCalls {
            guard let signature = Self.toolCallSignature(toolCall) else { continue }
            if let reasoningContent = entry.byToolCallSignature[signature] {
                return reasoningContent
            }
        }

        if let fingerprint = Self.assistantFingerprint(forText: Self.assistantText(from: message)) {
            let fingerprintReasoning = toolCalls.isEmpty
                ? entry.byAssistantFingerprint[fingerprint]
                : entry.byToolAssistantFingerprint[fingerprint]
            if let fingerprintReasoning {
                return fingerprintReasoning
            }
        }

        if toolCalls.isEmpty == false,
           let reasoningContent = Self.uniqueToolCallReasoningContent(in: entry)
        {
            return reasoningContent
        }

        return nil
    }

    private static func uniqueToolCallReasoningContent(in entry: ChatCompletionsReasoningCacheEntry) -> String? {
        var values = Set<String>()
        for value in entry.byToolCallID.values {
            values.insert(value)
        }
        for value in entry.byToolCallSignature.values {
            values.insert(value)
        }
        if let latest = entry.latestToolCallReasoningContent {
            values.insert(latest)
        }
        guard values.count == 1 else { return nil }
        return values.first
    }

    private func cacheKey(accountKey: String, sessionKey: String?) -> String? {
        let accountKey = accountKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let sessionKey = sessionKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard accountKey.isEmpty == false, sessionKey.isEmpty == false else {
            return nil
        }
        return "\(accountKey)\n\(sessionKey)"
    }

    private static func accountKey(fromCacheKey cacheKey: String) -> String {
        cacheKey.components(separatedBy: "\n").first ?? cacheKey
    }

    private func pruneExpiredLocked(now: Int64) {
        self.entries = self.entries.filter { $0.value.expiresAt > now }
    }

    private func enforceCapacityLocked() {
        guard self.entries.count > self.capacity else { return }
        let overflow = self.entries.count - self.capacity
        let keysToRemove = self.entries
            .sorted { $0.value.touchedAt < $1.value.touchedAt }
            .prefix(overflow)
            .map(\.key)
        for key in keysToRemove {
            self.entries.removeValue(forKey: key)
        }
    }

    private static func assistantText(from message: [String: Any]) -> String {
        if let text = message["content"] as? String {
            return text
        }
        if message["content"] is NSNull {
            return ""
        }
        let content = message["content"] as? [[String: Any]] ?? []
        return content.compactMap { block -> String? in
            let type = (block["type"] as? String)?.lowercased() ?? ""
            guard ["text", "output_text", "input_text"].contains(type) else {
                return nil
            }
            return block["text"] as? String
        }.joined()
    }

    private static func assistantFingerprint(forText text: String) -> String? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else {
            return nil
        }
        return Helpers.sha256(normalized)
    }

    private static func toolCallSignature(_ toolCall: [String: Any]) -> String? {
        let function = toolCall["function"] as? [String: Any]
        let rawName = function?["name"] ?? toolCall["name"]
        let rawArguments = function?["arguments"] ?? toolCall["arguments"]
        guard let name = Self.trimmedString(rawName),
              let arguments = Self.normalizedArguments(rawArguments)
        else {
            return nil
        }
        return Helpers.sha256("\(name)\n\(arguments)")
    }

    private static func normalizedArguments(_ value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = trimmed.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data),
               JSONSerialization.isValidJSONObject(object),
               let normalized = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            {
                return String(decoding: normalized, as: UTF8.self)
            }
            return trimmed
        }

        guard let value,
              JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        else {
            return nil
        }
        let normalized = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func trimmedString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
