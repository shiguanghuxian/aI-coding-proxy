import Foundation

public struct GeminiToolSchemaContext: Sendable, Equatable {
    public var requiredParameterNames: [String]

    public init(requiredParameterNames: [String] = []) {
        self.requiredParameterNames = requiredParameterNames
    }
}

public struct GeminiToolCorrectionHint: Sendable, Equatable {
    public var toolName: String
    public var missingRequiredParameter: String
    public var rawError: String

    public init(
        toolName: String,
        missingRequiredParameter: String,
        rawError: String
    ) {
        self.toolName = toolName
        self.missingRequiredParameter = missingRequiredParameter
        self.rawError = rawError
    }
}

public struct GeminiRequestContext: Sendable, Equatable {
    public var sourceModel: String
    public var includeThoughts: Bool
    public var thinkingBudget: Int?
    public var thinkingLevel: String?
    public var allowsFunctionCalls: Bool
    public var isGeminiCLISession: Bool
    public var toolSchemasByName: [String: GeminiToolSchemaContext]
    public var toolCorrectionHints: [GeminiToolCorrectionHint]

    public init(
        sourceModel: String,
        includeThoughts: Bool = true,
        thinkingBudget: Int? = nil,
        thinkingLevel: String? = nil,
        allowsFunctionCalls: Bool = false,
        isGeminiCLISession: Bool = false,
        toolSchemasByName: [String: GeminiToolSchemaContext] = [:],
        toolCorrectionHints: [GeminiToolCorrectionHint] = []
    ) {
        self.sourceModel = sourceModel
        self.includeThoughts = includeThoughts
        self.thinkingBudget = thinkingBudget
        self.thinkingLevel = thinkingLevel
        self.allowsFunctionCalls = allowsFunctionCalls
        self.isGeminiCLISession = isGeminiCLISession
        self.toolSchemasByName = toolSchemasByName
        self.toolCorrectionHints = toolCorrectionHints
    }

    public static func `default`(sourceModel: String) -> Self {
        .init(sourceModel: sourceModel)
    }
}

public struct GeminiToolCallStreamState: Sendable, Equatable {
    public var itemID: String
    public var callID: String
    public var name: String
    public var thoughtSignature: String?
    public var argumentsBuffer: String
    public var emitted: Bool

    public init(
        itemID: String,
        callID: String,
        name: String,
        thoughtSignature: String? = nil,
        argumentsBuffer: String = "",
        emitted: Bool = false
    ) {
        self.itemID = itemID
        self.callID = callID
        self.name = name
        self.thoughtSignature = thoughtSignature
        self.argumentsBuffer = argumentsBuffer
        self.emitted = emitted
    }
}

public struct GeminiThoughtStreamState: Sendable, Equatable {
    public var key: String
    public var buffer: String
    public var emitted: Bool

    public init(
        key: String,
        buffer: String = "",
        emitted: Bool = false
    ) {
        self.key = key
        self.buffer = buffer
        self.emitted = emitted
    }
}

public struct GeminiStreamState: Sendable, Equatable {
    public var toolCalls: [String: GeminiToolCallStreamState]
    public var thoughtParts: [String: GeminiThoughtStreamState]
    public var sawVisibleContent: Bool
    public var sawThoughtContent: Bool
    public var emittedVisibleTextThoughtSignature: Bool
    public var finishReasonOverride: String?

    public init(
        toolCalls: [String: GeminiToolCallStreamState] = [:],
        thoughtParts: [String: GeminiThoughtStreamState] = [:],
        sawVisibleContent: Bool = false,
        sawThoughtContent: Bool = false,
        emittedVisibleTextThoughtSignature: Bool = false,
        finishReasonOverride: String? = nil
    ) {
        self.toolCalls = toolCalls
        self.thoughtParts = thoughtParts
        self.sawVisibleContent = sawVisibleContent
        self.sawThoughtContent = sawThoughtContent
        self.emittedVisibleTextThoughtSignature = emittedVisibleTextThoughtSignature
        self.finishReasonOverride = finishReasonOverride
    }
}

public enum GeminiTranscoder {
    public static let defaultGeminiModel = "gemini-2.5-flash"
    public static let compatibilityThoughtSignature = "proxy_ts_compat_bypass_v1"

    private struct NormalizedGeminiTools {
        var tools: [[String: Any]]
        var toolSchemasByName: [String: GeminiToolSchemaContext]
    }

    private struct NormalizedGeminiContents {
        var input: [[String: Any]]
        var toolCorrectionHints: [GeminiToolCorrectionHint]
    }

    public static func normalizeGenerateContentRequest(
        _ payload: [String: Any],
        model: String
    ) throws -> (request: [String: Any], responseModel: String, context: GeminiRequestContext) {
        let responseModel = self.normalizedModelName(model)
        let normalizedTools = self.normalizeTools(payload["tools"])
        let contents = try self.normalizeContents(
            payload["contents"],
            toolSchemasByName: normalizedTools.toolSchemasByName
        )
        let instructions = try self.normalizeSystemInstruction(
            payload["systemInstruction"] ?? payload["system_instruction"]
        )
        let generationConfig = self.generationConfig(
            payload["generationConfig"] ?? payload["generation_config"]
        )
        let thinkingConfig = self.thinkingConfig(
            generationConfig["thinkingConfig"] ?? generationConfig["thinking_config"]
        )

        if let candidateCount = self.intValue(
            generationConfig["candidateCount"] ?? generationConfig["candidate_count"]
        ), candidateCount > 1 {
            throw ProxyError.message("Gemini `candidateCount` > 1 is not supported at `$.generationConfig.candidateCount`.")
        }

        var request: [String: Any] = [
            "model": responseModel,
            "stream": true,
            "store": false,
            "instructions": instructions,
            "input": ProxyTranscoder.sanitizedTrailingToolHistory(contents.input),
            "parallel_tool_calls": false,
            "include": ["reasoning.encrypted_content"],
            "reasoning": [
                "effort": "low",
                "summary": "auto",
            ],
        ]

        if let temperature = generationConfig["temperature"] {
            request["temperature"] = temperature
        }
        if let topP = generationConfig["topP"] ?? generationConfig["top_p"] {
            request["top_p"] = topP
        }
        if let topK = generationConfig["topK"] ?? generationConfig["top_k"] {
            request["top_k"] = topK
        }
        if let maxOutputTokens = generationConfig["maxOutputTokens"] ?? generationConfig["max_output_tokens"] {
            request["max_output_tokens"] = maxOutputTokens
        }
        if let stopSequences = generationConfig["stopSequences"] ?? generationConfig["stop_sequences"] {
            request["stop"] = stopSequences
        }

        let tools = normalizedTools.tools
        if !tools.isEmpty {
            request["tools"] = tools
        }
        if let toolChoice = self.normalizeToolChoice(payload["toolConfig"] ?? payload["tool_config"]) {
            request["tool_choice"] = toolChoice
        }

        let context = GeminiRequestContext(
            sourceModel: responseModel,
            includeThoughts: self.boolValue(
                thinkingConfig["includeThoughts"] ?? thinkingConfig["include_thoughts"]
            ) ?? true,
            thinkingBudget: self.intValue(
                thinkingConfig["thinkingBudget"] ?? thinkingConfig["thinking_budget"]
            ),
            thinkingLevel: self.trimmedString(
                thinkingConfig["thinkingLevel"] ?? thinkingConfig["thinking_level"]
            ),
            allowsFunctionCalls: !tools.isEmpty,
            toolSchemasByName: normalizedTools.toolSchemasByName,
            toolCorrectionHints: contents.toolCorrectionHints
        )

        return (request, responseModel, context)
    }

    public static func normalizeCountTokensRequest(
        _ payload: [String: Any],
        model: String
    ) throws -> (request: [String: Any], responseModel: String, context: GeminiRequestContext) {
        var normalized = try self.normalizeGenerateContentRequest(payload, model: model)
        normalized.request["stream"] = false
        normalized.request["max_output_tokens"] = 1
        return normalized
    }

    public static func generateContentResponse(
        from completedResponse: [String: Any],
        requestedModel: String,
        context: GeminiRequestContext
    ) -> [String: Any] {
        let usage = ProxyTranscoder.usageFromCompletedResponse(completedResponse)
        return [
            "candidates": [[
                "index": 0,
                "content": [
                    "role": "model",
                    "parts": self.parts(
                        from: completedResponse,
                        requestedModel: requestedModel,
                        includeThoughts: context.includeThoughts,
                        includeNonThoughts: true,
                        context: context
                    ),
                ],
                "finishReason": self.finishReason(from: completedResponse, context: context),
            ]],
            "modelVersion": requestedModel,
            "usageMetadata": self.usageMetadata(from: usage),
        ]
    }

    public static func countTokensResponse(from usage: UpstreamUsage) -> [String: Any] {
        var response: [String: Any] = [
            "totalTokens": usage.inputTokens,
        ]
        if let cacheHitTokens = usage.cacheHitTokens, cacheHitTokens > 0 {
            response["cachedContentTokenCount"] = cacheHitTokens
        }
        return response
    }

    public static func containsThoughtSignature(in payload: [String: Any]) -> Bool {
        self.valueContainsThoughtSignature(payload)
    }

    public static func replacingThoughtSignaturesWithCompatibilitySignature(
        in payload: [String: Any]
    ) -> [String: Any] {
        self.replaceThoughtSignatures(in: payload) as? [String: Any] ?? payload
    }

    public static func streamGenerateContentSSEChunks(
        from event: SSEEvent,
        state: inout GeminiStreamState,
        requestedModel: String,
        context: GeminiRequestContext
    ) -> [String] {
        guard let json = ProxyTranscoder.jsonObject(from: event),
              let type = ProxyTranscoder.responseEventType(from: json)
        else {
            return []
        }

        switch type {
        case "response.output_text.delta":
            let delta = json["delta"] as? String ?? ""
            guard !delta.isEmpty else { return [] }
            let textPart = self.visibleTextPartPayload(
                text: delta,
                thoughtSignature: nil,
                context: context,
                emittedThoughtSignature: &state.emittedVisibleTextThoughtSignature
            )
            state.sawVisibleContent = true
            return [
                self.sseData([
                    "candidates": [[
                        "index": 0,
                        "content": [
                            "role": "model",
                            "parts": [
                                textPart,
                            ],
                        ],
                    ]],
                ]),
            ]

        case "response.reasoning_summary_text.delta",
             "response.reasoning_summary_text.done",
             "response.reasoning_text.delta",
             "response.reasoning_text.done":
            return self.reasoningChunks(
                from: json,
                type: type,
                state: &state,
                context: context
            )

        case "response.output_item.added",
             "response.function_call_arguments.delta",
             "response.function_call_arguments.done",
             "response.output_item.done":
            guard let functionCall = ProxyTranscoder.upstreamFunctionCallEvent(from: json) else {
                return []
            }
            return self.functionCallChunks(
                from: functionCall,
                state: &state,
                requestedModel: requestedModel,
                context: context
            )

        case "response.completed":
            let response = json["response"] as? [String: Any] ?? [:]
            let usage = ProxyTranscoder.usageFromCompletedResponse(response)
            var chunks: [String] = []
            let fallbackThoughts = context.includeThoughts && !state.sawThoughtContent
            let fallbackVisible = !state.sawVisibleContent
            if fallbackThoughts || fallbackVisible {
                let parts = self.parts(
                    from: response,
                    requestedModel: requestedModel,
                    includeThoughts: fallbackThoughts,
                    includeNonThoughts: fallbackVisible,
                    context: context
                )
                if !parts.isEmpty {
                    chunks.append(
                        self.sseData([
                            "candidates": [[
                                "index": 0,
                                "content": [
                                    "role": "model",
                                    "parts": parts,
                                ],
                            ]],
                        ])
                    )
                }
            }
            let finishReason = state.finishReasonOverride
                ?? self.finishReason(from: response, context: context)
            chunks.append(
                self.sseData([
                    "candidates": [[
                        "index": 0,
                        "content": [
                            "role": "model",
                            "parts": [],
                        ],
                        "finishReason": finishReason,
                    ]],
                    "modelVersion": requestedModel,
                    "usageMetadata": self.usageMetadata(from: usage),
                ])
            )
            return chunks

        default:
            return []
        }
    }

    public static func errorSSEChunk(
        status: Int,
        message: String,
        statusText: String
    ) -> String {
        self.sseData([
            "error": [
                "code": status,
                "message": message,
                "status": statusText,
            ],
        ])
    }

    public static func extractText(from response: [String: Any]) -> String {
        let candidates = response["candidates"] as? [[String: Any]] ?? []
        let parts = (candidates.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        var fragments: [String] = []
        for part in parts {
            if self.boolValue(part["thought"]) == true {
                continue
            }
            if let text = part["text"] as? String, !text.isEmpty {
                fragments.append(text)
                continue
            }
            if let functionCall = part["functionCall"] as? [String: Any],
               let name = functionCall["name"] as? String,
               !name.isEmpty
            {
                fragments.append("[functionCall] \(name)")
            }
        }
        return fragments.joined(separator: "\n")
    }

    private static func normalizedModelName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Self.defaultGeminiModel
        }
        if trimmed.hasPrefix("models/") {
            return String(trimmed.dropFirst("models/".count))
        }
        return trimmed
    }

    private static func normalizeSystemInstruction(_ raw: Any?) throws -> String {
        guard let raw else { return "" }
        if let text = raw as? String {
            return text
        }
        guard let content = raw as? [String: Any] else {
            throw ProxyError.message("Unsupported Gemini `systemInstruction` payload.")
        }
        return try self.extractTextParts(
            from: content["parts"],
            path: "$.systemInstruction.parts"
        )
        .joined(separator: "\n\n")
    }

    private static func normalizeContents(
        _ raw: Any?,
        toolSchemasByName: [String: GeminiToolSchemaContext]
    ) throws -> NormalizedGeminiContents {
        guard let contents = raw as? [Any], !contents.isEmpty else {
            throw ProxyError.message("Gemini request is missing `contents`.")
        }

        var input: [[String: Any]] = []
        var pendingFunctionCallIDsByName: [String: [String]] = [:]
        var toolCorrectionHints: [GeminiToolCorrectionHint] = []

        for (contentIndex, rawContent) in contents.enumerated() {
            guard let content = rawContent as? [String: Any] else {
                throw ProxyError.message("Unsupported Gemini content at `$.contents[\(contentIndex)]`.")
            }

            let rawRole = ((content["role"] as? String) ?? "user").lowercased()
            let role: String
            switch rawRole {
            case "model", "assistant":
                role = "assistant"
            case "user", "tool":
                role = "user"
            default:
                throw ProxyError.message("Unsupported Gemini role `\(rawRole)` at `$.contents[\(contentIndex)].role`.")
            }

            guard let parts = content["parts"] as? [Any], !parts.isEmpty else {
                throw ProxyError.message("Gemini content is missing `parts` at `$.contents[\(contentIndex)].parts`.")
            }

            var textBlocks: [[String: Any]] = []

            for (partIndex, rawPart) in parts.enumerated() {
                guard let part = rawPart as? [String: Any] else {
                    throw ProxyError.message("Unsupported Gemini part at `$.contents[\(contentIndex)].parts[\(partIndex)]`.")
                }

                if self.isThoughtPart(part) {
                    continue
                }

                if let text = part["text"] as? String {
                    textBlocks.append(
                        ProxyTranscoder.textContentBlock(text: text, role: role)
                    )
                    continue
                }

                if !textBlocks.isEmpty {
                    input.append([
                        "type": "message",
                        "role": role,
                        "content": textBlocks,
                    ])
                    textBlocks.removeAll(keepingCapacity: true)
                }

                if let functionCall = part["functionCall"] as? [String: Any]
                    ?? part["function_call"] as? [String: Any]
                {
                    guard role == "assistant" else {
                        throw ProxyError.message("Gemini `functionCall` is only supported on model content at `$.contents[\(contentIndex)].parts[\(partIndex)]`.")
                    }
                    let name = (functionCall["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !name.isEmpty else {
                        throw ProxyError.message("Gemini `functionCall` is missing `name` at `$.contents[\(contentIndex)].parts[\(partIndex)].functionCall.name`.")
                    }
                    let callID = self.functionCallID(
                        from: functionCall,
                        fallbackPrefix: "call_"
                    )
                    pendingFunctionCallIDsByName[name, default: []].append(callID)
                    input.append([
                        "type": "function_call",
                        "call_id": callID,
                        "name": name,
                        "arguments": self.jsonString(functionCall["args"] ?? functionCall["arguments"] ?? [:]),
                    ])
                    continue
                }

                if let functionResponse = part["functionResponse"] as? [String: Any]
                    ?? part["function_response"] as? [String: Any]
                {
                    let name = (functionResponse["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    guard !name.isEmpty else {
                        throw ProxyError.message("Gemini `functionResponse` is missing `name` at `$.contents[\(contentIndex)].parts[\(partIndex)].functionResponse.name`.")
                    }
                    let explicitCallID = self.trimmedString(
                        functionResponse["id"]
                            ?? functionResponse["call_id"]
                            ?? functionResponse["callId"]
                    )
                    let queued = pendingFunctionCallIDsByName[name] ?? []
                    let callID: String
                    if let explicitCallID {
                        callID = explicitCallID
                        if let first = queued.first, first == explicitCallID {
                            pendingFunctionCallIDsByName[name] = Array(queued.dropFirst())
                        }
                    } else if let first = queued.first {
                        callID = first
                        pendingFunctionCallIDsByName[name] = Array(queued.dropFirst())
                    } else {
                        throw ProxyError.message(
                            "Gemini `functionResponse` is missing `id` and no matching prior `functionCall` was found at `$.contents[\(contentIndex)].parts[\(partIndex)].functionResponse`."
                        )
                    }

                    if let correctionHint = self.toolCorrectionHint(
                        toolName: name,
                        response: functionResponse["response"],
                        toolSchemasByName: toolSchemasByName
                    ), !toolCorrectionHints.contains(correctionHint) {
                        toolCorrectionHints.append(correctionHint)
                    }

                    input.append([
                        "type": "function_call_output",
                        "call_id": callID,
                        "output": self.jsonString(functionResponse["response"] ?? [:]),
                    ])
                    continue
                }

                if part["inlineData"] != nil || part["inline_data"] != nil
                    || part["fileData"] != nil || part["file_data"] != nil
                    || part["executableCode"] != nil || part["executable_code"] != nil
                    || part["codeExecutionResult"] != nil || part["code_execution_result"] != nil
                {
                    throw ProxyError.message("Gemini non-text multimodal parts are not supported at `$.contents[\(contentIndex)].parts[\(partIndex)]`.")
                }

                throw ProxyError.message("Unsupported Gemini part at `$.contents[\(contentIndex)].parts[\(partIndex)]`.")
            }

            if !textBlocks.isEmpty {
                input.append([
                    "type": "message",
                    "role": role,
                    "content": textBlocks,
                ])
            }
        }

        return .init(
            input: input,
            toolCorrectionHints: toolCorrectionHints
        )
    }

    private static func extractTextParts(from raw: Any?, path: String) throws -> [String] {
        guard let parts = raw as? [Any] else {
            throw ProxyError.message("Unsupported Gemini text parts at `\(path)`.")
        }
        return try parts.enumerated().map { index, rawPart in
            guard let part = rawPart as? [String: Any], let text = part["text"] as? String else {
                throw ProxyError.message("Gemini system instructions only support text parts at `\(path)[\(index)]`.")
            }
            return text
        }
    }

    private static func generationConfig(_ raw: Any?) -> [String: Any] {
        raw as? [String: Any] ?? [:]
    }

    private static func thinkingConfig(_ raw: Any?) -> [String: Any] {
        raw as? [String: Any] ?? [:]
    }

    private static func normalizeTools(_ raw: Any?) -> NormalizedGeminiTools {
        guard let tools = raw as? [Any] else {
            return .init(tools: [], toolSchemasByName: [:])
        }
        var normalized: [[String: Any]] = []
        var toolSchemasByName: [String: GeminiToolSchemaContext] = [:]
        for rawTool in tools {
            guard let tool = rawTool as? [String: Any] else { continue }
            let declarations = tool["functionDeclarations"] as? [Any]
                ?? tool["function_declarations"] as? [Any]
                ?? []
            for rawDeclaration in declarations {
                guard let declaration = rawDeclaration as? [String: Any] else { continue }
                let name = (declaration["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !name.isEmpty else { continue }
                var function: [String: Any] = [
                    "type": "function",
                    "name": name,
                ]
                if let description = declaration["description"] {
                    function["description"] = description
                }
                if let parameters = declaration["parameters"] {
                    function["parameters"] = parameters
                }
                normalized.append(function)

                toolSchemasByName[name] = GeminiToolSchemaContext(
                    requiredParameterNames: self.requiredParameterNames(from: declaration["parameters"])
                )
            }
        }
        return .init(
            tools: normalized,
            toolSchemasByName: toolSchemasByName
        )
    }

    private static func normalizeToolChoice(_ raw: Any?) -> Any? {
        guard let rawConfig = raw as? [String: Any] else {
            return nil
        }
        let functionCallingConfig = rawConfig["functionCallingConfig"] as? [String: Any]
            ?? rawConfig["function_calling_config"] as? [String: Any]
            ?? [:]
        let mode = ((functionCallingConfig["mode"] as? String) ?? "").uppercased()
        let allowedNames = (functionCallingConfig["allowedFunctionNames"] as? [String]
            ?? functionCallingConfig["allowed_function_names"] as? [String]
            ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        switch mode {
        case "AUTO", "":
            return "auto"
        case "ANY":
            if allowedNames.count == 1 {
                return [
                    "type": "function",
                    "name": allowedNames[0],
                ]
            }
            return "required"
        case "NONE":
            return nil
        default:
            return nil
        }
    }

    private static func parts(
        from completedResponse: [String: Any],
        requestedModel: String,
        includeThoughts: Bool,
        includeNonThoughts: Bool,
        context: GeminiRequestContext
    ) -> [[String: Any]] {
        let output = completedResponse["output"] as? [[String: Any]] ?? []
        var parts: [[String: Any]] = []
        var emittedVisibleTextThoughtSignature = false
        for item in output {
            let type = item["type"] as? String ?? ""
            switch type {
            case "reasoning":
                guard includeThoughts else { continue }
                parts.append(contentsOf: self.reasoningParts(from: item))
            case "message":
                guard includeNonThoughts else { continue }
                let content = item["content"] as? [[String: Any]] ?? []
                var messageThoughtSignature = self.itemThoughtSignature(from: item)
                for block in content {
                    guard let text = self.messageText(from: block) else { continue }
                    parts.append(
                        self.visibleTextPartPayload(
                            text: text,
                            thoughtSignature: messageThoughtSignature,
                            context: context,
                            emittedThoughtSignature: &emittedVisibleTextThoughtSignature
                        )
                    )
                    messageThoughtSignature = nil
                }
            case "function_call":
                guard includeNonThoughts,
                      context.allowsFunctionCalls,
                      let functionCall = self.functionCallPart(
                        callID: self.trimmedString(item["call_id"]),
                        name: self.trimmedString(item["name"]),
                        arguments: item["arguments"]
                      )
                else {
                    continue
                }
                parts.append(
                    self.functionCallPartPayload(
                        functionCall: functionCall,
                        requestedModel: requestedModel,
                        thoughtSignature: self.itemThoughtSignature(from: item)
                    )
                )
            default:
                continue
            }
        }
        return parts
    }

    private static func finishReason(
        from completedResponse: [String: Any],
        context: GeminiRequestContext
    ) -> String {
        let output = completedResponse["output"] as? [[String: Any]] ?? []
        if output.contains(where: { self.isMalformedFunctionCall($0) }) {
            return "MALFORMED_FUNCTION_CALL"
        }
        if output.contains(where: { ($0["type"] as? String) == "function_call" }),
           context.allowsFunctionCalls == false
        {
            return "UNEXPECTED_TOOL_CALL"
        }

        let incompleteReason = self.incompleteReason(from: completedResponse)
        if incompleteReason == "max_output_tokens" {
            return "MAX_TOKENS"
        }
        if self.isSafetyReason(incompleteReason) || self.containsRefusal(in: completedResponse) {
            return "SAFETY"
        }

        return "STOP"
    }

    private static func usageMetadata(from usage: UpstreamUsage) -> [String: Any] {
        var metadata: [String: Any] = [
            "promptTokenCount": usage.inputTokens,
            "candidatesTokenCount": usage.outputTokens,
            "totalTokenCount": usage.totalTokens,
        ]
        if let cacheHitTokens = usage.cacheHitTokens, cacheHitTokens > 0 {
            metadata["cachedContentTokenCount"] = cacheHitTokens
        }
        return metadata
    }

    private static func functionCallChunks(
        from event: UpstreamFunctionCallEvent,
        state: inout GeminiStreamState,
        requestedModel: String,
        context: GeminiRequestContext
    ) -> [String] {
        let itemID = event.itemID ?? "fc_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var toolState = state.toolCalls[itemID] ?? .init(
            itemID: itemID,
            callID: event.callID ?? "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))",
            name: event.name ?? "",
            thoughtSignature: event.thoughtSignature
        )

        if let callID = event.callID, !callID.isEmpty {
            toolState.callID = callID
        }
        if let name = event.name, !name.isEmpty {
            toolState.name = name
        }
        if let thoughtSignature = event.thoughtSignature, !thoughtSignature.isEmpty {
            toolState.thoughtSignature = thoughtSignature
        }
        if let delta = event.delta, !delta.isEmpty {
            toolState.argumentsBuffer.append(delta)
        }
        if let arguments = event.arguments, !arguments.isEmpty {
            toolState.argumentsBuffer = arguments
        }

        state.toolCalls[itemID] = toolState

        guard context.allowsFunctionCalls else {
            state.finishReasonOverride = "UNEXPECTED_TOOL_CALL"
            return []
        }

        switch event.phase {
        case .added, .delta:
            return []
        case .argumentsDone, .itemDone:
            guard toolState.emitted == false else {
                return []
            }
            guard let functionCall = self.functionCallPart(
                callID: toolState.callID,
                name: toolState.name,
                arguments: toolState.argumentsBuffer
            ) else {
                state.finishReasonOverride = "MALFORMED_FUNCTION_CALL"
                return []
            }
            toolState.emitted = true
            state.toolCalls[itemID] = toolState
            state.sawVisibleContent = true
            return [
                self.sseData([
                    "candidates": [[
                        "index": 0,
                        "content": [
                            "role": "model",
                            "parts": [
                                self.functionCallPartPayload(
                                    functionCall: functionCall,
                                    requestedModel: requestedModel,
                                    thoughtSignature: toolState.thoughtSignature
                                ),
                            ],
                        ],
                    ]],
                ]),
            ]
        }
    }

    private static func reasoningChunks(
        from json: [String: Any],
        type: String,
        state: inout GeminiStreamState,
        context: GeminiRequestContext
    ) -> [String] {
        guard context.includeThoughts else {
            return []
        }

        let key = self.reasoningStreamKey(from: json, type: type)
        var thoughtState = state.thoughtParts[key] ?? .init(key: key)
        let text = self.reasoningStreamText(from: json)

        if type.hasSuffix(".delta") {
            guard !text.isEmpty else { return [] }
            thoughtState.buffer.append(text)
            thoughtState.emitted = true
            state.thoughtParts[key] = thoughtState
            state.sawThoughtContent = true
            return [self.thoughtChunk(text: text)]
        }

        guard !text.isEmpty else {
            state.thoughtParts[key] = thoughtState
            return []
        }

        thoughtState.buffer = text
        defer {
            state.thoughtParts[key] = thoughtState
        }
        guard thoughtState.emitted == false else {
            return []
        }

        thoughtState.emitted = true
        state.sawThoughtContent = true
        return [self.thoughtChunk(text: text)]
    }

    private static func jsonString(_ value: Any) -> String {
        if let string = value as? String {
            return string
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            return "\(value)"
        }
        return text
    }

    private static func jsonObject(from raw: Any?) -> [String: Any]? {
        if let object = raw as? [String: Any] {
            return object
        }
        guard let text = raw as? String,
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return object
    }

    private static func requiredParameterNames(from rawParameters: Any?) -> [String] {
        guard let parameters = rawParameters as? [String: Any] else {
            return []
        }
        let required = parameters["required"] as? [Any] ?? []
        var names: [String] = []
        for rawName in required {
            guard let name = self.trimmedString(rawName) else {
                continue
            }
            if !names.contains(name) {
                names.append(name)
            }
        }
        return names
    }

    private static func toolCorrectionHint(
        toolName: String,
        response: Any?,
        toolSchemasByName: [String: GeminiToolSchemaContext]
    ) -> GeminiToolCorrectionHint? {
        guard let errorText = self.functionResponseErrorMessage(from: response),
              let missingRequiredParameter = self.missingRequiredParameterName(from: errorText)
        else {
            return nil
        }

        let requiredParameterNames = toolSchemasByName[toolName]?.requiredParameterNames ?? []
        guard requiredParameterNames.isEmpty || requiredParameterNames.contains(missingRequiredParameter) else {
            return nil
        }

        return .init(
            toolName: toolName,
            missingRequiredParameter: missingRequiredParameter,
            rawError: errorText
        )
    }

    private static func functionResponseErrorMessage(from response: Any?) -> String? {
        if let object = response as? [String: Any] {
            return self.errorMessage(from: object["error"])
        }
        if let object = self.jsonObject(from: response) {
            return self.errorMessage(from: object["error"])
        }
        return self.errorMessage(from: response)
    }

    private static func errorMessage(from value: Any?) -> String? {
        if let text = self.trimmedString(value) {
            return text
        }
        guard let object = value as? [String: Any] else {
            return nil
        }
        return self.trimmedString(
            object["message"]
                ?? object["detail"]
                ?? object["description"]
                ?? object["error_description"]
                ?? object["error"]
        )
    }

    private static func missingRequiredParameterName(from errorText: String) -> String? {
        let pattern = #"(?:params\s+)?must have required property ['"]([^'"]+)['"]"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return nil
        }

        let fullRange = NSRange(errorText.startIndex..<errorText.endIndex, in: errorText)
        guard let match = regex.firstMatch(in: errorText, options: [], range: fullRange),
              match.numberOfRanges >= 2,
              let range = Range(match.range(at: 1), in: errorText)
        else {
            return nil
        }
        return String(errorText[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func intValue(_ value: Any?) -> Int? {
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

    private static func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let value as Bool:
            return value
        case let value as NSNumber:
            return value.boolValue
        case let value as String:
            switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "1":
                return true
            case "false", "0":
                return false
            default:
                return nil
            }
        default:
            return nil
        }
    }

    private static func trimmedString(_ value: Any?) -> String? {
        let trimmed = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isThoughtPart(_ part: [String: Any]) -> Bool {
        self.boolValue(part["thought"]) == true
    }

    private static func messageText(from block: [String: Any]) -> String? {
        let blockType = (block["type"] as? String ?? "").lowercased()
        switch blockType {
        case "output_text", "text":
            return block["text"] as? String
        case "refusal":
            return (block["refusal"] as? String) ?? (block["text"] as? String)
        default:
            return nil
        }
    }

    private static func reasoningParts(from item: [String: Any]) -> [[String: Any]] {
        let summaryParts = (item["summary"] as? [Any] ?? []).compactMap { rawPart -> String? in
            guard let part = rawPart as? [String: Any] else {
                return nil
            }
            let type = (part["type"] as? String ?? "").lowercased()
            guard type == "summary_text" || type == "text" || part["summary_text"] != nil else {
                return nil
            }
            return self.trimmedString(part["text"] ?? part["summary_text"])
        }
        if !summaryParts.isEmpty {
            return summaryParts.map { ["text": $0, "thought": true] }
        }

        let contentParts = (item["content"] as? [Any] ?? []).compactMap { rawPart -> String? in
            guard let part = rawPart as? [String: Any] else {
                return nil
            }
            let type = (part["type"] as? String ?? "").lowercased()
            guard type == "reasoning_text" || type == "text" || part["reasoning_text"] != nil else {
                return nil
            }
            return self.trimmedString(part["text"] ?? part["reasoning_text"])
        }
        return contentParts.map { ["text": $0, "thought": true] }
    }

    private static func itemThoughtSignature(from item: [String: Any]) -> String? {
        self.trimmedString(
            item["thoughtSignature"]
                ?? item["thought_signature"]
                ?? ((item["functionCall"] as? [String: Any])?["thoughtSignature"])
                ?? ((item["functionCall"] as? [String: Any])?["thought_signature"])
        )
    }

    private static func functionCallPart(
        callID: String?,
        name: String?,
        arguments: Any?
    ) -> [String: Any]? {
        guard let name else {
            return nil
        }

        let argumentsObject: [String: Any]
        if let object = arguments as? [String: Any] {
            argumentsObject = object
        } else if let text = arguments as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                argumentsObject = [:]
            } else if let object = self.jsonObject(from: text) {
                argumentsObject = object
            } else {
                return nil
            }
        } else if arguments == nil {
            argumentsObject = [:]
        } else {
            return nil
        }

        var functionCall: [String: Any] = [
            "name": name,
            "args": argumentsObject,
        ]
        if let callID {
            functionCall["id"] = callID
        }
        return functionCall
    }

    private static func functionCallPartPayload(
        functionCall: [String: Any],
        requestedModel: String,
        thoughtSignature: String?
    ) -> [String: Any] {
        var part: [String: Any] = [
            "functionCall": functionCall,
        ]
        if let resolvedThoughtSignature = thoughtSignature
            ?? self.syntheticThoughtSignature(
                requestedModel: requestedModel,
                functionCall: functionCall
            )
        {
            part["thoughtSignature"] = resolvedThoughtSignature
        }
        return part
    }

    private static func visibleTextPartPayload(
        text: String,
        thoughtSignature: String?,
        context: GeminiRequestContext,
        emittedThoughtSignature: inout Bool
    ) -> [String: Any] {
        var part: [String: Any] = [
            "text": text,
        ]
        if let resolvedThoughtSignature = self.visibleTextThoughtSignature(
            explicitThoughtSignature: thoughtSignature,
            context: context,
            emittedThoughtSignature: &emittedThoughtSignature
        ) {
            part["thoughtSignature"] = resolvedThoughtSignature
        }
        return part
    }

    private static func visibleTextThoughtSignature(
        explicitThoughtSignature: String?,
        context: GeminiRequestContext,
        emittedThoughtSignature: inout Bool
    ) -> String? {
        if let explicitThoughtSignature = self.trimmedString(explicitThoughtSignature) {
            emittedThoughtSignature = true
            return explicitThoughtSignature
        }
        guard context.isGeminiCLISession, emittedThoughtSignature == false else {
            return nil
        }
        emittedThoughtSignature = true
        return self.compatibilityThoughtSignature
    }

    private static func syntheticThoughtSignature(
        requestedModel: String,
        functionCall: [String: Any]
    ) -> String? {
        guard let callID = self.trimmedString(functionCall["id"]),
              let name = self.trimmedString(functionCall["name"])
        else {
            return nil
        }

        let arguments = self.jsonString(functionCall["args"] ?? [:])
        let seed = [
            requestedModel.trimmingCharacters(in: .whitespacesAndNewlines),
            callID,
            name,
            arguments,
        ].joined(separator: "\n")
        return "proxy_ts_\(Helpers.sha256(seed))"
    }

    private static func valueContainsThoughtSignature(_ value: Any?) -> Bool {
        switch value {
        case let object as [String: Any]:
            if object["thoughtSignature"] != nil || object["thought_signature"] != nil {
                return true
            }
            return object.values.contains { self.valueContainsThoughtSignature($0) }
        case let array as [Any]:
            return array.contains { self.valueContainsThoughtSignature($0) }
        default:
            return false
        }
    }

    private static func replaceThoughtSignatures(in value: Any?) -> Any? {
        switch value {
        case let object as [String: Any]:
            var updated: [String: Any] = [:]
            updated.reserveCapacity(object.count)
            for (key, nestedValue) in object {
                if key == "thoughtSignature" || key == "thought_signature" {
                    updated[key] = self.compatibilityThoughtSignature
                } else {
                    updated[key] = self.replaceThoughtSignatures(in: nestedValue)
                }
            }
            return updated
        case let array as [Any]:
            return array.map { self.replaceThoughtSignatures(in: $0) as Any }
        default:
            return value
        }
    }

    private static func isMalformedFunctionCall(_ item: [String: Any]) -> Bool {
        guard (item["type"] as? String) == "function_call" else {
            return false
        }
        return self.functionCallPart(
            callID: self.trimmedString(item["call_id"]),
            name: self.trimmedString(item["name"]),
            arguments: item["arguments"]
        ) == nil
    }

    private static func incompleteReason(from completedResponse: [String: Any]) -> String {
        let status = (completedResponse["status"] as? String)?.lowercased() ?? ""
        guard status == "incomplete" else {
            return ""
        }
        return ((completedResponse["incomplete_details"] as? [String: Any])?["reason"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
    }

    private static func containsRefusal(in completedResponse: [String: Any]) -> Bool {
        let output = completedResponse["output"] as? [[String: Any]] ?? []
        for item in output {
            if (item["type"] as? String)?.lowercased() == "refusal" {
                return true
            }
            let content = item["content"] as? [[String: Any]] ?? []
            if content.contains(where: { (($0["type"] as? String) ?? "").lowercased() == "refusal" }) {
                return true
            }
        }
        return false
    }

    private static func isSafetyReason(_ reason: String) -> Bool {
        guard !reason.isEmpty else {
            return false
        }
        let reasons: Set<String> = [
            "content_filter",
            "content_policy",
            "refusal",
            "safety",
            "safety_violation",
        ]
        return reasons.contains(reason)
    }

    private static func reasoningStreamText(from json: [String: Any]) -> String {
        (json["delta"] as? String)
            ?? (json["text"] as? String)
            ?? (((json["part"] as? [String: Any])?["text"] as? String) ?? "")
    }

    private static func reasoningStreamKey(from json: [String: Any], type: String) -> String {
        let components: [String] = [
            type.replacingOccurrences(of: ".delta", with: "").replacingOccurrences(of: ".done", with: ""),
            self.trimmedString(json["item_id"]) ?? "",
            self.trimmedString(json["id"]) ?? "",
            String(self.intValue(json["output_index"]) ?? -1),
            String(self.intValue(json["content_index"]) ?? -1),
            String(self.intValue(json["summary_index"]) ?? -1),
            String(self.intValue(json["part_index"]) ?? -1),
        ]
        return components.joined(separator: ":")
    }

    private static func thoughtChunk(text: String) -> String {
        self.sseData([
            "candidates": [[
                "index": 0,
                "content": [
                    "role": "model",
                    "parts": [[
                        "text": text,
                        "thought": true,
                    ]],
                ],
            ]],
        ])
    }

    private static func functionCallID(from object: [String: Any], fallbackPrefix: String) -> String {
        if let explicit = self.trimmedString(object["id"] ?? object["call_id"] ?? object["callId"]) {
            return explicit
        }
        return "\(fallbackPrefix)\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    }

    private static func sseData(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? "{}"
        return "data: \(data)\n\n"
    }
}
