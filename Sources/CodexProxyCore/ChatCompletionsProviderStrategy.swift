import Foundation

enum ChatCompletionsProviderID: String, Sendable, Equatable {
    case generic
    case deepSeek
    case deepSeekLegacy
    case mimo
    case minimax
    case senseNova
    case kimi
}

struct ChatCompletionsProviderStrategy: Sendable, Equatable {
    var providerID: ChatCompletionsProviderID
    var profile: ChatCompletionsCompatibilityProfile
    var assemblyMode: ProxyTranscoder.ChatCompletionsAssemblyMode
    var forwardsResponsesReasoningEffort: Bool
    var normalizesDeepSeekThinkingParameters: Bool
    var defaultsThinkingEnabled: Bool
    var defaultReasoningEffort: String?
    var removesHistoricalReasoningContent: Bool
    var injectMissingToolReasoning: Bool
    var injectMissingPlainAssistantReasoning: Bool
    var injectMissingToolOutputs: Bool
    var deferSystemDeveloperInterruptions: Bool
    var omitsEmptyAssistantToolContent: Bool
    var removesThinkingParameters: Bool
    var setsDisabledReasoningEffortNone: Bool
    var dropsNullAssistantContent: Bool
    var dropsToolChoiceAuto: Bool
    var dropsStreamOptions: Bool
    var dropsParallelToolCalls: Bool
    var mergesSystemMessages: Bool
    var dropsResponseFormat: Bool
    var dropsNonFunctionTools: Bool
    var dropsReasoningEffort: Bool
    var extractsInlineThinkTags: Bool
    var stickySessionTTLSeconds: Int64

    static func resolve(
        configured: ChatCompletionsCompatibilityProfile,
        baseURL: String?,
        providerPreset: OpenAICompatibleProviderPreset,
        model: String?
    ) -> ChatCompletionsProviderStrategy {
        let profile = ChatCompletionsCompatibility.resolvedProfile(
            configured: configured,
            baseURL: baseURL,
            providerPreset: providerPreset,
            model: model
        )
        switch profile {
        case .deepSeekV4Thinking:
            return ChatCompletionsProviderStrategy(
                providerID: .deepSeek,
                profile: profile,
                assemblyMode: .deepSeekStableAssembly,
                forwardsResponsesReasoningEffort: true,
                normalizesDeepSeekThinkingParameters: true,
                defaultsThinkingEnabled: true,
                defaultReasoningEffort: "high",
                removesHistoricalReasoningContent: false,
                injectMissingToolReasoning: true,
                injectMissingPlainAssistantReasoning: true,
                injectMissingToolOutputs: true,
                deferSystemDeveloperInterruptions: false,
                omitsEmptyAssistantToolContent: true,
                removesThinkingParameters: false,
                setsDisabledReasoningEffortNone: false,
                dropsNullAssistantContent: true,
                dropsToolChoiceAuto: false,
                dropsStreamOptions: false,
                dropsParallelToolCalls: false,
                mergesSystemMessages: false,
                dropsResponseFormat: false,
                dropsNonFunctionTools: false,
                dropsReasoningEffort: false,
                extractsInlineThinkTags: false,
                stickySessionTTLSeconds: PromptCacheSupport.chatCompletionsAPIKeyStickySessionTTLSeconds
            )
        case .deepSeekLegacyReasoner:
            return ChatCompletionsProviderStrategy(
                providerID: .deepSeekLegacy,
                profile: profile,
                assemblyMode: .standard,
                forwardsResponsesReasoningEffort: false,
                normalizesDeepSeekThinkingParameters: false,
                defaultsThinkingEnabled: false,
                defaultReasoningEffort: nil,
                removesHistoricalReasoningContent: true,
                injectMissingToolReasoning: false,
                injectMissingPlainAssistantReasoning: false,
                injectMissingToolOutputs: false,
                deferSystemDeveloperInterruptions: true,
                omitsEmptyAssistantToolContent: false,
                removesThinkingParameters: false,
                setsDisabledReasoningEffortNone: false,
                dropsNullAssistantContent: false,
                dropsToolChoiceAuto: false,
                dropsStreamOptions: false,
                dropsParallelToolCalls: false,
                mergesSystemMessages: false,
                dropsResponseFormat: false,
                dropsNonFunctionTools: false,
                dropsReasoningEffort: false,
                extractsInlineThinkTags: false,
                stickySessionTTLSeconds: PromptCacheSupport.stickySessionTTLSeconds
            )
        case .mimoStrict:
            return ChatCompletionsProviderStrategy(
                providerID: .mimo,
                profile: profile,
                assemblyMode: .standard,
                forwardsResponsesReasoningEffort: false,
                normalizesDeepSeekThinkingParameters: false,
                defaultsThinkingEnabled: false,
                defaultReasoningEffort: nil,
                removesHistoricalReasoningContent: false,
                injectMissingToolReasoning: true,
                injectMissingPlainAssistantReasoning: false,
                injectMissingToolOutputs: true,
                deferSystemDeveloperInterruptions: true,
                omitsEmptyAssistantToolContent: true,
                removesThinkingParameters: false,
                setsDisabledReasoningEffortNone: false,
                dropsNullAssistantContent: true,
                dropsToolChoiceAuto: false,
                dropsStreamOptions: false,
                dropsParallelToolCalls: false,
                mergesSystemMessages: false,
                dropsResponseFormat: false,
                dropsNonFunctionTools: false,
                dropsReasoningEffort: false,
                extractsInlineThinkTags: false,
                stickySessionTTLSeconds: PromptCacheSupport.chatCompletionsAPIKeyStickySessionTTLSeconds
            )
        case .minimaxStrict:
            return ChatCompletionsProviderStrategy(
                providerID: .minimax,
                profile: profile,
                assemblyMode: .providerStableAssembly,
                forwardsResponsesReasoningEffort: true,
                normalizesDeepSeekThinkingParameters: false,
                defaultsThinkingEnabled: false,
                defaultReasoningEffort: nil,
                removesHistoricalReasoningContent: false,
                injectMissingToolReasoning: false,
                injectMissingPlainAssistantReasoning: false,
                injectMissingToolOutputs: true,
                deferSystemDeveloperInterruptions: true,
                omitsEmptyAssistantToolContent: true,
                removesThinkingParameters: true,
                setsDisabledReasoningEffortNone: true,
                dropsNullAssistantContent: true,
                dropsToolChoiceAuto: true,
                dropsStreamOptions: false,
                dropsParallelToolCalls: false,
                mergesSystemMessages: true,
                dropsResponseFormat: false,
                dropsNonFunctionTools: false,
                dropsReasoningEffort: false,
                extractsInlineThinkTags: true,
                stickySessionTTLSeconds: PromptCacheSupport.chatCompletionsAPIKeyStickySessionTTLSeconds
            )
        case .senseNovaStrict:
            return ChatCompletionsProviderStrategy(
                providerID: .senseNova,
                profile: profile,
                assemblyMode: .providerStableAssembly,
                forwardsResponsesReasoningEffort: true,
                normalizesDeepSeekThinkingParameters: false,
                defaultsThinkingEnabled: false,
                defaultReasoningEffort: nil,
                removesHistoricalReasoningContent: false,
                injectMissingToolReasoning: false,
                injectMissingPlainAssistantReasoning: false,
                injectMissingToolOutputs: true,
                deferSystemDeveloperInterruptions: true,
                omitsEmptyAssistantToolContent: true,
                removesThinkingParameters: true,
                setsDisabledReasoningEffortNone: true,
                dropsNullAssistantContent: true,
                dropsToolChoiceAuto: true,
                dropsStreamOptions: false,
                dropsParallelToolCalls: false,
                mergesSystemMessages: true,
                dropsResponseFormat: true,
                dropsNonFunctionTools: true,
                dropsReasoningEffort: false,
                extractsInlineThinkTags: false,
                stickySessionTTLSeconds: PromptCacheSupport.chatCompletionsAPIKeyStickySessionTTLSeconds
            )
        case .kimiStrict:
            return ChatCompletionsProviderStrategy(
                providerID: .kimi,
                profile: profile,
                assemblyMode: .providerStableAssembly,
                forwardsResponsesReasoningEffort: true,
                normalizesDeepSeekThinkingParameters: false,
                defaultsThinkingEnabled: false,
                defaultReasoningEffort: nil,
                removesHistoricalReasoningContent: false,
                injectMissingToolReasoning: false,
                injectMissingPlainAssistantReasoning: false,
                injectMissingToolOutputs: true,
                deferSystemDeveloperInterruptions: true,
                omitsEmptyAssistantToolContent: true,
                removesThinkingParameters: false,
                setsDisabledReasoningEffortNone: false,
                dropsNullAssistantContent: true,
                dropsToolChoiceAuto: false,
                dropsStreamOptions: false,
                dropsParallelToolCalls: false,
                mergesSystemMessages: false,
                dropsResponseFormat: false,
                dropsNonFunctionTools: false,
                dropsReasoningEffort: true,
                extractsInlineThinkTags: false,
                stickySessionTTLSeconds: PromptCacheSupport.chatCompletionsAPIKeyStickySessionTTLSeconds
            )
        case .genericStrict:
            return ChatCompletionsProviderStrategy(
                providerID: .generic,
                profile: profile,
                assemblyMode: .providerStableAssembly,
                forwardsResponsesReasoningEffort: true,
                normalizesDeepSeekThinkingParameters: false,
                defaultsThinkingEnabled: false,
                defaultReasoningEffort: nil,
                removesHistoricalReasoningContent: false,
                injectMissingToolReasoning: false,
                injectMissingPlainAssistantReasoning: false,
                injectMissingToolOutputs: true,
                deferSystemDeveloperInterruptions: true,
                omitsEmptyAssistantToolContent: true,
                removesThinkingParameters: true,
                setsDisabledReasoningEffortNone: true,
                dropsNullAssistantContent: true,
                dropsToolChoiceAuto: true,
                dropsStreamOptions: false,
                dropsParallelToolCalls: false,
                mergesSystemMessages: true,
                dropsResponseFormat: false,
                dropsNonFunctionTools: false,
                dropsReasoningEffort: false,
                extractsInlineThinkTags: true,
                stickySessionTTLSeconds: PromptCacheSupport.chatCompletionsAPIKeyStickySessionTTLSeconds
            )
        case .auto, .generic:
            return ChatCompletionsProviderStrategy(
                providerID: .generic,
                profile: .generic,
                assemblyMode: .providerStableAssembly,
                forwardsResponsesReasoningEffort: true,
                normalizesDeepSeekThinkingParameters: false,
                defaultsThinkingEnabled: false,
                defaultReasoningEffort: nil,
                removesHistoricalReasoningContent: false,
                injectMissingToolReasoning: false,
                injectMissingPlainAssistantReasoning: false,
                injectMissingToolOutputs: true,
                deferSystemDeveloperInterruptions: true,
                omitsEmptyAssistantToolContent: true,
                removesThinkingParameters: true,
                setsDisabledReasoningEffortNone: true,
                dropsNullAssistantContent: true,
                dropsToolChoiceAuto: true,
                dropsStreamOptions: false,
                dropsParallelToolCalls: false,
                mergesSystemMessages: true,
                dropsResponseFormat: false,
                dropsNonFunctionTools: false,
                dropsReasoningEffort: false,
                extractsInlineThinkTags: true,
                stickySessionTTLSeconds: PromptCacheSupport.chatCompletionsAPIKeyStickySessionTTLSeconds
            )
        }
    }

    var metadata: [String: String] {
        [
            "chat_provider_id": self.providerID.rawValue,
            "chat_compatibility_profile": self.profile.rawValue,
            "chat_provider_forwards_reasoning_effort": self.forwardsResponsesReasoningEffort ? "true" : "false",
            "chat_provider_defaults_thinking": self.defaultsThinkingEnabled ? "true" : "false",
            "chat_provider_default_reasoning_effort": self.defaultReasoningEffort ?? "",
            "chat_provider_removes_thinking_parameters": self.removesThinkingParameters ? "true" : "false",
            "chat_provider_merges_system_messages": self.mergesSystemMessages ? "true" : "false",
            "chat_provider_drops_response_format": self.dropsResponseFormat ? "true" : "false",
            "chat_provider_drops_non_function_tools": self.dropsNonFunctionTools ? "true" : "false",
            "chat_provider_extracts_inline_think_tags": self.extractsInlineThinkTags ? "true" : "false",
        ]
    }
}
