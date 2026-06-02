import Foundation

public enum ProxyTranscoder {
    public struct ChatCompletionsRequestBuildDiagnostics: Sendable, Equatable {
        public var encryptedContentReasoningCount: Int
        public var directReasoningContentCount: Int
        public var summaryReasoningContentCount: Int
        public var contentReasoningCount: Int
        public var assistantItemReasoningContentCount: Int

        public init(
            encryptedContentReasoningCount: Int = 0,
            directReasoningContentCount: Int = 0,
            summaryReasoningContentCount: Int = 0,
            contentReasoningCount: Int = 0,
            assistantItemReasoningContentCount: Int = 0
        ) {
            self.encryptedContentReasoningCount = max(0, encryptedContentReasoningCount)
            self.directReasoningContentCount = max(0, directReasoningContentCount)
            self.summaryReasoningContentCount = max(0, summaryReasoningContentCount)
            self.contentReasoningCount = max(0, contentReasoningCount)
            self.assistantItemReasoningContentCount = max(0, assistantItemReasoningContentCount)
        }

        public var metadata: [String: String] {
            [
                "used_encrypted_content": self.encryptedContentReasoningCount > 0 ? "true" : "false",
                "reasoning_source_encrypted_content_count": "\(self.encryptedContentReasoningCount)",
                "reasoning_source_direct_count": "\(self.directReasoningContentCount)",
                "reasoning_source_summary_count": "\(self.summaryReasoningContentCount)",
                "reasoning_source_content_count": "\(self.contentReasoningCount)",
                "assistant_item_reasoning_content_count": "\(self.assistantItemReasoningContentCount)",
            ]
        }
    }

    public static let supportedModels = [
        "gpt-5.5",
        "gpt-5.4",
        "gpt-5.3-codex",
        "gpt-5.4-mini",
        "gpt-5.2",
    ]
    public static let defaultModel = supportedModels.first ?? "gpt-5.5"

    private static let requestModelMap: [String: String] = [
        "gpt-5-4": "gpt-5.4",
    ]

    public static func convertChatCompletionsRequest(
        _ payload: [String: Any],
        allowCustomModelPassthrough: Bool = false,
        additionalSupportedModels: Set<String> = []
    ) throws -> (request: [String: Any], downstreamStream: Bool, model: String) {
        if payload["messages"] == nil, payload["input"] != nil {
            let normalized = try self.normalizeResponsesRequest(
                payload,
                allowCustomModelPassthrough: allowCustomModelPassthrough,
                additionalSupportedModels: additionalSupportedModels
            )
            let model = normalized["model"] as? String ?? self.defaultModel
            return (normalized, (payload["stream"] as? Bool) ?? false, model)
        }
        guard let messages = payload["messages"] as? [[String: Any]] else {
            throw ProxyError.message("chat/completions 缺少 messages")
        }
        let requestedModel = try self.normalizeClientModel(
            (payload["model"] as? String) ?? self.defaultModel,
            allowCustomModelPassthrough: allowCustomModelPassthrough,
            additionalSupportedModels: additionalSupportedModels
        )
        let downstreamStream = (payload["stream"] as? Bool) ?? false

        var input: [[String: Any]] = []
        for message in messages {
            let role = (message["role"] as? String) ?? "user"
            if role == "tool" {
                input.append([
                    "type": "function_call_output",
                    "call_id": message["tool_call_id"] as? String ?? "",
                    "output": self.stringifyMessageContent(message["content"]),
                ])
                continue
            }
            let translatedRole = role == "system" ? "developer" : role
            let reasoningContent = self.trimmedString(message["reasoning_content"])
            let toolCalls = message["tool_calls"] as? [[String: Any]] ?? []
            if translatedRole == "assistant", !toolCalls.isEmpty {
                let content = self.normalizeMessageContent(message["content"], role: translatedRole)
                if !self.chatCompletionMessageContent(from: content).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    input.append([
                        "type": "message",
                        "role": translatedRole,
                        "content": content,
                    ])
                }

                for (index, toolCall) in toolCalls.enumerated() {
                    let function = toolCall["function"] as? [String: Any] ?? [:]
                    let callID = (toolCall["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                        ?? "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
                    guard !callID.isEmpty else { continue }
                    var functionItem: [String: Any] = [
                        "type": "function_call",
                        "id": "fc_\(callID)",
                        "call_id": callID,
                        "name": function["name"] as? String ?? "tool",
                        "arguments": self.stringValue(function["arguments"]),
                    ]
                    if index == 0, let reasoningContent {
                        functionItem["reasoning_content"] = reasoningContent
                    }
                    input.append(functionItem)
                }
                continue
            }
            var inputItem: [String: Any] = [
                "type": "message",
                "role": translatedRole,
                "content": self.normalizeMessageContent(message["content"], role: translatedRole),
            ]
            if translatedRole == "assistant", let reasoningContent {
                inputItem["reasoning_content"] = reasoningContent
            }
            input.append(inputItem)
        }

        var request: [String: Any] = [
            "model": requestedModel,
            "stream": true,
            "store": false,
            "instructions": "",
            "input": input,
            "parallel_tool_calls": (payload["parallel_tool_calls"] as? Bool) ?? true,
            "include": ["reasoning.encrypted_content"],
            "reasoning": [
                "effort": (payload["reasoning_effort"] as? String) ?? "medium",
                "summary": ((payload["reasoning"] as? [String: Any])?["summary"] as? String) ?? "auto",
            ],
        ]
        if let tools = payload["tools"] {
            request["tools"] = tools
        }
        if let temperature = payload["temperature"] {
            request["temperature"] = temperature
        }
        if let topP = payload["top_p"] {
            request["top_p"] = topP
        }
        if let maxOutputTokens = payload["max_completion_tokens"] ?? payload["max_tokens"] {
            request["max_output_tokens"] = maxOutputTokens
        }
        if let promptCacheKey = payload["prompt_cache_key"] {
            request["prompt_cache_key"] = promptCacheKey
        }
        if let thinking = payload["thinking"] {
            request["thinking"] = thinking
        }
        return (request, downstreamStream, requestedModel)
    }

    public static func normalizeResponsesRequest(
        _ payload: [String: Any],
        allowCustomModelPassthrough: Bool = false,
        additionalSupportedModels: Set<String> = []
    ) throws -> [String: Any] {
        var request = payload
        request["model"] = try self.normalizeClientModel(
            (payload["model"] as? String) ?? self.defaultModel,
            allowCustomModelPassthrough: allowCustomModelPassthrough,
            additionalSupportedModels: additionalSupportedModels
        )
        request["stream"] = true
        request["store"] = false
        if request["instructions"] == nil {
            request["instructions"] = ""
        }
        request["parallel_tool_calls"] = (payload["parallel_tool_calls"] as? Bool) ?? true

        var include = payload["include"] as? [String] ?? []
        if !include.contains("reasoning.encrypted_content") {
            include.append("reasoning.encrypted_content")
        }
        request["include"] = include

        let originalReasoning = payload["reasoning"] as? [String: Any] ?? [:]
        request["reasoning"] = [
            "effort": originalReasoning["effort"] as? String ?? "medium",
            "summary": originalReasoning["summary"] as? String ?? "auto",
        ]

        request["input"] = self.normalizeResponsesInput(payload["input"])
        request.removeValue(forKey: "metadata")
        return request
    }

    public static func upstreamChatCompletionsRequest(
        from normalizedRequest: [String: Any],
        upstreamModel: String,
        stream: Bool
    ) -> [String: Any] {
        self.upstreamChatCompletionsRequestWithDiagnostics(
            from: normalizedRequest,
            upstreamModel: upstreamModel,
            stream: stream
        ).request
    }

    public static func upstreamChatCompletionsRequestWithDiagnostics(
        from normalizedRequest: [String: Any],
        upstreamModel: String,
        stream: Bool
    ) -> (request: [String: Any], diagnostics: ChatCompletionsRequestBuildDiagnostics) {
        var messages: [[String: Any]] = []
        var lastAssistantMessageIndex: Int?
        var pendingReasoningContent: String?
        var diagnostics = ChatCompletionsRequestBuildDiagnostics()
        let instructions = (normalizedRequest["instructions"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !instructions.isEmpty {
            messages.append([
                "role": "system",
                "content": instructions,
            ])
        }

        for item in self.sanitizedChatCompletionToolHistory(
            normalizedRequest["input"] as? [[String: Any]] ?? []
        ) {
            let type = item["type"] as? String ?? ""
            switch type {
            case "reasoning":
                if let extracted = self.reasoningContentWithSource(fromOutputItem: item) {
                    switch extracted.source {
                    case .encryptedContent:
                        diagnostics.encryptedContentReasoningCount += 1
                    case .direct:
                        diagnostics.directReasoningContentCount += 1
                    case .summary:
                        diagnostics.summaryReasoningContentCount += 1
                    case .content:
                        diagnostics.contentReasoningCount += 1
                    }
                    pendingReasoningContent = self.joinReasoningContent(
                        pendingReasoningContent,
                        extracted.content
                    )
                }
            case "message":
                let role = ((item["role"] as? String) ?? "user").lowercased()
                let chatRole = self.chatCompletionRole(for: role)
                var message: [String: Any] = [
                    "role": chatRole,
                    "content": self.chatCompletionMessageContentValue(
                        from: item["content"],
                        chatRole: chatRole
                    ),
                ]
                if chatRole == "assistant" {
                    if let reasoningContent = self.trimmedString(item["reasoning_content"])
                        ?? pendingReasoningContent
                    {
                        if self.trimmedString(item["reasoning_content"]) != nil {
                            diagnostics.assistantItemReasoningContentCount += 1
                        }
                        message["reasoning_content"] = reasoningContent
                        pendingReasoningContent = nil
                    }
                }
                messages.append(message)
                lastAssistantMessageIndex = chatRole == "assistant" ? messages.indices.last : nil
            case "function_call_output":
                let callID = (item["call_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !callID.isEmpty else { continue }
                messages.append([
                    "role": "tool",
                    "tool_call_id": callID,
                    "content": self.stringValue(item["output"]),
                ])
                lastAssistantMessageIndex = nil
            case "function_call":
                let callID = (item["call_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "tool"
                guard !callID.isEmpty else { continue }
                let toolCall: [String: Any] = [
                    "id": callID,
                    "type": "function",
                    "function": [
                        "name": name,
                        "arguments": self.stringValue(item["arguments"]),
                    ],
                ]
                let reasoningContent = self.trimmedString(item["reasoning_content"])
                    ?? pendingReasoningContent
                if self.trimmedString(item["reasoning_content"]) != nil {
                    diagnostics.assistantItemReasoningContentCount += 1
                }
                if let assistantIndex = lastAssistantMessageIndex,
                   ((messages[assistantIndex]["role"] as? String) ?? "") == "assistant"
                {
                    var toolCalls = messages[assistantIndex]["tool_calls"] as? [[String: Any]] ?? []
                    toolCalls.append(toolCall)
                    messages[assistantIndex]["tool_calls"] = toolCalls
                    if messages[assistantIndex]["reasoning_content"] == nil,
                       let reasoningContent
                    {
                        messages[assistantIndex]["reasoning_content"] = reasoningContent
                    }
                } else {
                    var message: [String: Any] = [
                        "role": "assistant",
                        "content": "",
                        "tool_calls": [toolCall],
                    ]
                    if let reasoningContent {
                        message["reasoning_content"] = reasoningContent
                    }
                    messages.append(message)
                    lastAssistantMessageIndex = messages.indices.last
                }
                if reasoningContent != nil {
                    pendingReasoningContent = nil
                }
            default:
                continue
            }
        }

        var request: [String: Any] = [
            "model": upstreamModel,
            "messages": messages,
            "stream": stream,
        ]
        if let maxTokens = normalizedRequest["max_output_tokens"] {
            request["max_tokens"] = maxTokens
        } else if let maxTokens = normalizedRequest["max_tokens"] {
            request["max_tokens"] = maxTokens
        }
        if let temperature = normalizedRequest["temperature"] {
            request["temperature"] = temperature
        }
        if let topP = normalizedRequest["top_p"] {
            request["top_p"] = topP
        }
        if let user = normalizedRequest["user"] {
            request["user"] = user
        }
        if let tools = self.chatCompletionTools(from: normalizedRequest["tools"]), !tools.isEmpty {
            request["tools"] = tools
        }
        if let toolChoice = self.chatCompletionToolChoice(from: normalizedRequest["tool_choice"]) {
            request["tool_choice"] = toolChoice
        }
        if let thinking = normalizedRequest["thinking"] {
            request["thinking"] = thinking
        }
        return (request, diagnostics)
    }

    private struct PendingChatToolCallGroup {
        var reasoningItems: [[String: Any]]
        var calls: [[String: Any]] = []
        var outputs: [[String: Any]] = []
        var deferredItems: [[String: Any]] = []
        var callIDs: Set<String> = []
        var outputIDs: Set<String> = []
        var hasStartedOutputs = false
    }

    private static func sanitizedChatCompletionToolHistory(_ input: [[String: Any]]) -> [[String: Any]] {
        guard input.isEmpty == false else {
            return input
        }

        var result: [[String: Any]] = []
        var pendingReasoningItems: [[String: Any]] = []
        var pendingGroup: PendingChatToolCallGroup?
        var emittedCallIDs: Set<String> = []
        var emittedOutputIDs: Set<String> = []

        func flushPendingReasoning() {
            guard pendingReasoningItems.isEmpty == false else { return }
            result.append(contentsOf: pendingReasoningItems)
            pendingReasoningItems.removeAll()
        }

        func emitPendingGroupIfComplete() {
            guard let group = pendingGroup,
                  group.callIDs.isEmpty == false,
                  group.callIDs == group.outputIDs
            else {
                return
            }
            let outputsByCallID = Dictionary(
                uniqueKeysWithValues: group.outputs.compactMap { output -> (String, [String: Any])? in
                    let callID = (output["call_id"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard callID.isEmpty == false else { return nil }
                    return (callID, output)
                }
            )
            let orderedOutputs = group.calls.compactMap { call -> [String: Any]? in
                let callID = (call["call_id"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return outputsByCallID[callID]
            }
            result.append(contentsOf: group.reasoningItems)
            result.append(contentsOf: group.calls)
            result.append(contentsOf: orderedOutputs)
            result.append(contentsOf: group.deferredItems)
            emittedCallIDs.formUnion(group.callIDs)
            emittedOutputIDs.formUnion(group.outputIDs)
            pendingGroup = nil
        }

        func dropPendingGroup() {
            pendingGroup = nil
        }

        func hasFutureOutput(for callIDs: Set<String>, after itemIndex: Int) -> Bool {
            guard callIDs.isEmpty == false else { return false }
            var scan = itemIndex + 1
            while scan < input.count {
                let item = input[scan]
                let type = (item["type"] as? String ?? "").lowercased()
                if type == "function_call_output",
                   let callID = (item["call_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   callIDs.contains(callID)
                {
                    return true
                }
                if self.isChatCompletionSystemMessage(item) {
                    scan += 1
                    continue
                }
                if type != "function_call_output" {
                    return false
                }
                scan += 1
            }
            return false
        }

        for (itemIndex, item) in input.enumerated() {
            let type = (item["type"] as? String ?? "").lowercased()
            if self.isChatCompletionSystemMessage(item) {
                if let group = pendingGroup {
                    if hasFutureOutput(for: group.callIDs.subtracting(group.outputIDs), after: itemIndex) {
                        pendingGroup?.deferredItems.append(item)
                    } else {
                        dropPendingGroup()
                        flushPendingReasoning()
                        result.append(item)
                    }
                } else {
                    flushPendingReasoning()
                    result.append(item)
                }
                continue
            }

            switch type {
            case "reasoning":
                if pendingGroup != nil {
                    pendingGroup?.reasoningItems.append(item)
                } else {
                    pendingReasoningItems.append(item)
                }

            case "function_call":
                let callID = (item["call_id"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard callID.isEmpty == false else { continue }
                if emittedCallIDs.contains(callID) {
                    pendingReasoningItems.removeAll()
                    continue
                }
                if pendingGroup?.hasStartedOutputs == true {
                    dropPendingGroup()
                }
                if pendingGroup == nil {
                    pendingGroup = PendingChatToolCallGroup(reasoningItems: pendingReasoningItems)
                    pendingReasoningItems.removeAll()
                }
                guard pendingGroup?.callIDs.contains(callID) == false else { continue }
                pendingGroup?.calls.append(item)
                pendingGroup?.callIDs.insert(callID)

            case "function_call_output":
                let callID = (item["call_id"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard callID.isEmpty == false else { continue }
                guard emittedOutputIDs.contains(callID) == false else { continue }
                guard pendingGroup?.callIDs.contains(callID) == true else { continue }
                guard pendingGroup?.outputIDs.contains(callID) == false else { continue }
                pendingGroup?.outputs.append(item)
                pendingGroup?.outputIDs.insert(callID)
                pendingGroup?.hasStartedOutputs = true
                emitPendingGroupIfComplete()

            case "message":
                dropPendingGroup()
                flushPendingReasoning()
                result.append(item)

            default:
                dropPendingGroup()
                flushPendingReasoning()
            }
        }

        flushPendingReasoning()
        return result
    }

    private static func isChatCompletionSystemMessage(_ item: [String: Any]) -> Bool {
        guard ((item["type"] as? String) ?? "").lowercased() == "message" else {
            return false
        }
        let role = ((item["role"] as? String) ?? "").lowercased()
        return role == "system" || role == "developer"
    }

    static func sanitizedTrailingToolHistory(_ input: [[String: Any]]) -> [[String: Any]] {
        guard input.isEmpty == false else {
            return input
        }

        var trimStartIndex = input.count

        for index in input.indices.reversed() {
            let item = input[index]
            let type = item["type"] as? String ?? ""

            switch type {
            case "function_call_output":
                return trimStartIndex < input.count ? Array(input[..<trimStartIndex]) : input

            case "function_call":
                let callID = (item["call_id"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard callID.isEmpty == false else {
                    trimStartIndex = index
                    continue
                }
                trimStartIndex = index

            default:
                return trimStartIndex < input.count ? Array(input[..<trimStartIndex]) : input
            }
        }

        return trimStartIndex < input.count ? Array(input[..<trimStartIndex]) : input
    }

    public static func completedResponse(
        fromChatCompletion payload: [String: Any],
        requestedModel: String,
        input: Any? = nil
    ) -> [String: Any] {
        let choice = (payload["choices"] as? [[String: Any]])?.first ?? [:]
        let message = choice["message"] as? [String: Any] ?? [:]
        let text = self.chatCompletionMessageText(from: message["content"])
        let reasoningContent = self.trimmedString(message["reasoning_content"])
        let toolCalls = message["tool_calls"] as? [[String: Any]] ?? []
        var output: [[String: Any]] = []
        if let reasoningContent {
            output.append(self.reasoningOutputItem(reasoningContent))
        }
        if !text.isEmpty {
            let messageItem: [String: Any] = [
                "id": "msg_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
                "type": "message",
                "role": "assistant",
                "content": [[
                    "type": "output_text",
                    "text": text,
                ]],
            ]
            output.append(messageItem)
        }
        for toolCall in toolCalls {
            let function = toolCall["function"] as? [String: Any] ?? [:]
            let callID = (toolCall["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            let functionItem: [String: Any] = [
                "type": "function_call",
                "id": callID,
                "call_id": callID,
                "name": function["name"] as? String ?? "tool",
                "arguments": function["arguments"] as? String ?? "",
            ]
            output.append(functionItem)
        }

        let usage = self.extractUsage(from: payload["usage"])
        var response: [String: Any] = [
            "id": "resp_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
            "object": "response",
            "created_at": self.int64Value(payload["created"]) ?? Helpers.now(),
            "status": "completed",
            "model": requestedModel,
            "output": output,
            "usage": self.completedUsageObject(usage),
        ]
        if let input {
            response["input"] = input
        }
        return response
    }

    public static func responseSSEChunks(
        fromChatCompletionEvent event: SSEEvent,
        state: inout OpenAIChatSyntheticStreamState,
        requestedModel: String,
        input: Any? = nil
    ) throws -> [String] {
        let trimmedData = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !state.isCompleted else { return [] }
        if trimmedData == "[DONE]" {
            let chunks = self.finalizeResponseSSEChunks(
                fromChatCompletionState: state,
                requestedModel: requestedModel,
                input: input
            )
            state.isCompleted = true
            return chunks
        }
        guard let json = self.jsonObject(from: event) else { return [] }

        if let createdAt = self.int64Value(json["created"]) {
            state.createdAt = createdAt
        }
        let usage = self.extractUsage(from: json["usage"])
        if usage.inputTokens > 0 {
            state.inputTokens = usage.inputTokens
        }
        if usage.outputTokens > 0 {
            state.outputTokens = usage.outputTokens
        }
        if let cacheHitTokens = usage.cacheHitTokens {
            state.cacheHitTokens = cacheHitTokens
        }

        let choice = (json["choices"] as? [[String: Any]])?.first ?? [:]
        let delta = choice["delta"] as? [String: Any] ?? [:]
        var chunks: [String] = []
        chunks.append(contentsOf: self.initialSyntheticResponseSSEChunks(
            state: &state,
            requestedModel: requestedModel,
            input: input
        ))

        let textDelta = self.chatCompletionMessageText(from: delta["content"])
        if !textDelta.isEmpty {
            if !state.textItemAdded {
                state.textItemAdded = true
                chunks.append(
                    self.sseData([
                        "type": "response.output_item.added",
                        "output_index": 0,
                        "item": [
                            "id": state.textItemID,
                            "type": "message",
                            "role": "assistant",
                            "content": [],
                        ],
                    ])
                )
            }
            if !state.textContentPartAdded {
                state.textContentPartAdded = true
                chunks.append(
                    self.sseData([
                        "type": "response.content_part.added",
                        "output_index": 0,
                        "content_index": 0,
                        "item_id": state.textItemID,
                        "part": [
                            "type": "output_text",
                            "text": "",
                        ],
                    ])
                )
            }
            state.textBuffer.append(textDelta)
            chunks.append(
                self.sseData([
                    "type": "response.output_text.delta",
                    "output_index": 0,
                    "content_index": 0,
                    "item_id": state.textItemID,
                    "delta": textDelta,
                ])
            )
        }
        if let reasoningDelta = delta["reasoning_content"] as? String, !reasoningDelta.isEmpty {
            if !state.reasoningItemAdded {
                state.reasoningItemAdded = true
                chunks.append(
                    self.sseData([
                        "type": "response.output_item.added",
                        "output_index": 0,
                        "item": [
                            "id": state.reasoningItemID,
                            "type": "reasoning",
                        ],
                    ])
                )
            }
            state.reasoningContentBuffer.append(reasoningDelta)
            chunks.append(
                self.sseData([
                    "type": "response.reasoning_summary_text.delta",
                    "item_id": state.reasoningItemID,
                    "output_index": 0,
                    "content_index": 0,
                    "delta": reasoningDelta,
                ])
            )
        }

        for toolCall in delta["tool_calls"] as? [[String: Any]] ?? [] {
            let index = self.intValue(toolCall["index"]) ?? 0
            var stateTool = state.toolCalls[index] ?? .init(index: index)
            if let callID = (toolCall["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !callID.isEmpty {
                stateTool.callID = callID
                stateTool.itemID = callID
            }
            let function = toolCall["function"] as? [String: Any] ?? [:]
            if let name = (function["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                stateTool.name = name
                stateTool.hasName = true
            }
            let argumentsDelta = function["arguments"] as? String ?? ""
            if !argumentsDelta.isEmpty {
                stateTool.argumentsBuffer.append(argumentsDelta)
            }
            chunks.append(contentsOf: self.syntheticToolCallChunks(
                state: &stateTool,
                latestArgumentsDelta: argumentsDelta
            ))
            state.toolCalls[index] = stateTool
        }
        return chunks
    }

    public static func finalizeResponseSSEChunks(
        fromChatCompletionState state: OpenAIChatSyntheticStreamState,
        requestedModel: String,
        input: Any? = nil
    ) -> [String] {
        guard !state.isCompleted else { return [] }
        var chunks: [String] = []
        var mutableState = state
        chunks.append(contentsOf: self.initialSyntheticResponseSSEChunks(
            state: &mutableState,
            requestedModel: requestedModel,
            input: input
        ))

        if mutableState.textContentPartAdded {
            if !mutableState.textBuffer.isEmpty {
                chunks.append(
                    self.sseData([
                        "type": "response.output_text.done",
                        "output_index": 0,
                        "content_index": 0,
                        "item_id": mutableState.textItemID,
                        "text": mutableState.textBuffer,
                    ])
                )
            }
            chunks.append(
                self.sseData([
                    "type": "response.content_part.done",
                    "output_index": 0,
                    "content_index": 0,
                    "item_id": mutableState.textItemID,
                    "part": [
                        "type": "output_text",
                        "text": mutableState.textBuffer,
                    ],
                ])
            )
        }
        if mutableState.textItemAdded {
            chunks.append(
                self.sseData([
                    "type": "response.output_item.done",
                    "output_index": 0,
                    "item": [
                        "id": mutableState.textItemID,
                        "type": "message",
                        "role": "assistant",
                        "content": mutableState.textBuffer.isEmpty ? [] : [[
                            "type": "output_text",
                            "text": mutableState.textBuffer,
                        ]],
                    ],
                ])
            )
        }
        if mutableState.reasoningItemAdded {
            chunks.append(
                self.sseData([
                    "type": "response.reasoning_summary_text.done",
                    "item_id": mutableState.reasoningItemID,
                    "output_index": 0,
                    "content_index": 0,
                    "text": mutableState.reasoningContentBuffer,
                ])
            )
            chunks.append(
                self.sseData([
                    "type": "response.output_item.done",
                    "output_index": 0,
                    "item": self.reasoningOutputItem(
                        mutableState.reasoningContentBuffer,
                        id: mutableState.reasoningItemID
                    ),
                ])
            )
        }

        for index in mutableState.toolCalls.keys.sorted() {
            guard var tool = mutableState.toolCalls[index] else { continue }
            if !tool.added {
                chunks.append(contentsOf: self.syntheticToolCallChunks(
                    state: &tool,
                    latestArgumentsDelta: nil,
                    forceAdded: true
                ))
            }
            guard tool.added else { continue }
            mutableState.toolCalls[index] = tool
            chunks.append(
                self.sseData([
                    "type": "response.function_call_arguments.done",
                    "output_index": tool.outputIndex,
                    "item_id": tool.itemID,
                    "arguments": tool.argumentsBuffer,
                ])
            )
            chunks.append(
                self.sseData([
                    "type": "response.output_item.done",
                    "output_index": tool.outputIndex,
                    "item": [
                        "id": tool.itemID,
                        "type": "function_call",
                        "call_id": tool.callID,
                        "name": tool.name,
                        "arguments": tool.argumentsBuffer,
                    ],
                ])
            )
        }

        chunks.append(
            self.sseData([
                "type": "response.completed",
                "response": self.completedResponse(
                    fromChatCompletionState: mutableState,
                    requestedModel: requestedModel,
                    input: input
                ),
            ])
        )
        chunks.append("data: [DONE]\n\n")
        return chunks
    }

    public static func chatCompletionFromCompletedResponse(
        completedResponse: [String: Any],
        requestedModel: String
    ) -> [String: Any] {
        let responseID = completedResponse["id"] as? String ?? "chatcmpl_\(UUID().uuidString)"
        let createdAt = Int((completedResponse["created_at"] as? Int64) ?? Helpers.now())
        let usage = self.extractUsage(from: completedResponse["usage"])
        let output = completedResponse["output"] as? [[String: Any]] ?? []
        let assistantText = self.extractAssistantText(from: completedResponse)
        let reasoningContent = self.extractReasoningContent(from: completedResponse)
        let toolCalls = output.compactMap { item -> [String: Any]? in
            guard (item["type"] as? String) == "function_call" else { return nil }
            let callID = (item["call_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
            return [
                "id": callID,
                "type": "function",
                "function": [
                    "name": item["name"] as? String ?? "tool",
                    "arguments": item["arguments"] as? String ?? "",
                ],
            ]
        }
        let messageContent: Any = assistantText.isEmpty && !toolCalls.isEmpty ? NSNull() : assistantText
        let messageToolCalls: Any = toolCalls.isEmpty ? NSNull() : toolCalls
        let finishReason = toolCalls.isEmpty ? "stop" : "tool_calls"
        var message: [String: Any] = [
            "role": "assistant",
            "content": messageContent,
            "tool_calls": messageToolCalls,
        ]
        if let reasoningContent {
            message["reasoning_content"] = reasoningContent
        }
        var response: [String: Any] = [
            "id": responseID,
            "object": "chat.completion",
            "created": createdAt,
            "model": requestedModel,
            "choices": [[
                "index": 0,
                "message": message,
                "finish_reason": finishReason,
            ]],
        ]
        response["usage"] = self.chatCompletionUsageObject(usage)
        return response
    }

    public static func usageFromCompletedResponse(_ completedResponse: [String: Any]) -> UpstreamUsage {
        self.extractUsage(from: completedResponse["usage"])
    }

    public static func hasRecognizableUsage(in completedResponse: [String: Any]) -> Bool {
        self.hasRecognizableUsage(inUsageObject: completedResponse["usage"])
    }

    public static func hasRecognizableUsage(inUsageObject value: Any?) -> Bool {
        guard let usage = value as? [String: Any] else {
            return false
        }
        return self.int64Value(usage["input_tokens"]) != nil
            || self.int64Value(usage["prompt_tokens"]) != nil
            || self.int64Value(usage["output_tokens"]) != nil
            || self.int64Value(usage["completion_tokens"]) != nil
            || self.int64Value(usage["total_tokens"]) != nil
    }

    public static func normalizedAnthropicUsageObject(_ value: Any?) -> [String: Any]? {
        guard var usage = value as? [String: Any] else {
            return nil
        }

        let cacheReadTokens = self.anthropicCacheReadInputTokens(from: usage)
        if let cacheReadTokens, cacheReadTokens >= 0 {
            usage["cache_read_input_tokens"] = cacheReadTokens
            if usage["cached_tokens"] == nil {
                usage["cached_tokens"] = cacheReadTokens
            }
        }
        if usage["cache_creation_input_tokens"] == nil,
           let cacheCreationTokens = self.anthropicCacheCreationInputTokens(from: usage),
           cacheCreationTokens >= 0
        {
            usage["cache_creation_input_tokens"] = cacheCreationTokens
        }
        return usage
    }

    public static func usageFromAnthropicUsage(_ value: Any?) -> UpstreamUsage {
        guard let usage = self.normalizedAnthropicUsageObject(value) else {
            return .init()
        }

        let rawInput = self.int64Value(usage["input_tokens"])
            ?? self.int64Value(usage["prompt_tokens"])
            ?? 0
        let output = self.int64Value(usage["output_tokens"])
            ?? self.int64Value(usage["completion_tokens"])
            ?? 0
        let cacheHitTokens = self.anthropicCacheReadInputTokens(from: usage)
        let cacheCreationTokens = self.anthropicCacheCreationInputTokens(from: usage) ?? 0
        let input = rawInput + (cacheHitTokens ?? 0) + cacheCreationTokens

        return UpstreamUsage(
            inputTokens: input,
            outputTokens: output,
            totalTokens: input + output,
            cacheHitTokens: cacheHitTokens
        )
    }

    public static func extractAssistantText(from completedResponse: [String: Any]) -> String {
        guard let output = completedResponse["output"] as? [[String: Any]] else { return "" }
        var parts: [String] = []
        for item in output where (item["type"] as? String) == "message" {
            let content = item["content"] as? [[String: Any]] ?? []
            for contentPart in content where (contentPart["type"] as? String) == "output_text" {
                if let text = contentPart["text"] as? String {
                    parts.append(text)
                }
            }
        }
        return parts.joined()
    }

    public static func extractReasoningContent(from completedResponse: [String: Any]) -> String? {
        guard let output = completedResponse["output"] as? [[String: Any]] else { return nil }
        let parts = output.compactMap { item -> String? in
            guard (item["type"] as? String) == "reasoning" else { return nil }
            return self.reasoningContent(fromOutputItem: item)
        }
        let joined = parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    public static func extractAssistantText(from events: [SSEEvent]) -> String {
        var parts: [String] = []
        for event in events {
            guard
                let data = event.data.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let type = json["type"] as? String,
                type == "response.output_text.delta",
                let delta = json["delta"] as? String
            else {
                continue
            }
            parts.append(delta)
        }
        return parts.joined()
    }

    public static func completedResponseByEnsuringAssistantText(
        _ completedResponse: [String: Any],
        fallbackText: String
    ) -> [String: Any] {
        guard self.extractAssistantText(from: completedResponse).isEmpty else {
            return completedResponse
        }

        let trimmed = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return completedResponse
        }

        var response = completedResponse
        response["output"] = [[
            "type": "message",
            "role": "assistant",
            "content": [[
                "type": "output_text",
                "text": trimmed,
            ]],
        ]]
        return response
    }

    public static func chatCompletionSSEChunks(
        from event: SSEEvent,
        streamState: inout ChatStreamState,
        requestedModel: String
    ) -> [String] {
        guard let data = event.data.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String
        else {
            return []
        }

        switch type {
        case "response.created":
            if let response = json["response"] as? [String: Any] {
                streamState.responseID = response["id"] as? String ?? "chatcmpl_\(UUID().uuidString)"
                streamState.createdAt = (response["created_at"] as? Int64) ?? Helpers.now()
            }
            let chunk: [String: Any] = [
                "id": streamState.responseID,
                "object": "chat.completion.chunk",
                "created": streamState.createdAt,
                "model": requestedModel,
                "choices": [[
                    "index": 0,
                    "delta": ["role": "assistant"],
                    "finish_reason": NSNull(),
                ]],
            ]
            return [self.sseData(chunk)]
        case "response.output_item.added",
             "response.function_call_arguments.delta",
             "response.function_call_arguments.done":
            guard let functionCall = self.upstreamFunctionCallEvent(from: json) else {
                return []
            }
            return self.chatCompletionToolCallSSEChunks(from: functionCall, streamState: &streamState, requestedModel: requestedModel)
        case "response.output_text.delta":
            let delta = json["delta"] as? String ?? ""
            let chunk: [String: Any] = [
                "id": streamState.responseID,
                "object": "chat.completion.chunk",
                "created": streamState.createdAt,
                "model": requestedModel,
                "choices": [[
                    "index": 0,
                    "delta": ["content": delta],
                    "finish_reason": NSNull(),
                ]],
            ]
            return [self.sseData(chunk)]
        case "response.reasoning_summary_text.delta":
            let delta = json["delta"] as? String ?? ""
            let chunk: [String: Any] = [
                "id": streamState.responseID,
                "object": "chat.completion.chunk",
                "created": streamState.createdAt,
                "model": requestedModel,
                "choices": [[
                    "index": 0,
                    "delta": ["reasoning_content": delta],
                    "finish_reason": NSNull(),
                ]],
            ]
            return [self.sseData(chunk)]
        case "response.completed":
            let response = json["response"] as? [String: Any] ?? [:]
            let usage = self.extractUsage(from: response["usage"])
            let finishReason = ((response["output"] as? [[String: Any]]) ?? []).contains(where: {
                ($0["type"] as? String) == "function_call"
            }) ? "tool_calls" : "stop"
            var done: [String: Any] = [
                "id": streamState.responseID,
                "object": "chat.completion.chunk",
                "created": streamState.createdAt,
                "model": requestedModel,
                "choices": [[
                    "index": 0,
                    "delta": [:],
                    "finish_reason": finishReason,
                ]],
            ]
            done["usage"] = self.chatCompletionUsageObject(usage)
            return [self.sseData(done), "data: [DONE]\n\n"]
        default:
            return []
        }
    }

    public static func responsesSSEChunks(from event: SSEEvent) -> [String] {
        ["data: \(event.data)\n\n"]
    }

    public static func responseCreatedSSEChunk(
        responseID: String,
        createdAt: Int64,
        requestedModel: String
    ) -> String {
        self.sseData([
            "type": "response.created",
            "response": [
                "id": responseID,
                "object": "response",
                "created_at": createdAt,
                "status": "in_progress",
                "model": requestedModel,
            ],
        ])
    }

    public static func responseFailedSSEChunk(
        responseID: String,
        createdAt: Int64,
        requestedModel: String,
        message: String
    ) -> String {
        self.sseData([
            "type": "response.failed",
            "response": [
                "id": responseID,
                "object": "response",
                "created_at": createdAt,
                "status": "failed",
                "model": requestedModel,
                "error": [
                    "message": message,
                    "type": "server_error",
                ],
            ],
        ])
    }

    public static func extractCompletedResponse(from events: [SSEEvent]) -> [String: Any]? {
        for event in events.reversed() {
            guard let data = event.data.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (json["type"] as? String) == "response.completed"
            else {
                continue
            }
            return json["response"] as? [String: Any]
        }
        return nil
    }

    public static func decodeSSE(_ bytes: Data) -> [SSEEvent] {
        let text = String(decoding: bytes, as: UTF8.self)
        return text
            .components(separatedBy: "\n\n")
            .compactMap { block in
                let lines = block.split(separator: "\n")
                guard !lines.isEmpty else { return nil }
                let dataLines = lines.compactMap { line -> String? in
                    guard line.hasPrefix("data:") else { return nil }
                    return String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                }
                let eventLine = lines.first(where: { $0.hasPrefix("event:") }).map {
                    String($0.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                }
                guard !dataLines.isEmpty else { return nil }
                return SSEEvent(event: eventLine, data: dataLines.joined(separator: "\n"))
            }
    }

    static func messageTextContentType(for role: String) -> String {
        role.lowercased() == "assistant" ? "output_text" : "input_text"
    }

    static func textContentBlock(text: String, role: String) -> [String: Any] {
        [
            "type": self.messageTextContentType(for: role),
            "text": text,
        ]
    }

    static func normalizeMessageContent(_ content: Any?, role: String) -> [[String: Any]] {
        let normalizedRole = role.lowercased()
        if let text = content as? String {
            return [self.textContentBlock(text: text, role: normalizedRole)]
        }
        if let array = content as? [[String: Any]] {
            return array.compactMap { item -> [String: Any]? in
                if let type = item["type"] as? String, type == "text" {
                    return self.textContentBlock(text: item["text"] as? String ?? "", role: normalizedRole)
                }

                if let type = item["type"] as? String, type == "input_text" {
                    guard normalizedRole == "assistant" else {
                        return item
                    }
                    var converted = item
                    converted["type"] = "output_text"
                    return converted
                }

                if let type = item["type"] as? String, type == "output_text" || type == "refusal" {
                    return item
                }

                if let type = item["type"] as? String, type == "image_url",
                   let imageURL = self.chatCompletionImageURLObject(from: item),
                   let url = imageURL["url"] as? String
                {
                    var converted: [String: Any] = [
                        "type": "input_image",
                        "image_url": url,
                    ]
                    if let detail = imageURL["detail"] {
                        converted["detail"] = detail
                    }
                    return converted
                }

                if let type = item["type"] as? String, type == "input_image" || type == "input_file" {
                    return item
                }

                return nil
            }
        }
        return [self.textContentBlock(text: "", role: normalizedRole)]
    }

    private static func normalizeResponsesInput(_ input: Any?) -> Any {
        if let text = input as? String {
            return [
                [
                    "type": "message",
                    "role": "user",
                    "content": self.normalizeMessageContent(text, role: "user"),
                ]
            ]
        }

        if let items = input as? [[String: Any]] {
            return items.map { item in
                if (item["type"] as? String) == "message" {
                    var normalized = item
                    let role = (item["role"] as? String) ?? "user"
                    normalized["role"] = role
                    normalized["content"] = self.normalizeMessageContent(item["content"], role: role)
                    return normalized
                }

                if item["role"] != nil, item["content"] != nil {
                    let role = (item["role"] as? String) ?? "user"
                    var normalized: [String: Any] = [
                        "type": "message",
                        "role": role,
                        "content": self.normalizeMessageContent(item["content"], role: role),
                    ]
                    if let reasoningContent = self.trimmedString(item["reasoning_content"]) {
                        normalized["reasoning_content"] = reasoningContent
                    }
                    return normalized
                }

                return item
            }
        }

        return input ?? [
            [
                "type": "message",
                "role": "user",
                "content": self.normalizeMessageContent("", role: "user"),
            ]
        ]
    }

    private static func stringifyMessageContent(_ content: Any?) -> String {
        if let content = content as? String {
            return content
        }
        if let content = content as? [Any],
           let data = try? JSONSerialization.data(withJSONObject: content) {
            return String(decoding: data, as: UTF8.self)
        }
        if let content = content as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: content) {
            return String(decoding: data, as: UTF8.self)
        }
        return ""
    }

    private static func chatCompletionRole(for role: String) -> String {
        switch role {
        case "developer", "system":
            return "system"
        case "assistant":
            return "assistant"
        default:
            return "user"
        }
    }

    private static func chatCompletionMessageContent(from content: Any?) -> String {
        if let text = content as? String {
            return text
        }
        let blocks = content as? [[String: Any]] ?? self.normalizeMessageContent(content, role: "user")
        let text = blocks.compactMap { block -> String? in
            let type = (block["type"] as? String)?.lowercased() ?? ""
            switch type {
            case "input_text", "output_text", "text":
                return block["text"] as? String
            case "refusal":
                return block["refusal"] as? String ?? block["text"] as? String
            default:
                return nil
            }
        }
        .joined()
        return text
    }

    private static func chatCompletionMessageContentValue(from content: Any?, chatRole: String) -> Any {
        guard chatRole == "user",
              let multimodalContent = self.chatCompletionMultimodalMessageContent(from: content)
        else {
            return self.chatCompletionMessageContent(from: content)
        }
        return multimodalContent
    }

    private static func chatCompletionMultimodalMessageContent(from content: Any?) -> [[String: Any]]? {
        let blocks = content as? [[String: Any]] ?? self.normalizeMessageContent(content, role: "user")
        var parts: [[String: Any]] = []
        var hasImage = false

        for block in blocks {
            let type = (block["type"] as? String)?.lowercased() ?? ""
            switch type {
            case "input_text", "output_text", "text":
                let text = block["text"] as? String ?? ""
                guard !text.isEmpty else { continue }
                parts.append([
                    "type": "text",
                    "text": text,
                ])
            case "refusal":
                let text = (block["refusal"] as? String) ?? (block["text"] as? String) ?? ""
                guard !text.isEmpty else { continue }
                parts.append([
                    "type": "text",
                    "text": text,
                ])
            case "input_image", "image_url":
                guard let imageURL = self.chatCompletionImageURLObject(from: block) else {
                    continue
                }
                hasImage = true
                parts.append([
                    "type": "image_url",
                    "image_url": imageURL,
                ])
            default:
                continue
            }
        }

        return hasImage ? parts : nil
    }

    private static func chatCompletionImageURLObject(from block: [String: Any]) -> [String: Any]? {
        var imageURL: [String: Any] = [:]
        if let object = block["image_url"] as? [String: Any] {
            imageURL = object
        } else if let object = block["image_url"] as? [String: String] {
            imageURL = object.reduce(into: [String: Any]()) { partial, item in
                partial[item.key] = item.value
            }
        } else if let url = block["image_url"] as? String {
            imageURL["url"] = url
        }

        if imageURL["url"] == nil, let url = block["url"] as? String {
            imageURL["url"] = url
        }

        guard let url = self.trimmedString(imageURL["url"]) else {
            return nil
        }
        imageURL["url"] = url

        if imageURL["detail"] == nil, let detail = block["detail"] {
            imageURL["detail"] = detail
        }
        return imageURL
    }

    private static func chatCompletionMessageText(from content: Any?) -> String {
        if let text = content as? String {
            return text
        }
        if let array = content as? [[String: Any]] {
            return array.compactMap { block -> String? in
                let type = (block["type"] as? String)?.lowercased() ?? ""
                switch type {
                case "text", "output_text", "input_text":
                    return block["text"] as? String
                case "refusal":
                    return block["refusal"] as? String ?? block["text"] as? String
                default:
                    return nil
                }
            }
            .joined()
        }
        return ""
    }

    private static func reasoningOutputItem(_ text: String, id: String? = nil) -> [String: Any] {
        [
            "id": id ?? "reason_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
            "type": "reasoning",
            "encrypted_content": text,
            "content": [[
                "type": "output_text",
                "text": text,
            ]],
            "summary": [[
                "type": "summary_text",
                "text": text,
            ]],
        ]
    }

    private enum ReasoningContentSource {
        case encryptedContent
        case direct
        case summary
        case content
    }

    private static func reasoningContent(fromOutputItem item: [String: Any]) -> String? {
        self.reasoningContentWithSource(fromOutputItem: item)?.content
    }

    private static func reasoningContentWithSource(fromOutputItem item: [String: Any]) -> (content: String, source: ReasoningContentSource)? {
        if let encrypted = self.trimmedString(item["encrypted_content"]) {
            return (encrypted, .encryptedContent)
        }
        if let direct = self.trimmedString(item["reasoning_content"]) {
            return (direct, .direct)
        }
        var parts: [String] = []
        if let summary = item["summary"] as? [[String: Any]] {
            parts.append(contentsOf: summary.compactMap { block in
                let type = (block["type"] as? String)?.lowercased() ?? ""
                guard type == "summary_text" || type == "text" else { return nil }
                return self.trimmedString(block["text"])
            })
        }
        let summaryJoined = self.uniqueJoinedReasoningParts(parts)
        if summaryJoined.isEmpty == false {
            return (summaryJoined, .summary)
        }

        parts.removeAll()
        if let content = item["content"] as? [[String: Any]] {
            parts.append(contentsOf: content.compactMap { block in
                let type = (block["type"] as? String)?.lowercased() ?? ""
                guard ["output_text", "reasoning_text", "summary_text", "text"].contains(type) else {
                    return nil
                }
                return self.trimmedString(block["text"])
            })
        }
        let contentJoined = self.uniqueJoinedReasoningParts(parts)
        return contentJoined.isEmpty ? nil : (contentJoined, .content)
    }

    private static func uniqueJoinedReasoningParts(_ parts: [String]) -> String {
        var uniqueParts: [String] = []
        for part in parts {
            guard uniqueParts.contains(part) == false else { continue }
            uniqueParts.append(part)
        }
        return uniqueParts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func joinReasoningContent(_ lhs: String?, _ rhs: String?) -> String? {
        let parts = [lhs, rhs].compactMap {
            $0?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "\n\n")
    }

    private static func chatCompletionTools(from tools: Any?) -> [[String: Any]]? {
        guard let tools = tools as? [[String: Any]] else { return nil }
        let normalized = tools.compactMap { tool -> [String: Any]? in
            let type = (tool["type"] as? String)?.lowercased() ?? ""
            if type == "function", let function = tool["function"] as? [String: Any] {
                var normalizedFunction = function
                if normalizedFunction["description"] == nil {
                    normalizedFunction["description"] = ""
                }
                if normalizedFunction["parameters"] == nil {
                    normalizedFunction["parameters"] = [
                        "type": "object",
                        "properties": [:],
                    ]
                }
                return [
                    "type": "function",
                    "function": normalizedFunction,
                ]
            }
            if ["web_search", "code_interpreter", "file_search"].contains(type) {
                let name = ((tool["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                    $0.isEmpty ? nil : $0
                } ?? type
                let function: [String: Any] = [
                    "name": name,
                    "description": tool["description"] as? String ?? "\(type) tool",
                    "parameters": tool["parameters"] ?? [
                        "type": "object",
                        "properties": [
                            "query": [
                                "type": "string",
                                "description": "The search query",
                            ],
                        ],
                        "required": ["query"],
                    ],
                ]
                return [
                    "type": "function",
                    "function": function,
                ]
            }
            let name = (tool["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown_tool"
            let function: [String: Any] = [
                "name": name.isEmpty ? "unknown_tool" : name,
                "description": tool["description"] as? String ?? "",
                "parameters": tool["parameters"] ?? [
                    "type": "object",
                    "properties": [:],
                ],
            ]
            return [
                "type": "function",
                "function": function,
            ]
        }
        return normalized.isEmpty ? nil : normalized
    }

    private static func chatCompletionToolChoice(from toolChoice: Any?) -> Any? {
        if let toolChoice = toolChoice as? String {
            return toolChoice
        }
        guard let object = toolChoice as? [String: Any] else { return nil }
        if let function = object["function"] as? [String: Any] {
            return [
                "type": "function",
                "function": function,
            ]
        }
        let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return nil }
        return [
            "type": "function",
            "function": [
                "name": name,
            ],
        ]
    }

    public static func completedResponse(
        fromChatCompletionState state: OpenAIChatSyntheticStreamState,
        requestedModel: String,
        input: Any? = nil
    ) -> [String: Any] {
        var output: [[String: Any]] = []
        if state.reasoningItemAdded {
            output.append(self.reasoningOutputItem(state.reasoningContentBuffer))
        }
        if !state.textBuffer.isEmpty || !state.reasoningItemAdded {
            let messageItem: [String: Any] = [
                "id": state.textItemID,
                "type": "message",
                "role": "assistant",
                "content": [[
                    "type": "output_text",
                    "text": state.textBuffer,
                ]],
            ]
            output.append(messageItem)
        }
        for index in state.toolCalls.keys.sorted() {
            guard let tool = state.toolCalls[index], tool.added else { continue }
            let functionItem: [String: Any] = [
                "type": "function_call",
                "id": tool.itemID,
                "call_id": tool.callID,
                "name": tool.name,
                "arguments": tool.argumentsBuffer,
            ]
            output.append(functionItem)
        }
        let usage = UpstreamUsage(
            inputTokens: state.inputTokens,
            outputTokens: state.outputTokens,
            totalTokens: state.inputTokens + state.outputTokens,
            cacheHitTokens: state.cacheHitTokens
        )
        var response: [String: Any] = [
            "id": state.responseID,
            "object": "response",
            "created_at": state.createdAt,
            "status": "completed",
            "model": requestedModel,
            "output": output,
            "usage": self.completedUsageObject(usage),
        ]
        if let input {
            response["input"] = input
        }
        return response
    }

    private static func stringValue(_ value: Any?) -> String {
        if let string = value as? String {
            return string
        }
        if let array = value as? [Any], let data = try? JSONSerialization.data(withJSONObject: array) {
            return String(decoding: data, as: UTF8.self)
        }
        if let object = value as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: object) {
            return String(decoding: data, as: UTF8.self)
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return ""
    }

    private static func trimmedString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func mapClientModel(
        _ model: String,
        additionalSupportedModels: Set<String> = []
    ) throws -> String {
        try self.normalizeClientModel(
            model,
            additionalSupportedModels: additionalSupportedModels
        )
    }

    public static func isSupportedClientModel(
        _ model: String,
        additionalSupportedModels: Set<String> = []
    ) -> Bool {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        let normalized = self.requestModelMap[trimmed] ?? trimmed
        return self.supportedModels.contains(normalized)
            || additionalSupportedModels.contains(normalized)
            || additionalSupportedModels.contains(trimmed)
    }

    private static func normalizeClientModel(
        _ model: String,
        allowCustomModelPassthrough: Bool = false,
        additionalSupportedModels: Set<String> = []
    ) throws -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProxyError.message("不支持的模型 \(model)")
        }
        let normalized = self.requestModelMap[trimmed] ?? trimmed
        return normalized
    }

    private static func extractUsage(from value: Any?) -> UpstreamUsage {
        guard let usage = value as? [String: Any] else { return .init() }
        let input = self.int64Value(usage["input_tokens"])
            ?? self.int64Value(usage["prompt_tokens"])
            ?? 0
        let output = self.int64Value(usage["output_tokens"])
            ?? self.int64Value(usage["completion_tokens"])
            ?? 0
        let total = self.int64Value(usage["total_tokens"]) ?? (input + output)
        let cacheHitTokens = self.int64Value((usage["input_tokens_details"] as? [String: Any])?["cached_tokens"])
            ?? self.int64Value((usage["prompt_tokens_details"] as? [String: Any])?["cached_tokens"])
            ?? self.int64Value((usage["input_tokens_details"] as? [String: Any])?["cache_read_input_tokens"])
            ?? self.int64Value((usage["prompt_tokens_details"] as? [String: Any])?["cache_read_input_tokens"])
            ?? self.int64Value(usage["prompt_cache_hit_tokens"])
            ?? self.int64Value(usage["cache_read_input_tokens"])
            ?? self.int64Value(usage["cached_tokens"])
        return UpstreamUsage(
            inputTokens: input,
            outputTokens: output,
            totalTokens: total,
            cacheHitTokens: cacheHitTokens
        )
    }

    private static func anthropicCacheReadInputTokens(from usage: [String: Any]) -> Int64? {
        self.int64Value(usage["cache_read_input_tokens"])
            ?? self.int64Value(usage["cached_tokens"])
    }

    private static func anthropicCacheCreationInputTokens(from usage: [String: Any]) -> Int64? {
        if let value = self.int64Value(usage["cache_creation_input_tokens"]) {
            return value
        }
        guard let cacheCreation = usage["cache_creation"] as? [String: Any] else {
            return nil
        }
        let values = self.anthropicCacheCreationInputTokenValues(from: cacheCreation)
        guard values.isEmpty == false else {
            return nil
        }
        return values.reduce(0, +)
    }

    private static func anthropicCacheCreationInputTokenValues(from object: [String: Any]) -> [Int64] {
        var values: [Int64] = []
        for (key, value) in object {
            let normalizedKey = key.lowercased()
            if normalizedKey.contains("tokens"),
               let tokenValue = self.int64Value(value)
            {
                values.append(tokenValue)
                continue
            }
            if let nested = value as? [String: Any] {
                values.append(contentsOf: self.anthropicCacheCreationInputTokenValues(from: nested))
            }
        }
        return values
    }

    private static func completedUsageObject(_ usage: UpstreamUsage) -> [String: Any] {
        var object: [String: Any] = [
            "input_tokens": usage.inputTokens,
            "output_tokens": usage.outputTokens,
            "total_tokens": usage.totalTokens,
        ]
        if let cacheHitTokens = usage.cacheHitTokens {
            object["input_tokens_details"] = [
                "cached_tokens": cacheHitTokens,
            ]
        }
        return object
    }

    private static func chatCompletionUsageObject(_ usage: UpstreamUsage) -> [String: Any] {
        var object: [String: Any] = [
            "prompt_tokens": usage.inputTokens,
            "completion_tokens": usage.outputTokens,
            "total_tokens": usage.totalTokens,
        ]
        if let cacheHitTokens = usage.cacheHitTokens {
            object["prompt_tokens_details"] = [
                "cached_tokens": cacheHitTokens,
            ]
            object["prompt_cache_hit_tokens"] = cacheHitTokens
        }
        return object
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        switch value {
        case let intValue as Int64:
            return intValue
        case let intValue as Int:
            return Int64(intValue)
        case let number as NSNumber:
            return number.int64Value
        case let string as String:
            return Int64(string)
        default:
            return nil
        }
    }

    private static func syntheticToolCallChunks(
        state: inout OpenAIChatSyntheticToolCallState,
        latestArgumentsDelta: String?,
        forceAdded: Bool = false
    ) -> [String] {
        var chunks: [String] = []
        if !state.added {
            guard state.hasName || forceAdded else {
                return chunks
            }
            state.added = true
            chunks.append(
                self.sseData([
                    "type": "response.output_item.added",
                    "output_index": state.outputIndex,
                    "item": [
                        "id": state.itemID,
                        "type": "function_call",
                        "call_id": state.callID,
                        "name": state.name,
                        "arguments": "",
                    ],
                ])
            )
            let pendingArguments = String(state.argumentsBuffer.dropFirst(state.emittedArgumentsLength))
            if !pendingArguments.isEmpty {
                chunks.append(
                    self.sseData([
                        "type": "response.function_call_arguments.delta",
                        "output_index": state.outputIndex,
                        "item_id": state.itemID,
                        "delta": pendingArguments,
                    ])
                )
                state.emittedArgumentsLength = state.argumentsBuffer.count
            }
            return chunks
        }

        if let latestArgumentsDelta, !latestArgumentsDelta.isEmpty {
            chunks.append(
                self.sseData([
                    "type": "response.function_call_arguments.delta",
                    "output_index": state.outputIndex,
                    "item_id": state.itemID,
                    "delta": latestArgumentsDelta,
                ])
            )
            state.emittedArgumentsLength = state.argumentsBuffer.count
        }
        return chunks
    }

    private static func initialSyntheticResponseSSEChunks(
        state: inout OpenAIChatSyntheticStreamState,
        requestedModel: String,
        input: Any? = nil
    ) -> [String] {
        var chunks: [String] = []
        if !state.seenCreated {
            state.seenCreated = true
            chunks.append(
                self.sseData([
                    "type": "response.created",
                    "response": self.syntheticInProgressResponse(
                        state: state,
                        requestedModel: requestedModel,
                        input: input
                    ),
                ])
            )
        }
        if !state.seenInProgress {
            state.seenInProgress = true
            chunks.append(
                self.sseData([
                    "type": "response.in_progress",
                    "response": self.syntheticInProgressResponse(
                        state: state,
                        requestedModel: requestedModel,
                        input: input
                    ),
                ])
            )
        }
        return chunks
    }

    private static func syntheticInProgressResponse(
        state: OpenAIChatSyntheticStreamState,
        requestedModel: String,
        input: Any? = nil
    ) -> [String: Any] {
        var response: [String: Any] = [
            "id": state.responseID,
            "object": "response",
            "created_at": state.createdAt,
            "status": "in_progress",
            "model": requestedModel,
            "output": [],
        ]
        if let input {
            response["input"] = input
        }
        return response
    }

    private static func sseData(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data("{}".utf8)
        return "data: \(String(decoding: data, as: UTF8.self))\n\n"
    }

    private static func chatCompletionToolCallSSEChunks(
        from functionCall: UpstreamFunctionCallEvent,
        streamState: inout ChatStreamState,
        requestedModel: String
    ) -> [String] {
        let itemID = functionCall.itemID ?? "fc_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var state = streamState.toolCalls[itemID] ?? .init(
            index: functionCall.outputIndex ?? streamState.nextToolCallIndex,
            callID: functionCall.callID,
            name: functionCall.name ?? "tool",
            itemID: itemID
        )
        if let callID = functionCall.callID, !callID.isEmpty {
            state.callID = callID
        }
        if let name = functionCall.name, !name.isEmpty {
            state.name = name
        }
        if functionCall.phase == .delta, let delta = functionCall.delta {
            state.argumentsBuffer.append(delta)
        }
        if functionCall.phase == .argumentsDone, let arguments = functionCall.arguments {
            state.argumentsBuffer = arguments
        }
        streamState.toolCalls[itemID] = state
        streamState.nextToolCallIndex = max(streamState.nextToolCallIndex, state.index + 1)

        let baseChunk: [String: Any] = [
            "id": streamState.responseID,
            "object": "chat.completion.chunk",
            "created": streamState.createdAt,
            "model": requestedModel,
        ]

        switch functionCall.phase {
        case .added:
            var chunk = baseChunk
            chunk["choices"] = [[
                "index": 0,
                "delta": [
                    "tool_calls": [[
                        "index": state.index,
                        "id": state.callID,
                        "type": "function",
                        "function": [
                            "name": state.name,
                            "arguments": "",
                        ],
                    ]],
                ],
                "finish_reason": NSNull(),
            ]]
            return [self.sseData(chunk)]
        case .delta:
            guard let delta = functionCall.delta, !delta.isEmpty else { return [] }
            var chunk = baseChunk
            chunk["choices"] = [[
                "index": 0,
                "delta": [
                    "tool_calls": [[
                        "index": state.index,
                        "function": [
                            "arguments": delta,
                        ],
                    ]],
                ],
                "finish_reason": NSNull(),
            ]]
            return [self.sseData(chunk)]
        case .argumentsDone, .itemDone:
            return []
        }
    }
}

public struct ChatStreamState: Sendable {
    public var responseID: String
    public var createdAt: Int64
    public var toolCalls: [String: ChatCompletionToolCallState]
    public var nextToolCallIndex: Int

    public init(
        responseID: String = "chatcmpl_\(UUID().uuidString)",
        createdAt: Int64 = Helpers.now(),
        toolCalls: [String: ChatCompletionToolCallState] = [:],
        nextToolCallIndex: Int = 0
    ) {
        self.responseID = responseID
        self.createdAt = createdAt
        self.toolCalls = toolCalls
        self.nextToolCallIndex = nextToolCallIndex
    }
}

public struct ChatCompletionToolCallState: Sendable, Equatable {
    public var index: Int
    public var callID: String
    public var name: String
    public var itemID: String
    public var argumentsBuffer: String

    public init(
        index: Int,
        callID: String? = nil,
        name: String = "tool",
        itemID: String,
        argumentsBuffer: String = ""
    ) {
        self.index = index
        self.callID = callID ?? "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        self.name = name
        self.itemID = itemID
        self.argumentsBuffer = argumentsBuffer
    }
}

public struct OpenAIChatSyntheticToolCallState: Sendable, Equatable {
    public var index: Int
    public var outputIndex: Int
    public var itemID: String
    public var callID: String
    public var name: String
    public var argumentsBuffer: String
    public var emittedArgumentsLength: Int
    public var added: Bool
    public var hasName: Bool

    public init(
        index: Int,
        outputIndex: Int? = nil,
        itemID: String? = nil,
        callID: String? = nil,
        name: String = "tool",
        argumentsBuffer: String = "",
        emittedArgumentsLength: Int = 0,
        added: Bool = false,
        hasName: Bool? = nil
    ) {
        self.index = index
        self.outputIndex = outputIndex ?? (index + 1)
        let resolvedCallID = callID ?? "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        self.callID = resolvedCallID
        self.itemID = itemID ?? resolvedCallID
        self.name = name
        self.argumentsBuffer = argumentsBuffer
        self.emittedArgumentsLength = emittedArgumentsLength
        self.added = added
        self.hasName = hasName ?? (name != "tool")
    }
}

public struct OpenAIChatSyntheticStreamState: Sendable, Equatable {
    public var responseID: String
    public var createdAt: Int64
    public var inputTokens: Int64
    public var outputTokens: Int64
    public var cacheHitTokens: Int64?
    public var textBuffer: String
    public var reasoningContentBuffer: String
    public var toolCalls: [Int: OpenAIChatSyntheticToolCallState]
    public var textItemID: String
    public var reasoningItemID: String
    public var seenCreated: Bool
    public var seenInProgress: Bool
    public var textItemAdded: Bool
    public var textContentPartAdded: Bool
    public var reasoningItemAdded: Bool
    public var isCompleted: Bool

    public init(
        responseID: String = "resp_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
        createdAt: Int64 = Helpers.now(),
        inputTokens: Int64 = 0,
        outputTokens: Int64 = 0,
        cacheHitTokens: Int64? = nil,
        textBuffer: String = "",
        reasoningContentBuffer: String = "",
        toolCalls: [Int: OpenAIChatSyntheticToolCallState] = [:],
        textItemID: String = "msg_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
        reasoningItemID: String = "reason_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
        seenCreated: Bool = false,
        seenInProgress: Bool = false,
        textItemAdded: Bool = false,
        textContentPartAdded: Bool = false,
        reasoningItemAdded: Bool = false,
        isCompleted: Bool = false
    ) {
        self.responseID = responseID
        self.createdAt = createdAt
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheHitTokens = cacheHitTokens
        self.textBuffer = textBuffer
        self.reasoningContentBuffer = reasoningContentBuffer
        self.toolCalls = toolCalls
        self.textItemID = textItemID
        self.reasoningItemID = reasoningItemID
        self.seenCreated = seenCreated
        self.seenInProgress = seenInProgress
        self.textItemAdded = textItemAdded
        self.textContentPartAdded = textContentPartAdded
        self.reasoningItemAdded = reasoningItemAdded
        self.isCompleted = isCompleted
    }
}

struct UpstreamFunctionCallEvent: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case added
        case delta
        case argumentsDone
        case itemDone
    }

    var phase: Phase
    var outputIndex: Int?
    var itemID: String?
    var callID: String?
    var name: String?
    var thoughtSignature: String?
    var delta: String?
    var arguments: String?
}

public struct SSEEvent: Sendable, Equatable {
    public var event: String?
    public var data: String

    public init(event: String?, data: String) {
        self.event = event
        self.data = data
    }
}

public struct SSEIncrementalDecoder: Sendable {
    private var buffer: String

    public init(buffer: String = "") {
        self.buffer = buffer
    }

    public mutating func append(_ data: Data) -> [SSEEvent] {
        self.buffer.append(String(decoding: data, as: UTF8.self))
        var events: [SSEEvent] = []
        while let range = self.buffer.range(of: "\n\n") {
            let block = String(self.buffer[..<range.lowerBound])
            self.buffer.removeSubrange(..<range.upperBound)
            if let event = ProxyTranscoder.decodeSSE(Data(block.utf8)).first {
                events.append(event)
            }
        }
        return events
    }

    public mutating func finish() -> [SSEEvent] {
        defer { self.buffer.removeAll(keepingCapacity: false) }
        guard !self.buffer.isEmpty else { return [] }
        return ProxyTranscoder.decodeSSE(Data(self.buffer.utf8))
    }
}

extension ProxyTranscoder {
    static func jsonObject(from event: SSEEvent) -> [String: Any]? {
        guard let data = event.data.data(using: .utf8) else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func responseEventType(from event: SSEEvent) -> String? {
        self.responseEventType(from: self.jsonObject(from: event))
    }

    static func responseEventType(from json: [String: Any]?) -> String? {
        json?["type"] as? String
    }

    static func outputIndex(from json: [String: Any]) -> Int? {
        self.intValue(json["output_index"])
    }

    static func outputIndex(from event: SSEEvent) -> Int? {
        guard let json = self.jsonObject(from: event) else {
            return nil
        }
        return self.outputIndex(from: json)
    }

    static func upstreamFunctionCallEvent(from event: SSEEvent) -> UpstreamFunctionCallEvent? {
        guard let json = self.jsonObject(from: event) else {
            return nil
        }
        return self.upstreamFunctionCallEvent(from: json)
    }

    static func upstreamFunctionCallEvent(from json: [String: Any]) -> UpstreamFunctionCallEvent? {
        guard let type = self.responseEventType(from: json) else {
            return nil
        }

        switch type {
        case "response.output_item.added":
            guard let item = json["item"] as? [String: Any],
                  (item["type"] as? String) == "function_call"
            else {
                return nil
            }
            return UpstreamFunctionCallEvent(
                phase: .added,
                outputIndex: self.outputIndex(from: json),
                itemID: item["id"] as? String,
                callID: item["call_id"] as? String,
                name: item["name"] as? String,
                thoughtSignature: item["thoughtSignature"] as? String ?? item["thought_signature"] as? String,
                delta: nil,
                arguments: item["arguments"] as? String
            )
        case "response.function_call_arguments.delta":
            return UpstreamFunctionCallEvent(
                phase: .delta,
                outputIndex: self.outputIndex(from: json),
                itemID: json["item_id"] as? String,
                callID: nil,
                name: nil,
                thoughtSignature: nil,
                delta: json["delta"] as? String,
                arguments: nil
            )
        case "response.function_call_arguments.done":
            return UpstreamFunctionCallEvent(
                phase: .argumentsDone,
                outputIndex: self.outputIndex(from: json),
                itemID: json["item_id"] as? String,
                callID: nil,
                name: nil,
                thoughtSignature: nil,
                delta: nil,
                arguments: json["arguments"] as? String
            )
        case "response.output_item.done":
            guard let item = json["item"] as? [String: Any],
                  (item["type"] as? String) == "function_call"
            else {
                return nil
            }
            return UpstreamFunctionCallEvent(
                phase: .itemDone,
                outputIndex: self.outputIndex(from: json),
                itemID: item["id"] as? String,
                callID: item["call_id"] as? String,
                name: item["name"] as? String,
                thoughtSignature: item["thoughtSignature"] as? String ?? item["thought_signature"] as? String,
                delta: nil,
                arguments: item["arguments"] as? String
            )
        default:
            return nil
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        switch value {
        case let intValue as Int:
            return intValue
        case let int64Value as Int64:
            return Int(int64Value)
        case let number as NSNumber:
            return number.intValue
        case let string as String:
            return Int(string)
        default:
            return nil
        }
    }
}
