import Foundation

public struct AnthropicSyntheticStreamState: Sendable {
    public struct ToolCall: Sendable {
        public var itemID: String
        public var callID: String
        public var name: String
        public var argumentsBuffer: String

        public init(itemID: String, callID: String, name: String, argumentsBuffer: String = "") {
            self.itemID = itemID
            self.callID = callID
            self.name = name
            self.argumentsBuffer = argumentsBuffer
        }
    }

    public var responseID: String
    public var createdAt: Int64
    public var inputTokens: Int64
    public var outputTokens: Int64
    public var cacheReadTokens: Int64?
    public var textBlocks: [Int: String]
    public var toolCalls: [Int: ToolCall]
    public var seenCreated: Bool

    public init(
        responseID: String = "resp_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
        createdAt: Int64 = Helpers.now(),
        inputTokens: Int64 = 0,
        outputTokens: Int64 = 0,
        cacheReadTokens: Int64? = nil,
        textBlocks: [Int: String] = [:],
        toolCalls: [Int: ToolCall] = [:],
        seenCreated: Bool = false
    ) {
        self.responseID = responseID
        self.createdAt = createdAt
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.textBlocks = textBlocks
        self.toolCalls = toolCalls
        self.seenCreated = seenCreated
    }
}

public enum AnthropicUpstreamBridge {
    public static let defaultOpenAIToAnthropicModel = "claude-sonnet-4-5"

    public static func normalizeRequest(
        _ request: [String: Any],
        upstreamModel: String,
        stream: Bool
    ) -> [String: Any] {
        var messages: [[String: Any]] = []
        var systemParts: [String] = []

        if let instructions = request["instructions"] as? String {
            let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                systemParts.append(trimmed)
            }
        }

        for item in request["input"] as? [[String: Any]] ?? [] {
            let type = item["type"] as? String ?? ""
            switch type {
            case "message":
                let role = ((item["role"] as? String) ?? "user").lowercased()
                let blocks = self.messageBlocks(from: item["content"], role: role)
                guard !blocks.isEmpty else { continue }
                if role == "developer" || role == "system" {
                    let text = blocks.compactMap { $0["text"] as? String }.joined(separator: "\n\n")
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        systemParts.append(trimmed)
                    }
                    continue
                }
                self.appendMessage(role: role == "assistant" ? "assistant" : "user", blocks: blocks, to: &messages)

            case "function_call_output":
                let callID = (item["call_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !callID.isEmpty else { continue }
                let output = self.stringValue(item["output"])
                self.appendMessage(
                    role: "user",
                    blocks: [[
                        "type": "tool_result",
                        "tool_use_id": callID,
                        "content": output,
                    ]],
                    to: &messages
                )

            case "function_call":
                let callID = (item["call_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "tool"
                guard !callID.isEmpty else { continue }
                let argumentsText = self.stringValue(item["arguments"])
                self.appendMessage(
                    role: "assistant",
                    blocks: [[
                        "type": "tool_use",
                        "id": callID,
                        "name": name,
                        "input": self.jsonObject(from: argumentsText) ?? ["_raw": argumentsText],
                    ]],
                    to: &messages
                )

            default:
                continue
            }
        }

        var normalized: [String: Any] = [
            "model": upstreamModel,
            "messages": messages,
            "stream": stream,
            "max_tokens": request["max_output_tokens"] ?? 1_024,
        ]

        let systemText = systemParts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        if !systemText.isEmpty {
            normalized["system"] = systemText
        }
        if let temperature = request["temperature"] {
            normalized["temperature"] = temperature
        }
        if let topP = request["top_p"] {
            normalized["top_p"] = topP
        }
        if let stop = request["stop"] {
            normalized["stop_sequences"] = stop
        }
        if let tools = request["tools"] {
            let normalizedTools = self.normalizeTools(tools)
            if !normalizedTools.isEmpty {
                normalized["tools"] = normalizedTools
            }
        }
        if let toolChoice = self.normalizeToolChoice(request["tool_choice"]) {
            normalized["tool_choice"] = toolChoice
        }
        return normalized
    }

    public static func completedResponse(
        from anthropicMessage: [String: Any],
        requestedModel: String
    ) -> [String: Any] {
        let usage = ProxyTranscoder.usageFromAnthropicUsage(anthropicMessage["usage"])

        var output: [[String: Any]] = []
        let textBlocks = self.textBlocks(from: anthropicMessage)
        if !textBlocks.isEmpty {
            output.append([
                "type": "message",
                "role": "assistant",
                "content": textBlocks.map { text in
                    [
                        "type": "output_text",
                        "text": text,
                    ]
                },
            ])
        }

        for block in self.toolUseBlocks(from: anthropicMessage) {
            let input = block["input"] ?? [:]
            output.append([
                "type": "function_call",
                "id": block["id"] as? String ?? "fc_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
                "call_id": block["id"] as? String ?? "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
                "name": block["name"] as? String ?? "tool",
                "arguments": self.stringValue(input),
            ])
        }

        return [
            "id": anthropicMessage["id"] as? String ?? "resp_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
            "object": "response",
            "created_at": Helpers.now(),
            "status": "completed",
            "model": requestedModel,
            "output": output,
            "usage": self.completedUsageObject(usage),
        ]
    }

    public static func responseSSEChunks(
        from event: SSEEvent,
        state: inout AnthropicSyntheticStreamState,
        requestedModel: String
    ) -> [String] {
        guard let json = ProxyTranscoder.jsonObject(from: event),
              let type = json["type"] as? String
        else {
            return []
        }

        switch type {
        case "message_start":
            let message = json["message"] as? [String: Any] ?? [:]
            if let responseID = message["id"] as? String, !responseID.isEmpty {
                state.responseID = responseID
            }
            state.createdAt = Helpers.now()
            if message["usage"] != nil {
                let usage = ProxyTranscoder.usageFromAnthropicUsage(message["usage"])
                state.inputTokens = usage.inputTokens
                state.cacheReadTokens = self.mergedCacheReadTokens(
                    current: state.cacheReadTokens,
                    next: usage.cacheHitTokens
                )
            }
            state.seenCreated = true
            return [self.sseData([
                "type": "response.created",
                "response": [
                    "id": state.responseID,
                    "created_at": state.createdAt,
                    "model": requestedModel,
                ],
            ])]

        case "content_block_start":
            let index = self.intValue(from: json["index"]) ?? 0
            let block = json["content_block"] as? [String: Any] ?? [:]
            let blockType = block["type"] as? String ?? ""
            if blockType == "tool_use" {
                let callID = block["id"] as? String ?? "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
                let itemID = "fc_\(callID)"
                let name = block["name"] as? String ?? "tool"
                let initialArguments = self.stringValue(block["input"] ?? [:])
                state.toolCalls[index] = .init(itemID: itemID, callID: callID, name: name, argumentsBuffer: initialArguments == "{}" ? "" : initialArguments)
                var chunks = [
                    self.sseData([
                        "type": "response.output_item.added",
                        "output_index": index,
                        "item": [
                            "id": itemID,
                            "type": "function_call",
                            "call_id": callID,
                            "name": name,
                            "arguments": "",
                        ],
                    ]),
                ]
                if !initialArguments.isEmpty && initialArguments != "{}" {
                    chunks.append(
                        self.sseData([
                            "type": "response.function_call_arguments.delta",
                            "output_index": index,
                            "item_id": itemID,
                            "delta": initialArguments,
                        ])
                    )
                }
                return chunks
            }
            return []

        case "content_block_delta":
            let index = self.intValue(from: json["index"]) ?? 0
            let delta = json["delta"] as? [String: Any] ?? [:]
            let deltaType = delta["type"] as? String ?? ""
            if deltaType == "text_delta" {
                let text = delta["text"] as? String ?? ""
                state.textBlocks[index, default: ""].append(text)
                return text.isEmpty ? [] : [
                    self.sseData([
                        "type": "response.output_text.delta",
                        "output_index": index,
                        "delta": text,
                    ]),
                ]
            }
            if deltaType == "input_json_delta", var tool = state.toolCalls[index] {
                let partial = delta["partial_json"] as? String ?? ""
                tool.argumentsBuffer.append(partial)
                state.toolCalls[index] = tool
                return partial.isEmpty ? [] : [
                    self.sseData([
                        "type": "response.function_call_arguments.delta",
                        "output_index": index,
                        "item_id": tool.itemID,
                        "delta": partial,
                    ]),
                ]
            }
            return []

        case "content_block_stop":
            let index = self.intValue(from: json["index"]) ?? 0
            guard let tool = state.toolCalls[index] else {
                return []
            }
            return [
                self.sseData([
                    "type": "response.function_call_arguments.done",
                    "output_index": index,
                    "item_id": tool.itemID,
                    "arguments": tool.argumentsBuffer,
                ]),
                self.sseData([
                    "type": "response.output_item.done",
                    "output_index": index,
                    "item": [
                        "id": tool.itemID,
                        "type": "function_call",
                        "call_id": tool.callID,
                        "name": tool.name,
                        "arguments": tool.argumentsBuffer,
                    ],
                ]),
            ]

        case "message_delta":
            if json["usage"] != nil {
                let usage = ProxyTranscoder.usageFromAnthropicUsage(json["usage"])
                let updatedInputFromUsage = state.inputTokens == 0 && usage.inputTokens > 0
                if state.inputTokens == 0, usage.inputTokens > 0 {
                    state.inputTokens = usage.inputTokens
                }
                state.outputTokens = usage.outputTokens
                let previousCacheReadTokens = state.cacheReadTokens ?? 0
                state.cacheReadTokens = self.mergedCacheReadTokens(
                    current: state.cacheReadTokens,
                    next: usage.cacheHitTokens
                )
                if let cacheReadTokens = state.cacheReadTokens,
                   cacheReadTokens > previousCacheReadTokens,
                   updatedInputFromUsage == false
                {
                    state.inputTokens += cacheReadTokens - previousCacheReadTokens
                }
            }
            return []

        case "message_stop":
            let completed = self.completedResponse(from: state, requestedModel: requestedModel)
            return [
                self.sseData([
                    "type": "response.completed",
                    "response": completed,
                ]),
            ]

        default:
            return []
        }
    }

    public static func completedResponse(
        from state: AnthropicSyntheticStreamState,
        requestedModel: String
    ) -> [String: Any] {
        var output: [[String: Any]] = []
        let orderedText = state.textBlocks.keys.sorted().compactMap { index -> [String: Any]? in
            let text = state.textBlocks[index]?.trimmingCharacters(in: .newlines) ?? ""
            guard !text.isEmpty else { return nil }
            return [
                "type": "output_text",
                "text": text,
            ]
        }
        if !orderedText.isEmpty {
            output.append([
                "type": "message",
                "role": "assistant",
                "content": orderedText,
            ])
        }
        for index in state.toolCalls.keys.sorted() {
            guard let tool = state.toolCalls[index] else { continue }
            output.append([
                "type": "function_call",
                "id": tool.itemID,
                "call_id": tool.callID,
                "name": tool.name,
                "arguments": tool.argumentsBuffer,
            ])
        }
        return [
            "id": state.responseID,
            "object": "response",
            "created_at": state.createdAt,
            "status": "completed",
            "model": requestedModel,
            "output": output,
            "usage": self.completedUsageObject(
                UpstreamUsage(
                    inputTokens: state.inputTokens,
                    outputTokens: state.outputTokens,
                    totalTokens: state.inputTokens + state.outputTokens,
                    cacheHitTokens: state.cacheReadTokens
                )
            ),
        ]
    }

    private static func completedUsageObject(_ usage: UpstreamUsage) -> [String: Any] {
        var object: [String: Any] = [
            "input_tokens": usage.inputTokens,
            "output_tokens": usage.outputTokens,
            "total_tokens": usage.totalTokens,
        ]
        if let cacheReadTokens = usage.cacheHitTokens {
            object["cache_read_input_tokens"] = cacheReadTokens
        }
        return object
    }

    private static func mergedCacheReadTokens(current: Int64?, next: Int64?) -> Int64? {
        switch (current, next) {
        case let (current?, next?):
            return max(current, next)
        case (nil, let next?):
            return next
        case (let current?, nil):
            return current
        case (nil, nil):
            return nil
        }
    }

    private static func appendMessage(role: String, blocks: [[String: Any]], to messages: inout [[String: Any]]) {
        guard !blocks.isEmpty else { return }
        if let lastIndex = messages.indices.last, (messages[lastIndex]["role"] as? String) == role {
            var content = messages[lastIndex]["content"] as? [[String: Any]] ?? []
            content.append(contentsOf: blocks)
            messages[lastIndex]["content"] = content
            return
        }
        messages.append([
            "role": role,
            "content": blocks,
        ])
    }

    private static func messageBlocks(from rawContent: Any?, role: String) -> [[String: Any]] {
        guard let content = rawContent as? [[String: Any]] else {
            let text = self.stringValue(rawContent).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [[
                "type": "text",
                "text": text,
            ]]
        }

        return content.compactMap { block in
            let type = (block["type"] as? String ?? "").lowercased()
            switch type {
            case "input_text", "output_text", "text", "refusal":
                let text = self.stringValue(block["text"] ?? block["refusal"]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                return [
                    "type": "text",
                    "text": text,
                ]
            default:
                return nil
            }
        }
    }

    private static func normalizeTools(_ rawTools: Any) -> [[String: Any]] {
        guard let tools = rawTools as? [[String: Any]] else { return [] }
        return tools.compactMap { tool in
            if let function = tool["function"] as? [String: Any] {
                let name = function["name"] as? String ?? ""
                guard !name.isEmpty else { return nil }
                return [
                    "name": name,
                    "description": function["description"] as? String ?? "",
                    "input_schema": function["parameters"] as? [String: Any] ?? ["type": "object", "properties": [:]],
                ]
            }
            if let name = tool["name"] as? String, !name.isEmpty {
                return [
                    "name": name,
                    "description": tool["description"] as? String ?? "",
                    "input_schema": tool["input_schema"] as? [String: Any] ?? ["type": "object", "properties": [:]],
                ]
            }
            return nil
        }
    }

    private static func normalizeToolChoice(_ rawToolChoice: Any?) -> [String: Any]? {
        guard let rawToolChoice else { return nil }
        if let string = rawToolChoice as? String {
            switch string.lowercased() {
            case "auto":
                return ["type": "auto"]
            case "required":
                return ["type": "any"]
            default:
                return nil
            }
        }
        guard let object = rawToolChoice as? [String: Any] else { return nil }
        if let type = object["type"] as? String {
            switch type {
            case "function":
                let name = ((object["function"] as? [String: Any])?["name"] as? String) ?? (object["name"] as? String) ?? ""
                guard !name.isEmpty else { return nil }
                return ["type": "tool", "name": name]
            case "required":
                return ["type": "any"]
            case "auto", "any", "tool":
                return object
            default:
                return nil
            }
        }
        if let name = object["name"] as? String, !name.isEmpty {
            return ["type": "tool", "name": name]
        }
        return nil
    }

    private static func textBlocks(from anthropicMessage: [String: Any]) -> [String] {
        let content = anthropicMessage["content"] as? [[String: Any]] ?? []
        return content.compactMap { block in
            guard (block["type"] as? String) == "text" else { return nil }
            let text = block["text"] as? String ?? ""
            return text.isEmpty ? nil : text
        }
    }

    private static func toolUseBlocks(from anthropicMessage: [String: Any]) -> [[String: Any]] {
        let content = anthropicMessage["content"] as? [[String: Any]] ?? []
        return content.filter { ($0["type"] as? String) == "tool_use" }
    }

    private static func jsonObject(from text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }

    private static func stringValue(_ value: Any?) -> String {
        if let string = value as? String {
            return string
        }
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            return "\(value ?? "")"
        }
        return text
    }

    private static func intValue(from value: Any?) -> Int? {
        switch value {
        case let value as Int:
            return value
        case let value as Int64:
            return Int(value)
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }

    private static func int64Value(from value: Any?) -> Int64? {
        switch value {
        case let value as Int64:
            return value
        case let value as Int:
            return Int64(value)
        case let value as NSNumber:
            return value.int64Value
        case let value as String:
            return Int64(value)
        default:
            return nil
        }
    }

    private static func sseData(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? "{}"
        return "data: \(data)\n\n"
    }
}
