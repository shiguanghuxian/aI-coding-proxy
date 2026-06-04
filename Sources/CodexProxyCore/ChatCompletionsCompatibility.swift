import Foundation

enum ChatCompletionsCompatibility {
    static let missingReasoningPlaceholder = "(this turn ran without thinking mode)"
    static let missingToolOutputPlaceholder = "[tool output missing - no function_call_output was provided for this call_id]"

    struct PrepareReport: Sendable, Equatable {
        var effectiveProfile: ChatCompletionsCompatibilityProfile = .auto
        var providerID: ChatCompletionsProviderID = .generic
        var providerDefaultsThinking: Bool = false
        var providerDefaultReasoningEffort: String?
        var cacheRestoredReasoningCount: Int = 0
        var cacheRestoredExactReasoningCount: Int = 0
        var cacheRestoredByToolCallIDCount: Int = 0
        var cacheRestoredByToolCallSignatureCount: Int = 0
        var cacheRestoredByAssistantFingerprintCount: Int = 0
        var cacheRestoredByUniqueToolReasoningCount: Int = 0
        var cacheRestoredByLatestToolReasoningCount: Int = 0
        var pinnedFallbackReasoningCount: Int = 0
        var placeholderReasoningCount: Int = 0
        var placeholderToolOutputCount: Int = 0
        var omittedAssistantToolContentCount: Int = 0
        var finalAssistantToolCallCount: Int = 0
        var finalReasoningContentCount: Int = 0
        var finalMessagesCount: Int = 0
        var finalPrefixSHA256: String = ""

        var metadata: [String: String] {
            [
                "chat_compatibility_profile": self.effectiveProfile.rawValue,
                "chat_provider_id": self.providerID.rawValue,
                "chat_provider_defaults_thinking": self.providerDefaultsThinking ? "true" : "false",
                "chat_provider_default_reasoning_effort": self.providerDefaultReasoningEffort ?? "",
                "reasoning_source_cache_count": "\(max(0, self.cacheRestoredReasoningCount))",
                "reasoning_source_cache_exact_count": "\(max(0, self.cacheRestoredExactReasoningCount))",
                "reasoning_source_cache_tool_call_id_count": "\(max(0, self.cacheRestoredByToolCallIDCount))",
                "reasoning_source_cache_tool_signature_count": "\(max(0, self.cacheRestoredByToolCallSignatureCount))",
                "reasoning_source_cache_fingerprint_count": "\(max(0, self.cacheRestoredByAssistantFingerprintCount))",
                "reasoning_source_cache_unique_tool_count": "\(max(0, self.cacheRestoredByUniqueToolReasoningCount))",
                "reasoning_source_cache_latest_tool_count": "\(max(0, self.cacheRestoredByLatestToolReasoningCount))",
                "reasoning_source_cache_pinned_fallback_count": "\(max(0, self.pinnedFallbackReasoningCount))",
                "reasoning_placeholder_count": "\(max(0, self.placeholderReasoningCount))",
                "tool_output_placeholder_count": "\(max(0, self.placeholderToolOutputCount))",
                "assistant_tool_content_omitted_by_provider_count": "\(max(0, self.omittedAssistantToolContentCount))",
                "assistant_tool_call_count": "\(max(0, self.finalAssistantToolCallCount))",
                "reasoning_content_count": "\(max(0, self.finalReasoningContentCount))",
                "final_messages_count": "\(max(0, self.finalMessagesCount))",
                "final_messages_prefix_sha256": self.finalPrefixSHA256,
            ]
        }
    }

    static func resolvedProfile(
        configured: ChatCompletionsCompatibilityProfile,
        baseURL: String?,
        providerPreset: OpenAICompatibleProviderPreset,
        model: String?
    ) -> ChatCompletionsCompatibilityProfile {
        guard configured == .auto else {
            return configured
        }

        let lowerModel = (model ?? "").lowercased()
        let host = self.host(from: baseURL).lowercased()

        if lowerModel.contains("deepseek-reasoner")
            || lowerModel.contains("deepseek_reasoner")
            || lowerModel.contains("deepseek-r1")
        {
            return .deepSeekLegacyReasoner
        }
        if host.contains("mimo")
            || host.contains("xiaomi")
            || lowerModel.contains("mimo")
            || lowerModel.contains("xiaomi")
        {
            return .mimoStrict
        }
        if host.contains("minimaxi.com")
            || host.contains("minimax.chat")
            || lowerModel.hasPrefix("minimax-")
            || lowerModel.hasPrefix("abab")
        {
            return .minimaxStrict
        }
        if host.contains("sensenova.cn")
            || lowerModel.hasPrefix("sensenova-")
            || lowerModel.hasPrefix("deepseek-v4-flash")
        {
            return .senseNovaStrict
        }
        if host.contains("moonshot.cn")
            || host.contains("moonshot.ai")
            || host.contains("platform.kimi")
            || lowerModel.hasPrefix("kimi-")
            || lowerModel.hasPrefix("moonshot-v1-")
        {
            return .kimiStrict
        }
        if host.contains("deepseek")
            || lowerModel.contains("deepseek-v4")
            || lowerModel.contains("deepseek_chat")
            || lowerModel.contains("deepseek-chat")
            || lowerModel == "deepseek"
        {
            return .deepSeekV4Thinking
        }
        if providerPreset.usesOpenAIChatCompletionsAPI {
            return .generic
        }
        return .generic
    }

    static func providerStrategy(
        configured: ChatCompletionsCompatibilityProfile,
        baseURL: String?,
        providerPreset: OpenAICompatibleProviderPreset,
        model: String?
    ) -> ChatCompletionsProviderStrategy {
        ChatCompletionsProviderStrategy.resolve(
            configured: configured,
            baseURL: baseURL,
            providerPreset: providerPreset,
            model: model
        )
    }

    static func prepareRequest(
        _ request: [String: Any],
        configuredProfile: ChatCompletionsCompatibilityProfile,
        baseURL: String?,
        providerPreset: OpenAICompatibleProviderPreset,
        reasoningCache: ChatCompletionsReasoningCache?,
        accountKey: String,
        sessionKey: String?,
        now: Int64 = Helpers.now()
    ) -> [String: Any] {
        self.prepareRequestWithReport(
            request,
            configuredProfile: configuredProfile,
            baseURL: baseURL,
            providerPreset: providerPreset,
            reasoningCache: reasoningCache,
            accountKey: accountKey,
            sessionKey: sessionKey,
            now: now
        ).request
    }

    static func prepareRequestWithReport(
        _ request: [String: Any],
        configuredProfile: ChatCompletionsCompatibilityProfile,
        baseURL: String?,
        providerPreset: OpenAICompatibleProviderPreset,
        reasoningCache: ChatCompletionsReasoningCache?,
        accountKey: String,
        sessionKey: String?,
        now: Int64 = Helpers.now()
    ) -> (request: [String: Any], report: PrepareReport) {
        let strategy = self.providerStrategy(
            configured: configuredProfile,
            baseURL: baseURL,
            providerPreset: providerPreset,
            model: request["model"] as? String
        )
        var report = PrepareReport(
            effectiveProfile: strategy.profile,
            providerID: strategy.providerID,
            providerDefaultsThinking: strategy.defaultsThinkingEnabled,
            providerDefaultReasoningEffort: strategy.defaultReasoningEffort
        )

        var prepared = request
        prepared.removeValue(forKey: "enable_thinking")

        prepared = self.requestByApplyingProviderDefaults(prepared, strategy: strategy)
        if strategy.normalizesDeepSeekThinkingParameters {
            prepared = self.prepareDeepSeekV4Parameters(prepared)
        }
        if self.isStreaming(prepared) {
            prepared = self.requestByIncludingStreamingUsage(prepared)
        }
        prepared = self.requestByApplyingProviderParameterCompatibility(prepared, strategy: strategy)

        if let reasoningCache {
            let applied = reasoningCache.applyWithReport(
                to: prepared,
                accountKey: accountKey,
                sessionKey: sessionKey,
                now: now
            )
            prepared = applied.request
            report.cacheRestoredReasoningCount += applied.report.restoredReasoningContentCount
            report.cacheRestoredExactReasoningCount += applied.report.restoredExactReasoningContentCount
            report.cacheRestoredByToolCallIDCount += applied.report.restoredByToolCallIDCount
            report.cacheRestoredByToolCallSignatureCount += applied.report.restoredByToolCallSignatureCount
            report.cacheRestoredByAssistantFingerprintCount += applied.report.restoredByAssistantFingerprintCount
            report.cacheRestoredByUniqueToolReasoningCount += applied.report.restoredByUniqueToolReasoningCount
            report.cacheRestoredByLatestToolReasoningCount += applied.report.restoredByLatestToolReasoningCount
            report.pinnedFallbackReasoningCount += applied.report.pinnedFallbackReasoningCount
        }

        prepared = self.requestBySanitizingTools(
            prepared,
            dropNonFunctionTools: strategy.dropsNonFunctionTools
        )

        if strategy.removesHistoricalReasoningContent {
            prepared = self.requestByRemovingReasoningContent(prepared)
            report = self.finalizeReport(report, request: prepared)
            return (prepared, report)
        }

        let sanitized = self.requestBySanitizingMessages(
            prepared,
            injectMissingReasoning: strategy.injectMissingToolReasoning,
            injectMissingAssistantReasoning: strategy.injectMissingPlainAssistantReasoning,
            injectMissingToolOutputs: strategy.injectMissingToolOutputs,
            deferSystemDeveloperInterruptions: strategy.deferSystemDeveloperInterruptions,
            omitEmptyAssistantToolContent: strategy.omitsEmptyAssistantToolContent
        )
        prepared = sanitized.request
        prepared = self.requestByApplyingProviderMessageCompatibility(prepared, strategy: strategy)
        report.placeholderReasoningCount += sanitized.placeholderReasoningCount
        report.placeholderToolOutputCount += sanitized.placeholderToolOutputCount
        report.omittedAssistantToolContentCount += sanitized.omittedAssistantToolContentCount
        report = self.finalizeReport(report, request: prepared)
        return (prepared, report)
    }

    static func humanizedUpstreamErrorMessage(_ message: String) -> String {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.contains("context_length_exceeded")
            || lower.contains("maximum context length")
            || lower.contains("context length")
            || lower.contains("prompt too long")
            || lower.contains("上下文长度")
            || lower.contains("输入过长")
            || lower.contains("提示过长")
        {
            return "上游模型上下文长度不足：请缩短当前会话、清理较早历史，或切换更长上下文模型。\(self.rawSuffix(trimmed))"
        }
        if lower.contains("malformed json")
            || lower.contains("invalid json")
            || lower.contains("unexpected end of data")
            || lower.contains("tool arguments")
            || lower.contains("function.arguments")
            || lower.contains("json parse")
        {
            return "上游拒绝了工具调用 JSON：代理已清理常见畸形参数，若仍失败，请开启诊断请求体查看具体工具历史。\(self.rawSuffix(trimmed))"
        }
        return message
    }

    private static func finalizeReport(_ report: PrepareReport, request: [String: Any]) -> PrepareReport {
        var next = report
        let messages = request["messages"] as? [[String: Any]] ?? []
        next.finalMessagesCount = messages.count
        next.finalAssistantToolCallCount = messages.reduce(0) { count, message in
            let toolCalls = message["tool_calls"] as? [[String: Any]] ?? []
            return self.role(of: message) == "assistant" ? count + toolCalls.count : count
        }
        next.finalReasoningContentCount = messages.reduce(0) { count, message in
            self.trimmedString(message["reasoning_content"]) == nil ? count : count + 1
        }
        next.finalPrefixSHA256 = DiagnosticRequestBodySupport.normalizedPrefixSHA256(from: request)
        return next
    }

    private static func requestByApplyingProviderDefaults(
        _ request: [String: Any],
        strategy: ChatCompletionsProviderStrategy
    ) -> [String: Any] {
        var updated = request
        if strategy.defaultsThinkingEnabled && updated["thinking"] == nil {
            updated["thinking"] = ["type": "enabled"]
        }
        if let defaultReasoningEffort = strategy.defaultReasoningEffort,
           updated["reasoning_effort"] == nil,
           self.isThinkingDisabled(updated["thinking"]) == false
        {
            updated["reasoning_effort"] = defaultReasoningEffort
        }
        return updated
    }

    private static func requestByApplyingProviderParameterCompatibility(
        _ request: [String: Any],
        strategy: ChatCompletionsProviderStrategy
    ) -> [String: Any] {
        var updated = request
        let hadDisabledThinking = self.isThinkingDisabled(updated["thinking"])
        if strategy.removesThinkingParameters {
            updated.removeValue(forKey: "thinking")
            updated.removeValue(forKey: "enable_thinking")
        }
        if strategy.setsDisabledReasoningEffortNone, hadDisabledThinking {
            updated["reasoning_effort"] = "none"
        }
        if strategy.dropsToolChoiceAuto,
           self.trimmedString(updated["tool_choice"])?.lowercased() == "auto"
        {
            updated.removeValue(forKey: "tool_choice")
        }
        if strategy.dropsStreamOptions {
            updated.removeValue(forKey: "stream_options")
        }
        if strategy.dropsParallelToolCalls {
            updated.removeValue(forKey: "parallel_tool_calls")
        }
        if strategy.dropsResponseFormat {
            updated.removeValue(forKey: "response_format")
        }
        if strategy.dropsReasoningEffort {
            updated.removeValue(forKey: "reasoning_effort")
        }
        return updated
    }

    private static func prepareDeepSeekV4Parameters(_ request: [String: Any]) -> [String: Any] {
        var updated = request
        if updated["reasoning_effort"] != nil && updated["thinking"] == nil {
            updated["thinking"] = ["type": "enabled"]
        }
        if self.isThinkingDisabled(updated["thinking"]) {
            if (updated["reasoning_effort"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "none" {
                updated.removeValue(forKey: "reasoning_effort")
            }
            return updated
        }
        if self.isThinkingEnabled(updated["thinking"]) {
            updated.removeValue(forKey: "temperature")
            updated.removeValue(forKey: "top_p")
            updated.removeValue(forKey: "presence_penalty")
            updated.removeValue(forKey: "frequency_penalty")
        }
        return updated
    }

    private static func requestByIncludingStreamingUsage(_ request: [String: Any]) -> [String: Any] {
        var updated = request
        var streamOptions = updated["stream_options"] as? [String: Any] ?? [:]
        streamOptions["include_usage"] = true
        updated["stream_options"] = streamOptions
        return updated
    }

    private static func requestBySanitizingTools(
        _ request: [String: Any],
        dropNonFunctionTools: Bool
    ) -> [String: Any] {
        guard let tools = request["tools"] as? [[String: Any]], tools.isEmpty == false else {
            return request
        }

        var seen = Set<String>()
        var sanitized: [[String: Any]] = []
        for tool in tools {
            let type = self.trimmedString(tool["type"])?.lowercased() ?? "function"
            if dropNonFunctionTools, type != "function", type != "custom" {
                continue
            }

            let key = self.toolDeduplicationKey(tool)
            guard seen.contains(key) == false else { continue }
            seen.insert(key)

            var next = tool
            if next["strict"] is NSNull {
                next.removeValue(forKey: "strict")
            }
            if var function = next["function"] as? [String: Any] {
                if function["strict"] is NSNull {
                    function.removeValue(forKey: "strict")
                }
                next["function"] = function
            }
            sanitized.append(next)
        }

        var updated = request
        if sanitized.isEmpty {
            updated.removeValue(forKey: "tools")
        } else {
            updated["tools"] = sanitized
        }
        return updated
    }

    private static func requestByApplyingProviderMessageCompatibility(
        _ request: [String: Any],
        strategy: ChatCompletionsProviderStrategy
    ) -> [String: Any] {
        guard var messages = request["messages"] as? [[String: Any]], messages.isEmpty == false else {
            return request
        }

        var changed = false
        if strategy.dropsNullAssistantContent {
            for index in messages.indices
                where self.role(of: messages[index]) == "assistant"
                    && messages[index]["content"] is NSNull
            {
                messages[index].removeValue(forKey: "content")
                changed = true
            }
        }
        if strategy.mergesSystemMessages {
            let merged = self.messagesByMergingSystemMessages(messages)
            if self.normalizedJSONString(merged) != self.normalizedJSONString(messages) {
                messages = merged
                changed = true
            }
        }

        guard changed else { return request }
        var updated = request
        updated["messages"] = messages
        return updated
    }

    private static func messagesByMergingSystemMessages(_ messages: [[String: Any]]) -> [[String: Any]] {
        let systemMessages = messages.filter { self.role(of: $0) == "system" }
        guard systemMessages.isEmpty == false else {
            return messages
        }
        if systemMessages.count == 1, self.role(of: messages.first ?? [:]) == "system" {
            return messages
        }

        let contents = systemMessages.compactMap { self.trimmedString($0["content"]) }
        let nonSystemMessages = messages.filter { self.role(of: $0) != "system" }
        guard contents.isEmpty == false else {
            return nonSystemMessages
        }

        var merged: [[String: Any]] = [[
            "role": "system",
            "content": contents.joined(separator: "\n\n"),
        ]]
        merged.append(contentsOf: nonSystemMessages)
        return merged
    }

    private static func requestByRemovingReasoningContent(_ request: [String: Any]) -> [String: Any] {
        guard var messages = request["messages"] as? [[String: Any]], messages.isEmpty == false else {
            return request
        }
        var changed = false
        for index in messages.indices where messages[index]["reasoning_content"] != nil {
            messages[index].removeValue(forKey: "reasoning_content")
            changed = true
        }
        guard changed else { return request }
        var updated = request
        updated["messages"] = messages
        return updated
    }

    private struct MessageSanitizationResult {
        var request: [String: Any]
        var placeholderReasoningCount: Int = 0
        var placeholderToolOutputCount: Int = 0
        var omittedAssistantToolContentCount: Int = 0
    }

    private static func requestBySanitizingMessages(
        _ request: [String: Any],
        injectMissingReasoning: Bool,
        injectMissingAssistantReasoning: Bool,
        injectMissingToolOutputs: Bool,
        deferSystemDeveloperInterruptions: Bool,
        omitEmptyAssistantToolContent: Bool
    ) -> MessageSanitizationResult {
        var result = MessageSanitizationResult(request: request)
        guard let messages = request["messages"] as? [[String: Any]], messages.isEmpty == false else {
            return result
        }

        var changed = false
        var sanitized: [[String: Any]] = []
        var emittedCallIDs = Set<String>()
        var emittedOutputIDs = Set<String>()
        var index = 0

        while index < messages.count {
            var message = messages[index]
            let role = self.role(of: message)

            if role == "tool" {
                changed = true
                index += 1
                continue
            }

            guard role == "assistant",
                  let rawToolCalls = message["tool_calls"] as? [[String: Any]],
                  rawToolCalls.isEmpty == false
            else {
                if injectMissingAssistantReasoning,
                   role == "assistant",
                   self.trimmedString(message["reasoning_content"]) == nil
                {
                    message["reasoning_content"] = self.missingReasoningPlaceholder
                    result.placeholderReasoningCount += 1
                    changed = true
                }
                sanitized.append(message)
                index += 1
                continue
            }

            let toolCalls = self.sanitizedToolCalls(rawToolCalls, emittedCallIDs: &emittedCallIDs)
            if toolCalls.isEmpty {
                message.removeValue(forKey: "tool_calls")
                sanitized.append(message)
                changed = true
                index += 1
                continue
            }

            message["tool_calls"] = toolCalls
            if omitEmptyAssistantToolContent,
               self.isEmptyAssistantToolContent(message["content"])
            {
                message.removeValue(forKey: "content")
                result.omittedAssistantToolContentCount += 1
                changed = true
            }
            if injectMissingReasoning, self.trimmedString(message["reasoning_content"]) == nil {
                message["reasoning_content"] = self.missingReasoningPlaceholder
                result.placeholderReasoningCount += 1
                changed = true
            }

            let callIDs = toolCalls.compactMap { self.trimmedString($0["id"]) }
            var outputsByID: [String: [String: Any]] = [:]
            var deferredInterruptions: [[String: Any]] = []
            var scan = index + 1
            while scan < messages.count {
                let next = messages[scan]
                let nextRole = self.role(of: next)
                if nextRole == "tool",
                   let callID = self.trimmedString(next["tool_call_id"]),
                   callIDs.contains(callID)
                {
                    if emittedOutputIDs.contains(callID) == false {
                        outputsByID[callID] = next
                        emittedOutputIDs.insert(callID)
                    } else {
                        changed = true
                    }
                    scan += 1
                    continue
                }
                if injectMissingToolOutputs,
                   deferSystemDeveloperInterruptions,
                   (nextRole == "system" || nextRole == "developer"),
                   self.hasRemainingToolOutput(for: callIDs, in: messages, after: scan)
                {
                    deferredInterruptions.append(next)
                    changed = true
                    scan += 1
                    continue
                }
                if nextRole == "tool" {
                    changed = true
                    scan += 1
                    continue
                }
                break
            }

            let missingOutputIDs = callIDs.filter { outputsByID[$0] == nil }
            if missingOutputIDs.isEmpty == false && injectMissingToolOutputs == false {
                changed = true
                index = scan
                continue
            }

            sanitized.append(message)
            for callID in callIDs {
                if let output = outputsByID[callID] {
                    sanitized.append(output)
                } else {
                    sanitized.append([
                        "role": "tool",
                        "tool_call_id": callID,
                        "content": self.missingToolOutputPlaceholder,
                    ])
                    emittedOutputIDs.insert(callID)
                    result.placeholderToolOutputCount += 1
                    changed = true
                }
            }
            if deferredInterruptions.isEmpty == false {
                sanitized.append(contentsOf: deferredInterruptions)
            }
            if scan > index + 1 {
                changed = true
            }
            index = scan
        }

        guard changed || sanitized.count != messages.count else {
            return result
        }
        var updated = request
        updated["messages"] = sanitized
        result.request = updated
        return result
    }

    private static func hasRemainingToolOutput(for callIDs: [String], in messages: [[String: Any]], after index: Int) -> Bool {
        guard callIDs.isEmpty == false else { return false }
        var scan = index + 1
        while scan < messages.count {
            let message = messages[scan]
            let role = self.role(of: message)
            if role == "tool",
               let callID = self.trimmedString(message["tool_call_id"]),
               callIDs.contains(callID)
            {
                return true
            }
            if role != "system", role != "developer" {
                return false
            }
            scan += 1
        }
        return false
    }

    private static func isEmptyAssistantToolContent(_ value: Any?) -> Bool {
        guard let value else { return true }
        if value is NSNull {
            return true
        }
        if let string = value as? String {
            return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let array = value as? [Any] {
            return array.isEmpty
        }
        return false
    }

    private static func isThinkingDisabled(_ value: Any?) -> Bool {
        guard let object = value as? [String: Any] else {
            return false
        }
        if let enabled = object["enabled"] as? Bool {
            return enabled == false
        }
        if let type = self.trimmedString(object["type"])?.lowercased() {
            return type == "disabled" || type == "off" || type == "false"
        }
        return false
    }

    private static func sanitizedToolCalls(
        _ toolCalls: [[String: Any]],
        emittedCallIDs: inout Set<String>
    ) -> [[String: Any]] {
        var result: [[String: Any]] = []
        for raw in toolCalls {
            guard let callID = self.trimmedString(raw["id"]),
                  emittedCallIDs.contains(callID) == false
            else {
                continue
            }
            emittedCallIDs.insert(callID)

            var toolCall = raw
            var function = toolCall["function"] as? [String: Any] ?? [:]
            function["arguments"] = self.sanitizedFunctionArguments(function["arguments"])
            toolCall["function"] = function
            if self.trimmedString(toolCall["type"]) == nil {
                toolCall["type"] = "function"
            }
            result.append(toolCall)
        }
        return result
    }

    private static func sanitizedFunctionArguments(_ value: Any?) -> String {
        if let string = value as? String {
            return self.isValidJSONText(string) ? string : "{}"
        }
        guard let value else { return "{}" }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8),
           self.isValidJSONText(text)
        {
            return text
        }
        return "{}"
    }

    private static func isValidJSONText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false,
              let data = trimmed.data(using: .utf8)
        else {
            return false
        }
        return (try? JSONSerialization.jsonObject(with: data)) != nil
    }

    private static func normalizedJSONString(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            return ""
        }
        return text
    }

    private static func toolDeduplicationKey(_ tool: [String: Any]) -> String {
        let type = self.trimmedString(tool["type"])?.lowercased() ?? "function"
        if type == "function" {
            let function = tool["function"] as? [String: Any] ?? [:]
            let name = self.trimmedString(function["name"])?.lowercased() ?? "tool"
            return "function:\(name)"
        }
        if let name = self.trimmedString(tool["name"])?.lowercased() {
            return "\(type):\(name)"
        }
        return type
    }

    private static func role(of message: [String: Any]) -> String {
        ((message["role"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isStreaming(_ request: [String: Any]) -> Bool {
        (request["stream"] as? Bool) == true
    }

    private static func isThinkingEnabled(_ value: Any?) -> Bool {
        guard let object = value as? [String: Any] else {
            return false
        }
        if let enabled = object["enabled"] as? Bool {
            return enabled
        }
        if let type = self.trimmedString(object["type"])?.lowercased() {
            return type == "enabled" || type == "on" || type == "true"
        }
        return false
    }

    private static func host(from baseURL: String?) -> String {
        guard let trimmed = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false,
              let components = URLComponents(string: trimmed)
        else {
            return ""
        }
        return components.host ?? ""
    }

    private static func trimmedString(_ value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func rawSuffix(_ raw: String) -> String {
        let truncated = Helpers.truncate(raw, limit: 240)
        guard truncated.isEmpty == false else {
            return ""
        }
        return " 上游原始摘要：\(truncated)"
    }
}
