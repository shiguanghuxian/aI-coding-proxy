import Foundation

public struct AnthropicStreamState: Sendable {
    public var messageID: String
    public var started: Bool
    public var blockIndicesByKey: [String: Int]
    public var blockKeysByIndex: [Int: String]
    public var nextBlockIndex: Int
    public var openTextBlockKeys: Set<String>
    public var toolBlocks: [String: AnthropicToolStreamState]
    public var toolBlockKeysByItemID: [String: String]
    public var sawToolUse: Bool

    public init(
        messageID: String = "msg_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
        started: Bool = false,
        blockIndicesByKey: [String: Int] = [:],
        blockKeysByIndex: [Int: String] = [:],
        nextBlockIndex: Int = 0,
        openTextBlockKeys: Set<String> = [],
        toolBlocks: [String: AnthropicToolStreamState] = [:],
        toolBlockKeysByItemID: [String: String] = [:],
        sawToolUse: Bool = false
    ) {
        self.messageID = messageID
        self.started = started
        self.blockIndicesByKey = blockIndicesByKey
        self.blockKeysByIndex = blockKeysByIndex
        self.nextBlockIndex = nextBlockIndex
        self.openTextBlockKeys = openTextBlockKeys
        self.toolBlocks = toolBlocks
        self.toolBlockKeysByItemID = toolBlockKeysByItemID
        self.sawToolUse = sawToolUse
    }
}

public struct AnthropicToolStreamState: Sendable {
    public var key: String
    public var blockIndex: Int
    public var itemID: String?
    public var callID: String
    public var name: String
    public var argumentsBuffer: String
    public var emittedArgumentsLength: Int
    public var stopped: Bool

    public init(
        key: String,
        blockIndex: Int,
        itemID: String?,
        callID: String,
        name: String,
        argumentsBuffer: String = "",
        emittedArgumentsLength: Int = 0,
        stopped: Bool = false
    ) {
        self.key = key
        self.blockIndex = blockIndex
        self.itemID = itemID
        self.callID = callID
        self.name = name
        self.argumentsBuffer = argumentsBuffer
        self.emittedArgumentsLength = emittedArgumentsLength
        self.stopped = stopped
    }
}

public enum AnthropicTranscoder {
    public static let defaultAnthropicVersion = "2023-06-01"
    public static let defaultMaxTokens = 1_024
    private static let ignoredAssistantHistoryContentBlockTypes: Set<String> = [
        "thinking",
        "redacted_thinking",
    ]

    public static func normalizeMessagesRequest(
        _ payload: [String: Any]
    ) throws -> (request: [String: Any], downstreamStream: Bool, responseModel: String) {
        let responseModel = (payload["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? (payload["model"] as? String ?? "claude-sonnet-4-5")
            : "claude-sonnet-4-5"
        let downstreamStream = (payload["stream"] as? Bool) ?? false

        let instructions = try self.normalizeSystem(payload["system"])
        let input = try self.normalizeMessages(payload["messages"])

        var request: [String: Any] = [
            "stream": true,
            "store": false,
            "instructions": instructions,
            "input": input,
            "parallel_tool_calls": true,
            "include": ["reasoning.encrypted_content"],
            "reasoning": [
                "effort": self.reasoningEffort(from: payload["thinking"]),
                "summary": "auto",
            ],
            "max_output_tokens": self.maxTokens(from: payload["max_tokens"]),
        ]

        if let temperature = payload["temperature"] {
            request["temperature"] = temperature
        }
        if let topP = payload["top_p"] {
            request["top_p"] = topP
        }
        if let stopSequences = payload["stop_sequences"] as? [String], !stopSequences.isEmpty {
            request["stop"] = stopSequences
        }
        if let metadata = payload["metadata"] as? [String: Any], !metadata.isEmpty {
            request["metadata"] = metadata
        }
        if let tools = payload["tools"] {
            request["tools"] = try self.normalizeTools(tools)
        }
        if let toolChoice = payload["tool_choice"] {
            request["tool_choice"] = try self.normalizeToolChoice(toolChoice)
        }

        return (request, downstreamStream, responseModel)
    }

    public static func normalizeCountTokensRequest(
        _ payload: [String: Any]
    ) throws -> (request: [String: Any], responseModel: String) {
        var normalized = try self.normalizeMessagesRequest(payload)
        normalized.request["stream"] = false
        normalized.request["max_output_tokens"] = 1
        return (normalized.request, normalized.responseModel)
    }

    public static func messageResponse(
        from completedResponse: [String: Any],
        requestedModel: String
    ) -> [String: Any] {
        let usage = ProxyTranscoder.usageFromCompletedResponse(completedResponse)
        let content = self.contentBlocks(from: completedResponse)
        let stopReason = content.contains(where: {
            ($0["type"] as? String) == "tool_use"
        }) ? "tool_use" : "end_turn"

        return [
            "id": (completedResponse["id"] as? String) ?? "msg_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
            "type": "message",
            "role": "assistant",
            "model": requestedModel,
            "content": content,
            "stop_reason": stopReason,
            "stop_sequence": NSNull(),
            "usage": self.anthropicUsageObject(
                inputTokens: usage.inputTokens,
                outputTokens: usage.outputTokens,
                cacheReadTokens: usage.cacheHitTokens
            ),
        ]
    }

    public static func countTokensResponse(from usage: UpstreamUsage) -> [String: Any] {
        [
            "input_tokens": usage.inputTokens,
        ]
    }

    public static func pingSSEChunk() -> String {
        self.sseEvent(named: "ping", payload: ["type": "ping"])
    }

    public static func errorSSEChunk(message: String, type: String = "api_error") -> String {
        self.sseEvent(
            named: "error",
            payload: [
                "type": "error",
                "error": [
                    "type": type,
                    "message": message,
                ],
            ]
        )
    }

    public static func messagesSSEChunks(
        from event: SSEEvent,
        streamState: inout AnthropicStreamState,
        requestedModel: String
    ) -> [String] {
        guard let json = ProxyTranscoder.jsonObject(from: event),
              let type = ProxyTranscoder.responseEventType(from: json)
        else {
            return []
        }

        switch type {
        case "response.created":
            if let response = json["response"] as? [String: Any],
               let responseID = response["id"] as? String,
               !responseID.isEmpty
            {
                streamState.messageID = responseID
            }
            return self.ensureMessageStart(
                streamState: &streamState,
                requestedModel: requestedModel,
                inputTokens: 0
            )

        case "response.output_text.delta":
            var chunks: [String] = []
            chunks.append(contentsOf: self.ensureMessageStart(
                streamState: &streamState,
                requestedModel: requestedModel,
                inputTokens: 0
            ))
            let key = self.textBlockKey(from: json)
            let index = self.ensureBlockIndex(for: key, streamState: &streamState)
            if !streamState.openTextBlockKeys.contains(key) {
                streamState.openTextBlockKeys.insert(key)
                chunks.append(self.textBlockStartSSE(index: index))
            }
            let delta = json["delta"] as? String ?? ""
            if !delta.isEmpty {
                chunks.append(self.textBlockDeltaSSE(index: index, text: delta))
            }
            return chunks

        case "response.output_text.done":
            return self.closeTextBlock(from: json, streamState: &streamState)

        case "response.output_item.done":
            if let item = json["item"] as? [String: Any],
               (item["type"] as? String) == "message"
            {
                return self.closeTextBlock(from: json, streamState: &streamState)
            }
            if let functionCall = ProxyTranscoder.upstreamFunctionCallEvent(from: json) {
                return self.handleFunctionCallEvent(
                    functionCall,
                    streamState: &streamState,
                    requestedModel: requestedModel
                )
            }
            return []

        case "response.output_item.added",
             "response.function_call_arguments.delta",
             "response.function_call_arguments.done":
            guard let functionCall = ProxyTranscoder.upstreamFunctionCallEvent(from: json) else {
                return []
            }
            return self.handleFunctionCallEvent(
                functionCall,
                streamState: &streamState,
                requestedModel: requestedModel
            )

        case "response.completed":
            let response = json["response"] as? [String: Any] ?? [:]
            let usage = ProxyTranscoder.usageFromCompletedResponse(response)
            let contentBlocks = self.contentBlocks(from: response)
            var chunks: [String] = []
            chunks.append(contentsOf: self.ensureMessageStart(
                streamState: &streamState,
                requestedModel: requestedModel,
                inputTokens: usage.inputTokens
            ))
            chunks.append(contentsOf: self.closeOpenTextBlocks(streamState: &streamState))
            chunks.append(contentsOf: self.finishToolBlocks(
                from: contentBlocks,
                streamState: &streamState
            ))

            let stopReason = (streamState.sawToolUse || contentBlocks.contains(where: {
                ($0["type"] as? String) == "tool_use"
            })) ? "tool_use" : "end_turn"
            chunks.append(
                self.sseEvent(
                    named: "message_delta",
                    payload: [
                        "type": "message_delta",
                        "delta": [
                            "stop_reason": stopReason,
                            "stop_sequence": NSNull(),
                        ],
                        "usage": self.anthropicUsageObject(
                            inputTokens: nil,
                            outputTokens: usage.outputTokens,
                            cacheReadTokens: usage.cacheHitTokens
                        ),
                    ]
                )
            )
            chunks.append(
                self.sseEvent(
                    named: "message_stop",
                    payload: [
                        "type": "message_stop",
                    ]
                )
            )
            return chunks

        default:
            return []
        }
    }

    public static func extractText(from response: [String: Any]) -> String {
        guard let content = response["content"] as? [[String: Any]] else { return "" }
        var parts: [String] = []
        for block in content {
            if (block["type"] as? String) == "text", let text = block["text"] as? String, !text.isEmpty {
                parts.append(text)
                continue
            }
            if (block["type"] as? String) == "tool_use",
               let name = block["name"] as? String
            {
                parts.append("[tool_use] \(name)")
            }
        }
        return parts.joined(separator: "\n")
    }

    private static func ensureMessageStart(
        streamState: inout AnthropicStreamState,
        requestedModel: String,
        inputTokens: Int64
    ) -> [String] {
        guard !streamState.started else {
            return []
        }
        streamState.started = true
        return [
            self.sseEvent(
                named: "message_start",
                payload: [
                    "type": "message_start",
                    "message": [
                        "id": streamState.messageID,
                        "type": "message",
                        "role": "assistant",
                        "model": requestedModel,
                        "content": [],
                        "stop_reason": NSNull(),
                        "stop_sequence": NSNull(),
                        "usage": [
                            "input_tokens": inputTokens,
                            "output_tokens": 0,
                        ],
                    ],
                ]
            )
        ]
    }

    private static func textBlockKey(from json: [String: Any]) -> String {
        if let outputIndex = ProxyTranscoder.outputIndex(from: json) {
            return "text:\(outputIndex)"
        }
        return "text:default"
    }

    private static func anthropicUsageObject(
        inputTokens: Int64?,
        outputTokens: Int64?,
        cacheReadTokens: Int64?
    ) -> [String: Any] {
        var usage: [String: Any] = [:]
        if let inputTokens {
            usage["input_tokens"] = inputTokens
        }
        if let outputTokens {
            usage["output_tokens"] = outputTokens
        }
        if let cacheReadTokens {
            usage["cache_read_input_tokens"] = cacheReadTokens
        }
        return usage
    }

    private static func toolBlockKey(
        for functionCall: UpstreamFunctionCallEvent,
        streamState: AnthropicStreamState
    ) -> String {
        if let outputIndex = functionCall.outputIndex {
            return "tool:\(outputIndex)"
        }
        if let itemID = functionCall.itemID,
           let existing = streamState.toolBlockKeysByItemID[itemID]
        {
            return existing
        }
        if let itemID = functionCall.itemID, !itemID.isEmpty {
            return "tool-item:\(itemID)"
        }
        if let callID = functionCall.callID, !callID.isEmpty {
            return "tool-call:\(callID)"
        }
        return "tool-generated:\(streamState.nextBlockIndex)"
    }

    private static func ensureBlockIndex(
        for key: String,
        streamState: inout AnthropicStreamState
    ) -> Int {
        if let existing = streamState.blockIndicesByKey[key] {
            return existing
        }
        let index = streamState.nextBlockIndex
        streamState.blockIndicesByKey[key] = index
        streamState.blockKeysByIndex[index] = key
        streamState.nextBlockIndex += 1
        return index
    }

    private static func closeTextBlock(
        from json: [String: Any],
        streamState: inout AnthropicStreamState
    ) -> [String] {
        let preferredKey = self.textBlockKey(from: json)
        let key: String?
        if streamState.openTextBlockKeys.contains(preferredKey) {
            key = preferredKey
        } else if streamState.openTextBlockKeys.count == 1 {
            key = streamState.openTextBlockKeys.first
        } else {
            key = nil
        }

        guard let key,
              let index = streamState.blockIndicesByKey[key]
        else {
            return []
        }

        streamState.openTextBlockKeys.remove(key)
        return [self.blockStopSSE(index: index)]
    }

    private static func closeOpenTextBlocks(streamState: inout AnthropicStreamState) -> [String] {
        let orderedKeys = streamState.openTextBlockKeys.sorted {
            (streamState.blockIndicesByKey[$0] ?? .max) < (streamState.blockIndicesByKey[$1] ?? .max)
        }
        streamState.openTextBlockKeys.removeAll()
        return orderedKeys.compactMap { key in
            guard let index = streamState.blockIndicesByKey[key] else {
                return nil
            }
            return self.blockStopSSE(index: index)
        }
    }

    private static func handleFunctionCallEvent(
        _ functionCall: UpstreamFunctionCallEvent,
        streamState: inout AnthropicStreamState,
        requestedModel: String
    ) -> [String] {
        var chunks = self.ensureMessageStart(
            streamState: &streamState,
            requestedModel: requestedModel,
            inputTokens: 0
        )
        chunks.append(contentsOf: self.closeOpenTextBlocks(streamState: &streamState))

        let key = self.toolBlockKey(for: functionCall, streamState: streamState)
        var toolState = streamState.toolBlocks[key]
        if toolState == nil {
            let blockIndex = self.ensureBlockIndex(for: key, streamState: &streamState)
            toolState = AnthropicToolStreamState(
                key: key,
                blockIndex: blockIndex,
                itemID: functionCall.itemID,
                callID: (functionCall.callID?.isEmpty == false ? functionCall.callID! : functionCall.itemID) ?? "toolu_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
                name: (functionCall.name?.isEmpty == false ? functionCall.name! : nil) ?? "tool",
                argumentsBuffer: "",
                emittedArgumentsLength: 0,
                stopped: false
            )
            streamState.sawToolUse = true
            chunks.append(self.toolBlockStartSSE(
                index: blockIndex,
                callID: toolState?.callID ?? "tool",
                name: toolState?.name ?? "tool"
            ))
        }

        guard var resolvedToolState = toolState else {
            return chunks
        }

        if let itemID = functionCall.itemID, !itemID.isEmpty {
            resolvedToolState.itemID = itemID
            streamState.toolBlockKeysByItemID[itemID] = key
        }
        if let callID = functionCall.callID, !callID.isEmpty {
            resolvedToolState.callID = callID
        }
        if let name = functionCall.name, !name.isEmpty {
            resolvedToolState.name = name
        }

        switch functionCall.phase {
        case .added:
            if let arguments = functionCall.arguments, !arguments.isEmpty {
                chunks.append(contentsOf: self.emitToolArguments(
                    fullArguments: arguments,
                    toolState: &resolvedToolState
                ))
            }
        case .delta:
            if let delta = functionCall.delta, !delta.isEmpty {
                resolvedToolState.argumentsBuffer.append(delta)
                resolvedToolState.emittedArgumentsLength += delta.count
                chunks.append(self.toolBlockDeltaSSE(
                    index: resolvedToolState.blockIndex,
                    partialJSON: delta
                ))
            }
        case .argumentsDone, .itemDone:
            if let arguments = functionCall.arguments, !arguments.isEmpty {
                chunks.append(contentsOf: self.emitToolArguments(
                    fullArguments: arguments,
                    toolState: &resolvedToolState
                ))
            }
            if !resolvedToolState.stopped {
                resolvedToolState.stopped = true
                chunks.append(self.blockStopSSE(index: resolvedToolState.blockIndex))
            }
        }

        streamState.toolBlocks[key] = resolvedToolState
        return chunks
    }

    private static func emitToolArguments(
        fullArguments: String,
        toolState: inout AnthropicToolStreamState
    ) -> [String] {
        toolState.argumentsBuffer = fullArguments
        guard fullArguments.count > toolState.emittedArgumentsLength else {
            return []
        }
        let start = fullArguments.index(fullArguments.startIndex, offsetBy: toolState.emittedArgumentsLength)
        let suffix = String(fullArguments[start...])
        toolState.emittedArgumentsLength = fullArguments.count
        guard !suffix.isEmpty else {
            return []
        }
        return [self.toolBlockDeltaSSE(index: toolState.blockIndex, partialJSON: suffix)]
    }

    private static func finishToolBlocks(
        from contentBlocks: [[String: Any]],
        streamState: inout AnthropicStreamState
    ) -> [String] {
        var chunks: [String] = []

        for (index, block) in contentBlocks.enumerated() {
            let type = block["type"] as? String ?? ""
            switch type {
            case "text":
                guard streamState.blockKeysByIndex[index] == nil,
                      let text = block["text"] as? String,
                      !text.isEmpty
                else {
                    continue
                }
                chunks.append(self.textBlockStartSSE(index: index))
                chunks.append(self.textBlockDeltaSSE(index: index, text: text))
                chunks.append(self.blockStopSSE(index: index))

            case "tool_use":
                streamState.sawToolUse = true
                let input = self.jsonString(from: block["input"] ?? [:])
                if let key = streamState.blockKeysByIndex[index],
                   var toolState = streamState.toolBlocks[key]
                {
                    if !input.isEmpty {
                        chunks.append(contentsOf: self.emitToolArguments(
                            fullArguments: input,
                            toolState: &toolState
                        ))
                    }
                    if !toolState.stopped {
                        toolState.stopped = true
                        chunks.append(self.blockStopSSE(index: toolState.blockIndex))
                    }
                    streamState.toolBlocks[key] = toolState
                    continue
                }

                let callID = (block["id"] as? String) ?? "toolu_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
                let name = (block["name"] as? String) ?? "tool"
                chunks.append(self.toolBlockStartSSE(index: index, callID: callID, name: name))
                if !input.isEmpty, input != "{}" {
                    chunks.append(self.toolBlockDeltaSSE(index: index, partialJSON: input))
                }
                chunks.append(self.blockStopSSE(index: index))

            default:
                continue
            }
        }

        return chunks
    }

    private static func textBlockStartSSE(index: Int) -> String {
        self.sseEvent(
            named: "content_block_start",
            payload: [
                "type": "content_block_start",
                "index": index,
                "content_block": [
                    "type": "text",
                    "text": "",
                ],
            ]
        )
    }

    private static func textBlockDeltaSSE(index: Int, text: String) -> String {
        self.sseEvent(
            named: "content_block_delta",
            payload: [
                "type": "content_block_delta",
                "index": index,
                "delta": [
                    "type": "text_delta",
                    "text": text,
                ],
            ]
        )
    }

    private static func toolBlockStartSSE(index: Int, callID: String, name: String) -> String {
        self.sseEvent(
            named: "content_block_start",
            payload: [
                "type": "content_block_start",
                "index": index,
                "content_block": [
                    "type": "tool_use",
                    "id": callID,
                    "name": name,
                    "input": [:],
                ],
            ]
        )
    }

    private static func toolBlockDeltaSSE(index: Int, partialJSON: String) -> String {
        self.sseEvent(
            named: "content_block_delta",
            payload: [
                "type": "content_block_delta",
                "index": index,
                "delta": [
                    "type": "input_json_delta",
                    "partial_json": partialJSON,
                ],
            ]
        )
    }

    private static func blockStopSSE(index: Int) -> String {
        self.sseEvent(
            named: "content_block_stop",
            payload: [
                "type": "content_block_stop",
                "index": index,
            ]
        )
    }

    private static func normalizeSystem(_ rawSystem: Any?) throws -> String {
        guard let rawSystem else { return "" }
        if let text = rawSystem as? String {
            return text
        }
        guard let blocks = rawSystem as? [Any] else {
            throw ProxyError.message("Unsupported Anthropic system payload at `$.system`.")
        }

        var lines: [String] = []
        for (index, rawBlock) in blocks.enumerated() {
            guard let block = rawBlock as? [String: Any] else {
                throw ProxyError.message("Unsupported Anthropic system block at `$.system[\(index)]`.")
            }
            let type = (block["type"] as? String) ?? ""
            guard type == "text" else {
                throw ProxyError.message("Unsupported Anthropic content block `\(type)` at `$.system[\(index)]`.")
            }
            lines.append(block["text"] as? String ?? "")
        }
        return lines.joined(separator: "\n\n")
    }

    private static func normalizeMessages(_ rawMessages: Any?) throws -> [[String: Any]] {
        guard let rawMessages = rawMessages as? [Any], !rawMessages.isEmpty else {
            throw ProxyError.message("Anthropic messages request is missing `messages`.")
        }

        var input: [[String: Any]] = []
        for (messageIndex, rawMessage) in rawMessages.enumerated() {
            guard let message = rawMessage as? [String: Any] else {
                throw ProxyError.message("Unsupported Anthropic message at `$.messages[\(messageIndex)]`.")
            }

            let role = ((message["role"] as? String) ?? "user").lowercased()
            let rawContent = message["content"]
            if let text = rawContent as? String {
                input.append(self.messageItem(role: role, textBlocks: [
                    ProxyTranscoder.textContentBlock(text: text, role: role),
                ]))
                continue
            }

            guard let blocks = rawContent as? [Any] else {
                throw ProxyError.message("Unsupported Anthropic message content at `$.messages[\(messageIndex)].content`.")
            }

            var textBlocks: [[String: Any]] = []
            for (blockIndex, rawBlock) in blocks.enumerated() {
                guard let block = rawBlock as? [String: Any] else {
                    throw ProxyError.message("Unsupported Anthropic content block at `$.messages[\(messageIndex)].content[\(blockIndex)]`.")
                }

                let type = (block["type"] as? String) ?? ""
                switch type {
                case "text":
                    textBlocks.append(
                        ProxyTranscoder.textContentBlock(
                            text: block["text"] as? String ?? "",
                            role: role
                        )
                    )

                case "image":
                    continue

                case "tool_use":
                    if !textBlocks.isEmpty {
                        input.append(self.messageItem(role: role, textBlocks: textBlocks))
                        textBlocks.removeAll(keepingCapacity: true)
                    }
                    guard role == "assistant" else {
                        throw ProxyError.message("Anthropic `tool_use` is only supported on assistant messages at `$.messages[\(messageIndex)].content[\(blockIndex)]`.")
                    }
                    guard let name = block["name"] as? String, !name.isEmpty else {
                        throw ProxyError.message("Anthropic `tool_use` is missing `name` at `$.messages[\(messageIndex)].content[\(blockIndex)].name`.")
                    }
                    guard let callID = block["id"] as? String, !callID.isEmpty else {
                        throw ProxyError.message("Anthropic `tool_use` is missing `id` at `$.messages[\(messageIndex)].content[\(blockIndex)].id`.")
                    }
                    input.append([
                        "type": "function_call",
                        "call_id": callID,
                        "name": name,
                        "arguments": self.jsonString(from: block["input"] ?? [:]),
                    ])

                case "tool_result":
                    if !textBlocks.isEmpty {
                        input.append(self.messageItem(role: role, textBlocks: textBlocks))
                        textBlocks.removeAll(keepingCapacity: true)
                    }
                    guard role == "user" else {
                        throw ProxyError.message("Anthropic `tool_result` is only supported on user messages at `$.messages[\(messageIndex)].content[\(blockIndex)]`.")
                    }
                    guard let callID = block["tool_use_id"] as? String, !callID.isEmpty else {
                        throw ProxyError.message("Anthropic `tool_result` is missing `tool_use_id` at `$.messages[\(messageIndex)].content[\(blockIndex)].tool_use_id`.")
                    }
                    input.append([
                        "type": "function_call_output",
                        "call_id": callID,
                        "output": self.toolResultOutputString(from: block["content"]),
                    ])

                case let ignoredType where self.ignoredAssistantHistoryContentBlockTypes.contains(ignoredType):
                    guard role == "assistant" else {
                        throw ProxyError.message("Unsupported Anthropic content block `\(ignoredType)` at `$.messages[\(messageIndex)].content[\(blockIndex)]`.")
                    }
                    continue

                default:
                    throw ProxyError.message("Unsupported Anthropic content block `\(type)` at `$.messages[\(messageIndex)].content[\(blockIndex)]`.")
                }
            }

            if !textBlocks.isEmpty {
                input.append(self.messageItem(role: role, textBlocks: textBlocks))
            }
        }

        return input
    }

    private static func normalizeTools(_ rawTools: Any) throws -> [[String: Any]] {
        guard let rawTools = rawTools as? [Any] else {
            throw ProxyError.message("Anthropic `tools` must be an array at `$.tools`.")
        }

        return try rawTools.enumerated().map { index, rawTool in
            guard let tool = rawTool as? [String: Any] else {
                throw ProxyError.message("Unsupported Anthropic tool at `$.tools[\(index)]`.")
            }
            guard let name = tool["name"] as? String, !name.isEmpty else {
                throw ProxyError.message("Anthropic tool is missing `name` at `$.tools[\(index)].name`.")
            }
            let schema = tool["input_schema"] as? [String: Any] ?? [
                "type": "object",
                "properties": [:],
            ]
            var normalized: [String: Any] = [
                "type": "function",
                "name": name,
                "parameters": schema,
            ]
            if let description = tool["description"] as? String, !description.isEmpty {
                normalized["description"] = description
            }
            return normalized
        }
    }

    private static func normalizeToolChoice(_ rawToolChoice: Any) throws -> Any {
        if let mode = rawToolChoice as? String {
            switch mode {
            case "auto":
                return "auto"
            case "any":
                return "required"
            default:
                throw ProxyError.message("Unsupported Anthropic tool_choice `\(mode)` at `$.tool_choice`.")
            }
        }

        guard let choice = rawToolChoice as? [String: Any] else {
            throw ProxyError.message("Anthropic `tool_choice` must be a string or object at `$.tool_choice`.")
        }

        let type = (choice["type"] as? String) ?? "auto"
        switch type {
        case "auto":
            return "auto"
        case "any":
            return "required"
        case "tool":
            guard let name = choice["name"] as? String, !name.isEmpty else {
                throw ProxyError.message("Anthropic tool_choice is missing `name` at `$.tool_choice.name`.")
            }
            return [
                "type": "function",
                "name": name,
            ]
        default:
            throw ProxyError.message("Unsupported Anthropic tool_choice `\(type)` at `$.tool_choice.type`.")
        }
    }

    private static func reasoningEffort(from rawThinking: Any?) -> String {
        guard let thinking = rawThinking as? [String: Any] else { return "medium" }
        let budget = (thinking["budget_tokens"] as? Int) ?? Int((thinking["budget_tokens"] as? Int64) ?? 0)
        switch budget {
        case ..<1_025:
            return budget > 0 ? "low" : "medium"
        case 1_025...4_096:
            return "medium"
        default:
            return "high"
        }
    }

    private static func maxTokens(from rawMaxTokens: Any?) -> Int {
        if let value = rawMaxTokens as? Int, value > 0 {
            return value
        }
        if let value = rawMaxTokens as? Int64, value > 0 {
            return Int(value)
        }
        return self.defaultMaxTokens
    }

    private static func messageItem(role: String, textBlocks: [[String: Any]]) -> [String: Any] {
        [
            "type": "message",
            "role": role,
            "content": textBlocks,
        ]
    }

    private static func toolResultOutputString(from rawContent: Any?) -> String {
        if let content = rawContent as? String {
            return content
        }
        if let blocks = rawContent as? [Any] {
            var parts: [String] = []
            for rawBlock in blocks {
                guard let block = rawBlock as? [String: Any] else { continue }
                if (block["type"] as? String) == "text", let text = block["text"] as? String {
                    parts.append(text)
                } else {
                    parts.append(self.jsonString(from: block))
                }
            }
            return parts.joined(separator: "\n")
        }
        if let content = rawContent as? [String: Any] {
            return self.jsonString(from: content)
        }
        return ""
    }

    private static func contentBlocks(from completedResponse: [String: Any]) -> [[String: Any]] {
        guard let output = completedResponse["output"] as? [[String: Any]] else { return [] }

        var blocks: [[String: Any]] = []
        for item in output {
            let type = item["type"] as? String ?? ""
            switch type {
            case "message":
                guard (item["role"] as? String) == "assistant" else { continue }
                let content = item["content"] as? [[String: Any]] ?? []
                for contentPart in content {
                    if (contentPart["type"] as? String) == "output_text",
                       let text = contentPart["text"] as? String
                    {
                        blocks.append([
                            "type": "text",
                            "text": text,
                        ])
                    }
                }

            case "function_call":
                let argumentsText = item["arguments"] as? String ?? "{}"
                let parsedInput = self.parseJSONObject(from: argumentsText) ?? ["_raw": argumentsText]
                blocks.append([
                    "type": "tool_use",
                    "id": (item["call_id"] as? String) ?? "toolu_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
                    "name": (item["name"] as? String) ?? "tool",
                    "input": parsedInput,
                ])

            default:
                continue
            }
        }
        return blocks
    }

    private static func parseJSONObject(from text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }

    private static func jsonString(from object: Any) -> String {
        if let string = object as? String {
            return string
        }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            return "\(object)"
        }
        return text
    }

    private static func sseEvent(named name: String, payload: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [])) ?? Data("{}".utf8)
        return "event: \(name)\ndata: \(String(decoding: data, as: UTF8.self))\n\n"
    }
}
